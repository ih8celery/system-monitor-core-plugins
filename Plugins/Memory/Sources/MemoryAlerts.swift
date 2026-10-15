import Foundation
import SystemBarKit

/// The Memory tab's notification settings. Every key is optional; a wrong one keeps its default
/// and is reported, because a misspelt setting must never silently do nothing.
struct MemoryAlertConfig: Equatable {
    static let defaultSwapMegabytesPerMinute = 100.0
    static let defaultSwapMinutes = 5.0
    /// Past these a setting is a typo, not a choice.
    static let swapMegabytesPerMinuteRange = 1.0...1_000_000.0
    static let swapMinutesRange = 1.0...60.0

    /// Pressure reaches warning or critical.
    var notifyPressure = true
    /// Swapping in and out at or above `swapMegabytesPerMinute`, averaged over `swapMinutes`.
    var notifySwap = true
    var swapMegabytesPerMinute = defaultSwapMegabytesPerMinute
    var swapMinutes = defaultSwapMinutes

    /// The config the settings describe, and one line per setting that could not be used.
    static func parse(_ settings: PluginSettings) -> (config: MemoryAlertConfig, problems: [String]) {
        var config = MemoryAlertConfig()
        var problems: [String] = []
        func flag(_ key: String, _ apply: (Bool) -> Void) {
            guard settings[key] != nil else { return }
            guard let value = settings.bool(forKey: key) else {
                return problems.append("settings: \"\(key)\" must be true or false; the default stays")
            }
            apply(value)
        }
        func number(_ key: String, in range: ClosedRange<Double>, _ apply: (Double) -> Void) {
            guard settings[key] != nil else { return }
            guard let value = settings.number(forKey: key), value.isFinite, range.contains(value) else {
                return problems.append("settings: \"\(key)\" must be a number from \(Int(range.lowerBound)) to \(Int(range.upperBound)); the default stays")
            }
            apply(value)
        }
        flag("notifyPressure") { config.notifyPressure = $0 }
        flag("notifySwap") { config.notifySwap = $0 }
        number("swapMegabytesPerMinute", in: swapMegabytesPerMinuteRange) { config.swapMegabytesPerMinute = $0 }
        number("swapMinutes", in: swapMinutesRange) { config.swapMinutes = $0 }
        return (config, problems)
    }
}

/// What the rules remember between samples: which condition each one is in now, so a rule fires
/// when it crosses into its condition and stays quiet while the condition holds. A value type;
/// `evaluating` returns the next rules and what to post.
struct MemoryAlertRules {
    /// A collect lands at most this far from the one before, so a window this much short is full.
    private static let coverageSlack = MemorySampling.backgroundInterval
    /// Samples further apart than this (a sleep, a stall) leave a hole the rule will not bridge.
    private static let longestGap = 3 * MemorySampling.backgroundInterval
    private static let quietSamplesAllowed = 1

    let config: MemoryAlertConfig
    /// The highest level already announced since pressure last read Normal.
    private var announcedPressure: MemoryPressureLevel = .normal
    private var isSwapping = false
    private var swapWatch: SwapHistory

    init(config: MemoryAlertConfig) {
        self.config = config
        swapWatch = SwapHistory(window: config.swapMinutes * 60)
    }

    func evaluating(_ reading: MemoryReading) -> (rules: MemoryAlertRules, notifications: [PluginNotification]) {
        var next = self
        var notifications: [PluginNotification] = []
        if config.notifyPressure, let note = next.pressureCrossing(reading) { notifications.append(note) }
        if config.notifySwap, let note = next.swapCrossing(reading) { notifications.append(note) }
        return (next, notifications)
    }

    /// Fires on rising into warning or critical, each once until pressure has read Normal again:
    /// easing from critical to warning re-arms nothing, so a level that flickers between the two
    /// is one notification each. An unreadable level changes nothing.
    private mutating func pressureCrossing(_ reading: MemoryReading) -> PluginNotification? {
        guard let level = reading.pressure else { return nil }
        guard level != .normal else {
            announcedPressure = .normal
            return nil
        }
        guard level.severity > announcedPressure.severity else { return nil }
        announcedPressure = level
        switch level {
        case .normal:
            return nil
        case .warning:
            return PluginNotification(
                id: "memory.pressure.warning",
                title: "Memory pressure: Warning",
                body: "macOS has started compressing or swapping to keep up. \(memoryByteString(reading.memory.used)) of \(memoryByteString(reading.memory.total)) is in use."
            )
        case .critical:
            return PluginNotification(
                id: "memory.pressure.critical",
                title: "Memory pressure: Critical",
                body: "macOS is struggling to find memory. \(memoryByteString(reading.memory.used)) of \(memoryByteString(reading.memory.total)) is in use."
            )
        }
    }

    /// Fires when swapping has held at or above the threshold for the whole window: every
    /// stretch between samples at the rate, allowing one quiet sample (the kernel counts in
    /// bursts). One burst, or a window that is short or has a hole in it (a sleep), is not it.
    /// Fires once, and again only after the condition has lapsed.
    private mutating func swapCrossing(_ reading: MemoryReading) -> PluginNotification? {
        swapWatch = swapWatch.recording(reading.memory, at: reading.sampledAt)
        let isAbove = hasSustainedSwapping()
        defer { isSwapping = isAbove }
        guard isAbove, !isSwapping else { return nil }
        return PluginNotification(
            id: "memory.swap",
            title: "Heavy swapping",
            body: "macOS has been swapping at least \(memoryByteString(UInt64(config.swapMegabytesPerMinute * 1_048_576))) a minute for the last \(Int(config.swapMinutes)) minutes."
        )
    }

    private func hasSustainedSwapping() -> Bool {
        guard swapWatch.span >= swapWatch.window - Self.coverageSlack else { return false }
        let thresholdBytesPerSecond = config.swapMegabytesPerMinute * 1_048_576 / 60
        var quietSamples = 0
        for interval in swapWatch.intervals {
            guard interval.seconds > 0, interval.seconds <= Self.longestGap else { return false }
            if Double(interval.bytes) / interval.seconds < thresholdBytesPerSecond { quietSamples += 1 }
        }
        return quietSamples <= Self.quietSamplesAllowed
    }
}

private extension MemoryPressureLevel {
    var severity: Int {
        switch self {
        case .normal: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }
}
