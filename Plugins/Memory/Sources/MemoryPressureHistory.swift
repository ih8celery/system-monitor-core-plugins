import Foundation
import SwiftUI
import SystemBarKit

/// One sample on the graph: memory used as a share of RAM, and the kernel's pressure level then.
struct PressurePoint: Equatable {
    let at: Date
    let usedShare: Double
    let pressure: MemoryPressureLevel?
}

/// The graph's data: the last `window` seconds of samples, oldest first. A value type, so
/// recording returns the next history and the old one stays as it was.
struct PressureHistory {
    static let window: TimeInterval = 15 * 60
    /// The host calls a hidden tab every 10 s and a showing one every 3 s; a point is kept about
    /// every 10 s either way. A little under 10 so a call that lands a moment early still counts.
    static let minimumSpacing: TimeInterval = 9

    private(set) var points: [PressurePoint] = []

    /// A copy with the reading applied. A reading that did not find the machine's memory adds
    /// nothing (zero would be a claim), and one too soon after the last point adds nothing either.
    func recording(_ reading: MemoryReading) -> PressureHistory {
        let memory = reading.memory
        guard memory.total > 0 else { return self }
        if let last = points.last, reading.sampledAt.timeIntervalSince(last.at) < Self.minimumSpacing { return self }
        let share = min(1, Double(memory.used) / Double(memory.total))
        let cutoff = reading.sampledAt.addingTimeInterval(-Self.window)
        var next = PressureHistory()
        next.points = points.filter { $0.at >= cutoff }
            + [PressurePoint(at: reading.sampledAt, usedShare: share, pressure: reading.pressure)]
        return next
    }
}

/// Activity Monitor's colours for the kernel's levels; unknown is neutral.
func pressureColor(_ level: MemoryPressureLevel?) -> Color {
    switch level {
    case .normal: return Palette.good
    case .warning: return Palette.caution
    case .critical: return Palette.critical
    case nil: return Color.gray
    }
}

/// Memory used over the last 15 minutes, one bar per sample, each coloured by the pressure level
/// at that moment. Time runs left to right across the whole window ending at the newest sample.
struct PressureGraph: View {
    let history: PressureHistory

    var body: some View {
        Canvas { context, size in
            guard let newest = history.points.last?.at else { return }
            let start = newest.addingTimeInterval(-PressureHistory.window)
            let barWidth = max(2, size.width * PressureHistory.minimumSpacing / PressureHistory.window)
            for point in history.points {
                let x = size.width * point.at.timeIntervalSince(start) / PressureHistory.window - barWidth
                let height = size.height * point.usedShare
                let bar = CGRect(x: max(0, x), y: size.height - height, width: barWidth, height: height)
                context.fill(Path(bar), with: .color(pressureColor(point.pressure)))
            }
        }
        .background(Color.primary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
