import SwiftUI
import SystemBarKit

/// The battery's charge as a bar, with the charge limit marked on it when one is set below 100%.
struct BatteryBarView: View {
    let percent: Int
    let limit: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressBar(value: Double(percent) / 100, color: Palette.good)
                .frame(height: 8)
                .overlay(alignment: .leading) { marker }
            if let limit, chargeLimitMarkerFraction(limit) != nil {
                Text("Charge limit \(limit)%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
    }

    @ViewBuilder private var marker: some View {
        if let fraction = chargeLimitMarkerFraction(limit) {
            GeometryReader { geometry in
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 2, height: 16)
                    .offset(x: geometry.size.width * fraction - 1, y: -4)
            }
        }
    }
}
