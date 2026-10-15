import Foundation
import SystemBarKit

/// The Memory tab's notification rules: what each setting means, when a rule fires, and that it
/// fires on crossing into its condition rather than on every sample while it stays true.
@MainActor
enum MemoryAlertTests {
    static func runAll() {
        testDefaultsWhenSettingsAreEmpty()
        testSettingsAreRead()
        testBadSettingsKeepDefaultsAndAreReported()
        testPressureFiresOnCrossingIntoWarning()
        testPressureEscalatesToCritical()
        testPressureFiresAgainAfterRecovery()
        testPressureRearmsOnlyAtNormal()
        testUnknownPressureChangesNothing()
        testPressureRuleCanBeTurnedOff()
        testSwapFiresAfterSustainedRate()
        testBriefSwapBurstDoesNotFire()
        testSwapFiresOnceWhileItStaysHigh()
        testSwapRuleCanBeTurnedOff()
        testSwapVerdictDoesNotDependOnCadence()
        testSwapAfterALongGapFiresNothing()
        testQuietShareOfTheWindowIsAllowed()
        testNotificationIdsAreStable()
        testPluginPostsThroughTheHost()
    }

    private static let mb: UInt64 = 1_048_576
    private static func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    private static func reading(_ seconds: TimeInterval, pressure: MemoryPressureLevel? = .normal, swapped: UInt64 = 0) -> MemoryReading {
        MemoryReading(
            memory: MemorySnapshot(total: 64 * 1_073_741_824, used: 40 * 1_073_741_824, swapInsTotal: swapped / 2, swapOutsTotal: swapped - swapped / 2),
            gpu: GPUSnapshot(), pressure: pressure, sampledAt: at(seconds)
        )
    }

    /// Runs readings through the rules, returning every notification posted, in order.
    private static func post(_ readings: [MemoryReading], config: MemoryAlertConfig = MemoryAlertConfig()) -> [PluginNotification] {
        var rules = MemoryAlertRules(config: config)
        var posted: [PluginNotification] = []
        for reading in readings {
            let result = rules.evaluating(reading)
            rules = result.rules
            posted += result.notifications
        }
        return posted
    }

    private static func testDefaultsWhenSettingsAreEmpty() {
        let parsed = MemoryAlertConfig.parse(.empty)
        expect(parsed.problems.isEmpty, "no settings is not a problem, got \(parsed.problems)")
        expect(parsed.config.notifyPressure && parsed.config.notifySwap, "both rules are on by default")
        expect(parsed.config.swapMegabytesPerMinute == 100 && parsed.config.swapMinutes == 5, "swapping above 100 MB a minute for 5 minutes by default")
    }

    private static func testSettingsAreRead() {
        let settings = PluginSettings(values: [
            "notifyPressure": .bool(false), "notifySwap": .bool(true),
            "swapMegabytesPerMinute": .number(250), "swapMinutes": .number(10),
        ])
        let parsed = MemoryAlertConfig.parse(settings)
        expect(parsed.problems.isEmpty, "valid settings raise no problem, got \(parsed.problems)")
        expect(!parsed.config.notifyPressure && parsed.config.notifySwap, "each flag is read")
        expect(parsed.config.swapMegabytesPerMinute == 250 && parsed.config.swapMinutes == 10, "and each number")
    }

    private static func testBadSettingsKeepDefaultsAndAreReported() {
        let settings = PluginSettings(values: [
            "notifyPressure": .string("no"), "swapMegabytesPerMinute": .number(0), "swapMinutes": .number(-3),
        ])
        let parsed = MemoryAlertConfig.parse(settings)
        expect(parsed.config == MemoryAlertConfig(), "a misspelt or out-of-range value keeps the default")
        expect(parsed.problems.count == 3, "and each is reported by name, got \(parsed.problems)")
        expect(parsed.problems.allSatisfy { $0.hasPrefix("settings: \"") }, "in the tabs' usual wording, got \(parsed.problems)")
        let huge = MemoryAlertConfig.parse(PluginSettings(values: ["swapMinutes": .number(10_000), "swapMegabytesPerMinute": .number(.infinity)]))
        expect(huge.problems.count == 2, "a number past the sane range, or not finite, is refused, got \(huge.problems)")
    }

    private static func testPressureFiresOnCrossingIntoWarning() {
        let posted = post([reading(0), reading(3), reading(6, pressure: .warning), reading(9, pressure: .warning), reading(12, pressure: .warning)])
        expect(posted.map(\.id) == ["memory.pressure.warning"], "one notification when pressure crosses into warning, not one per sample, got \(posted.map(\.id))")
    }

    private static func testPressureEscalatesToCritical() {
        let posted = post([reading(0, pressure: .warning), reading(3, pressure: .critical), reading(6, pressure: .critical)])
        expect(posted.map(\.id) == ["memory.pressure.warning", "memory.pressure.critical"], "warning then critical each fire once, got \(posted.map(\.id))")
        let down = post([reading(0, pressure: .critical), reading(3, pressure: .warning)])
        expect(down.map(\.id) == ["memory.pressure.critical"], "easing from critical to warning is not news, got \(down.map(\.id))")
    }

    /// Re-arming only at Normal keeps a level that flickers between warning and critical to one
    /// notification each, instead of one per flicker.
    private static func testPressureRearmsOnlyAtNormal() {
        let flicker = post([reading(0, pressure: .critical), reading(3, pressure: .warning), reading(6, pressure: .critical), reading(9, pressure: .warning)])
        expect(flicker.map(\.id) == ["memory.pressure.critical"], "critical, warning, critical again without passing Normal fires once, got \(flicker.map(\.id))")
        let rearmed = post([reading(0, pressure: .critical), reading(3, pressure: .warning), reading(6), reading(9, pressure: .critical)])
        expect(rearmed.map(\.id) == ["memory.pressure.critical", "memory.pressure.critical"], "after Normal the next rise fires again, got \(rearmed.map(\.id))")
    }

    private static func testPressureFiresAgainAfterRecovery() {
        let posted = post([reading(0, pressure: .warning), reading(3), reading(6, pressure: .warning)])
        expect(posted.count == 2, "after pressure returns to normal, the next crossing fires again, got \(posted.count)")
    }

    private static func testUnknownPressureChangesNothing() {
        let posted = post([reading(0, pressure: .warning), reading(3, pressure: nil), reading(6, pressure: .warning)])
        expect(posted.count == 1, "an unreadable level neither clears nor re-fires the rule, got \(posted.count)")
    }

    private static func testPressureRuleCanBeTurnedOff() {
        var config = MemoryAlertConfig()
        config.notifyPressure = false
        expect(post([reading(0, pressure: .critical)], config: config).isEmpty, "notifyPressure false posts nothing")
    }

    /// 100 MB a minute for 5 minutes by default: 600 MB over 5 minutes is 120 MB a minute.
    private static func steady(_ megabytesPerMinute: UInt64, minutes: Int, step: Int = 10) -> [MemoryReading] {
        stride(from: 0, through: minutes * 60, by: step).map { seconds in
            reading(TimeInterval(seconds), swapped: UInt64(seconds) * megabytesPerMinute * mb / 60)
        }
    }

    private static func testSwapFiresAfterSustainedRate() {
        let fast = steady(120, minutes: 5)
        expect(post(Array(fast.prefix(fast.count - 3))).isEmpty, "not before the rate has held for the whole window")
        let posted = post(fast)
        expect(posted.map(\.id) == ["memory.swap"], "fires once the rate has held for 5 minutes, got \(posted.map(\.id))")
        expect(post(steady(60, minutes: 8)).isEmpty, "a rate under the threshold never fires")
    }

    private static func testBriefSwapBurstDoesNotFire() {
        let burst = [reading(0, swapped: 0), reading(10, swapped: 2_000 * mb)] + stride(from: 20, through: 900, by: 10).map { reading(TimeInterval($0), swapped: 2_000 * mb) }
        expect(post(burst).isEmpty, "one big burst is not swapping for N minutes: nothing fires, now or when the window fills, got \(post(burst).map(\.id))")
    }

    private static func testSwapFiresOnceWhileItStaysHigh() {
        let posted = post(steady(120, minutes: 12))
        expect(posted.count == 1, "keeps swapping for 12 minutes, one notification, got \(posted.count)")
    }

    private static func testSwapRuleCanBeTurnedOff() {
        var config = MemoryAlertConfig()
        config.notifySwap = false
        expect(post(steady(500, minutes: 6), config: config).isEmpty, "notifySwap false posts nothing")
    }

    private static func testNotificationIdsAreStable() {
        let first = post([reading(0, pressure: .warning, swapped: 5 * mb)])
        let second = post([reading(900, pressure: .warning, swapped: 900 * mb)])
        expect(first.map(\.id) == second.map(\.id) && first.map(\.id) == ["memory.pressure.warning"], "an id carries no reading, time or UUID")
        expect(first.first?.title.isEmpty == false && first.first?.body.isEmpty == false, "and every notification has a title and a body")
    }

    private static func swapAt(step: Int, megabytesPerMinute: UInt64, minutes: Int) -> [MemoryReading] {
        steady(megabytesPerMinute, minutes: minutes, step: step)
    }

    /// Swap is bursty: the counters step up every third second, so a 3 s collect sees each step
    /// and a 10 s collect sees three or four at once. The verdict must be the same either way.
    private static func burstyReadings(step: Int, megabytesPerBurst: UInt64, minutes: Int) -> [MemoryReading] {
        stride(from: 0, through: minutes * 60, by: step).map { seconds in
            reading(TimeInterval(seconds), swapped: 1_000 * mb + UInt64(seconds / 3) * megabytesPerBurst * mb)
        }
    }

    private static func testSwapVerdictDoesNotDependOnCadence() {
        for burst in [2, 10] as [UInt64] {
            let visible = post(burstyReadings(step: 3, megabytesPerBurst: burst, minutes: 6)).map(\.id)
            let hidden = post(burstyReadings(step: 10, megabytesPerBurst: burst, minutes: 6)).map(\.id)
            expect(visible == hidden, "\(burst) MB every third second reads the same sampled every 3 s or every 10 s, got \(visible) and \(hidden)")
        }
        expect(post(burstyReadings(step: 3, megabytesPerBurst: 10, minutes: 6)).map(\.id) == ["memory.swap"], "200 MB a minute in bursts fires at either cadence")
        expect(post(burstyReadings(step: 10, megabytesPerBurst: 10, minutes: 6)).map(\.id) == ["memory.swap"], "including hidden")
    }

    private static func testSwapAfterALongGapFiresNothing() {
        let busy = swapAt(step: 10, megabytesPerMinute: 500, minutes: 4)
        let resumed = reading(busy.last!.sampledAt.timeIntervalSince1970 + 7_200, swapped: 100_000 * mb)
        expect(post(busy + [resumed]).isEmpty, "the first sample after a two-hour gap (sleep) cannot make a rate, so nothing fires")
        let afterSleep = busy + [resumed] + stride(from: 10, through: 100, by: 10).map {
            reading(resumed.sampledAt.timeIntervalSince1970 + TimeInterval($0), swapped: 100_000 * mb + UInt64($0) * 500 * mb / 60)
        }
        expect(post(afterSleep).isEmpty, "and the window must fill again after the gap before the rule can fire")
    }

    /// A tenth of the window may be quiet (the kernel counts in bursts), whatever the cadence;
    /// more than that is not sustained.
    private static func testQuietShareOfTheWindowIsAllowed() {
        func withQuiet(_ quietSeconds: Set<Int>) -> [MemoryReading] {
            var total: UInt64 = 0
            return stride(from: 0, through: 300, by: 10).map { seconds in
                if seconds > 0 && !quietSeconds.contains(seconds) { total += 40 * mb }
                return reading(TimeInterval(seconds), swapped: 1_000 * mb + total)
            }
        }
        expect(post(withQuiet([150])).map(\.id) == ["memory.swap"], "10 s quiet of 300 s still fires")
        expect(post(withQuiet([150, 160, 170])).map(\.id) == ["memory.swap"], "30 s quiet, exactly a tenth, still fires")
        expect(post(withQuiet([150, 160, 170, 180])).isEmpty, "40 s quiet, over a tenth, does not")
    }

    private static func testPluginPostsThroughTheHost() {
        let recorder = HostServices.recordingNotifications()
        let levels = LevelSequence([1, 2, 2, 4, 1, 2])
        let host = HostServices(
            homeDirectory: "/tmp/systembar-tests",
            processes: Feed(initial: ProcessSummary()), fastStats: Feed(initial: FastStatsSnapshot()),
            runner: { _, _, _, _ in CommandOutput(output: "", error: "", status: 0, didTimeout: false) },
            log: { _ in },
            settings: PluginSettings(values: ["notifySwap": .bool(false)]),
            dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("systembar-tests-data"),
            notify: recorder.notify
        )
        let plugin = MemoryPlugin(host: host, kernelPressureLevel: { levels.next() })
        for _ in 0..<6 { plugin.collect() }
        let ids = recorder.posted().map(\.id)
        expect(
            ids == ["memory.pressure.warning", "memory.pressure.critical", "memory.pressure.warning"],
            "the plugin posts each crossing through host.notify, never a real notification, got \(ids)"
        )
    }
}

/// Hands out kernel pressure levels one call at a time.
private final class LevelSequence: @unchecked Sendable {
    private let levels: [Int32]
    private var index = 0
    private let lock = NSLock()
    init(_ levels: [Int32]) { self.levels = levels }
    func next() -> Int32 {
        lock.withLock { defer { index += 1 }; return levels[min(index, levels.count - 1)] }
    }
}
