import Combine
import Foundation
import SystemBarKit

/// What a hidden collect costs on a Mac with no battery: ioreg backs off to once a minute after
/// six empty replies, and an unchanged history is not republished. Run from `PowerTests.runAll()`.
@MainActor
enum PowerHiddenCostTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    static func runAll() {
        testEmptyRepliesBackOffToOnceAMinute()
        testAnUnchangedHistoryIsNotRepublished()
    }

    private static func plugin(_ answer: LockedText, clock: LockedDate, reads: LogRecorder) -> PowerPlugin {
        let host = makeHost(runner: { path, arguments, _, _ in
            if path == PowerCollector.ioregPath { reads.record(([path] + arguments).joined(separator: " ")) }
            return CommandOutput(output: path == PowerCollector.ioregPath ? answer.value : "", error: "", status: 0, didTimeout: false)
        }, dataDirectory: temporaryDirectory())
        return PowerPlugin(host: host, clock: { clock.value })
    }

    /// Collects every 10 s from now until `seconds` from now, as the host does while hidden.
    private static func collect(_ tab: PowerPlugin, clock: LockedDate, for seconds: Int) {
        for _ in 0..<(seconds / 10) {
            tab.collect()
            clock.advance(by: 10)
        }
    }

    private static func testEmptyRepliesBackOffToOnceAMinute() {
        let answer = LockedText("")
        let clock = LockedDate(start)
        let reads = LogRecorder()
        let tab = plugin(answer, clock: clock, reads: reads)
        collect(tab, clock: clock, for: 180)
        expect(reads.count == 8, "six empty replies 10 s apart, then one a minute (at 110 s and 170 s), got \(reads.count)")
        answer.value = PowerDrawFixtures.onBattery
        collect(tab, clock: clock, for: 60)
        let found = reads.count
        collect(tab, clock: clock, for: 60)
        expect(reads.count == found + 6, "once a battery entry appears, every 10 s again, got \(reads.count - found)")
    }

    private static func testAnUnchangedHistoryIsNotRepublished() {
        let clock = LockedDate(start)
        let empty = plugin(LockedText(""), clock: clock, reads: LogRecorder())
        var publishes = 0
        let watch = empty.$history.dropFirst().sink { _ in publishes += 1 }
        collect(empty, clock: clock, for: 100)
        spinRunLoop(for: 0.2)
        expect(publishes == 0, "with nothing recorded, main is not woken to publish the same history, got \(publishes)")
        let battery = plugin(LockedText(PowerDrawFixtures.onBattery), clock: clock, reads: LogRecorder())
        var batteryPublishes = 0
        let batteryWatch = battery.$history.dropFirst().sink { _ in batteryPublishes += 1 }
        collect(battery, clock: clock, for: 30)
        waitUntil { batteryPublishes == 3 }
        expect(batteryPublishes == 3, "each recorded reading is published, got \(batteryPublishes)")
        watch.cancel()
        batteryWatch.cancel()
    }
}
