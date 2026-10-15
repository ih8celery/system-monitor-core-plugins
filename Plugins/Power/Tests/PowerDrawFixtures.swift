import Foundation

/// ioreg battery entries for the power-draw tests, on the captured shape in `PowerFixtures`.
/// Captured on the development Mac on 2026-10-14 unless named otherwise.
enum PowerDrawFixtures {
    /// The power keys of one entry. A nil leaves that key out, as ioreg would.
    struct Power {
        var batteryInstalled: Bool? = true
        var voltage: Int?
        var amperage: Int?
        var adapterWatts: Int?
        var systemPowerIn: Int?
        var systemLoad: Int?
        var batteryPower: Int?

        var xml: String {
            func integer(_ key: String, _ value: Int?, _ indent: String = "\t\t") -> String {
                value.map { "\(indent)<key>\(key)</key>\n\(indent)<integer>\($0)</integer>\n" } ?? ""
            }
            let installed = batteryInstalled.map { "\t\t<key>BatteryInstalled</key>\n\t\t<\($0)/>\n" } ?? ""
            let adapter = "\t\t<key>AdapterDetails</key>\n\t\t<dict>\n\t\t\t<key>FamilyCode</key>\n\t\t\t<integer>0</integer>\n"
                + integer("Watts", adapterWatts, "\t\t\t") + "\t\t</dict>\n"
            let telemetry = "\t\t<key>PowerTelemetryData</key>\n\t\t<dict>\n"
                + integer("BatteryPower", batteryPower, "\t\t\t") + integer("SystemLoad", systemLoad, "\t\t\t")
                + integer("SystemPowerIn", systemPowerIn, "\t\t\t") + "\t\t</dict>\n"
            return installed + adapter + integer("Amperage", amperage) + integer("Voltage", voltage) + telemetry
        }
    }

    /// On the 94 W charger, held at 80%, the battery idle: the 3wj.1.3 probe's AC reading.
    static let acIdle = PowerFixtures.ioreg(
        external: true, fullyCharged: false, charging: false, capacity: 80, notChargingReason: 16_777_216,
        extraKeys: Power(voltage: 12497, amperage: 0, adapterWatts: 94, systemPowerIn: 46496, systemLoad: 46496, batteryPower: 0).xml
    )

    /// On the 94 W charger and charging at 20%, captured by the coordinator on 2026-10-14 at
    /// 21:11 with `ioreg -rn AppleSmartBattery -a`, over a minute after charging began so the
    /// telemetry had caught up (log: battery-probe.txt in the coordinator's run folder).
    /// SystemPowerIn includes the charge current: SystemVoltageIn 19556 mV x SystemCurrentIn
    /// 3975 mA is the same 77.7 W. The telemetry's BatteryPower reads -6.2 W while the battery
    /// takes +50.2 W, and SystemLoad 83.9 W; the collector uses neither.
    static let acCharging = acChargingWith(systemLoad: 83935, batteryPower: -6199)

    /// The charging capture with its telemetry battery and load figures replaced.
    static func acChargingWith(systemLoad: Int, batteryPower: Int) -> String {
        PowerFixtures.ioreg(
            external: true, fullyCharged: false, charging: true, capacity: 20, notChargingReason: 0,
            rawMaxCapacity: 6240, cycleCount: 25, temperature: 3092, timeRemaining: 137,
            extraKeys: Power(
                voltage: 11529, amperage: 4356, adapterWatts: 94,
                systemPowerIn: 77736, systemLoad: systemLoad, batteryPower: batteryPower
            ).xml
        )
    }

    /// Unplugged and settled, 20:37: the telemetry reads -12.1 W while the battery gives 48.4 W.
    static let onBattery = PowerFixtures.ioreg(
        external: false, fullyCharged: false, charging: false, capacity: 54, notChargingReason: 128,
        rawMaxCapacity: 6270, temperature: 3093, timeRemaining: 47,
        extraKeys: Power(voltage: 11398, amperage: -4246, systemPowerIn: 0, systemLoad: -12102, batteryPower: 12102).xml
    )

    /// The first reading after the user unplugged, 20:13 (the coordinator's battery probe): the
    /// telemetry still holds the charger's 84.8 W in while ExternalConnected is already false.
    static let justUnplugged = PowerFixtures.ioreg(
        external: false, fullyCharged: false, charging: false, capacity: 80, notChargingReason: 0,
        extraKeys: Power(voltage: 12487, amperage: -158, systemPowerIn: 84810, systemLoad: 87030, batteryPower: -2230).xml
    )

    /// Amperage stored as the signed value's unsigned 64-bit form. `ioreg -a`, which the
    /// collector reads, prints it signed; reading through `int64Value` is right for either.
    static let onBatteryUnsignedAmperage = PowerFixtures.ioreg(
        external: false, fullyCharged: false, charging: false, capacity: 54, notChargingReason: 128,
        extraKeys: Power(voltage: 11398, amperage: nil, systemPowerIn: 0).xml
            + "\t\t<key>Amperage</key>\n\t\t<integer>18446744073709547370</integer>\n"
    )

    /// A Mac with no battery whose entry still reports what comes in. Not captured: no desktop
    /// Mac was available.
    static let noBatteryWithInput = PowerFixtures.ioreg(
        external: true, fullyCharged: false, charging: false, capacity: 0, notChargingReason: 0,
        rawMaxCapacity: nil, designCapacity: nil, cycleCount: nil, temperature: nil, timeRemaining: nil,
        extraKeys: Power(batteryInstalled: false, systemPowerIn: 31600).xml
    )

    static let noBatteryNoFigures = PowerFixtures.ioreg(
        external: true, fullyCharged: false, charging: false, capacity: 0, notChargingReason: 0,
        rawMaxCapacity: nil, designCapacity: nil, cycleCount: nil, temperature: nil, timeRemaining: nil,
        extraKeys: Power(batteryInstalled: false).xml
    )
}
