import Foundation

/// Watts through the Mac, by spec P1 as amended after the battery probe. Each is nil when it
/// cannot be stood behind, never 0 W as a stand-in for absent. On AC the Mac figure takes the
/// battery's instant watts off SystemPowerIn, which is averaged over about a minute, so for a
/// minute after charging starts or stops (at the limit, say) it can read high or low.
struct PowerDraw: Equatable {
    /// What the Mac itself draws.
    var macWatts: Double?
    /// Signed: positive into the battery, negative out of it.
    var batteryWatts: Double?
    /// The charger's rating, only while one is connected.
    var chargerRatedWatts: Int?
}

extension PowerCollector {
    /// Nil when the entry is missing or holds none of the figures. `sourceJustChanged` is true
    /// within `SourceChangeTracker.lagWindow` of a plug or unplug, while `PowerTelemetryData`
    /// still lags.
    static func powerDraw(from battery: [String: Any]?, sourceJustChanged: Bool) -> PowerDraw? {
        guard let battery else { return nil }
        let isExternal = battery["ExternalConnected"] as? Bool ?? false
        let telemetry = battery["PowerTelemetryData"] as? [String: Any]
        let powerIn = positive(milliToUnit(telemetry?["SystemPowerIn"]))
        let hasBattery = battery["BatteryInstalled"] as? Bool ?? (battery["Voltage"] != nil)
        let batteryFlow = hasBattery ? batteryWatts(from: battery) : nil
        let adapterWatts = (battery["AdapterDetails"] as? [String: Any])?["Watts"] as? Int

        let mac: Double?
        if !hasBattery {
            mac = powerIn
        } else if !isExternal {
            // Never the charger's input while unplugged, however stale the telemetry is.
            mac = positive(batteryFlow.map(abs))
        } else if sourceJustChanged {
            mac = nil
        } else {
            // What comes in, less what the battery takes (or plus what it gives).
            mac = positive(powerIn.map { $0 - (batteryFlow ?? 0) })
        }

        let draw = PowerDraw(
            macWatts: mac,
            batteryWatts: batteryFlow,
            chargerRatedWatts: isExternal ? adapterWatts.flatMap { $0 > 0 ? $0 : nil } : nil
        )
        return draw == PowerDraw() ? nil : draw
    }

    /// Voltage x Amperage. Amperage is signed (negative is discharge), even where ioreg prints it
    /// as an unsigned 64-bit number.
    static func batteryWatts(from battery: [String: Any]) -> Double? {
        guard let voltage = battery["Voltage"] as? Int, voltage > 0,
              let amperage = (battery["Amperage"] as? NSNumber)?.int64Value
        else { return nil }
        return Double(voltage) * Double(amperage) / 1_000_000
    }

    private static func milliToUnit(_ value: Any?) -> Double? {
        (value as? NSNumber).map { $0.doubleValue / 1000 }
    }

    private static func positive(_ watts: Double?) -> Double? {
        watts.flatMap { $0 > 0 ? $0 : nil }
    }
}

func wattsLabel(_ watts: Double) -> String {
    String(format: "%.1f W", watts)
}

/// Below this the battery is neither charging nor giving, whatever the sign says.
private let idleBatteryWatts = 0.05

func batteryFlowLabel(_ watts: Double) -> String {
    if abs(watts) < idleBatteryWatts { return "Idle" }
    return watts > 0 ? "\(wattsLabel(watts)) in" : "\(wattsLabel(-watts)) out"
}

func chargerLabel(_ ratedWatts: Int) -> String {
    "\(ratedWatts) W rated"
}
