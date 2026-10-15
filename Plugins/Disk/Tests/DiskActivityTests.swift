import Foundation
import SystemBarKit

/// The Disk tab's read/write activity: the counter parser over captured `ioreg` text, the rate
/// history built from counter deltas, and the plugin sampling it through the host.
@MainActor
enum DiskActivityTests {
    static func runAll() {
        testParserSumsInternalDevicesAndSkipsDiskImages()
        testParserRejectsTextThatIsNotCounters()
        testFirstSampleHasNoRateYet()
        testRatesAreByteDeltasOverElapsedTime()
        testACounterGoingBackwardsGivesZero()
        testHistoryKeepsOnlyTheLatestPoints()
        testSamplingRunsIoregThroughTheHostAndGraphsTheDelta()
        testAFailedReadKeepsTheHistoryAndSaysSo()
    }

    /// Trimmed from `ioreg -a -l -r -c IOBlockStorageDevice -d 2` on a Mac with an SD reader, the
    /// internal SSD and a mounted disk image.
    static let captured = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><array>
    \(device(location: "Internal", read: 0, write: 0))
    \(device(location: "Internal", read: 771_672_174_592, write: 1_536_251_506_688))
    \(device(location: "File", read: 42_909_305_856, write: 0))
    </array></plist>
    """

    static func device(location: String, read: UInt64, write: UInt64) -> String {
        """
        <dict><key>IOObjectClass</key><string>IOBlockStorageDevice</string>
        <key>IORegistryEntryChildren</key><array><dict>
        <key>IOObjectClass</key><string>IOBlockStorageDriver</string>
        <key>Statistics</key><dict>
        <key>Bytes (Read)</key><integer>\(read)</integer>
        <key>Bytes (Write)</key><integer>\(write)</integer>
        </dict></dict></array>
        <key>Protocol Characteristics</key><dict>
        <key>Physical Interconnect Location</key><string>\(location)</string></dict></dict>
        """
    }

    static func plist(read: UInt64, write: UInt64) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><array>\(device(location: "Internal", read: read, write: write))</array></plist>
        """
    }

    private static let start = Date(timeIntervalSince1970: 1_000_000)

    private static func testParserSumsInternalDevicesAndSkipsDiskImages() {
        let counters = DiskActivity.parseCounters(captured)
        expect(counters == DiskCounters(bytesRead: 771_672_174_592, bytesWritten: 1_536_251_506_688),
               "internal devices count and a mounted disk image does not, got \(String(describing: counters))")

        let two = "<plist version=\"1.0\"><array>\(device(location: "Internal", read: 10, write: 1))\(device(location: "Internal", read: 5, write: 2))</array></plist>"
        expect(DiskActivity.parseCounters(two) == DiskCounters(bytesRead: 15, bytesWritten: 3), "two internal disks add up")
    }

    private static func testParserRejectsTextThatIsNotCounters() {
        expect(DiskActivity.parseCounters("") == nil, "empty output is not a reading")
        expect(DiskActivity.parseCounters("not a plist") == nil, "text that is not a plist is not a reading")
        expect(DiskActivity.parseCounters("<plist version=\"1.0\"><array/></plist>") == nil, "no internal device means no reading, not zero")
        let imageOnly = "<plist version=\"1.0\"><array>\(device(location: "File", read: 9, write: 9))</array></plist>"
        expect(DiskActivity.parseCounters(imageOnly) == nil, "a disk image alone is not the internal disk")
    }

    private static func testFirstSampleHasNoRateYet() {
        let history = DiskActivityHistory().applying(DiskCounters(bytesRead: 100, bytesWritten: 100), at: start)
        expect(history.readRates.isEmpty && history.writeRates.isEmpty, "one reading has nothing to subtract from")
        expect(history.currentReadRate == 0 && history.currentWriteRate == 0, "the cards show zero until there is a rate")
    }

    private static func testRatesAreByteDeltasOverElapsedTime() {
        let first = DiskActivityHistory().applying(DiskCounters(bytesRead: 1_000, bytesWritten: 5_000), at: start)
        let second = first.applying(DiskCounters(bytesRead: 3_000, bytesWritten: 5_500), at: start.addingTimeInterval(2))
        expect(second.readRates == [1_000] && second.writeRates == [250], "bytes over seconds: \(second.readRates) \(second.writeRates)")
        expect(second.currentReadRate == 1_000 && second.currentWriteRate == 250, "the cards follow the newest point")
        expect(first.readRates.isEmpty, "applying returns a new history and leaves the old one alone")
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

    private static func testSamplingRunsIoregThroughTheHostAndGraphsTheDelta() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = LogRecorder()
        let line = "/usr/sbin/ioreg -a -l -r -c IOBlockStorageDevice -d 2"
        let readings = ReadingQueue([plist(read: 1_000, write: 0), plist(read: 3_000, write: 4_000)])
        let host = makeHost(runner: { path, arguments, _, _ in
            let command = ([path] + arguments).joined(separator: " ")
            recorder.record(command)
            guard command == line else { return CommandOutput(output: "", error: "unexpected command: \(command)", status: 1, didTimeout: false) }
            return CommandOutput(output: readings.next(), error: "", status: 0, didTimeout: false)
        }, dataDirectory: directory)
        let plugin = DiskPlugin(host: host)

        plugin.sampleActivity(at: start)
        plugin.sampleActivity(at: start.addingTimeInterval(2))
        waitUntil { plugin.activity.readRates.count == 1 }
        expect(recorder.messages == [line, line], "ioreg runs by explicit path with an argument array, got \(recorder.messages)")
        expect(plugin.activity.currentReadRate == 1_000 && plugin.activity.currentWriteRate == 2_000, "the plugin graphs the delta, got \(plugin.activity.currentReadRate) \(plugin.activity.currentWriteRate)")
        expect(plugin.activity.problem == nil, "a good read has no problem")
    }

    private static func testAFailedReadKeepsTheHistoryAndSaysSo() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = makeHost(runner: { _, _, _, _ in CommandOutput(output: "garbage", error: "", status: 0, didTimeout: false) }, dataDirectory: directory)
        let plugin = DiskPlugin(host: host)
        plugin.sampleActivity(at: start)
        waitUntil { plugin.activity.problem != nil }
        expect(plugin.activity.problem == "Disk activity is not available: ioreg gave no internal-disk counters", "an unreadable answer says so rather than drawing zeros, got \(String(describing: plugin.activity.problem))")
        expect(plugin.activity.readRates.isEmpty, "nothing is drawn")
    }
}

/// Hands out canned `ioreg` answers in order, safely from the runner's thread.
final class ReadingQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [String]

    init(_ readings: [String]) { remaining = readings }

    func next() -> String {
        lock.withLock { remaining.isEmpty ? "" : remaining.removeFirst() }
    }
}
