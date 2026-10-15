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
        testADipBelowTheThresholdRestartsTheClock()
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

    private static func testSustainedCPUFiresOnceAfterTheWindow() {
        let (engine, posted, _) = engine()
        engine.observeCPU(percent: 95, at: start)
        engine.observeCPU(percent: 95, at: start.addingTimeInterval(299))
        expect(posted().isEmpty, "four minutes and 59 seconds is not five minutes, got \(posted())")
        engine.observeCPU(percent: 95, at: start.addingTimeInterval(300))
        expect(posted().count == 1, "five sustained minutes fires, got \(posted().count)")
        engine.observeCPU(percent: 99, at: start.addingTimeInterval(400))
        engine.observeCPU(percent: 99, at: start.addingTimeInterval(4_000))
        expect(posted().count == 1, "staying above does not fire again, got \(posted().count)")
    }

    private static func testADipBelowTheThresholdRestartsTheClock() {
        let (engine, posted, _) = engine()
        engine.observeCPU(percent: 95, at: start)
        engine.observeCPU(percent: 50, at: start.addingTimeInterval(200))
        engine.observeCPU(percent: 95, at: start.addingTimeInterval(250))
        engine.observeCPU(percent: 95, at: start.addingTimeInterval(500))
        expect(posted().isEmpty, "250 seconds since the dip is not five minutes, got \(posted())")
        engine.observeCPU(percent: 95, at: start.addingTimeInterval(550))
        expect(posted().count == 1, "five minutes after the dip fires, got \(posted().count)")
    }

    private static func testTheThresholdItselfCounts() {
        let (engine, posted, _) = engine(["cpuAlertPercent": .number(80), "cpuAlertMinutes": .number(1)])
        engine.observeCPU(percent: 80, at: start)
        engine.observeCPU(percent: 80, at: start.addingTimeInterval(60))
        expect(posted().count == 1, "CPU at exactly the threshold counts as above it, got \(posted().count)")
    }

    private static func testTheCPURuleFiresAgainAfterRecovering() {
        let (engine, posted, _) = engine(["cpuAlertMinutes": .number(1)])
        engine.observeCPU(percent: 95, at: start)
        engine.observeCPU(percent: 95, at: start.addingTimeInterval(60))
        engine.observeCPU(percent: 10, at: start.addingTimeInterval(120))
        engine.observeCPU(percent: 95, at: start.addingTimeInterval(180))
        engine.observeCPU(percent: 95, at: start.addingTimeInterval(240))
        expect(posted().count == 2, "a second episode fires again (the host limits how often it is shown), got \(posted().count)")
    }

    private static func testNotificationIdsAreStableAndFiguresLiveInTheBody() {
        let (engine, posted, _) = engine(["cpuAlertMinutes": .number(1)])
        for episode in 0..<2 {
            let base = start.addingTimeInterval(Double(episode) * 1_000)
            engine.observeCPU(percent: 90 + Double(episode) * 5, at: base)
            engine.observeCPU(percent: 90 + Double(episode) * 5, at: base.addingTimeInterval(60))
            engine.observeCPU(percent: 0, at: base.addingTimeInterval(100))
        }
        engine.observeThermal(.serious)
        engine.observeThermal(.nominal)
        engine.observeThermal(.critical)
        let all = posted()
        expect(all.filter { $0.id == CPURuleEngine.cpuRuleID }.count == 2 && all.filter { $0.id == CPURuleEngine.thermalRuleID }.count == 2, "each rule keeps one id however often it fires, got \(all.map(\.id))")
        expect(CPURuleEngine.cpuRuleID != CPURuleEngine.thermalRuleID, "the two rules have different ids")
        expect(all.first?.body.contains("90") == true && all.first?.body.contains("1 minute") == true, "the body says the reading and the window, got \(String(describing: all.first?.body))")
        expect(all.allSatisfy { !$0.id.contains("90") && !$0.id.contains("95") }, "no reading is in an id, got \(all.map(\.id))")
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
        send(snapshot)
        spinRunLoop(for: 0.2) // the feed delivers on the main queue; let the first reading land at `start`
        clock.value = start.addingTimeInterval(61)
        send(snapshot)
        waitUntil(2) { posted().count == 1 }
        expect(posted().count == 1 && posted().first?.id == CPURuleEngine.cpuRuleID, "a minute of 95% on the 1-second feed fires the rule, got \(posted())")
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
