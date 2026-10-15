import Foundation

/// What the battery is doing, as the battery driver reports it. pmset's words are not used:
/// "not charging" and "discharging" both contain "charging".
enum ChargeState: Equatable {
    case charging
    case discharging
    case full
    case heldAtLimit
    case onACNotCharging
}

extension PowerCollector {
    static let ioregPath = "/usr/sbin/ioreg"
    static let ioregArguments = ["-r", "-n", "AppleSmartBattery", "-a"]

    /// The `ChargerData.NotChargingReason` bit seen while this Mac sat at its 80% charge limit.
    /// Any other reason reads as on AC, not charging, so a pause for some other cause is never
    /// called the limit.
    static let chargeLimitReason = 0x0100_0000

    /// Reads `ioreg -r -n AppleSmartBattery -a`. Nil when there is no battery (ioreg prints
    /// nothing) or the reading cannot be understood, so the panel asserts nothing.
    static func parseChargeState(_ output: String) -> ChargeState? {
        guard let data = output.data(using: .utf8),
              let entries = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]],
              let battery = entries.first,
              let isExternal = battery["ExternalConnected"] as? Bool,
              let isCharging = battery["IsCharging"] as? Bool,
              let isFull = battery["FullyCharged"] as? Bool
        else { return nil }

        if isCharging { return .charging }
        if !isExternal { return .discharging }
        if isFull { return .full }
        let reason = (battery["ChargerData"] as? [String: Any])?["NotChargingReason"] as? Int ?? 0
        return reason & chargeLimitReason != 0 ? .heldAtLimit : .onACNotCharging
    }
}
