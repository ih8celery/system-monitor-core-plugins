import SwiftUI
import SystemBarKit

/// What the Mac draws, what the battery takes or gives, and the charger's rating: one pill each
/// for the figures there are, or a line saying this Mac reports none.
struct PowerDrawView: View {
    let draw: PowerDraw?
    let flow: PowerFlow?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Power draw")
            if let flow {
                PowerFlowView(flow: flow)
                    .padding(.vertical, 6)
            }
            if pills.isEmpty {
                Text("This Mac reports no power figures.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    ForEach(pills, id: \.label) { pill in
                        StatPill(label: pill.label, value: pill.value)
                    }
                }
            }
        }
    }

    private var pills: [PillText] {
        guard let draw else { return [] }
        return [
            draw.macWatts.map { PillText(label: "Mac", value: wattsLabel($0)) },
            draw.batteryWatts.map { PillText(label: "Battery", value: batteryFlowLabel($0)) },
            draw.chargerRatedWatts.map { PillText(label: "Charger", value: chargerLabel($0)) },
        ]
        .compactMap { $0 }
    }
}
