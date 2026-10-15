import Foundation
import SystemBarKit

/// Bytes swapped out to disk and back in over a window.
struct SwapActivity: Equatable {
    var bytesOut: UInt64 = 0
    var bytesIn: UInt64 = 0

    var isIdle: Bool { bytesOut == 0 && bytesIn == 0 }
}

/// The swap counters at each recent sample, kept for `MemorySampling.swapWindow`. The counters
/// count since boot, so the figure worth showing is the newest less the oldest still in the window.
struct SwapHistory {
    private struct Sample {
        let at: Date
        let ins: UInt64
        let outs: UInt64
    }

    private var samples: [Sample] = []
    /// How long a sample is kept; the swap line reads the last minute, the swap rule its own minutes.
    let window: TimeInterval

    init(window: TimeInterval = MemorySampling.swapWindow) {
        self.window = window
    }

    /// How much time the kept samples cover, so a rule can tell a full window from a short one.
    var span: TimeInterval {
        guard let oldest = samples.first, let newest = samples.last else { return 0 }
        return newest.at.timeIntervalSince(oldest.at)
    }

    /// How much swap traffic, in bytes, came between each pair of neighbouring samples, and how
    /// long that took. A counter that went backwards counts as no movement.
    var intervals: [(seconds: TimeInterval, bytes: UInt64)] {
        zip(samples, samples.dropFirst()).map { older, newer in
            (newer.at.timeIntervalSince(older.at), (newer.ins - min(newer.ins, older.ins)) + (newer.outs - min(newer.outs, older.outs)))
        }
    }

    /// A copy with one more sample, and everything a window older than it dropped. A sample whose
    /// counters are both zero is a failed read (a machine that has swapped at all never reads
    /// zero), and is dropped: kept, it would become the oldest sample and make the count since
    /// boot look like the last minute.
    func recording(_ memory: MemorySnapshot, at date: Date) -> SwapHistory {
        guard memory.swapInsTotal > 0 || memory.swapOutsTotal > 0 else { return self }
        let cutoff = date.addingTimeInterval(-window)
        var next = SwapHistory(window: window)
        next.samples = samples.filter { $0.at >= cutoff }
            + [Sample(at: date, ins: memory.swapInsTotal, outs: memory.swapOutsTotal)]
        return next
    }

    /// A counter that went backwards (a failed read) counts as no movement, never as a wrap.
    var activity: SwapActivity {
        guard let oldest = samples.first, let newest = samples.last else { return SwapActivity() }
        return SwapActivity(
            bytesOut: newest.outs - min(newest.outs, oldest.outs),
            bytesIn: newest.ins - min(newest.ins, oldest.ins)
        )
    }
}

/// "Swapping X out, Y in", or nil when nothing moved in the window so the line stays hidden.
func swapActivityText(_ activity: SwapActivity) -> String? {
    guard !activity.isIdle else { return nil }
    return "Swapping \(memoryByteString(activity.bytesOut)) out, \(memoryByteString(activity.bytesIn)) in"
}
