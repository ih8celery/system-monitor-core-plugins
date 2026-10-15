import Foundation
import SystemBarKit

/// The Network panel's formatters. Only this panel uses them.

/// Every network speed on the tab (the Down/Up cards and the Bandwidth rows) in 1000-based
/// units, as Finder and Activity Monitor count them. The speed test keeps networkQuality's Mbps.
func networkRateText(_ bytesPerSecond: Double) -> String {
    fileRateString(bytesPerSecond)
}

/// A Down or Up card's total, in Finder's units. Nil while the host has not read the counters yet
/// (the feed holds 0 until then), so the card shows nothing rather than a false 0 B.
func sinceStartupText(_ bytes: UInt64) -> String? {
    guard bytes > 0 else { return nil }
    return "\(fileByteString(bytes)) since the Mac started up"
}

let sinceStartupHelp = "Everything the Mac's network ports have moved since the Mac started up, not just while SystemBar was open. A port you unplug takes its bytes with it, so the figure can drop."

func speedTestRateText(_ megabitsPerSecond: Double?) -> String {
    guard let megabitsPerSecond else { return "-- Mbps" }
    return String(format: megabitsPerSecond >= 100 ? "%.0f Mbps" : "%.1f Mbps", max(0, megabitsPerSecond))
}

func speedTestLatencyText(_ milliseconds: Double?) -> String {
    guard let milliseconds else { return "-- ms" }
    return String(format: milliseconds >= 10 ? "%.0f ms" : "%.1f ms", max(0, milliseconds))
}

/// The latency section's latest figure for one line.
func latencyText(_ point: LatencyPoint?) -> String {
    switch point {
    case .reply(let milliseconds): String(format: milliseconds >= 10 ? "%.0f ms" : "%.1f ms", max(0, milliseconds))
    case .failed: "failed"
    case .unknown: "no route"
    case nil: "-- ms"
    }
}
