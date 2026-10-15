import Foundation
import SystemBarKit

/// Tests for the CPU tab's notification rules: sustained high CPU, and a serious thermal state.
/// Every test posts through a recording host; none posts a real notification.
@MainActor
enum CPURulesTests {
    static func runAll() {
        testSettingsDefaults()
        testSettingsAcceptValidValues()
        testSettingsRejectBadValuesAndSaySo()
        testSustainedCPUFiresOnceAfterTheWindow()
        testShortDipsInARealLoadStillFire()
        testABriefSpikeInAnIdleWindowDoesNotFire()
        testAGapInTheReadingsRestartsTheWindow()
        testTheWindowNeedsTheWholeSpanBeforeItCanFire()
        testTheThresholdItselfCounts()
        testTheCPURuleFiresAgainAfterRecovering()
        testNotificationIdsAreStableAndFiguresLiveInTheBody()
        testThermalFiresOnCrossingIntoSeriousOrWorse()
        testStartingHotIsNotACrossing()
        testDisabledRulesPostNothing()
        testThePluginFeedsTheCPURule()
    }

    private static let start = Date(timeIntervalSince1970: 1_000_000)

    private static func engine(
        _ values: [String: PluginSettings.Value] = [:],
        thermal: ProcessInfo.ThermalState = .nominal
    ) -> (engine: CPURuleEngine, posted: @Sendable () -> [PluginNotification], log: LogRecorder) {
        let (notify, posted) = HostServices.recordingNotifications()
        let log = LogRecorder()
        let host = HostServices(
            homeDirectory: "/tmp/systembar-tests",
            processes: Feed(initial: ProcessSummary()),
            fastStats: Feed(initial: FastStatsSnapshot()),
            runner: { _, _, _, _ in CommandOutput(output: "", error: "", status: 0, didTimeout: false) },
            log: { log.record($0) },
            settings: PluginSettings(values: values),
            dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("systembar-tests-data"),
            notify: notify
        )
        return (CPURuleEngine(host: host, thermalState: thermal), posted, log)
    }

    private static func testSettingsDefaults() {
        let parsed = CPURuleSettings.parse(.empty)
        expect(parsed.settings == CPURuleSettings(isCPUAlertOn: true, cpuPercent: 90, cpuMinutes: 5, isThermalAlertOn: true), "with no settings both rules are on at 90% for 5 minutes, got \(parsed.settings)")
        expect(parsed.problems.isEmpty, "no settings is not a problem, got \(parsed.problems)")
    }

    private static func testSettingsAcceptValidValues() {
        let parsed = CPURuleSettings.parse(PluginSettings(values: [
            "cpuAlert": .bool(false), "cpuAlertPercent": .number(75), "cpuAlertMinutes": .number(10), "thermalAlert": .bool(false),
        ]))
        expect(parsed.settings == CPURuleSettings(isCPUAlertOn: false, cpuPercent: 75, cpuMinutes: 10, isThermalAlertOn: false), "valid settings are taken as given, got \(parsed.settings)")
        expect(parsed.problems.isEmpty, "valid settings raise no problem, got \(parsed.problems)")
    }

    private static func testSettingsRejectBadValuesAndSaySo() {
        let cases: [(String, PluginSettings.Value)] = [
            ("cpuAlertPercent", .number(0)), ("cpuAlertPercent", .number(101)), ("cpuAlertPercent", .string("90")),
            ("cpuAlertMinutes", .number(0)), ("cpuAlertMinutes", .number(1_000)), ("cpuAlertMinutes", .number(.nan)),
            ("cpuAlert", .string("yes")), ("thermalAlert", .number(1)),
        ]
        for (key, value) in cases {
            let parsed = CPURuleSettings.parse(PluginSettings(values: [key: value]))
            expect(parsed.settings == CPURuleSettings.parse(.empty).settings, "a bad \(key) \(value) keeps the default, got \(parsed.settings)")
            expect(parsed.problems.count == 1 && parsed.problems[0].contains(key), "a bad \(key) is named in one problem, got \(parsed.problems)")
        }
    }

    /// One reading a second from `from` up to and including `to` seconds after `start`, the way the
    /// host's feed delivers them; `percent` answers for each second.
    private static func feed(_ engine: CPURuleEngine, from: Int, to: Int, _ percent: (Int) -> Double) {
        for second in from...to { engine.observeCPU(percent: percent(second), at: start.addingTimeInterval(Double(second))) }
    }

    private static func testSustainedCPUFiresOnceAfterTheWindow() {
        let (engine, posted, _) = engine()
        feed(engine, from: 0, to: 299) { _ in 95 }
        expect(posted().isEmpty, "four minutes and 59 seconds of readings do not cover five minutes, got \(posted())")
        feed(engine, from: 300, to: 300) { _ in 95 }
        expect(posted().count == 1, "five minutes of 95% fires, got \(posted().count)")
        feed(engine, from: 301, to: 4_000) { _ in 99 }
        expect(posted().count == 1, "staying above does not fire again, got \(posted().count)")
    }

    private static func testShortDipsInARealLoadStillFire() {
        // A build: 92-100% with a second or two at 75% between jobs. The mean is well over 90.
        let (engine, posted, _) = engine()
        feed(engine, from: 0, to: 300) { second in second % 10 == 9 ? 75 : (second % 2 == 0 ? 100 : 92) }
        expect(posted().count == 1, "a heavy load with brief dips to 75% fires, got \(posted().count)")
        expect(posted().first?.body.contains("averaged") == true, "the body says what was measured, got \(String(describing: posted().first?.body))")
    }

    private static func testABriefSpikeInAnIdleWindowDoesNotFire() {
        let (engine, posted, _) = engine()
        feed(engine, from: 0, to: 300) { second in (100...129).contains(second) ? 100 : 5 }
        expect(posted().isEmpty, "a 30 second spike to 100% in five idle minutes averages about 15%, got \(posted())")
    }

    private static func testAGapInTheReadingsRestartsTheWindow() {
        // The popover closed: the feed stopped, and its first reading afterwards describes the
        // whole closed interval, so none of it can count towards "stayed high".
        let (engine, posted, _) = engine(["cpuAlertMinutes": .number(1)])
        feed(engine, from: 0, to: 40) { _ in 95 }
        feed(engine, from: 600, to: 630) { _ in 95 }
        expect(posted().isEmpty, "30 seconds after a long gap is not a minute, got \(posted())")
        feed(engine, from: 631, to: 660) { _ in 95 }
        expect(posted().count == 1, "a full minute of readings after the gap fires, got \(posted().count)")
    }

    private static func testTheWindowNeedsTheWholeSpanBeforeItCanFire() {
        let (engine, posted, _) = engine(["cpuAlertMinutes": .number(1)])
        engine.observeCPU(percent: 100, at: start)
        engine.observeCPU(percent: 100, at: start.addingTimeInterval(3))
        expect(posted().isEmpty, "three seconds at 100% is not a minute, got \(posted())")
    }

    private static func testTheThresholdItselfCounts() {
        let (engine, posted, _) = engine(["cpuAlertPercent": .number(80), "cpuAlertMinutes": .number(1)])
        feed(engine, from: 0, to: 60) { _ in 80 }
        expect(posted().count == 1, "an average at exactly the threshold counts as above it, got \(posted().count)")
    }

    private static func testTheCPURuleFiresAgainAfterRecovering() {
        let (engine, posted, _) = engine(["cpuAlertMinutes": .number(1)])
        feed(engine, from: 0, to: 60) { _ in 95 }
        feed(engine, from: 61, to: 180) { _ in 10 }
        feed(engine, from: 181, to: 260) { _ in 95 }
        expect(posted().count == 2, "a second episode fires again (the host limits how often it is shown), got \(posted().count)")
    }

    private static func testNotificationIdsAreStableAndFiguresLiveInTheBody() {
        let (engine, posted, _) = engine(["cpuAlertMinutes": .number(1)])
        feed(engine, from: 0, to: 60) { _ in 96 }
        feed(engine, from: 61, to: 200) { _ in 0 }
        feed(engine, from: 1_000, to: 1_060) { _ in 99 }
        engine.observeThermal(.serious)
        engine.observeThermal(.nominal)
        engine.observeThermal(.critical)
        let all = posted()
        expect(all.filter { $0.id == CPURuleEngine.cpuRuleID }.count == 2 && all.filter { $0.id == CPURuleEngine.thermalRuleID }.count == 2, "each rule keeps one id however often it fires, got \(all.map(\.id))")
        expect(CPURuleEngine.cpuRuleID != CPURuleEngine.thermalRuleID, "the two rules have different ids")
        let first = all.first?.body ?? ""
        expect(first.contains("96") && first.contains("last minute"), "the body says the average and the window, got \(first)")
        expect(all.allSatisfy { !$0.id.contains("96") && !$0.id.contains("99") }, "no reading is in an id, got \(all.map(\.id))")
    }

    private static func testThermalFiresOnCrossingIntoSeriousOrWorse() {
        let (engine, posted, _) = engine()
        engine.observeThermal(.fair)
        expect(posted().isEmpty, "fair is not serious")
        engine.observeThermal(.serious)
        expect(posted().count == 1, "crossing into serious fires, got \(posted().count)")
        engine.observeThermal(.critical)
        expect(posted().count == 1, "serious to critical is still inside the condition, got \(posted().count)")
        engine.observeThermal(.fair)
        engine.observeThermal(.critical)
        expect(posted().count == 2, "recovering and crossing again fires again, got \(posted().count)")
    }

    private static func testStartingHotIsNotACrossing() {
        let (engine, posted, _) = engine(thermal: .serious)
        engine.observeThermal(.serious)
        expect(posted().isEmpty, "a Mac that is already serious when the tab loads has not crossed into it, got \(posted())")
    }

    private static func testDisabledRulesPostNothing() {
        let (engine, posted, _) = engine(["cpuAlert": .bool(false), "thermalAlert": .bool(false), "cpuAlertMinutes": .number(1)])
        engine.observeCPU(percent: 100, at: start)
        engine.observeCPU(percent: 100, at: start.addingTimeInterval(600))
        engine.observeThermal(.critical)
        expect(posted().isEmpty, "switched-off rules post nothing, got \(posted())")
    }

    private static func testThePluginFeedsTheCPURule() {
        let (notify, posted) = HostServices.recordingNotifications()
        var snapshot = FastStatsSnapshot()
        snapshot.cpuUsagePercent = 95
        let (fastStats, send) = Feed.forTesting(initial: snapshot)
        let clock = ClockBox(start)
        let host = HostServices(
            homeDirectory: "/tmp/systembar-tests",
            processes: Feed(initial: ProcessSummary()),
            fastStats: fastStats,
            runner: { _, _, _, _ in CommandOutput(output: "", error: "", status: 0, didTimeout: false) },
            log: { _ in },
            settings: PluginSettings(values: ["cpuAlertMinutes": .number(1)]),
            dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("systembar-tests-data"),
            notify: notify
        )
        let plugin = CPUPlugin(host: host, now: { clock.value })
        // Readings five seconds apart, the widest gap the rule treats as continuous. The feed
        // delivers on the main queue, so each one is let land before the clock moves.
        for step in 0...13 {
            clock.value = start.addingTimeInterval(Double(step) * 5)
            send(snapshot)
            spinRunLoop(for: 0.05)
        }
        waitUntil(2) { posted().count == 1 }
        expect(posted().count == 1 && posted().first?.id == CPURuleEngine.cpuRuleID, "a minute of 95% on the feed fires the rule, got \(posted())")
        _ = plugin
    }
}

/// A clock a test moves by hand.
final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date
    init(_ date: Date) { stored = date }
    var value: Date {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
