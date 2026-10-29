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
    /// What the charger puts in: the Mac plus what the battery takes (less what it gives), as
    /// SystemPowerIn is. On AC it always equals the charger's arrows: charger to Mac plus charger
    /// to battery, and the Mac's draw is charger to Mac plus battery to Mac.
    let chargerInWatts: Double?

    /// Nil without a charger reading from the battery driver. While `isSettling`, every arrow
    /// keeps its place but drops its number: just after a plug or unplug even Amperage lags, so
    /// the battery's direction comes from the driver's `isCharging` instead of its watts.
    init?(draw: PowerDraw?, isExternal: Bool?, isSettling: Bool, isCharging driverSaysCharging: Bool = false) {
        guard let isExternal else { return nil }
        let mac = isSettling ? nil : draw?.macWatts
        let battery = isSettling ? nil : draw?.batteryWatts
        let flow = battery ?? 0
        let isCharging = isSettling ? driverSaysCharging : flow >= idleBatteryWatts
        let isGiving = !isSettling && flow <= -idleBatteryWatts
        // An idle battery lights no arrow, so it adds nothing to the sums either.
        let counted = isCharging || isGiving ? flow : 0

        isPluggedIn = isExternal
        hasBattery = draw?.hasBattery ?? false
        if isExternal {
            // While the battery gives, the charger's arrow carries only its share of the Mac.
            chargerToMac = .active(isGiving ? mac.map { $0 + counted } : mac)
            chargerToBattery = isCharging ? .active(battery) : .inactive
            batteryToMac = isGiving ? .active(battery.map(abs)) : .inactive
            chargerInWatts = mac.map { $0 + counted }
        } else {
            chargerToMac = .inactive
            chargerToBattery = .inactive
            batteryToMac = .active(mac)
            chargerInWatts = nil
        }
    }
}
