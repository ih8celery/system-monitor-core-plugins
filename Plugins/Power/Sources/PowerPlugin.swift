import Combine
import Foundation
import SwiftUI
import SystemBarKit

/// The Power tab as a bundle. The host calls `collect()` on this plugin's queue once a minute
/// while the tab shows and every 10 seconds while it is hidden. Showing, a collect makes every
/// read and publishes the snapshot on the main thread, where the panel observes it. Hidden, it
/// makes only the one ioreg read of the battery driver, enough for the Mac's draw, and records
/// that into the day's history, which is saved in the tab's data folder (see `PowerHistoryKeeper`). Both run the battery-low
/// and not-charging notification rules from that same read, so they work with the window closed.
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
    /// Settings that could not be used, worded for the panel; each is also logged.
    @Published private(set) var settingsProblems: [String]
    private let host: HostServices
    private var feedSubscription: AnyCancellable?
    private let clock: @Sendable () -> Date
    /// When the charger last came or went. Only `sample()` touches it, and the host calls
    /// `collect()` on this plugin's one queue, so samples never overlap.
    private var sourceTracker = SourceChangeTracker()
    /// Empty battery-driver replies in a row, and when the driver was last read. Hidden collects
    /// only, like `sourceTracker`.
    private var emptyDriverReplies = 0
    private var lastDriverReadAt: Date?
    /// A Mac with no battery answers ioreg with nothing every time: after this many empty
    /// replies in a row, a hidden collect reads the driver only once a minute.
    static let emptyRepliesBeforeBackOff = 6
    static let backedOffReadInterval: TimeInterval = 60
    /// The history as `collect()` keeps it; `history` is its copy on main.
    private let historyKeeper: PowerHistoryKeeper
    private let showingLock = NSLock()
    private var isShowing = false
    /// What the notification rules remember. Touched only by `collect`, which the host calls one at a time.
    private var alerts: PowerAlertRules
    private let chargeLimitFile: URL

    @MainActor public convenience init(host: HostServices) {
        self.init(host: host, clock: { Date() })
    }

    @MainActor init(host: HostServices, clock: @escaping @Sendable () -> Date, chargeLimitFile: URL = PowerCollector.chargeLimitFile) {
        self.host = host
        self.clock = clock
        self.chargeLimitFile = chargeLimitFile
        let parsed = PowerAlertConfig.parse(host.settings)
        parsed.problems.forEach { host.log("Power: \($0)") }
        settingsProblems = parsed.problems
        alerts = PowerAlertRules(config: parsed.config)
        historyKeeper = PowerHistoryKeeper(
            store: PowerHistoryStore.standard(dataDirectory: host.dataDirectory), clock: clock, log: { host.log($0) }
        )
        history = historyKeeper.current
        super.init()
        contributors = PowerCollector.contributors(from: host.processes.value.topCPU)
        feedSubscription = host.processes.publisher.sink { [weak self] summary in
            self?.contributors = PowerCollector.contributors(from: summary.topCPU)
        }
    }

    public func collect() {
        guard showingLock.withLock({ isShowing }) else {
            let reading = hiddenSample()
            alert(reading.battery, isSettling: reading.isSettling) { PowerCollector.chargeLimit(fileAt: chargeLimitFile) }
            guard let history = historyKeeper.record(reading.macWatts) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.history = history
            }
            return
        }
        let next = sample()
        alert(next.batteryAlert, isSettling: next.isSettling) { next.chargeLimit }
        let history = historyKeeper.record(next.powerDraw?.macWatts)
        DispatchQueue.main.async { [weak self] in
            self?.snapshot = next
            if let history { self?.history = history }
        }
    }

    /// Main thread: the host showing or hiding the tab. Hidden, the pmset reads are not run, and
    /// the history is written, off the main thread.
    @MainActor public func visibilityChanged(isVisible: Bool) {
        showingLock.withLock { isShowing = isVisible }
        guard !isVisible else { return }
        let keeper = historyKeeper
        DispatchQueue.global(qos: .utility).async { keeper.save() }
    }

    deinit {
        historyKeeper.save()
    }

    /// One reading, remembering when the charger came or went so the next can tell whether
    /// the telemetry has caught up.
    func sample() -> PowerSnapshot {
        let now = clock()
        let before = sourceTracker
        let next = PowerCollector.collect(using: host, chargeLimitFile: chargeLimitFile) { before.observing($0, at: now).isSettling(at: now) }
        sourceTracker = before.observing(next.isExternal, at: now)
        return next
    }

    /// The hidden sample: the battery driver alone, through the same tracker, so the settle
    /// window still holds when the tab opens. The Mac's draw is nil while settling.
    func hiddenSample() -> HiddenSample {
        let now = clock()
        if emptyDriverReplies >= Self.emptyRepliesBeforeBackOff, let last = lastDriverReadAt,
           abs(now.timeIntervalSince(last)) < Self.backedOffReadInterval {
            return HiddenSample(macWatts: nil, battery: nil, isSettling: false)
        }
        let entry = PowerCollector.readDriver(using: host).entry
        lastDriverReadAt = now
        emptyDriverReplies = entry == nil ? emptyDriverReplies + 1 : 0
        let isExternal = entry?["ExternalConnected"] as? Bool
        let next = sourceTracker.observing(isExternal, at: now)
        sourceTracker = next
        let isSettling = next.isSettling(at: now)
        return HiddenSample(
            macWatts: PowerCollector.powerDraw(from: entry, sourceJustChanged: isSettling)?.macWatts,
            battery: BatteryAlertReading(entry: entry),
            isSettling: isSettling
        )
    }

    /// Runs the notification rules on this read and posts what they say. The host keeps each
    /// rule to one notification an hour.
    private func alert(_ battery: BatteryAlertReading?, isSettling: Bool, chargeLimit: () -> Int?) {
        let result = alerts.evaluating(battery, at: clock(), isSettling: isSettling, chargeLimit: chargeLimit)
        alerts = result.rules
        result.notifications.forEach { host.notify(id: $0.id, title: $0.title, body: $0.body) }
    }

    /// What a hidden collect reads from the battery driver alone.
    struct HiddenSample {
        let macWatts: Double?
        let battery: BatteryAlertReading?
        let isSettling: Bool
    }

    @MainActor public func makeView() -> AnyView {
        AnyView(PowerPanel(plugin: self))
    }
}
