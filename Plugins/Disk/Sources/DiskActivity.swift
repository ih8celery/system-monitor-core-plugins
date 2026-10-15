import Foundation

/// Bytes the internal disk has read and written since boot, summed over its block storage drivers.
struct DiskCounters: Equatable {
    var bytesRead: UInt64
    var bytesWritten: UInt64
}

enum DiskActivity {
    /// Every block storage device with its driver's `Statistics`, as a plist. Plain `ioreg`, no
    /// root: the counters are public registry properties.
    static let ioregPath = "/usr/sbin/ioreg"
    static let ioregArguments = ["-a", "-l", "-r", "-c", "IOBlockStorageDevice", "-d", "2"]
    static let unavailableProblem = "Disk activity is not available: ioreg gave no internal-disk counters"

    /// The sum over devices whose interconnect location is Internal, so a mounted disk image or an
    /// external drive does not count as the Mac's own disk. Nil when the text is not a plist or
    /// holds no internal counters: zero would be a claim the disk is idle.
    static func parseCounters(_ text: String) -> DiskCounters? {
        guard let data = text.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let devices = plist as? [[String: Any]] else { return nil }
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
    /// At one sample a second, two minutes of graph.
    static let pointLimit = 120

    private(set) var readRates: [Double] = []
    private(set) var writeRates: [Double] = []
    /// The last failed read, worded for the panel; cleared by the next good one.
    private(set) var problem: String?
    private var last: (counters: DiskCounters, at: Date)?

    var currentReadRate: Double { readRates.last ?? 0 }
    var currentWriteRate: Double { writeRates.last ?? 0 }

    /// A copy with the reading applied. The first reading only sets the baseline. A counter that
    /// went backwards (the driver restarted) gives 0 for that point rather than an unsigned wrap,
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
        next.readRates = Self.appending(Self.rate(from: last.counters.bytesRead, to: counters.bytesRead, over: elapsed), to: readRates)
        next.writeRates = Self.appending(Self.rate(from: last.counters.bytesWritten, to: counters.bytesWritten, over: elapsed), to: writeRates)
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

    private static func appending(_ value: Double, to values: [Double]) -> [Double] {
        Array((values + [value]).suffix(pointLimit))
    }
}
