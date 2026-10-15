import Foundation
import SystemBarKit

/// The Disk tab's read/write activity: the counter parser over captured `ioreg` text, the rate
/// history built from counter deltas, and the plugin sampling it through the host.
@MainActor
enum DiskActivityTests {
    static func runAll() {
        testParserSumsInternalDevicesAndSkipsDiskImages()
        testTheBuiltInCardReaderIsNotTheMacsDisk()
        testParserRejectsDevicesWithoutInternalCounters()
        testFirstSampleHasNoRateYet()
        testRatesAreByteDeltasOverElapsedTime()
        testASlowSampleFillsEverySecondItCovers()
        testALongGapResetsTheBaselineAndDrawsItIdle()
        testACounterGoingBackwardsGivesZero()
        testHistoryKeepsOnlyTheLatestPoints()
        testTheRealRegistryGivesMonotonicInternalCounters()
        testSamplingGraphsTheDeltaBetweenReads()
        testAFailedReadKeepsTheHistoryAndSaysSo()
        testHiddenPluginKeepsSamplingAtTheHiddenCadence()
        testShowingTheTabSpeedsSamplingUp()
        testTheTimerStopsWhenThePluginIsReleased()
        testSpeedsReadInAppleUnits()
    }

    /// Trimmed from `ioreg -a -l -r -c IOBlockStorageDevice -d 2`, the shape the IOKit reader rebuilds, on a Mac with an SD reader, the
    /// internal SSD and a mounted disk image.
    static let captured = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><array>
    \(device(location: "Internal", interconnect: "Secure Digital", read: 0, write: 0))
    \(device(location: "Internal", read: 771_672_174_592, write: 1_536_251_506_688))
    \(device(location: "File", read: 42_909_305_856, write: 0))
    </array></plist>
    """

    static func device(location: String, interconnect: String = "Apple Fabric", read: UInt64, write: UInt64) -> String {
        """
        <dict><key>IOObjectClass</key><string>IOBlockStorageDevice</string>
        <key>IORegistryEntryChildren</key><array><dict>
        <key>IOObjectClass</key><string>IOBlockStorageDriver</string>
        <key>Statistics</key><dict>
        <key>Bytes (Read)</key><integer>\(read)</integer>
        <key>Bytes (Write)</key><integer>\(write)</integer>
        </dict></dict></array>
        <key>Protocol Characteristics</key><dict>
        <key>Physical Interconnect</key><string>\(interconnect)</string>
        <key>Physical Interconnect Location</key><string>\(location)</string></dict></dict>
        """
    }

    private static let start = Date(timeIntervalSince1970: 1_000_000)

    /// The captured plist as the device dictionaries the reader hands the parser.
    private static func devices(from text: String) -> [[String: Any]] {
        guard let data = text.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return [] }
        return plist as? [[String: Any]] ?? []
    }

    private static func testParserSumsInternalDevicesAndSkipsDiskImages() {
        let counters = DiskActivity.counters(from: devices(from: captured))
        expect(counters == DiskCounters(bytesRead: 771_672_174_592, bytesWritten: 1_536_251_506_688),
               "internal devices count and a mounted disk image does not, got \(String(describing: counters))")

        let two = "<plist version=\"1.0\"><array>\(device(location: "Internal", read: 10, write: 1))\(device(location: "Internal", read: 5, write: 2))</array></plist>"
        expect(DiskActivity.counters(from: devices(from: two)) == DiskCounters(bytesRead: 15, bytesWritten: 3), "two internal disks add up")
    }

    private static func testTheBuiltInCardReaderIsNotTheMacsDisk() {
        let withCard = "<plist version=\"1.0\"><array>\(device(location: "Internal", interconnect: "Secure Digital", read: 99, write: 99))\(device(location: "Internal", read: 10, write: 1))</array></plist>"
        expect(DiskActivity.counters(from: devices(from: withCard)) == DiskCounters(bytesRead: 10, bytesWritten: 1), "a card in the built-in reader does not add to the internal disk")
        let cardOnly = "<plist version=\"1.0\"><array>\(device(location: "Internal", interconnect: "Secure Digital", read: 99, write: 99))</array></plist>"
        expect(DiskActivity.counters(from: devices(from: cardOnly)) == nil, "the reader alone is not a reading")
    }

    private static func testParserRejectsDevicesWithoutInternalCounters() {
        expect(DiskActivity.counters(from: []) == nil, "no devices is not a reading")
        expect(DiskActivity.counters(from: devices(from: "<plist version=\"1.0\"><array/></plist>")) == nil, "no internal device means no reading, not zero")
        let imageOnly = "<plist version=\"1.0\"><array>\(device(location: "File", read: 9, write: 9))</array></plist>"
        expect(DiskActivity.counters(from: devices(from: imageOnly)) == nil, "a disk image alone is not the internal disk")
    }

    private static func testFirstSampleHasNoRateYet() {
        let history = DiskActivityHistory().applying(DiskCounters(bytesRead: 100, bytesWritten: 100), at: start)
        expect(history.readRates.isEmpty && history.writeRates.isEmpty, "one reading has nothing to subtract from")
        expect(history.currentReadRate == 0 && history.currentWriteRate == 0, "the cards show zero until there is a rate")
    }

    private static func testRatesAreByteDeltasOverElapsedTime() {
        let first = DiskActivityHistory().applying(DiskCounters(bytesRead: 1_000, bytesWritten: 5_000), at: start)
        let second = first.applying(DiskCounters(bytesRead: 2_000, bytesWritten: 5_250), at: start.addingTimeInterval(1))
        expect(second.readRates == [1_000] && second.writeRates == [250], "bytes over seconds: \(second.readRates) \(second.writeRates)")
        expect(second.currentReadRate == 1_000 && second.currentWriteRate == 250, "the cards follow the newest point")
        expect(first.readRates.isEmpty, "applying returns a new history and leaves the old one alone")
    }

    /// The axis is one point per second, so a reading taken while the tab was hidden, 5 s after
    /// the last, adds five points at its average speed and the graph is full on open.
    private static func testASlowSampleFillsEverySecondItCovers() {
        let first = DiskActivityHistory().applying(DiskCounters(bytesRead: 0, bytesWritten: 0), at: start)
        let slow = first.applying(DiskCounters(bytesRead: 5_000, bytesWritten: 10_000), at: start.addingTimeInterval(5))
        expect(slow.readRates == Array(repeating: 1_000, count: 5), "five seconds, five points, got \(slow.readRates)")
        expect(slow.writeRates == Array(repeating: 2_000, count: 5), "got \(slow.writeRates)")
    }

    /// After the Mac sleeps, one average over an hour would paint a flat lie across the graph, so
    /// the gap is drawn idle, as long as it lasted (up to the whole graph), with no rate.
    private static func testALongGapResetsTheBaselineAndDrawsItIdle() {
        let first = DiskActivityHistory().applying(DiskCounters(bytesRead: 0, bytesWritten: 0), at: start)
        let busy = first.applying(DiskCounters(bytesRead: 500, bytesWritten: 0), at: start.addingTimeInterval(1))
        let gap = busy.applying(DiskCounters(bytesRead: 9_000_000, bytesWritten: 0), at: start.addingTimeInterval(1 + 45))
        expect(gap.readRates == [500] + Array(repeating: 0, count: 45), "a 45 s gap is 45 idle points after the real one, got \(gap.readRates)")
        let sleep = busy.applying(DiskCounters(bytesRead: 9_000_000, bytesWritten: 0), at: start.addingTimeInterval(3_600))
        expect(sleep.readRates == Array(repeating: 0, count: DiskActivityHistory.pointLimit), "an hour asleep fills the graph with idle, got \(sleep.readRates.count) points")
        let next = gap.applying(DiskCounters(bytesRead: 9_000_100, bytesWritten: 0), at: start.addingTimeInterval(1 + 46))
        expect(next.readRates.last == 100, "the reading after the gap is the new baseline, got \(String(describing: next.readRates.last))")
    }

    private static func testACounterGoingBackwardsGivesZero() {
        let first = DiskActivityHistory().applying(DiskCounters(bytesRead: 5_000, bytesWritten: 5_000), at: start)
        let reset = first.applying(DiskCounters(bytesRead: 100, bytesWritten: 6_000), at: start.addingTimeInterval(1))
        expect(reset.readRates == [0], "a counter that went backwards (a driver reset) is zero, not a huge unsigned wrap")
        expect(reset.writeRates == [1_000], "the other counter is unaffected")
        let next = reset.applying(DiskCounters(bytesRead: 400, bytesWritten: 6_000), at: start.addingTimeInterval(2))
        expect(next.readRates == [0, 300], "the reset reading is the new baseline")

        let sameInstant = next.applying(DiskCounters(bytesRead: 900, bytesWritten: 6_000), at: start.addingTimeInterval(2))
        expect(sameInstant.readRates.count == 2, "a reading with no time elapsed adds no point")
    }

    private static func testHistoryKeepsOnlyTheLatestPoints() {
        var history = DiskActivityHistory().applying(DiskCounters(bytesRead: 0, bytesWritten: 0), at: start)
        let total = DiskActivityHistory.pointLimit + 5
        for second in 1...total {
            history = history.applying(DiskCounters(bytesRead: UInt64(second) * 10, bytesWritten: 0), at: start.addingTimeInterval(TimeInterval(second)))
        }
        expect(history.readRates.count == DiskActivityHistory.pointLimit, "history is bounded, got \(history.readRates.count)")
        expect(history.readRates.allSatisfy { $0 == 10 }, "every kept point is a 10 B/s delta")
    }

    /// This Mac's own registry: the in-process read finds the internal disk, and two reads never
    /// go backwards.
    private static func testTheRealRegistryGivesMonotonicInternalCounters() {
        // A Mac with no internal block-storage driver (a VM, say) has nothing to read; that is a
        // different machine, not a failure of this code, so say so and move on.
        guard let first = IOKitDiskReader.read() else {
            fputs("SKIP testTheRealRegistryGivesMonotonicInternalCounters: no internal-disk counters on this machine\n", stderr)
            return
        }
        expect(first.bytesRead > 0 || first.bytesWritten > 0, "an internal disk that has booted a Mac has moved bytes, got \(first)")
        let second = IOKitDiskReader.read()
        expect((second?.bytesRead ?? 0) >= first.bytesRead && (second?.bytesWritten ?? 0) >= first.bytesWritten, "counters only grow between reads")
    }

    private static func makePlugin(reader: @escaping @Sendable () -> DiskCounters?, visible: TimeInterval = 3_600, hidden: TimeInterval = 3_600, directory: URL) -> DiskPlugin {
        DiskPlugin(
            host: makeHost(dataDirectory: directory),
            plans: [],
            now: { Date() },
            listChildren: { _ in [] },
            activity: ActivitySampling(read: reader, visibleInterval: visible, hiddenInterval: hidden)
        )
    }

    private static func testSamplingGraphsTheDeltaBetweenReads() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let readings = ReadingQueue([DiskCounters(bytesRead: 1_000, bytesWritten: 0), DiskCounters(bytesRead: 3_000, bytesWritten: 4_000)])
        let plugin = makePlugin(reader: { readings.next() }, directory: directory)

        plugin.sampleActivity(at: start)
        plugin.sampleActivity(at: start.addingTimeInterval(2))
        waitUntil { plugin.activity.readRates.count == 2 }
        expect(plugin.activity.currentReadRate == 1_000 && plugin.activity.currentWriteRate == 2_000, "the plugin graphs the delta, got \(plugin.activity.currentReadRate) \(plugin.activity.currentWriteRate)")
        expect(plugin.activity.problem == nil, "a good read has no problem")
    }

    private static func testAFailedReadKeepsTheHistoryAndSaysSo() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let plugin = makePlugin(reader: { nil }, directory: directory)
        plugin.sampleActivity(at: start)
        waitUntil { plugin.activity.problem != nil }
        expect(plugin.activity.problem == "Disk activity is not available: the registry gave no internal-disk counters", "an unreadable answer says so rather than drawing zeros, got \(String(describing: plugin.activity.problem))")
        expect(plugin.activity.readRates.isEmpty, "nothing is drawn")
    }

    /// The graph is full when the tab opens: nobody has to show the tab for sampling to run.
    private static func testHiddenPluginKeepsSamplingAtTheHiddenCadence() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = CallCounter()
        let plugin = makePlugin(reader: { counter.tick(); return DiskCounters(bytesRead: 0, bytesWritten: 0) }, hidden: 0.02, directory: directory)
        waitUntil(2) { counter.count >= 3 }
        expect(counter.count >= 3, "a hidden tab samples on its own timer, got \(counter.count) reads")
        _ = plugin
    }

    private static func testShowingTheTabSpeedsSamplingUp() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = CallCounter()
        let plugin = makePlugin(reader: { counter.tick(); return DiskCounters(bytesRead: 0, bytesWritten: 0) }, visible: 0.02, hidden: 3_600, directory: directory)
        spinRunLoop(for: 0.15)
        expect(counter.count == 0, "hidden at a slow cadence, nothing has been read yet, got \(counter.count)")
        plugin.visibilityChanged(isVisible: true)
        waitUntil(2) { counter.count >= 3 }
        expect(counter.count >= 3, "showing the tab switches to the fast cadence, got \(counter.count) reads")
        plugin.visibilityChanged(isVisible: false)
        spinRunLoop(for: 0.1)
        let afterHide = counter.count
        spinRunLoop(for: 0.2)
        expect(counter.count == afterHide, "hiding it goes back to the slow cadence: \(afterHide) then \(counter.count)")
    }

    private static func testTheTimerStopsWhenThePluginIsReleased() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = CallCounter()
        var plugin: DiskPlugin? = makePlugin(reader: { counter.tick(); return DiskCounters(bytesRead: 0, bytesWritten: 0) }, hidden: 0.02, directory: directory)
        waitUntil(2) { counter.count >= 2 }
        plugin = nil
        spinRunLoop(for: 0.1)
        let afterRelease = counter.count
        spinRunLoop(for: 0.3)
        expect(counter.count == afterRelease, "a released plugin reads nothing more: \(afterRelease) then \(counter.count)")
        _ = plugin
    }

    private static func testSpeedsReadInAppleUnits() {
        expect(DiskActivity.rateText(1_234_567) == "1.2 MB/s", "speeds are decimal MB/s as Finder-era tools write them, got \(DiskActivity.rateText(1_234_567))")
        expect(DiskActivity.rateText(0) == "0 B/s", "idle reads as zero, got \(DiskActivity.rateText(0))")
    }
}

/// Hands out canned counter readings in order, safely from the timer's queue; once they run out
/// it answers nil.
final class ReadingQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [DiskCounters]

    init(_ readings: [DiskCounters]) { remaining = readings }

    func next() -> DiskCounters? {
        lock.withLock { remaining.isEmpty ? nil : remaining.removeFirst() }
    }
}

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func tick() { lock.withLock { calls += 1 } }
    var count: Int { lock.withLock { calls } }
}
