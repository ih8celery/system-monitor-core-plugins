import Foundation
import SystemBarKit

struct PowerContributor: Identifiable {
    var id: String { name }
    let name: String
    let evidence: String
}

struct PowerSnapshot {
    var powerSource = "Unknown"
    var thermalState = "Unknown"
    var batteryPercent: Int?
    var chargeState: ChargeState?
    var batteryDetail: BatteryDetail?
    var chargeLimit: Int?
    var powerDraw: PowerDraw?
    /// Whether the battery driver answered, so no power figures can be told from no sample yet.
    var hasDriverReading = false
    /// The charger as this sample saw it, so the next can tell a plug or unplug.
    var isExternal: Bool?
    var sleepAssertions: [String] = []
    var status = "Waiting for power sample"
    var health = SampleHealth.degraded
}
