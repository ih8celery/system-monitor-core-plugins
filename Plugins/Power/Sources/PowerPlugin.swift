import Combine
import Foundation
import SwiftUI
import SystemBarKit

/// The Power tab as a bundle. The host calls `collect()` on this plugin's queue once a minute
/// while the tab shows and every 10 seconds while it is hidden. Showing, a collect makes every
/// read and publishes the snapshot on the main thread, where the panel observes it. Hidden, it
/// makes only the one ioreg read of the battery driver, enough for the Mac's draw, and records
/// that into the day's history, which is saved in the tab's data folder.
/// Contributors follow the process feed instead, on their own 10-second cadence, so the first
/// showing after launch does not sit empty for up to a minute waiting on `collect()`.
@objc(SystemBarPowerPlugin)
public final class PowerPlugin: NSObject, TabPlugin, ObservableObject {
    public static let identifier = "power"
    public let title = "Power"
    public let systemImage = "bolt.heart"
    public let accent = Palette.caution
    public let refreshInterval: TimeInterval = 60
    public let sharedFeeds: Set<SharedFeed> = [.processes]
    public let backgroundInterval: TimeInterval? = PowerPlugin.hiddenInterval
    static let hiddenInterval: TimeInterval = 10

    @Published private(set) var snapshot = PowerSnapshot()
    @Published private(set) var contributors: [PowerContributor] = []
    @Published private(set) var history: PowerHistory
    private let host: HostServices
    private var feedSubscription: AnyCancellable?
    private let clock: @Sendable () -> Date
    /// When the charger last came or went. Only `sample()` touches it, and the host calls
    /// `collect()` on this plugin's one queue, so samples never overlap.
    private var sourceTracker = SourceChangeTracker()
    /// The history as `collect()` keeps it; `history` is its copy on main.
    private var recordedHistory: PowerHistory
    private let store: PowerHistoryStore
    private let showingLock = NSLock()
    private var isShowing = false

    @MainActor public convenience init(host: HostServices) {
        self.init(host: host, clock: { Date() })
    }

    @MainActor init(host: HostServices, clock: @escaping @Sendable () -> Date) {
        self.host = host
        self.clock = clock
        store = PowerHistoryStore.standard(dataDirectory: host.dataDirectory)
        let now = clock()
        let loaded = PowerHistory(points: store.load(now: now, log: host.log), now: now)
        history = loaded
        recordedHistory = loaded
        super.init()
        contributors = PowerCollector.contributors(from: host.processes.value.topCPU)
        feedSubscription = host.processes.publisher.sink { [weak self] summary in
            self?.contributors = PowerCollector.contributors(from: summary.topCPU)
        }
    }

    public func collect() {
        guard showingLock.withLock({ isShowing }) else {
            let history = record(hiddenSample())
            DispatchQueue.main.async { [weak self] in
                self?.history = history
            }
            return
        }
        let next = sample()
        let history = record(next.powerDraw?.macWatts)
        DispatchQueue.main.async { [weak self] in
            self?.snapshot = next
            self?.history = history
        }
    }

    /// Main thread: the host showing or hiding the tab. Hidden, the pmset reads are not run.
    @MainActor public func visibilityChanged(isVisible: Bool) {
        showingLock.withLock { isShowing = isVisible }
    }

    /// One reading, remembering when the charger came or went so the next can tell whether
    /// the telemetry has caught up.
    func sample() -> PowerSnapshot {
        let now = clock()
        let before = sourceTracker
        let next = PowerCollector.collect(using: host) { before.observing($0, at: now).isSettling(at: now) }
        sourceTracker = before.observing(next.isExternal, at: now)
        return next
    }

    /// The hidden sample: the battery driver alone, through the same tracker, so the settle
    /// window still holds when the tab opens. Returns the Mac's draw, nil while settling.
    func hiddenSample() -> Double? {
        let now = clock()
        let entry = PowerCollector.readDriver(using: host).entry
        let isExternal = entry?["ExternalConnected"] as? Bool
        let next = sourceTracker.observing(isExternal, at: now)
        sourceTracker = next
        return PowerCollector.powerDraw(from: entry, sourceJustChanged: next.isSettling(at: now))?.macWatts
    }

    /// Adds the reading to the history and saves it once per new minute, so the file is written
    /// at most once a minute. A failed save is logged and the history carries on in memory.
    private func record(_ watts: Double?) -> PowerHistory {
        let now = clock()
        let next = recordedHistory.recording(watts, at: now)
        if next.points.last?.minute != recordedHistory.points.last?.minute {
            do {
                try store.save(next.points, now: now)
            } catch {
                host.log("Power: could not save the power history to \(store.fileURL.path): \(error.localizedDescription)")
            }
        }
        recordedHistory = next
        return next
    }

    @MainActor public func makeView() -> AnyView {
        AnyView(PowerPanel(plugin: self))
    }
}
