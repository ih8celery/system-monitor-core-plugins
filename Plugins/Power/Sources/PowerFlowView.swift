import SwiftUI
import SystemBarKit

/// The charger on the left, the Mac and the battery on the right, an arrow for each way power
/// is going with its watts on it.
struct PowerFlowView: View {
    let flow: PowerFlow

    /// Each node's height, and the gap the battery-to-Mac arrow spans, so the charger's arrows
    /// meet the Mac and the battery at their middles.
    static let nodeHeight: CGFloat = 54
    static let gap: CGFloat = 30

    var body: some View {
        HStack(spacing: 0) {
            FlowNode(systemImage: "powerplug.fill", title: "Charger", detail: chargerDetail, isLit: flow.isPluggedIn)
            VStack(spacing: Self.gap) {
                FlowArrow(link: flow.chargerToMac)
                    .frame(height: Self.nodeHeight)
                if flow.hasBattery {
                    FlowArrow(link: flow.chargerToBattery)
                        .frame(height: Self.nodeHeight)
                }
            }
            .frame(width: 120)
            VStack(spacing: 0) {
                FlowNode(systemImage: "laptopcomputer", title: "Mac", detail: nil, isLit: true)
                if flow.hasBattery {
                    FlowArrow(link: flow.batteryToMac, axis: .vertical)
                        .frame(height: Self.gap)
                    FlowNode(systemImage: "battery.75percent", title: "Battery", detail: batteryDetail, isLit: true)
                }
            }
        }
        .fixedSize()
    }

    private var chargerDetail: String {
        guard flow.isPluggedIn else { return "Unplugged" }
        return flow.chargerInWatts.map { "\(wattsLabel($0)) in" } ?? " "
    }

    private var batteryDetail: String? {
        flow.chargerToBattery == .inactive && flow.batteryToMac == .inactive ? "Idle" : nil
    }
}

private struct FlowNode: View {
    let systemImage: String
    let title: String
    let detail: String?
    let isLit: Bool

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
            Text(title).font(.caption.weight(.semibold))
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 76, height: PowerFlowView.nodeHeight)
        .opacity(isLit ? 1 : 0.35)
    }
}

/// A line with a head, and its watts above it. An inactive link is a faint line with no head.
private struct FlowArrow: View {
    let link: FlowLink
    var axis: Axis = .horizontal

    var body: some View {
        let isActive = link != .inactive
        let line = Capsule().fill(isActive ? Palette.good : Color.white.opacity(0.12))
        Group {
            if axis == .horizontal {
                HStack(spacing: 0) {
                    line.frame(height: 2)
                    if isActive { head("arrowtriangle.right.fill") }
                }
                .overlay(alignment: .top) { label.offset(y: -16) }
            } else {
                VStack(spacing: 0) {
                    if isActive { head("arrowtriangle.up.fill") }
                    line.frame(width: 2)
                }
                .overlay(alignment: .trailing) { label.fixedSize().offset(x: 54) }
            }
        }
    }

    private func head(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 9)).foregroundStyle(Palette.good)
    }

    @ViewBuilder private var label: some View {
        if case .active(let watts?) = link {
            Text(wattsLabel(watts)).font(.caption.monospacedDigit())
        }
    }
}
