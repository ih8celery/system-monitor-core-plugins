import Foundation
import SystemBarKit

/// The tab's rule settings, read from its own settings object. Every key is optional; one that is
/// present but wrong keeps its default and is reported, so a typo never silently disables a rule.
///
/// - `cpuAlert` (true/false, default true): tell me when CPU stays high.
/// - `cpuAlertPercent` (1-100, default 90): how high counts as high.
/// - `cpuAlertMinutes` (1-120, default 5): how long it must stay that high.
/// - `thermalAlert` (true/false, default true): tell me when the thermal state turns serious.
struct CPURuleSettings: Equatable {
    var isCPUAlertOn: Bool
    var cpuPercent: Double
    var cpuMinutes: Int
    var isThermalAlertOn: Bool

    static let defaults = CPURuleSettings(isCPUAlertOn: true, cpuPercent: 90, cpuMinutes: 5, isThermalAlertOn: true)
    static let percentRange = 1.0...100.0
    static let minutesRange = 1.0...120.0

    static func parse(_ settings: PluginSettings) -> (settings: CPURuleSettings, problems: [String]) {
        var result = defaults
        var problems: [String] = []

        func flag(_ key: String, _ apply: (Bool) -> Void) {
            guard settings[key] != nil else { return }
            guard let value = settings.bool(forKey: key) else {
                problems.append("settings: \"\(key)\" must be true or false; the default stays")
                return
            }
            apply(value)
        }
        func number(_ key: String, _ range: ClosedRange<Double>, _ apply: (Double) -> Void) {
            guard settings[key] != nil else { return }
            guard let value = settings.number(forKey: key), range.contains(value) else {
                problems.append("settings: \"\(key)\" must be a number from \(Int(range.lowerBound)) to \(Int(range.upperBound)); the default stays")
                return
            }
            apply(value)
        }

        flag("cpuAlert") { result.isCPUAlertOn = $0 }
        flag("thermalAlert") { result.isThermalAlertOn = $0 }
        number("cpuAlertPercent", percentRange) { result.cpuPercent = $0 }
        number("cpuAlertMinutes", minutesRange) { result.cpuMinutes = Int($0.rounded()) }
        return (result, problems)
    }
}

/// Fires once when CPU has stayed at or above the threshold for the whole window, then stays quiet
/// until CPU drops below the threshold and the condition builds up again.
struct SustainedCPUTracker: Equatable {
    private(set) var aboveSince: Date?
    private(set) var hasFired = false

    func observing(percent: Double, at now: Date, threshold: Double, window: TimeInterval) -> (tracker: SustainedCPUTracker, shouldFire: Bool) {
        guard percent >= threshold else { return (SustainedCPUTracker(), false) }
        let since = aboveSince ?? now
        let isDue = !hasFired && now.timeIntervalSince(since) >= window
        return (SustainedCPUTracker(aboveSince: since, hasFired: hasFired || isDue), isDue)
    }
}

/// Fires on the step into serious-or-worse, not while it stays there.
struct ThermalTracker: Equatable {
    var isHot: Bool

    init(state: ProcessInfo.ThermalState) { isHot = Self.isSeriousOrWorse(state) }

    func observing(_ state: ProcessInfo.ThermalState) -> (tracker: ThermalTracker, shouldFire: Bool) {
        let nowHot = Self.isSeriousOrWorse(state)
        return (ThermalTracker(state: state), nowHot && !isHot)
    }

    static func isSeriousOrWorse(_ state: ProcessInfo.ThermalState) -> Bool {
        state == .serious || state == .critical
    }
}

/// Turns readings into notifications. Each rule has one fixed id, because the host keeps one
/// notification per id per hour: a reading in the id would defeat that limit.
final class CPURuleEngine: @unchecked Sendable {
    static let cpuRuleID = "cpu.sustained-high"
    static let thermalRuleID = "cpu.thermal-serious"

    private let host: HostServices
    private let settings: CPURuleSettings
    private let lock = NSLock()
    private var cpuTracker = SustainedCPUTracker()
    private var thermalTracker: ThermalTracker

    /// `thermalState` is the state at load, so a Mac that is already hot has not "crossed" into it.
    init(host: HostServices, thermalState: ProcessInfo.ThermalState) {
        self.host = host
        let parsed = CPURuleSettings.parse(host.settings)
        parsed.problems.forEach(host.log)
        settings = parsed.settings
        thermalTracker = ThermalTracker(state: thermalState)
    }

    func observeCPU(percent: Double, at now: Date) {
        guard settings.isCPUAlertOn else { return }
        let window = TimeInterval(settings.cpuMinutes * 60)
        let shouldFire = lock.withLock { () -> Bool in
            let step = cpuTracker.observing(percent: percent, at: now, threshold: settings.cpuPercent, window: window)
            cpuTracker = step.tracker
            return step.shouldFire
        }
        guard shouldFire else { return }
        let minutes = settings.cpuMinutes
        host.notify(
            id: Self.cpuRuleID,
            title: "CPU has been busy",
            body: "CPU has stayed at \(percentString(settings.cpuPercent)) or more for \(minutes) \(minutes == 1 ? "minute" : "minutes"); it is at \(percentString(percent)) now."
        )
    }

    func observeThermal(_ state: ProcessInfo.ThermalState) {
        guard settings.isThermalAlertOn else { return }
        let shouldFire = lock.withLock { () -> Bool in
            let step = thermalTracker.observing(state)
            thermalTracker = step.tracker
            return step.shouldFire
        }
        guard shouldFire else { return }
        host.notify(
            id: Self.thermalRuleID,
            title: "Mac is running hot",
            body: "The thermal state is \(thermalStateLabel(state).lowercased()): macOS may be slowing the CPU to cool down."
        )
    }
}
