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
                LatencyFigure(label: "Router", text: routerLatencyText(state.history.latest), point: state.history.latest?.router, color: Self.routerColor)
                LatencyFigure(label: "Internet", text: latencyText(state.history.latest?.internet), point: state.history.latest?.internet, color: Self.internetColor)
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
            ForEach(state.notes, id: \.self) { note in
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
    let text: String
    let point: LatencyPoint?
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(text)
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

/// Five minutes of pings across the full width, each placed by its time, so the time axis never
/// stretches and a sleep shows as empty space rather than pre- and post-sleep pings side by side.
/// Each line breaks where a ping did not answer and across a gap; a failed ping is a red mark at
/// the height of its line's last reply, or at the top when there was none.
struct LatencyGraph: View {
    let samples: [LatencySample]

    private static let markSize: CGFloat = 4
    private static let minimumScale = 10.0
    /// The graph's span: the history's capacity in rounds.
    static let window = TimeInterval(LatencyHistory.capacity - 1) * NetworkSampling.pingInterval

    /// Where a sample sits: 0 at the graph's left edge to 1 at the latest round, and whether its
    /// line breaks before it because the previous round was too long ago.
    struct Slot: Equatable {
        let fraction: Double
        let breaksBefore: Bool
    }

    /// One slot per sample, in order; nil for a sample older than the window.
    static func slots(for samples: [LatencySample]) -> [Slot?] {
        guard let latest = samples.last?.at else { return [] }
        return samples.indices.map { index in
            let age = latest.timeIntervalSince(samples[index].at)
            guard age <= window else { return nil }
            let gap = index == 0 ? 0 : samples[index].at.timeIntervalSince(samples[index - 1].at)
            return Slot(fraction: 1 - age / window, breaksBefore: gap > NetworkSampling.maximumRoundGap)
        }
    }

    var body: some View {
        Canvas { context, size in
            // Inset by a mark, so a point or a red mark at an edge is drawn whole.
            let plot = CGRect(origin: .zero, size: size).insetBy(dx: Self.markSize, dy: Self.markSize)
            let slots = Self.slots(for: samples)
            let replies = zip(samples, slots).filter { $0.1 != nil }.flatMap { [$0.0.router.milliseconds, $0.0.internet.milliseconds] }.compactMap { $0 }
            let scale = max(replies.max() ?? 0, Self.minimumScale)
            let x = { (slot: Slot) in plot.minX + plot.width * CGFloat(slot.fraction) }
            let y = { (milliseconds: Double) in plot.minY + plot.height * (1 - CGFloat(milliseconds / scale)) }
            draw(\.router, slots: slots, color: LatencySection.routerColor, in: &context, top: plot.minY, x: x, y: y)
            draw(\.internet, slots: slots, color: LatencySection.internetColor, in: &context, top: plot.minY, x: x, y: y)
        }
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// One line, broken at every sample without a reply and across every gap; a reply with no
    /// joined neighbour is a dot.
    private func draw(_ line: KeyPath<LatencySample, LatencyPoint>, slots: [Slot?], color: Color, in context: inout GraphicsContext, top: CGFloat, x: (Slot) -> CGFloat, y: (Double) -> CGFloat) {
        var path = Path()
        var isDrawing = false
        var lastY = top
        for (index, sample) in samples.enumerated() {
            guard let slot = slots[index] else { continue }
            if slot.breaksBefore { isDrawing = false }
            let value = sample[keyPath: line]
            guard let milliseconds = value.milliseconds else {
                isDrawing = false
                if value.isFailure { context.fill(mark(at: CGPoint(x: x(slot), y: lastY)), with: .color(Palette.critical)) }
                continue
            }
            let next = CGPoint(x: x(slot), y: y(milliseconds))
            let isLast = index + 1 == samples.count
            let joinsNext = !isLast && samples[index + 1][keyPath: line].milliseconds != nil && slots[index + 1]?.breaksBefore == false
            if !isDrawing && !joinsNext { context.fill(mark(at: next), with: .color(color)) }
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
