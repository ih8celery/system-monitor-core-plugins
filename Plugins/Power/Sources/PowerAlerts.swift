import Foundation
import SystemBarKit

/// The Power tab's notification settings. Every key is optional; a wrong one keeps its default
/// and is reported, because a misspelt setting must never silently do nothing.
struct PowerAlertConfig: Equatable {
    static let defaultBatteryLowPercent = 20
    /// 0 would never fire and 100 would fire at once; either is a typo, not a choice.
    static let batteryLowPercentRange = 1...99

    /// The battery drops below `batteryLowPercent` while the Mac runs on it.
    var notifyBatteryLow = true
    var batteryLowPercent = defaultBatteryLowPercent
    /// Plugged in, not charging, and well under the charge limit for two minutes.
    var notifyNotCharging = true

    /// The config the settings describe, and one line per setting that could not be used.
    static func parse(_ settings: PluginSettings) -> (config: PowerAlertConfig, problems: [String]) {
        var config = PowerAlertConfig()
        var problems: [String] = []
        func flag(_ key: String, _ apply: (Bool) -> Void) {
            guard settings[key] != nil else { return }
            guard let value = settings.bool(forKey: key) else {
                return problems.append("settings: \"\(key)\" must be true or false; the default stays")
            }
            apply(value)
        }
        flag("notifyBatteryLow") { config.notifyBatteryLow = $0 }
        flag("notifyNotCharging") { config.notifyNotCharging = $0 }
        if settings["batteryLowPercent"] != nil {
            let range = batteryLowPercentRange
            if let value = settings.number(forKey: "batteryLowPercent"), value.rounded() == value, range.contains(Int(exactly: value) ?? 0) {
                config.batteryLowPercent = Int(value)
            } else {
                problems.append("settings: \"batteryLowPercent\" must be a whole number from \(range.lowerBound) to \(range.upperBound); the default \(defaultBatteryLowPercent) stays")
            }
        }
        return (config, problems)
    }
}

/// What the rules need from one battery driver read.
struct BatteryAlertReading: Equatable {
    let isExternal: Bool
    let isCharging: Bool
    let percent: Int
    /// `ChargerData.NotChargingReason`, 0 when the driver gives none.
    let notChargingReason: Int

    init(isExternal: Bool, isCharging: Bool, percent: Int, notChargingReason: Int) {
        self.isExternal = isExternal
        self.isCharging = isCharging
        self.percent = percent
        self.notChargingReason = notChargingReason
    }

    /// Nil for a Mac with no battery, or an entry missing what the rules need: no reading, no rule.
    init?(entry: [String: Any]?) {
        guard let entry, entry["BatteryInstalled"] as? Bool != false,
              let isExternal = entry["ExternalConnected"] as? Bool,
              let current = (entry["CurrentCapacity"] as? NSNumber)?.intValue,
              let maximum = (entry["MaxCapacity"] as? NSNumber)?.intValue, maximum > 0, current >= 0
        else { return nil }
        let charger = entry["ChargerData"] as? [String: Any]
        self.init(
            isExternal: isExternal,
            isCharging: entry["IsCharging"] as? Bool ?? false,
            percent: Int((Double(current) * 100 / Double(maximum)).rounded()),
            notChargingReason: (charger?["NotChargingReason"] as? NSNumber)?.intValue ?? 0
        )
    }
}

/// What the rules remember between samples. A value type; `evaluating` returns the next rules
/// and what to post. Both rules fire once on entering their condition and stay quiet while it
/// holds.
struct PowerAlertRules {
    /// Battery low re-arms only this far above the limit, so a level hovering at it fires once.
    static let rearmPoints = 5
    /// Not charging is normal this close under the charge limit: macOS tops up later.
    static let belowLimitPoints = 5
    /// How long not charging must hold, so macOS's brief pauses never fire it.
    static let notChargingHold: TimeInterval = 2 * 60
    /// Samples further apart than this (a sleep) leave a hole the hold will not bridge. Three
    /// visible minutes; hidden samples are 10 s apart.
    static let longestGap: TimeInterval = 3 * 60

    let config: PowerAlertConfig
    private var isBatteryLowArmed = true
    /// When the current not-charging stretch started being watched, nil when it is not happening.
    private var notChargingSince: Date?
    private var lastSampleAt: Date?
    private var hasAnnouncedNotCharging = false

    init(config: PowerAlertConfig) {
        self.config = config
    }

    /// `chargeLimit` is read only when the Mac is plugged in and not charging, so the hidden
    /// 10-second collect does not read the preferences file for nothing.
    func evaluating(
        _ reading: BatteryAlertReading?, at date: Date, isSettling: Bool, chargeLimit: () -> Int?
    ) -> (rules: PowerAlertRules, notifications: [PluginNotification]) {
        var next = self
        var notifications: [PluginNotification] = []
        if let reading {
            if let note = next.batteryLowCrossing(reading) { notifications.append(note) }
            if let note = next.notChargingCrossing(reading, at: date, isSettling: isSettling, chargeLimit: chargeLimit) { notifications.append(note) }
        } else {
            next.notChargingSince = nil
            next.hasAnnouncedNotCharging = false
        }
        next.lastSampleAt = date
        return (next, notifications)
    }

    private mutating func batteryLowCrossing(_ reading: BatteryAlertReading) -> PluginNotification? {
        let limit = config.batteryLowPercent
        if reading.isExternal || reading.percent >= limit + Self.rearmPoints { isBatteryLowArmed = true }
        guard !reading.isExternal, reading.percent < limit, isBatteryLowArmed else { return nil }
        isBatteryLowArmed = false
        guard config.notifyBatteryLow else { return nil }
        return PluginNotification(
            id: "power.battery-low",
            title: "Battery low: \(reading.percent)%",
            body: "The battery is at \(reading.percent)%, under your \(limit)% warning, and the Mac is running on it. Plug in the charger soon."
        )
    }

    private mutating func notChargingCrossing(
        _ reading: BatteryAlertReading, at date: Date, isSettling: Bool, chargeLimit: () -> Int?
    ) -> PluginNotification? {
        guard reading.isExternal, !reading.isCharging, !isSettling else {
            notChargingSince = nil
            hasAnnouncedNotCharging = false
            return nil
        }
        let limit = chargeLimit()
        guard reading.percent < (limit ?? 100) - Self.belowLimitPoints else {
            notChargingSince = nil
            hasAnnouncedNotCharging = false
            return nil
        }
        if let last = lastSampleAt, date.timeIntervalSince(last) > Self.longestGap { notChargingSince = nil }
        let since = notChargingSince ?? date
        notChargingSince = since
        guard date.timeIntervalSince(since) >= Self.notChargingHold, !hasAnnouncedNotCharging else { return nil }
        hasAnnouncedNotCharging = true
        guard config.notifyNotCharging else { return nil }
        let target = limit.map { "its \($0)% charge limit" } ?? "full"
        let reason = reading.notChargingReason == 0 ? "" : " The battery driver gives NotChargingReason \(reading.notChargingReason)."
        return PluginNotification(
            id: "power.not-charging",
            title: "Plugged in but not charging",
            body: "The battery is at \(reading.percent)% and has not charged for 2 minutes, though it is well short of \(target).\(reason)"
        )
    }
}
