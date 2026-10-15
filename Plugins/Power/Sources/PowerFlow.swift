import Foundation

/// One arrow in the flow picture: not drawn, or drawn with its watts, or drawn with no number
/// when the figure is missing or the telemetry is still settling.
enum FlowLink: Equatable {
    case inactive
    case active(Double?)
}

/// Where power goes, from the power draw: charger to Mac and to the battery on AC, battery to
/// Mac when unplugged (or topping up a charger the Mac outruns).
struct PowerFlow: Equatable {
    let isPluggedIn: Bool
    let hasBattery: Bool
    let chargerToMac: FlowLink
    let chargerToBattery: FlowLink
    let batteryToMac: FlowLink
    /// What the charger puts in: the Mac plus what the battery takes, as SystemPowerIn is.
    let chargerInWatts: Double?

    /// Nil without a charger reading from the battery driver. While `isSettling`, every arrow
    /// keeps its place but drops its number: just after a plug or unplug even Amperage lags.
    init?(draw: PowerDraw?, isExternal: Bool?, isSettling: Bool) {
        guard let isExternal else { return nil }
        let mac = isSettling ? nil : draw?.macWatts
        let battery = isSettling ? nil : draw?.batteryWatts
        let flow = draw?.batteryWatts ?? 0
        let isCharging = flow >= idleBatteryWatts
        let isGiving = flow <= -idleBatteryWatts

        isPluggedIn = isExternal
        hasBattery = draw?.batteryWatts != nil
        if isExternal {
            chargerToMac = .active(mac)
            chargerToBattery = isCharging ? .active(battery) : .inactive
            batteryToMac = isGiving ? .active(battery.map(abs)) : .inactive
            chargerInWatts = mac.map { $0 + (battery ?? 0) }
        } else {
            chargerToMac = .inactive
            chargerToBattery = .inactive
            batteryToMac = .active(mac)
            chargerInWatts = nil
        }
    }
}
