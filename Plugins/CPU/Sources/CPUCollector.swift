import Darwin
import Foundation
import SystemBarKit

/// The CPU tab's own reads: the chip's clusters from sysctl (once; a chip does not change), and
/// the load averages, uptime, thermal state and `pmset -g therm` on every collect while showing.
enum CPUCollector {
    static let pmsetPath = "/usr/bin/pmset"
    static let pmsetArguments = ["-g", "therm"]

    /// The clusters sysctl describes, laid over the kernel's core indices by `CPUClusters.layout`,
    /// or nil when sysctl has no perflevels or their counts do not match `coreCount`.
    static func clusters(coreCount: Int = ProcessInfo.processInfo.activeProcessorCount) -> [CPUCluster]? {
        guard let levels = sysctlInt("hw.nperflevels"), levels > 0 else { return nil }
        var names: [String] = []
        var counts: [Int] = []
        for level in 0..<levels {
            guard let name = sysctlString("hw.perflevel\(level).name"),
                  let count = sysctlInt("hw.perflevel\(level).logicalcpu") else { return nil }
            names.append(name)
            counts.append(count)
        }
        return CPUClusters.layout(names: names, counts: counts, coreCount: coreCount)
    }

    /// One reading of what the feed does not carry. `pmset` goes through the host so a test can
    /// answer it; the load averages, boot time and thermal state are kernel calls that cannot usefully fail.
    static func machineState(using host: HostServices, now: Date = Date()) -> MachineState {
        let therm = host.run(path: pmsetPath, arguments: pmsetArguments)
        let speedLimit = therm.status == 0 ? CPUThermal.parseSpeedLimit(therm.output) : nil
        return MachineState(
            loads: loadAverages(),
            uptime: uptime(bootedAt: bootTime(), now: now),
            coreCount: ProcessInfo.processInfo.activeProcessorCount,
            thermal: ThermalReading(state: ProcessInfo.processInfo.thermalState, speedLimitPercent: speedLimit),
            sampledAt: now
        )
    }

    /// The 1, 5 and 15-minute load averages; all zero if the kernel will not say, and any average
    /// it returns fewer than three of reads 0.
    static func loadAverages() -> LoadAverages {
        var loads = [Double](repeating: 0, count: 3)
        let filled = getloadavg(&loads, 3)
        guard filled >= 1 else { return .zero }
        return LoadAverages(
            one: loads[0],
            five: filled >= 2 ? loads[1] : 0,
            fifteen: filled >= 3 ? loads[2] : 0
        )
    }

    /// When the Mac booted, from `kern.boottime`, or nil when the kernel will not say.
    static func bootTime() -> Date? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))
    }

    static func uptime(bootedAt boot: Date?, now: Date) -> TimeInterval? {
        boot.map { now.timeIntervalSince($0) }
    }

    /// These are 32-bit `CTLTYPE_INT` values, so `Int32` is the right size; do not widen it to `Int`.
    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
