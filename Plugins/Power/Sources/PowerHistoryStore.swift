import Foundation

/// What the history file holds. The version lets a later build refuse a file it cannot read.
struct PowerHistoryFile: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let points: [MinutePoint]
}

/// The history's one file, in the tab's data folder. Writes are atomic (Foundation writes a
/// temporary file and renames it into place), so a crash mid-write never leaves half a file.
struct PowerHistoryStore {
    static let fileName = "power-history.json"

    let fileURL: URL

    static func standard(dataDirectory: URL) -> PowerHistoryStore {
        PowerHistoryStore(fileURL: dataDirectory.appendingPathComponent(fileName))
    }

    /// The saved points from the last day before `now`. A missing, unreadable or corrupt file is
    /// an empty history, said in the log, never a crash.
    func load(now: Date, log: (String) -> Void) -> [MinutePoint] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            log("Power: no saved power history yet at \(fileURL.path); starting empty")
            return []
        } catch {
            log("Power: could not read the power history at \(fileURL.path): \(error.localizedDescription); starting empty")
            return []
        }
        do {
            let file = try Self.decoder.decode(PowerHistoryFile.self, from: data)
            guard file.version == PowerHistoryFile.currentVersion else {
                log("Power: the power history at \(fileURL.path) is version \(file.version), but this build reads version \(PowerHistoryFile.currentVersion); starting empty")
                return []
            }
            return PowerHistory.trimmed(file.points, now: now)
        } catch {
            log("Power: the power history at \(fileURL.path) is corrupt: \(error.localizedDescription); starting empty")
            return []
        }
    }

    /// Creates the tab's folder on first use, then writes the last day's points atomically.
    func save(_ points: [MinutePoint], now: Date) throws {
        let file = PowerHistoryFile(version: PowerHistoryFile.currentVersion, points: PowerHistory.trimmed(points, now: now))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(file).write(to: fileURL, options: .atomic)
    }

    /// Whole-second ISO 8601 dates and sorted keys, so the file reads by eye.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
