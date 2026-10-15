import SwiftUI
import SystemBarKit

/// The latency section: the latest router and internet figures, both lines on one graph with
/// failed pings as red marks, and a line saying what is likely at fault when the internet fails.
struct LatencySection: View {
    let state: LatencyState

    static let routerColor = Palette.cyan
    static let internetColor = Palette.purple

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                SectionTitle("Latency")
                Spacer()
                LatencyFigure(label: "Router", point: state.history.latest?.router, color: Self.routerColor)
                LatencyFigure(label: "Internet", point: state.history.latest?.internet, color: Self.internetColor)
            }
            LatencyGraph(samples: state.history.samples)
                .frame(height: 54)
            HStack(spacing: 12) {
                LegendLabel(text: "Router", color: Self.routerColor)
                LegendLabel(text: "Internet (\(state.internetAddress))", color: Self.internetColor)
                LegendLabel(text: "Failed", color: Palette.critical)
                Spacer()
                ChartUnitLabel("ms - last 5 min")
            }
            if let note = state.settingsProblem ?? state.history.diagnosis?.text {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct LatencyFigure: View {
    let label: String
    let point: LatencyPoint?
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(latencyText(point))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(point?.isFailure == true ? Palette.critical : color)
        }
        .help(point.flatMap(failureReason) ?? "")
    }

    private func failureReason(_ point: LatencyPoint) -> String? {
        if case .failed(let reason) = point { return reason }
        return nil
    }
}

/// Five minutes of pings across the full width, so the time axis never stretches. Each line breaks
/// where a ping did not answer; a failed ping is a red mark at the height of its line's last
/// reply, or at the top when there was none.
struct LatencyGraph: View {
    let samples: [LatencySample]

    private static let markSize: CGFloat = 4
    private static let minimumScale = 10.0

    var body: some View {
        Canvas { context, size in
            // Inset by a mark, so a point or a red mark at an edge is drawn whole.
            let plot = CGRect(origin: .zero, size: size).insetBy(dx: Self.markSize, dy: Self.markSize)
            let replies = samples.flatMap { [$0.router.milliseconds, $0.internet.milliseconds] }.compactMap { $0 }
            let scale = max(replies.max() ?? 0, Self.minimumScale)
            let step = plot.width / CGFloat(max(LatencyHistory.capacity - 1, 1))
            let firstSlot = LatencyHistory.capacity - samples.count
            let x = { (index: Int) in plot.minX + CGFloat(firstSlot + index) * step }
            let y = { (milliseconds: Double) in plot.minY + plot.height * (1 - CGFloat(milliseconds / scale)) }
            draw(\.router, color: LatencySection.routerColor, in: &context, top: plot.minY, x: x, y: y)
            draw(\.internet, color: LatencySection.internetColor, in: &context, top: plot.minY, x: x, y: y)
        }
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// One line, broken at every sample without a reply; a reply with none either side is a dot.
    private func draw(_ line: KeyPath<LatencySample, LatencyPoint>, color: Color, in context: inout GraphicsContext, top: CGFloat, x: (Int) -> CGFloat, y: (Double) -> CGFloat) {
        var path = Path()
        var isDrawing = false
        var lastY = top
        for (index, sample) in samples.enumerated() {
            let value = sample[keyPath: line]
            guard let milliseconds = value.milliseconds else {
                isDrawing = false
                if value.isFailure { context.fill(mark(at: CGPoint(x: x(index), y: lastY)), with: .color(Palette.critical)) }
                continue
            }
            let next = CGPoint(x: x(index), y: y(milliseconds))
            let isAlone = !isDrawing && (index + 1 == samples.count || samples[index + 1][keyPath: line].milliseconds == nil)
            if isAlone { context.fill(mark(at: next), with: .color(color)) }
            if isDrawing { path.addLine(to: next) } else { path.move(to: next) }
            isDrawing = true
            lastY = next.y
        }
        context.stroke(path, with: .color(color), lineWidth: 1.5)
    }

    private func mark(at center: CGPoint) -> Path {
        Path(ellipseIn: CGRect(x: center.x - Self.markSize / 2, y: center.y - Self.markSize / 2, width: Self.markSize, height: Self.markSize))
    }
}
