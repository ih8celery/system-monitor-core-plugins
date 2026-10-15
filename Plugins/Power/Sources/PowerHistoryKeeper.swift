import Foundation

/// The history as collects record it, and when it goes to disk. Rewriting the whole file every
/// minute was about 200 MB a day of SSD writes, so it is written every 10 minutes, when the tab
/// is hidden, and when the plugin goes away. A quit can therefore lose up to the last 10 minutes.
/// Its own lock, because collects record on the plugin's queue while hiding the tab saves from
/// the main thread.
final class PowerHistoryKeeper: @unchecked Sendable {
    static let saveInterval: TimeInterval = 10 * 60

    private let lock = NSLock()
    private let store: PowerHistoryStore
    private let clock: @Sendable () -> Date
    private let log: @Sendable (String) -> Void
    private var history: PowerHistory
    private var lastSavedAt: Date
    private var hasUnsavedChanges = false

    /// Loads what was saved; a missing or corrupt file is an empty history, said in the log.
    init(store: PowerHistoryStore, clock: @escaping @Sendable () -> Date, log: @escaping @Sendable (String) -> Void) {
        self.store = store
        self.clock = clock
        self.log = log
        let now = clock()
        history = PowerHistory(points: store.load(now: now, log: log), now: now)
        lastSavedAt = now
    }

    var current: PowerHistory {
        lock.withLock { history }
    }

    /// Adds the reading, and writes the file when the clock is 10 minutes from the last write,
    /// either way, so a clock set backward does not put off the next write until it catches up.
    /// Nil when the history did not change (a nil reading), so there is nothing to publish.
    func record(_ watts: Double?) -> PowerHistory? {
        lock.withLock {
            let now = clock()
            let previous = history
            let next = history.recording(watts, at: now)
            if next != previous { hasUnsavedChanges = true }
            history = next
            if abs(now.timeIntervalSince(lastSavedAt)) >= Self.saveInterval { saveLocked(at: now) }
            return next == previous ? nil : next
        }
    }

    /// Writes the file now if anything changed since the last write.
    func save() {
        lock.withLock { saveLocked(at: clock()) }
    }

    /// A failed write is logged and the history carries on in memory, to be tried again later.
    private func saveLocked(at now: Date) {
        lastSavedAt = now
        guard hasUnsavedChanges else { return }
        do {
            try store.save(history.points, now: now)
            hasUnsavedChanges = false
        } catch {
            log("Power: could not save the power history to \(store.fileURL.path): \(error.localizedDescription)")
        }
    }
}
