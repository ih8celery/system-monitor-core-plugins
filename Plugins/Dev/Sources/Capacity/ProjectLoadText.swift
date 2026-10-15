import Foundation
import SystemBarKit

/// How a project row words what was measured: memory the way Activity Monitor writes it, disk
/// rates the way Finder does.
enum ProjectLoadText {
    static func measuredDetail(memory: UInt64, readRate: Double, writeRate: Double, sampled: Int, total: Int) -> String {
        let io = "\(fileRateString(readRate)) read, \(fileRateString(writeRate)) write"
        let figures = "\(memoryByteString(memory)) - \(io)"
        guard sampled == total else { return "\(figures) - \(sampled) of \(total) processes sampled" }
        return figures
    }
}
