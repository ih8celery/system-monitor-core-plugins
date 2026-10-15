import Foundation

/// When the charger was last seen to come or go, so the lagging `PowerTelemetryData` is not
/// trusted while it catches up. Timed by the clock rather than counted in samples: the Power
/// tab samples only while it shows, so two samples can be seconds or hours apart.
struct SourceChangeTracker: Equatable {
    /// How long after a plug or unplug the telemetry is not trusted. It lags about a minute.
    static let lagWindow: TimeInterval = 90

    private(set) var lastExternal: Bool?
    private(set) var lastSampleAt: Date?
    /// Nil when no change has been seen, or when one could not be timed.
    private(set) var changedAt: Date?

    /// This tracker after a sample saw `isExternal` at `now`. A change since a sample more than
    /// the lag window ago cannot be timed and most likely happened long ago, so it is trusted.
    func observing(_ isExternal: Bool?, at now: Date) -> SourceChangeTracker {
        guard let isExternal else { return self }
        let isChange = lastExternal.map { $0 != isExternal } ?? false
        let isTimeable = lastSampleAt.map { now.timeIntervalSince($0) <= Self.lagWindow } ?? false
        return SourceChangeTracker(
            lastExternal: isExternal,
            lastSampleAt: now,
            changedAt: isChange ? (isTimeable ? now : nil) : changedAt
        )
    }

    func isSettling(at now: Date) -> Bool {
        changedAt.map { now.timeIntervalSince($0) < Self.lagWindow } ?? false
    }
}
