import Foundation
import SystemBarKit

/// The Network tab's notification rules: their settings, each rule firing once on crossing into
/// its condition, a no-route round never counting as an outage, and the plugin posting through a
/// recording host while the tab is hidden.
@MainActor
enum NetworkRulesTests {
    static func runAll() {
        testSettingsDefaults()
        testSettingsAcceptValuesInRange()
        testSettingsKeepTheDefaultForABadValueAndSaySo()
        testUnreachableFiresOnceAtTheNthFailure()
        testUnreachableIgnoresNoRouteRounds()
        testUnreachableStartsAgainAfterASleep()
        testUnreachableCanBeTurnedOff()
        testSlowInternetFiresOnceTheWindowIsFull()
        testSlowInternetFiresAgainOnlyAfterRecovering()
        testSlowInternetIgnoresFailuresAndCanBeTurnedOff()
        testPluginPostsWhileHidden()
        testPluginPostsNothingWhenThereIsNoRoute()
        testPluginSaysNoRouterFoundWhenThereIsNone()
        testPluginReportsBadRuleSettings()
    }

    // MARK: - Settings

    private static func read(_ values: [String: PluginSettings.Value]) -> (settings: NetworkRuleSettings, problems: [String]) {
        NetworkRuleSettings.read(PluginSettings(values: values))
    }

    private static func testSettingsDefaults() {
        let (settings, problems) = NetworkRuleSettings.read(.empty)
        expect(settings == NetworkRuleSettings(), "no settings, the defaults")
        expect(settings.notifyUnreachable && settings.unreachablePings == 3, "unreachable after 3 failed pings, on")
        expect(settings.notifySlow && settings.slowMilliseconds == 200 && settings.slowMinutes == 5, "slow above 200 ms for 5 minutes, on")
        expect(problems.isEmpty, "and nothing to report")
    }

    private static func testSettingsAcceptValuesInRange() {
        let (settings, problems) = read([
            "notifyUnreachable": .bool(false), "unreachablePings": .number(12),
            "notifySlowInternet": .bool(false), "slowInternetMilliseconds": .number(450), "slowInternetMinutes": .number(15),
        ])
        expect(!settings.notifyUnreachable && settings.unreachablePings == 12, "got \(settings)")
        expect(!settings.notifySlow && settings.slowMilliseconds == 450 && settings.slowMinutes == 15, "got \(settings)")
        expect(problems.isEmpty, "valid values are not problems, got \(problems)")
    }

    private static func testSettingsKeepTheDefaultForABadValueAndSaySo() {
        let bad: [(String, PluginSettings.Value)] = [
            ("notifyUnreachable", .string("yes")), ("unreachablePings", .number(0)), ("unreachablePings", .number(2.5)),
            ("unreachablePings", .number(721)), ("notifySlowInternet", .number(1)), ("slowInternetMilliseconds", .number(0)),
            ("slowInternetMilliseconds", .string("200")), ("slowInternetMinutes", .number(61)), ("slowInternetMinutes", .number(.nan)),
        ]
        for (key, value) in bad {
            let (settings, problems) = read([key: value])
            expect(settings == NetworkRuleSettings(), "\(key) = \(value) keeps every default, got \(settings)")
            expect(problems.count == 1 && problems[0].hasPrefix("settings: \"\(key)\" must be"), "and names the key, got \(problems)")
        }
    }

    // MARK: - Internet unreachable

    private static let start = Date(timeIntervalSince1970: 10_000)

    private static func round(_ index: Int, router: LatencyPoint = .reply(2), internet: LatencyPoint) -> LatencySample {
        LatencySample(at: start.addingTimeInterval(TimeInterval(index) * NetworkSampling.pingInterval), router: router, internet: internet)
    }

    /// Runs `rounds` through the rules from `settings`, returning every notification's id in order.
    private static func posted(_ rounds: [LatencySample], settings: NetworkRuleSettings = NetworkRuleSettings()) -> [PluginNotification] {
        var rules = NetworkRules(settings: settings)
        var posted: [PluginNotification] = []
        for sample in rounds {
            let result = rules.checking(sample, internetAddress: "1.1.1.1")
            rules = result.rules
            posted += result.notifications
        }
        return posted
    }

    private static let failed = LatencyPoint.failed("timed out")

    private static func testUnreachableFiresOnceAtTheNthFailure() {
        let twoFailures = posted((0..<2).map { round($0, internet: failed) })
        expect(twoFailures.isEmpty, "two failed pings are not yet an outage, got \(twoFailures)")
        var onePing = NetworkRuleSettings()
        onePing.unreachablePings = 1
        let single = posted([round(0, internet: failed)], settings: onePing)
        expect(single.first?.body == "A ping to 1.1.1.1 failed. \(LatencyDiagnosis.internet.text).", "one ping reads in the singular, got \(String(describing: single.first?.body))")

        let outage = posted((0..<10).map { round($0, internet: failed) })
        expect(outage.map(\.id) == ["network.internet-unreachable"], "the third fires, and the rest of the outage stays quiet, got \(outage.map(\.id))")
        expect(outage.first?.title == "Internet unreachable", "got \(String(describing: outage.first?.title))")
        expect(outage.first?.body == "3 pings in a row to 1.1.1.1 failed. \(LatencyDiagnosis.internet.text).", "the body says how many and what is likely at fault, got \(String(describing: outage.first?.body))")

        let twice = posted((0..<3).map { round($0, internet: failed) } + [round(3, internet: .reply(20))] + (4..<7).map { round($0, internet: failed) })
        expect(twice.map(\.id) == ["network.internet-unreachable", "network.internet-unreachable"], "a reply ends the outage, so the next one fires again, got \(twice.map(\.id))")
        expect(twice[0].id == twice[1].id, "with the same id, so the host's cooldown can hold the second")
    }

    /// No IPv4 route means nothing was sent; the connection may well work over IPv6.
    private static func testUnreachableIgnoresNoRouteRounds() {
        let noRoute = posted((0..<10).map { round($0, router: .unknown, internet: .unknown) })
        expect(noRoute.isEmpty, "rounds with no route never count as an outage, got \(noRoute)")
        let broken = posted([round(0, internet: failed), round(1, internet: failed), round(2, router: .unknown, internet: .unknown), round(3, internet: failed)])
        expect(broken.isEmpty, "and they break a run of failures rather than extend it, got \(broken)")
    }

    /// Two failures before the lid closed and one after waking are not three in a row.
    private static func testUnreachableStartsAgainAfterASleep() {
        let asleep = 120
        let woke = posted([round(0, internet: failed), round(1, internet: failed), round(1 + asleep, internet: failed)])
        expect(woke.isEmpty, "a gap of many rounds ends the run, got \(woke.map(\.id))")
        let after = posted([round(0, internet: failed), round(1, internet: failed)] + (0..<3).map { round(1 + asleep + $0, internet: failed) })
        expect(after.map(\.id) == ["network.internet-unreachable"], "three in a row after waking still fire, got \(after.map(\.id))")
        let late = posted((0..<3).map { round($0 * 2, internet: failed) })
        expect(late.map(\.id) == ["network.internet-unreachable"], "a round or two late is still in a row, got \(late.map(\.id))")
    }

    private static func testUnreachableCanBeTurnedOff() {
        var off = NetworkRuleSettings()
        off.notifyUnreachable = false
        expect(posted((0..<10).map { round($0, internet: failed) }, settings: off).isEmpty, "notifyUnreachable false posts nothing")
    }

    // MARK: - Slow internet

    /// Five minutes of 5-second rounds is 60; the window counts as full once it spans that.
    private static let fullWindow = Int(5 * 60 / NetworkSampling.pingInterval)

    private static func testSlowInternetFiresOnceTheWindowIsFull() {
        let early = posted((0..<(fullWindow - 2)).map { round($0, internet: .reply(400)) })
        expect(early.isEmpty, "slow for less than 5 minutes is not yet slow, got \(early)")

        let slow = posted((0..<(fullWindow + 40)).map { round($0, internet: .reply(400)) })
        expect(slow.map(\.id) == ["network.slow-internet"], "a full window above the limit fires once, got \(slow.map(\.id))")
        expect(slow.first?.title == "Slow internet", "got \(String(describing: slow.first?.title))")
        expect(slow.first?.body == "Pings to 1.1.1.1 averaged 400 ms over the last 5 minutes, above your 200 ms limit.", "got \(String(describing: slow.first?.body))")

        let fine = posted((0..<(fullWindow + 40)).map { round($0, internet: .reply(150)) })
        expect(fine.isEmpty, "below the limit is never slow, got \(fine)")
    }

    private static func testSlowInternetFiresAgainOnlyAfterRecovering() {
        let slowFor = (0..<(fullWindow + 1)).map { round($0, internet: .reply(400)) }
        let recovered = (0..<(fullWindow + 1)).map { round(fullWindow + 1 + $0, internet: .reply(30)) }
        let slowAgain = (0..<(fullWindow + 1)).map { round(2 * (fullWindow + 1) + $0, internet: .reply(400)) }
        expect(posted(slowFor + recovered + slowAgain).map(\.id) == ["network.slow-internet", "network.slow-internet"], "once per slow spell")
    }

    private static func testSlowInternetIgnoresFailuresAndCanBeTurnedOff() {
        let mixed = (0..<(fullWindow + 1)).map { round($0, internet: $0.isMultiple(of: 2) ? failed : .reply(400)) }
        var quietOutage = NetworkRuleSettings()
        quietOutage.notifyUnreachable = false
        expect(posted(mixed, settings: quietOutage).map(\.id) == ["network.slow-internet"], "failed pings are left out of the average, not counted as fast or slow")
        let allFailed = (0..<(fullWindow + 1)).map { round($0, internet: failed) }
        expect(posted(allFailed, settings: quietOutage).isEmpty, "with no replies there is no latency to judge")
        var off = NetworkRuleSettings()
        off.notifySlow = false
        expect(posted((0..<(fullWindow + 1)).map { round($0, internet: .reply(400)) }, settings: off).isEmpty, "notifySlowInternet false posts nothing")
    }

    // MARK: - The plugin

    private static func notifyingHost(settings: PluginSettings = .empty) -> (host: HostServices, posted: @Sendable () -> [PluginNotification]) {
        let recording = HostServices.recordingNotifications()
        let host = HostServices(
            homeDirectory: "/tmp/systembar-tests",
            processes: Feed(initial: ProcessSummary()),
            fastStats: Feed(initial: FastStatsSnapshot()),
            runner: { _, _, _, _ in CommandOutput(output: "", error: "", status: 0, didTimeout: false) },
            log: { _ in },
            settings: settings,
            dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("systembar-tests-data"),
            notify: recording.notify
        )
        return (host, recording.posted)
    }

    private static func probes(gateway: String?, ping: @escaping Pinger) -> NetworkProbes {
        NetworkProbes(readWiFi: { nil }, ping: ping, gateway: { gateway }, now: { Date() })
    }

    private static func testPluginPostsWhileHidden() {
        let (host, posted) = notifyingHost()
        let plugin = NetworkPlugin(host: host, probes: probes(gateway: "192.168.1.1") { address, _ in
            address == "192.168.1.1" ? .reply(milliseconds: 2) : .timeout
        })
        for _ in 0..<5 { plugin.collect() }
        expect(posted().map(\.id) == ["network.internet-unreachable"], "the hidden tab's pings drive the rule, got \(posted().map(\.id))")
        expect(posted().first?.body.contains(LatencyDiagnosis.internet.text) == true, "and say the router still answers")
    }

    private static func testPluginPostsNothingWhenThereIsNoRoute() {
        let (host, posted) = notifyingHost()
        let plugin = NetworkPlugin(host: host, probes: probes(gateway: nil) { _, _ in .noRoute("Network is unreachable") })
        for _ in 0..<5 { plugin.collect() }
        expect(posted().isEmpty, "no IPv4 route is not an outage, got \(posted())")
    }

    /// A full-tunnel VPN: no router found, the internet pinged and failing. The router was never
    /// pinged, so the notification must not say it failed to answer.
    private static func testPluginSaysNoRouterFoundWhenThereIsNone() {
        let (host, posted) = notifyingHost()
        let plugin = NetworkPlugin(host: host, probes: probes(gateway: nil) { _, _ in .timeout })
        for _ in 0..<3 { plugin.collect() }
        expect(posted().first?.body.contains(LatencyDiagnosis.noRouter.text) == true, "got \(String(describing: posted().first?.body))")
        expect(posted().first?.body.contains("Neither the router") == false, "not that the router failed")
    }

    private static func testPluginReportsBadRuleSettings() {
        let (host, _) = notifyingHost(settings: PluginSettings(values: ["unreachablePings": .string("three")]))
        let plugin = NetworkPlugin(host: host, probes: .fake())
        expect(plugin.latency.settingsProblems.contains { $0.contains("unreachablePings") }, "the tab shows what is wrong, got \(plugin.latency.settingsProblems)")
    }
}
