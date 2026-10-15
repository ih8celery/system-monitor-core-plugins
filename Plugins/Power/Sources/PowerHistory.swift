import Foundation

/// One minute of the Mac's draw: the average of that minute's readings, and how many there were,
/// so a minute half-filled before a relaunch keeps averaging correctly after it.
struct MinutePoint: Codable, Equatable {
    /// The start of the minute.
    let minute: Date
    let watts: Double
    let samples: Int
}

/// How much of the history the graph shows.
enum HistorySpan: String, CaseIterable {
    case hour = "Hour"
    case day = "Day"

    var duration: TimeInterval {
        switch self {
        case .hour: return 60 * 60
        case .day: return PowerHistory.window
        }
    }
}

/// The Mac's draw over the last day, one point per minute that had a reading, oldest first. A
/// value type, so recording returns the next history and the old one stays as it was. A minute
/// with no reading (the Mac slept, the app was closed, the telemetry was settling) has no point:
/// the graph places points by time, so it shows as a gap, as the Memory tab's pressure graph does.
struct PowerHistory: Equatable {
    static let window: TimeInterval = 24 * 60 * 60
    static let pointLimit = 1440
    static let minuteLength: TimeInterval = 60

    private(set) var points: [MinutePoint] = []

    init() {}

    /// The given points, oldest first, with anything older than a day before `now` dropped.
    init(points: [MinutePoint], now: Date) {
        self.points = Self.trimmed(points, now: now)
    }

    static func trimmed(_ points: [MinutePoint], now: Date) -> [MinutePoint] {
        let cutoff = now.addingTimeInterval(-window)
        return Array(points.sorted { $0.minute < $1.minute }.filter { $0.minute >= cutoff }.suffix(pointLimit))
    }

    static func minuteStart(of date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: seconds - seconds.truncatingRemainder(dividingBy: minuteLength))
    }

    /// A copy with the reading applied. A nil reading is left out: no figure is not 0 W. The
    /// reading joins the point for its minute wherever that is, so a clock set backward merges
    /// into the minutes it repeats instead of adding duplicates after them.
    func recording(_ watts: Double?, at date: Date) -> PowerHistory {
        guard let watts else { return self }
        let minute = Self.minuteStart(of: date)
        var kept = points
        if let index = kept.firstIndex(where: { $0.minute == minute }) {
            let old = kept[index]
            let samples = old.samples + 1
            kept[index] = MinutePoint(minute: minute, watts: old.watts + (watts - old.watts) / Double(samples), samples: samples)
        } else {
            kept.append(MinutePoint(minute: minute, watts: watts, samples: 1))
        }
        return PowerHistory(points: kept, now: date)
    }

    /// Where the graph's time axis ends: the end of the newest minute.
    var windowEnd: Date? {
        points.last.map { $0.minute.addingTimeInterval(Self.minuteLength) }
    }

    /// The points inside the span, split wherever a minute is missing, so the graph draws each
    /// run as its own line and leaves the missing time empty.
    func runs(in span: HistorySpan) -> [[MinutePoint]] {
        guard let windowEnd else { return [] }
        let start = windowEnd.addingTimeInterval(-span.duration)
        return points.filter { $0.minute >= start }.reduce(into: [[MinutePoint]]()) { runs, point in
            if let previous = runs.last?.last, point.minute.timeIntervalSince(previous.minute) <= Self.minuteLength {
                runs[runs.count - 1].append(point)
            } else {
                runs.append([point])
            }
        }
    }
}

/// The graph's top: the highest draw shown rounded up to the next 10 W, and never under 10 W.
func historyScaleTop(_ highestWatts: Double) -> Double {
    let step = 10.0
    return max(step, (highestWatts / step).rounded(.down) * step + step)
}
