import SwiftUI
import SystemBarKit

/// The Mac's draw over the last hour, with the day behind a toggle.
struct PowerHistoryView: View {
    let history: PowerHistory
    @State private var span: HistorySpan

    init(history: PowerHistory, span: HistorySpan = .hour) {
        self.history = history
        _span = State(initialValue: span)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle("Draw over time")
                Spacer()
                SpanToggle(span: $span)
            }
            if history.points.isEmpty {
                Text("No readings yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                PowerHistoryGraph(history: history, span: span)
                    .frame(height: 90)
                HStack {
                    Text(span == .hour ? "1 h ago" : "24 h ago")
                    Spacer()
                    Text("now")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Hour or Day, as two small buttons drawn in SwiftUI (an AppKit segmented control does not
/// render in the preview pictures).
private struct SpanToggle: View {
    @Binding var span: HistorySpan

    var body: some View {
        HStack(spacing: 2) {
            ForEach(HistorySpan.allCases, id: \.self) { option in
                Button { span = option } label: {
                    Text(option.rawValue)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .foregroundStyle(span == option ? Color.primary : Color.secondary)
                        .background(span == option ? Color.primary.opacity(0.18) : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(span == option ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }
}

/// One line per run of consecutive minutes, filled below. Time runs left to right across the
/// whole span ending at the newest minute, so missing minutes are empty space.
struct PowerHistoryGraph: View {
    let history: PowerHistory
    let span: HistorySpan

    var body: some View {
        let runs = history.runs(in: span)
        let top = historyScaleTop(runs.joined().map(\.watts).max() ?? 0)
        Canvas { context, size in
            guard let end = history.windowEnd else { return }
            let start = end.addingTimeInterval(-span.duration)
            func point(_ sample: MinutePoint) -> CGPoint {
                let middle = sample.minute.addingTimeInterval(PowerHistory.minuteLength / 2)
                let x = size.width * middle.timeIntervalSince(start) / span.duration
                return CGPoint(x: x, y: size.height * (1 - min(1, sample.watts / top)))
            }
            for run in runs {
                let line = Self.path(through: run.map(point))
                var area = line
                area.addLine(to: CGPoint(x: point(run[run.count - 1]).x, y: size.height))
                area.addLine(to: CGPoint(x: point(run[0]).x, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .color(Palette.caution.opacity(0.25)))
                context.stroke(line, with: .color(Palette.caution), lineWidth: 1.5)
            }
        }
        .overlay(alignment: .topLeading) {
            Text(wattsAxisLabel(top))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(4)
        }
        .background(Color.primary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// A lone minute is drawn as a short dash so it still shows.
    private static func path(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        if points.count == 1 {
            path.move(to: CGPoint(x: first.x - 1.5, y: first.y))
            path.addLine(to: CGPoint(x: first.x + 1.5, y: first.y))
            return path
        }
        path.move(to: first)
        points.dropFirst().forEach { path.addLine(to: $0) }
        return path
    }
}

/// The scale's top, a whole number of watts.
func wattsAxisLabel(_ watts: Double) -> String {
    "\(Int(watts)) W"
}
