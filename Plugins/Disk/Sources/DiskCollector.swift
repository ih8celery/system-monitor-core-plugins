import Foundation
import SystemBarKit

/// The Disk tab's cheap 30-second reading: the mounted volumes and the local snapshot count.
/// Runs on the plugin's queue. The folder scans live in `DiskScanner`.
final class DiskCollector: @unchecked Sendable {
    private let host: HostServices

    init(host: HostServices) {
        self.host = host
    }

    func readVolumes() -> DiskVolumeReading {
        DiskVolumeReading(volumes: Self.collectDiskVolumes(), localSnapshotCount: collectLocalSnapshotCount(), sampledAt: Date())
    }

    static func collectDiskVolumes() -> [DiskVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsBrowsableKey,
            .volumeIsInternalKey
        ]

        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        let rootURL = URL(fileURLWithPath: "/")
        let candidates = mounted.contains(where: { $0.path == "/" }) ? mounted : [rootURL] + mounted

        return candidates.compactMap { url -> DiskVolume? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            guard values.volumeIsBrowsable != false else { return nil }
            guard let total = values.volumeTotalCapacity, total > 0 else { return nil }

            let free = UInt64(max(values.volumeAvailableCapacity ?? 0, 0))
            // Finder's number; absent on a volume that does not report it, which then has no
            // purgeable share rather than an invented one.
            let important = UInt64(max(values.volumeAvailableCapacityForImportantUsage ?? 0, 0))
            let purgeable = important > free ? important - free : 0

            return DiskVolume(
                name: values.volumeName ?? url.lastPathComponent,
                path: url.path,
                total: UInt64(total),
                free: free,
                purgeable: purgeable,
                isRoot: url.path == "/"
            )
        }
        .sorted { lhs, rhs in
            if lhs.isRoot != rhs.isRoot { return lhs.isRoot }
            return lhs.total > rhs.total
        }
    }

    func collectLocalSnapshotCount() -> Int {
        let result = host.run(path: "/usr/bin/tmutil", arguments: ["listlocalsnapshots", "/"])
        guard result.status == 0 else { return 0 }
        return Self.parseLocalSnapshotCount(result.output)
    }

    /// Output is a header line followed by one identifier per snapshot. Both Time Machine and
    /// OS-update snapshots hold real space, so every entry counts, not just the TM ones.
    static func parseLocalSnapshotCount(_ output: String) -> Int {
        output
            .split(separator: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("com.apple.") }
            .count
    }
}
