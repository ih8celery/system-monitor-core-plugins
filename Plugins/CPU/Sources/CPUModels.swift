import Foundation
import SystemBarKit

/// The CPU tab's own cadence. The headline, history, per-core and user/system figures come from
/// the host's 1-second feed; this is how often the tab reads what that feed does not carry.
enum CPUSampling {
    /// Load average, thermal state and `pmset -g therm`, while the tab is showing.
    static let refreshInterval: TimeInterval = 10
    /// The GPU's own cadence, while the tab is showing.
    static let gpuInterval: TimeInterval = 1
}

/// One group of cores that share a design, named as sysctl names it (`hw.perflevelN.name`),
/// with the range of core indices the kernel reports them under.
struct CPUCluster: Equatable {
    let name: String
    let cores: Range<Int>

    var coreCount: Int { cores.count }

    /// The cluster's busy percent: the mean of its cores' entries in the feed's `perCoreUsage`,
    /// or 0 when the feed has none yet (the first second, or a feed shorter than this cluster's range).
    func usage(perCore: [Double]) -> Double {
        guard !cores.isEmpty, cores.upperBound <= perCore.count else { return 0 }
        return perCore[cores].reduce(0, +) / Double(cores.count)
    }
}

enum CPUClusters {
    /// Which core indices belong to which perflevel. sysctl lists perflevels fastest first
    /// (`hw.perflevel0` is the fastest), but the kernel numbers cores slowest cluster first: on
    /// the development Mac the device tree puts the twelve "Performance" cores at 0-11 and the
    /// six "Super" cores at 12-17, and an M1 puts its four efficiency cores at 0-3. So the last
    /// perflevel takes the first indices, and so on back to perflevel 0. The result is in
    /// sysctl's order, fastest first, for display. Nil when the lists disagree or the counts do
    /// not add up to the core count (or one is not positive); the view then falls back to unnamed
    /// per-core bars. To re-check the rule on a new chip, compare each `cpuN` entry's
    /// `cluster-type` from `ioreg -p IODeviceTree -r -c IOPlatformDevice` with `sysctl hw.perflevel*`;
    /// the rule assumes `host_processor_info` index N is the device tree's `cpuN`. Its limit: a chip
    /// whose kernel does not number the slowest cluster first would be mislabelled, not refused,
    /// because no count check can tell.
    static func layout(names: [String], counts: [Int], coreCount: Int) -> [CPUCluster]? {
        guard names.count == counts.count, !names.isEmpty, counts.allSatisfy({ $0 > 0 }),
              counts.reduce(0, +) == coreCount else { return nil }
        var next = 0
        var slowestFirst: [CPUCluster] = []
        for (name, count) in zip(names, counts).reversed() {
            slowestFirst.append(CPUCluster(name: name, cores: next..<(next + count)))
            next += count
        }
        return Array(slowestFirst.reversed())
    }
}

/// What the thermal line shows: the coarse state macOS reports to any process, and, while the
/// tab is showing and on every thermal-state change, the speed limit `pmset -g therm` reports
/// (100 means no throttling).
struct ThermalReading: Equatable {
    let state: ProcessInfo.ThermalState
    let speedLimitPercent: Int?

    /// The line is hidden while there is nothing to say: a nominal state at full speed.
    var isNominal: Bool {
        state == .nominal && (speedLimitPercent ?? 100) >= 100
    }
}

enum CPUThermal {
    /// `pmset -g therm` prints `CPU_Speed_Limit = 80` under "CPU Power notify" while throttled,
    /// and "No CPU power status has been recorded" when nothing has happened. Nil for the latter,
    /// and for any output without a numeric line.
    static func parseSpeedLimit(_ output: String) -> Int? {
        for line in output.split(whereSeparator: \.isNewline) where line.contains("CPU_Speed_Limit") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}

/// The 1, 5 and 15-minute load averages: runnable threads, so "6.2 of 18 cores" reads as how many
/// cores could have been kept busy.
struct LoadAverages: Equatable {
    let one: Double
    let five: Double
    let fifteen: Double

    static let zero = LoadAverages(one: 0, five: 0, fifteen: 0)
}

/// How the machine-state column words its figures.
enum CPUFormat {
    private static let secondsPerMinute = 60
    private static let secondsPerHour = 3_600
    private static let secondsPerDay = 86_400

    /// "load 6.2 · 5.1 · 4.0 of 18 cores": 1, 5 and 15 minutes against the core count.
    static func loadLine(_ loads: LoadAverages, coreCount: Int) -> String {
        let figures = [loads.one, loads.five, loads.fifteen].map { String(format: "%.1f", $0) }
        return "load \(figures.joined(separator: " · ")) of \(coreCount) \(coreCount == 1 ? "core" : "cores")"
    }

    /// A list row's memory figure, in Activity Monitor's 1024-based style.
    static func processMemory(_ bytes: UInt64) -> String {
        "Memory \(memoryByteString(bytes))"
    }

    /// The drill-in header's right-hand side: the process's memory and how long it has run.
    static func drillSummary(memory: UInt64, uptime: String) -> String {
        "\(memoryByteString(memory)) · up \(uptime)"
    }

    /// The two largest units, whole: "up 3d 4h", "up 4h 12m", "up 12m". A negative interval (the
    /// clock stepped back) reads as just booted rather than as a minus sign.
    static func uptime(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        if total >= secondsPerDay {
            return "up \(total / secondsPerDay)d \(total % secondsPerDay / secondsPerHour)h"
        }
        if total >= secondsPerHour {
            return "up \(total / secondsPerHour)h \(total % secondsPerHour / secondsPerMinute)m"
        }
        if total >= secondsPerMinute { return "up \(total / secondsPerMinute)m" }
        return "up under a minute"
    }
}

/// What the left column says beyond the headline and the feed: read every
/// `CPUSampling.refreshInterval` while the tab is showing, and on every thermal-state change.
struct MachineState: Equatable {
    let loads: LoadAverages
    /// Seconds since boot, or nil when the kernel would not say.
    let uptime: TimeInterval?
    let coreCount: Int
    let thermal: ThermalReading
    let sampledAt: Date

    /// Before the first collect: the view hides the load line while `coreCount` is 0.
    static let empty = MachineState(
        loads: .zero,
        uptime: nil,
        coreCount: 0,
        thermal: ThermalReading(state: .nominal, speedLimitPercent: nil),
        sampledAt: .distantPast
    )
}
