import Foundation
import SystemBarKit

/// How busy the GPU was at one moment, as the accelerator's `PerformanceStatistics` reports it:
/// the whole device, the renderer stage and the tiler stage, each a percent.
struct GPUReading: Equatable {
    let device: Double
    let renderer: Double
    let tiler: Double

    var line: String {
        "Device \(percentString(device)) · Renderer \(percentString(renderer)) · Tiler \(percentString(tiler))"
    }
}

enum GPUParser {
    static let command = "/usr/sbin/ioreg"
    /// Depth 0: the statistics are a property of the accelerator itself, so its children are not read.
    static let arguments = ["-r", "-c", "AGXAccelerator", "-d", "0"]

    /// The three utilisations from `ioreg -r -c AGXAccelerator` text, or nil unless all three are
    /// there as numbers: a missing figure is not a zero.
    static func parse(_ text: String) -> GPUReading? {
        guard let device = value(in: text, key: "Device Utilization %"),
              let renderer = value(in: text, key: "Renderer Utilization %"),
              let tiler = value(in: text, key: "Tiler Utilization %") else { return nil }
        return GPUReading(device: device, renderer: renderer, tiler: tiler)
    }

    /// The number after `"key"=`. The key is matched with both its quotes, so a longer key that
    /// shares the prefix is never mistaken for it.
    private static func value(in text: String, key: String) -> Double? {
        guard let keyRange = text.range(of: "\"\(key)\""),
              let equals = text[keyRange.upperBound...].range(of: "=") else { return nil }
        let token = text[equals.upperBound...]
            .drop(while: { $0 == " " })
            .prefix { !$0.isNewline && $0 != "," && $0 != "}" }
        return Double(token.trimmingCharacters(in: .whitespaces))
    }
}

enum GPUHistory {
    /// One sample a second, drawn the way the CPU history is: the last 90 seconds.
    static let capacity = 90

    static func appending(_ sample: Double, to history: [Double]) -> [Double] {
        Array((history + [sample]).suffix(capacity))
    }
}
