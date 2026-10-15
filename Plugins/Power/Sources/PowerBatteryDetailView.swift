import SwiftUI
import SystemBarKit

/// Health, cycles, the battery's temperature and time remaining, one pill each for the readings
/// the driver gave.
struct BatteryDetailView: View {
    let detail: BatteryDetail
    let state: ChargeState?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Battery")
            HStack(spacing: 10) {
                ForEach(pills, id: \.label) { pill in
                    StatPill(label: pill.label, value: pill.value)
                }
            }
            if detail.healthPercent != nil {
                Text("Health is full-charge capacity over design capacity. It can pass 100% on a new battery and will not match System Settings exactly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var pills: [PillText] {
        [
            detail.healthPercent.map { PillText(label: "Health", value: batteryHealthLabel($0)) },
            detail.cycleCount.map { PillText(label: "Cycles", value: "\($0)") },
            detail.temperatureCelsius.map { PillText(label: "Battery temp", value: batteryTemperatureLabel($0)) },
            timeRemainingPill(state: state, minutes: detail.minutesRemaining),
        ]
        .compactMap { $0 }
    }
}
