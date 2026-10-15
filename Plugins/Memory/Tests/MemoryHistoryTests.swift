import Foundation
import SystemBarKit

/// The pressure history graph's data: what a sample records, how often, and how long it is kept.
@MainActor
enum MemoryHistoryTests {
    static func runAll() {
        testPointIsUsedShareColouredByPressure()
        testNoPointWithoutATotal()
        testVisibleCollectsAddAPointEveryTenSeconds()
        testHiddenCollectsFillFifteenMinutes()
        testOldPointsAreDropped()
        testGraphIsFullOnOpenAfterTheTabWasHidden()
        testPressureColours()
        testMemoryTabSamplesEveryTenSecondsWhileHidden()
    }

    private static func reading(at seconds: TimeInterval, used: UInt64 = 25, total: UInt64 = 100, pressure: MemoryPressureLevel? = .normal) -> MemoryReading {
        MemoryReading(
            memory: MemorySnapshot(total: total, used: used),
            gpu: GPUSnapshot(), pressure: pressure, sampledAt: Date(timeIntervalSince1970: seconds)
        )
    }

    private static func record(_ times: [TimeInterval]) -> MemoryStatsSnapshot {
        times.reduce(MemoryStatsSnapshot()) { $0.recording(reading(at: $1)) }
    }

    private static func testPointIsUsedShareColouredByPressure() {
        let stats = MemoryStatsSnapshot().recording(reading(at: 5, used: 30, total: 120, pressure: .warning))
        let point = stats.history.points.last
        expect(stats.history.points.count == 1, "the first reading is a point")
        expect(point?.usedShare == 0.25, "its height is memory used as a share of RAM, got \(String(describing: point?.usedShare))")
        expect(point?.pressure == .warning, "and its colour is the kernel's pressure level at that moment")
    }

    private static func testNoPointWithoutATotal() {
        let stats = MemoryStatsSnapshot().recording(reading(at: 0, used: 0, total: 0))
        expect(stats.history.points.isEmpty, "a reading that failed to find the machine's memory draws nothing, not zero")
    }

    private static func testVisibleCollectsAddAPointEveryTenSeconds() {
        let stats = record(stride(from: 0, through: 30, by: 3).map { TimeInterval($0) })
        expect(stats.history.points.count == 4, "collects every 3 s add a point about every 10 s, got \(stats.history.points.count) points")
    }

    private static func testHiddenCollectsFillFifteenMinutes() {
        let stats = record(stride(from: 0, through: 900, by: 10).map { TimeInterval($0) })
        expect(stats.history.points.count == 91, "a point every 10 s for 15 minutes, got \(stats.history.points.count)")
    }

    private static func testOldPointsAreDropped() {
        let stats = record(stride(from: 0, through: 1_200, by: 10).map { TimeInterval($0) })
        let oldest = stats.history.points.first?.at.timeIntervalSince1970
        expect(oldest == 300, "points older than 15 minutes go, so the oldest is 300 s here, got \(String(describing: oldest))")
    }

    /// The acceptance case: the host called a hidden tab every 10 s, so on open the graph already
    /// spans the whole window, with the visible 3 s collects carrying on from it.
    private static func testGraphIsFullOnOpenAfterTheTabWasHidden() {
        let hidden = record(stride(from: 0, through: 1_800, by: 10).map { TimeInterval($0) })
        let opened = hidden.recording(reading(at: 1_803))
        let span = (opened.history.points.last?.at.timeIntervalSince(opened.history.points.first?.at ?? .distantFuture)) ?? 0
        expect(span >= 890, "the graph spans the window the moment the tab opens, got \(span) s")
        expect(opened.history.points.count == hidden.history.points.count, "and a collect 3 s after the last point adds none")
    }

    private static func testPressureColours() {
        expect(pressureColor(.normal) == Palette.good, "normal is green")
        expect(pressureColor(.warning) == Palette.caution, "warning is yellow")
        expect(pressureColor(.critical) == Palette.critical, "critical is red")
        expect(pressureColor(nil) != Palette.good && pressureColor(nil) != Palette.critical, "an unknown level is not dressed up as a known one")
    }

    private static func testMemoryTabSamplesEveryTenSecondsWhileHidden() {
        expect(MemorySampling.backgroundInterval == 10, "the host calls the hidden tab every 10 s")
    }
}
