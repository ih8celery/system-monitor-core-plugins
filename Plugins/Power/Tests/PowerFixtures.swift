import Foundation

/// Battery readings for the Power tests. The "held" pair was captured on the development Mac on
/// 2026-10-14 while it sat at its 80% charge limit on a charger. The ioreg one is cut down to the
/// keys the collector reads, which keeps the battery's serial number out of the repo; the values
/// are as captured. The rest are that capture with only the named fields changed, because a
/// state like discharging cannot be captured without unplugging the Mac.
enum PowerFixtures {
    static let pmsetHeld = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=23396451)\t80%; AC attached; not charging present: true\n"

    static let ioregHeld = ioreg(external: true, fullyCharged: false, charging: false, capacity: 80, notChargingReason: 16_777_216)

    static let pmsetDischarging = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=23396451)\t79%; discharging; 5:12 remaining present: true\n"

    static let ioregDischarging = ioreg(external: false, fullyCharged: false, charging: false, capacity: 79, notChargingReason: 0)

    static let ioregCharging = ioreg(external: true, fullyCharged: false, charging: true, capacity: 64, notChargingReason: 0)

    static let ioregFull = ioreg(external: true, fullyCharged: true, charging: false, capacity: 100, notChargingReason: 0)

    /// The captured shape, with the five readings the collector looks at filled in.
    static func ioreg(external: Bool, fullyCharged: Bool, charging: Bool, capacity: Int, notChargingReason: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <array>
        \t<dict>
        \t\t<key>ChargerData</key>
        \t\t<dict>
        \t\t\t<key>NotChargingReason</key>
        \t\t\t<integer>\(notChargingReason)</integer>
        \t\t</dict>
        \t\t<key>CurrentCapacity</key>
        \t\t<integer>\(capacity)</integer>
        \t\t<key>ExternalConnected</key>
        \t\t<\(external)/>
        \t\t<key>FullyCharged</key>
        \t\t<\(fullyCharged)/>
        \t\t<key>IsCharging</key>
        \t\t<\(charging)/>
        \t\t<key>MaxCapacity</key>
        \t\t<integer>100</integer>
        \t</dict>
        </array>
        </plist>
        """
    }
}
