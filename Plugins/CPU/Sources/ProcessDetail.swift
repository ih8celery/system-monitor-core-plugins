import Foundation
import SystemBarKit

/// Per-PID facts shown in the drill-in panel for a tapped process group.
struct ProcessDetail: Identifiable {
    var id: Int32 { pid }
    let pid: Int32
    let command: String        // full args
    let path: String           // executable path
    let name: String
    let parentName: String
    let grandparentName: String
    let cpuPercent: Double     // whole-machine 0-100
    /// The physical footprint, as the list row counts it (resident size for a process whose
    /// footprint could not be read).
    let memory: UInt64
    let uptime: String
}

extension ProcessDetail {
    // MARK: - On-demand process drill-in (runs only when a row is tapped)

    /// Walk up the ppid chain, returning up to `hops` ancestor names. Stops early
    /// when an ancestor is not in the map (e.g. the kernel/pid 0), so chains shorter
    /// than `hops` are handled without inventing names.
    static func parentChain(of pid: Int32, in map: [Int32: PidRecord], hops: Int) -> [String] {
        var names: [String] = []
        var current = map[pid]?.ppid
        var remaining = hops

        while remaining > 0, let ppid = current, let ancestor = map[ppid] {
            names.append(ancestor.name)
            current = ancestor.ppid
            remaining -= 1
        }

        return names
    }

    /// Build per-PID detail rows for every process in the named group. The memory shown is each
    /// record's `physical`, so `map` should come from a parse that read footprints.
    ///
    /// A group's rows can differ from the list row for the same group by a few hundred KB: the host
    /// list leaves out processes under 1 MiB and reads footprints only for its top groups, and the
    /// two are read at different moments. That gap is accepted, not chased.
    static func groupDetail(name: String, in map: [Int32: PidRecord], coreCount: Int) -> [ProcessDetail] {
        map.values
            .filter { $0.name == name }
            .map { record in
                let chain = parentChain(of: record.pid, in: map, hops: 2)
                return ProcessDetail(
                    pid: record.pid,
                    command: record.args,
                    path: record.path,
                    name: record.name,
                    parentName: chain.first ?? "unknown",
                    grandparentName: chain.count > 1 ? chain[1] : "",
                    cpuPercent: ProcessCPUScale.wholeMachinePercent(summedPcpu: record.cpu, coreCount: coreCount),
                    memory: record.physical,
                    uptime: record.etime
                )
            }
            .sorted { $0.cpuPercent > $1.cpuPercent }
    }

    /// Runs the on-demand `ps` snapshot through the host and returns the tapped group's rows.
    /// Called on tap only — no cost to the idle sampling loop. `fileExists` is how the parser finds
    /// an executable path with spaces in it, such as Chrome's; tests pass a fake so they do not
    /// depend on what is installed. `footprint` reads a process's physical footprint, the figure
    /// the list shows; a test passes a fake.
    static func fetchGroupDetail(
        name: String,
        using host: HostServices,
        fileExists: (String) -> Bool = ProcessTable.isExistingRegularFile(atPath:),
        footprint: (Int32) -> UInt64? = ProcessTable.physicalFootprint(pid:)
    ) -> [ProcessDetail] {
        let result = host.run(path: ProcessTable.executable, arguments: ProcessTable.arguments)
        guard result.status == 0 else { return [] }
        let map = ProcessTable.parse(result.output, fileExists: fileExists, footprint: footprint)
        return groupDetail(name: name, in: map, coreCount: ProcessInfo.processInfo.activeProcessorCount)
    }
}
