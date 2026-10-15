import Foundation
import SystemBarKit

/// The battery-low and not-charging notifications, run from the battery driver read every collect
/// makes, shown or hidden. Run from `PowerTests.runAll()`.
/// File scope, so the plugins' `@Sendable` clocks can read it.
private let start = Date(timeIntervalSince1970: 1_800_000_000)

@MainActor
enum PowerAlertTests {
    private static let folder = temporaryDirectory()

    static func runAll() {
        defer { try? FileManager.default.removeItem(at: folder) }
        testTheReadingComesFromTheBatteryDriver()
        testAMacWithNoBatteryHasNoReading()
        testBatteryLowFiresOncePerCrossing()
        testBatteryLowRearmsFivePointsAboveOrOnPluggingIn()
        testBatteryLowNeedsTheMacOnBattery()
        testNotChargingFiresAfterTwoMinutes()
        testNotChargingNamesTheDriversReason()
        testNotChargingWithinFivePointsOfTheLimitIsNormal()
        testOptimizedChargingAtEightyIsNormal()
        testNotChargingNeverTimesInsideTheSettleWindow()
        testABriefPauseDoesNotFire()
        testASleepBetweenSamplesRestartsTheWait()
        testNotChargingRearmsOnceItCharges()
        testDisabledRulesNeverFire()
        testNoBatteryNeverFires()
        testSettingsAreValidated()
        testThePluginNotifiesFromHiddenCollects()
        testThePluginNotifiesNotChargingWithTheLimitFile()
        testThePluginShowsAndLogsABadSetting()
    }

    private static func battery(external: Bool, charging: Bool = false, percent: Int, reason: Int = 0) -> BatteryAlertReading {
        BatteryAlertReading(isExternal: external, isCharging: charging, percent: percent, notChargingReason: reason)
    }

    /// Feeds the readings in order, each `seconds` after `start`, and returns the ids posted.
    private static func run(
        _ readings: [(TimeInterval, BatteryAlertReading?)],
        config: PowerAlertConfig = PowerAlertConfig(),
        settling: Set<TimeInterval> = [],
        limit: Int? = nil
    ) -> [PluginNotification] {
        var rules = PowerAlertRules(config: config)
        var posted: [PluginNotification] = []
        for (seconds, reading) in readings {
            let result = rules.evaluating(reading, at: start.addingTimeInterval(seconds), isSettling: settling.contains(seconds), chargeLimit: { limit })
            rules = result.rules
            posted += result.notifications
        }
        return posted
    }

    /// One reading every 10 s from `from` to `to`, as hidden collects make them.
    private static func every10s(from: TimeInterval, to: TimeInterval, _ reading: BatteryAlertReading?) -> [(TimeInterval, BatteryAlertReading?)] {
        stride(from: from, through: to, by: 10).map { ($0, reading) }
    }

    private static func testTheReadingComesFromTheBatteryDriver() {
        let held = BatteryAlertReading(entry: PowerCollector.batteryEntry(PowerFixtures.ioregHeld))
        expect(held == battery(external: true, percent: 80, reason: 16_777_216), "the held capture reads plugged in, not charging, 80%, got \(String(describing: held))")
        let discharging = BatteryAlertReading(entry: PowerCollector.batteryEntry(PowerFixtures.ioregDischarging))
        expect(discharging == battery(external: false, percent: 79), "the discharging fixture reads on battery at 79%, got \(String(describing: discharging))")
        let charging = BatteryAlertReading(entry: PowerCollector.batteryEntry(PowerFixtures.ioregCharging))
        expect(charging?.isCharging == true, "IsCharging is read")
    }

    private static func testAMacWithNoBatteryHasNoReading() {
        expect(BatteryAlertReading(entry: nil) == nil, "no driver entry, no reading")
        expect(BatteryAlertReading(entry: PowerCollector.batteryEntry(PowerDrawFixtures.noBatteryWithInput)) == nil, "an entry with no battery installed is no reading")
        let partial = PowerCollector.batteryEntry("<plist version=\"1.0\"><array><dict><key>CurrentCapacity</key><integer>80</integer></dict></array></plist>")
        expect(BatteryAlertReading(entry: partial) == nil, "an entry that does not say whether the charger is in is no reading")
    }

    private static func testBatteryLowFiresOncePerCrossing() {
        let posted = run([22, 21, 20, 19, 18, 17].enumerated().map { (Double($0.offset) * 10, battery(external: false, percent: $0.element)) })
        expect(posted.map(\.id) == ["power.battery-low"], "crossing below 20% fires once, not at 20% and not again at 18%, got \(posted.map(\.id))")
        expect(posted.first?.body.contains("19%") == true, "the body says the level, got \(String(describing: posted.first?.body))")
    }

    private static func testBatteryLowRearmsFivePointsAboveOrOnPluggingIn() {
        let percents = [19, 24, 19, 25, 19]
        let posted = run(percents.enumerated().map { (Double($0.offset) * 10, battery(external: false, percent: $0.element)) })
        expect(posted.count == 2, "back to 24% re-arms nothing, 25% (five above) does, got \(posted.count)")
        let plugged = run([(0, battery(external: false, percent: 19)), (10, battery(external: true, percent: 19)), (20, battery(external: false, percent: 19))])
        expect(plugged.count == 2, "plugging in re-arms it, so unplugging still below fires again, got \(plugged.count)")
    }

    private static func testBatteryLowNeedsTheMacOnBattery() {
        expect(run([(0, battery(external: true, percent: 10))]).isEmpty, "on the charger a low battery is no warning")
    }

    private static func testNotChargingFiresAfterTwoMinutes() {
        let stuck = battery(external: true, percent: 50)
        let early = run(every10s(from: 0, to: 110, stuck))
        expect(early.isEmpty, "under two minutes is not yet a problem, got \(early.map(\.id))")
        let posted = run(every10s(from: 0, to: 300, stuck))
        expect(posted.map(\.id) == ["power.not-charging"], "two minutes plugged in, not charging, well below the limit fires once, got \(posted.map(\.id))")
        expect(posted.first?.body.contains("50%") == true, "the body says the level, got \(String(describing: posted.first?.body))")
    }

    private static func testNotChargingNamesTheDriversReason() {
        let withReason = run(every10s(from: 0, to: 120, battery(external: true, percent: 50, reason: 4)))
        expect(withReason.first?.body.contains("NotChargingReason 4") == true, "a non-zero reason is in the body, got \(String(describing: withReason.first?.body))")
        let without = run(every10s(from: 0, to: 120, battery(external: true, percent: 50)))
        expect(without.first.map { !$0.body.contains("NotChargingReason") } == true, "a zero reason is left out")
    }

    private static func testNotChargingWithinFivePointsOfTheLimitIsNormal() {
        expect(run(every10s(from: 0, to: 300, battery(external: true, percent: 75)), limit: 80).isEmpty, "five points under an 80% limit is macOS topping up later, not a problem")
        expect(run(every10s(from: 0, to: 300, battery(external: true, percent: 74)), limit: 80).count == 1, "six points under it is")
        expect(run(every10s(from: 0, to: 300, battery(external: true, percent: 96))).isEmpty, "with no limit file a nearly full battery is normal")
    }

    /// Optimized Battery Charging holds the battery at 80% for hours with no limit set, every day.
    private static func testOptimizedChargingAtEightyIsNormal() {
        expect(run(every10s(from: 0, to: 300, battery(external: true, percent: 80))).isEmpty, "held at 80% with no limit file is Optimized Battery Charging, not a problem")
        expect(run(every10s(from: 0, to: 300, battery(external: true, percent: 76)), limit: 90).isEmpty, "a 90% limit still allows the 80% hold")
        let low = run(every10s(from: 0, to: 110, battery(external: true, percent: 70))) + run(every10s(from: 0, to: 120, battery(external: true, percent: 70)))
        expect(low.count == 1, "70% on a charger, not charging, fires after two minutes and not before, got \(low.count)")
        expect(low.first?.body.contains("well short of 80%") == true, "the body names the 80% the rule measures from, got \(String(describing: low.first?.body))")
        let lowLimit = run(every10s(from: 0, to: 120, battery(external: true, percent: 54)), limit: 60)
        expect(lowLimit.first?.body.contains("well short of its 60% charge limit") == true, "a limit under 80% is the target, got \(String(describing: lowLimit.first?.body))")
    }

    private static func testNotChargingNeverTimesInsideTheSettleWindow() {
        let stuck = battery(external: true, percent: 50)
        let settling = Set(stride(from: 0.0, through: 90, by: 10))
        let posted = run(every10s(from: 0, to: 300, stuck), settling: settling)
        expect(posted.count == 1, "it still fires once the telemetry settles")
        let tooSoon = run(every10s(from: 0, to: 200, stuck), settling: settling)
        expect(tooSoon.isEmpty, "the two minutes start after the settle window, so 200 s is too soon, got \(tooSoon.map(\.id))")
    }

    private static func testABriefPauseDoesNotFire() {
        let readings = every10s(from: 0, to: 60, battery(external: true, percent: 50))
            + [(70, battery(external: true, charging: true, percent: 50))]
            + every10s(from: 80, to: 150, battery(external: true, percent: 50))
        expect(run(readings).isEmpty, "pauses shorter than two minutes, with charging between, never fire")
    }

    private static func testASleepBetweenSamplesRestartsTheWait() {
        let stuck = battery(external: true, percent: 50)
        let afterSleep = run([(0, stuck), (600, stuck)])
        expect(afterSleep.isEmpty, "a sample ten minutes after the last (the Mac slept) has not watched two minutes")
        expect(run([(0, stuck)] + every10s(from: 600, to: 720, stuck)).count == 1, "two watched minutes after waking do")
    }

    private static func testNotChargingRearmsOnceItCharges() {
        let readings = every10s(from: 0, to: 130, battery(external: true, percent: 50))
            + [(140, battery(external: true, charging: true, percent: 51))]
            + every10s(from: 150, to: 280, battery(external: true, percent: 51))
        expect(run(readings).count == 2, "charging again re-arms it, got \(run(readings).count)")
    }

    private static func testDisabledRulesNeverFire() {
        var config = PowerAlertConfig()
        config.notifyBatteryLow = false
        config.notifyNotCharging = false
        let readings = [(0.0, battery(external: false, percent: 5))] + every10s(from: 10, to: 300, battery(external: true, percent: 50))
        expect(run(readings, config: config).isEmpty, "turned off, neither rule fires")
    }

    private static func testNoBatteryNeverFires() {
        expect(run(every10s(from: 0, to: 300, nil)).isEmpty, "a Mac with no battery never fires")
    }

    private static func testSettingsAreValidated() {
        let defaults = PowerAlertConfig.parse(.empty)
        expect(defaults.config == PowerAlertConfig() && defaults.problems.isEmpty, "no settings is every default")
        expect(PowerAlertConfig().batteryLowPercent == 20 && PowerAlertConfig().notifyBatteryLow && PowerAlertConfig().notifyNotCharging, "both rules on, 20% by default")
        let good = PowerAlertConfig.parse(PluginSettings(values: ["batteryLowPercent": .number(15), "notifyNotCharging": .bool(false)]))
        expect(good.config.batteryLowPercent == 15 && !good.config.notifyNotCharging && good.problems.isEmpty, "good values are used")
        for bad: PluginSettings.Value in [.number(0), .number(100), .number(20.5), .string("20")] {
            let parsed = PowerAlertConfig.parse(PluginSettings(values: ["batteryLowPercent": bad]))
            expect(parsed.config.batteryLowPercent == 20 && parsed.problems.count == 1, "batteryLowPercent \(bad) keeps 20 and says so, got \(parsed)")
        }
        let notAFlag = PowerAlertConfig.parse(PluginSettings(values: ["notifyBatteryLow": .string("no")]))
        expect(notAFlag.config.notifyBatteryLow && notAFlag.problems.first?.contains("notifyBatteryLow") == true, "a flag that is not true or false keeps the default and is named")
    }

    private static func host(
        ioreg: String, settings: PluginSettings = .empty, log: LogRecorder = LogRecorder()
    ) -> (HostServices, @Sendable () -> [PluginNotification]) {
        let recorder = HostServices.recordingNotifications()
        let host = HostServices(
            homeDirectory: "/tmp/systembar-tests",
            processes: Feed(initial: ProcessSummary()), fastStats: Feed(initial: FastStatsSnapshot()),
            runner: { path, _, _, _ in
                CommandOutput(output: path == PowerCollector.ioregPath ? ioreg : "", error: "", status: 0, didTimeout: false)
            },
            log: { log.record($0) }, settings: settings,
            dataDirectory: folder.appendingPathComponent(UUID().uuidString),
            notify: recorder.notify
        )
        return (host, recorder.posted)
    }

    private static func testThePluginNotifiesFromHiddenCollects() {
        let low = PowerFixtures.ioreg(external: false, fullyCharged: false, charging: false, capacity: 15, notChargingReason: 0)
        let (host, posted) = host(ioreg: low)
        let plugin = PowerPlugin(host: host, clock: { start })
        plugin.collect()
        plugin.collect()
        expect(posted().map(\.id) == ["power.battery-low"], "a hidden collect at 15% on battery notifies once, got \(posted().map(\.id))")
    }

    private static func testThePluginNotifiesNotChargingWithTheLimitFile() {
        let stuck = PowerFixtures.ioreg(external: true, fullyCharged: false, charging: false, capacity: 74, notChargingReason: 4)
        let (host, posted) = host(ioreg: stuck)
        let clock = LockedDate(start)
        let limitFile = folder.appendingPathComponent("limit.plist")
        try? PowerChargeLimitFixtures.captured.write(to: limitFile)
        let plugin = PowerPlugin(host: host, clock: { clock.value }, chargeLimitFile: limitFile)
        for _ in 0...12 {
            plugin.collect()
            clock.advance(by: 10)
        }
        expect(posted().map(\.id) == ["power.not-charging"], "74% under the captured 80% limit, not charging for two minutes, notifies, got \(posted().map(\.id))")
        expect(posted().first?.body.contains("80%") == true, "and names the limit, got \(String(describing: posted().first?.body))")
    }

    private static func testThePluginShowsAndLogsABadSetting() {
        let log = LogRecorder()
        let (host, _) = host(ioreg: "", settings: PluginSettings(values: ["batteryLowPercent": .string("low")]), log: log)
        let plugin = PowerPlugin(host: host, clock: { start })
        expect(plugin.settingsProblems.count == 1 && plugin.settingsProblems[0].contains("batteryLowPercent"), "the tab shows the bad setting, got \(plugin.settingsProblems)")
        expect(log.messages.contains { $0.contains("batteryLowPercent") }, "and logs it, got \(log.messages)")
    }
}
