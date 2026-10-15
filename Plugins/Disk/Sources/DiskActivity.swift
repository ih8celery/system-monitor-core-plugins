import Foundation
import IOKit
import SystemBarKit

/// Bytes the internal disk has read and written since boot, summed over its block storage drivers.
struct DiskCounters: Equatable {
    var bytesRead: UInt64
    var bytesWritten: UInt64
}

enum DiskActivity {
    static let unavailableProblem = "Disk activity is not available: the registry gave no internal-disk counters"

    /// A speed as the cards show it: Apple's decimal units, the same as the sizes.
    static func rateText(_ bytesPerSecond: Double) -> String {
        fileRateString(bytesPerSecond)
    }

    /// The sum over devices whose interconnect location is Internal, so a mounted disk image or an
    /// external drive does not count as the Mac's own disk. Each device is a dictionary holding
    /// its "Protocol Characteristics" and its "IORegistryEntryChildren", the shape `ioreg -a`
    /// prints. Nil when no internal device has counters: zero would claim the disk is idle.
    static func counters(from devices: [[String: Any]]) -> DiskCounters? {
        var found = false
        var total = DiskCounters(bytesRead: 0, bytesWritten: 0)
        for device in devices where isInternal(device) {
            for driver in children(of: device) {
                guard let stats = driver["Statistics"] as? [String: Any],
                      let read = byteCount(stats["Bytes (Read)"]),
                      let written = byteCount(stats["Bytes (Write)"]) else { continue }
                found = true
                total = DiskCounters(bytesRead: total.bytesRead &+ read, bytesWritten: total.bytesWritten &+ written)
            }
        }
        return found ? total : nil
    }

    private static func isInternal(_ device: [String: Any]) -> Bool {
        let characteristics = device["Protocol Characteristics"] as? [String: Any]
        return characteristics?["Physical Interconnect Location"] as? String == "Internal"
    }

    private static func children(of device: [String: Any]) -> [[String: Any]] {
        let all = device["IORegistryEntryChildren"] as? [[String: Any]] ?? []
        return all.filter { $0["IOObjectClass"] as? String == "IOBlockStorageDriver" }
    }

    private static func byteCount(_ value: Any?) -> UInt64? {
        (value as? NSNumber).map { $0.uint64Value }
    }
}

/// The graph's data: read and write speeds, one point per sample, newest last. A value type, so a
/// sample returns the next history and the old one stays as it was.
struct DiskActivityHistory {
    /// One point per second, so two minutes of graph.
    static let pointLimit = 120
    /// A reading further than this from the last is a gap (the Mac slept, the tab was torn down),
    /// not a long sample: it becomes the new baseline and adds no points.
    static let maximumGap: TimeInterval = 30

    private(set) var readRates: [Double] = []
    private(set) var writeRates: [Double] = []
    /// The last failed read, worded for the panel; cleared by the next good one.
    private(set) var problem: String?
    private var last: (counters: DiskCounters, at: Date)?

    var currentReadRate: Double { readRates.last ?? 0 }
    var currentWriteRate: Double { writeRates.last ?? 0 }

    /// A copy with the reading applied. The first reading only sets the baseline. The axis is one
    /// point per second, so a reading n seconds after the last adds n points at the average
    /// speed over those seconds: sampling slowly while the tab is hidden still fills the graph. A
    /// counter that went backwards (the driver restarted) gives 0 rather than an unsigned wrap,
    /// and a reading with no time since the last adds no point.
    func applying(_ counters: DiskCounters, at date: Date) -> DiskActivityHistory {
        var next = self
        next.problem = nil
        guard let last else {
            next.last = (counters, date)
            return next
        }
        let elapsed = date.timeIntervalSince(last.at)
        guard elapsed > 0 else { return next }
        next.last = (counters, date)
        guard elapsed <= Self.maximumGap else { return next }
        let seconds = max(1, Int(elapsed.rounded()))
        next.readRates = Self.appending(Self.rate(from: last.counters.bytesRead, to: counters.bytesRead, over: elapsed), times: seconds, to: readRates)
        next.writeRates = Self.appending(Self.rate(from: last.counters.bytesWritten, to: counters.bytesWritten, over: elapsed), times: seconds, to: writeRates)
        return next
    }

    /// A copy that keeps the graph and says why the newest read gave nothing.
    func failing(_ message: String) -> DiskActivityHistory {
        var next = self
        next.problem = message
        return next
    }

    private static func rate(from old: UInt64, to new: UInt64, over elapsed: TimeInterval) -> Double {
        new >= old ? Double(new - old) / elapsed : 0
    }

    private static func appending(_ value: Double, times count: Int, to values: [Double]) -> [Double] {
        Array((values + Array(repeating: value, count: count)).suffix(pointLimit))
    }
}

/// Reads the internal disk's byte counters in process: no subprocess, so sampling every few
/// seconds while the tab is hidden costs a registry walk, not a process launch.
enum IOKitDiskReader {
    static func read() -> DiskCounters? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var devices: [[String: Any]] = []
        var driver = IOIteratorNext(iterator)
        while driver != 0 {
            if let device = device(owning: driver) { devices.append(device) }
            IOObjectRelease(driver)
            driver = IOIteratorNext(iterator)
        }
        return DiskActivity.counters(from: devices)
    }

    /// The driver's parent device and the driver's statistics, in the shape `counters(from:)` reads.
    private static func device(owning driver: io_registry_entry_t) -> [String: Any]? {
        guard let stats = property("Statistics", of: driver) as? [String: Any] else { return nil }
        var parent = io_registry_entry_t()
        guard IORegistryEntryGetParentEntry(driver, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }
        return [
            "Protocol Characteristics": property("Protocol Characteristics", of: parent) ?? [String: Any](),
            "IORegistryEntryChildren": [["IOObjectClass": "IOBlockStorageDriver", "Statistics": stats]],
        ]
    }

    private static func property(_ key: String, of entry: io_registry_entry_t) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
