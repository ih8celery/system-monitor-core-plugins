import Combine
import Foundation
import SwiftUI
import SystemBarKit

/// The Disk tab as a bundle. The host calls `collect()` every 30 s while the tab shows and, unless
/// settings turn it off, every 15 minutes while it is hidden. Each call reads the volumes on the
/// plugin's queue, then asks the scan queue to run whichever plans are due. The scan queue is the
/// plugin's own and serial: it alone touches the ledger, a plan can run for minutes without
/// holding up a volume read, and the panel's rescan button queues a forced run behind whatever
/// is going. Everything publishes on main, and the panel observes `snapshot`.
@objc(SystemBarDiskPlugin)
public final class DiskPlugin: NSObject, TabPlugin, ObservableObject {
    public static let identifier = "disk"
    public let title = "Disk"
    public let systemImage = "internaldrive"
    public let accent = Palette.cyan
    public let refreshInterval: TimeInterval = DiskSampling.refreshInterval
    public let sharedFeeds: Set<SharedFeed> = []
    /// Always 15 minutes: the hidden `collect()` also runs the low-space rule, which must not
    /// depend on whether folder scans are allowed in the background. `backgroundScans: false`
    /// stops only the scan step of a hidden call.
    public let backgroundInterval: TimeInterval? = DiskSampling.backgroundInterval

    /// For the panel, which shortens paths under home to `~/...`.
    var homeDirectory: String { host.homeDirectory }

    static let backgroundScansKey = "backgroundScans"

    @Published private(set) var snapshot = DiskSnapshot()
    /// The read/write graph; written on main, from readings taken on `activityQueue`.
    @Published private(set) var activity = DiskActivityHistory()

    private let host: HostServices
    private let collector: DiskCollector
    private let scanner: DiskScanner
    private let store: DiskLedgerStore
    private let plans: [DiskScanPlan]
    private let now: () -> Date
    private let scanQueue = DispatchQueue(label: "systembar.disk.scan", qos: .utility)
    /// The activity graph's reads, one at a time, apart from the scans. Only the timer and
    /// `sampleActivity` use it.
    private let activityQueue = DispatchQueue(label: "systembar.disk.activity", qos: .utility)
    /// Runs at the visible or hidden cadence for as long as the plugin lives; cancelled when it is
    /// released. Touched only on main, and in `deinit`, when nothing else holds the plugin.
    private var activityTimer: DispatchSourceTimer?
    private let activitySampling: ActivitySampling
    /// Touched only on `scanQueue`.
    private var ledger = DiskLedger()
    private var isLedgerLoaded = false
    /// When each plan last started a run, measured or not. Touched only on `scanQueue`; lost at
    /// relaunch, which costs at most one extra attempt per plan per launch.
    private var lastAttempt: [DiskPlanKind: Date] = [:]
    /// Each plan's last incomplete outcome, worded for the footer; a complete run removes its
    /// entry. Kept per plan so a later clean plan does not hide an earlier plan's gaps. Touched
    /// only on `scanQueue`.
    private var scanWarnings: [DiskPlanKind: String] = [:]
    /// A rescan is queued or running, so another click adds nothing. Set by the caller and
    /// cleared on `scanQueue`, so it sits behind a lock rather than on one queue.
    private let forcedRunLock = NSLock()
    private var isForcedRunQueued = false
    /// `backgroundScans` from settings, and whether the tab shows now (set by the host on main,
    /// read on the plugin's queue, so behind a lock). A hidden call scans only when allowed.
    private let scanGateLock = NSLock()
    private let scansWhileHidden: Bool
    private var isShowing = false
    /// The free-space rule and what it last saw. `collect()` is the only caller, one at a time,
    /// but the lock keeps that from being an unwritten assumption.
    private let lowSpaceLock = NSLock()
    private var lowSpaceRule: DiskLowSpaceRule

    @MainActor public convenience init(host: HostServices) {
        self.init(host: host, plans: DiskScanPlan.all, now: { Date() }, listChildren: DiskScanner.subfolders(of:), activity: .standard)
    }

    /// The plans, clock and folder listing are parameters so a test can run a tiny plan over a
    /// fake tree in no time; the app uses `init(host:)`.
    @MainActor init(host: HostServices, plans: [DiskScanPlan], now: @escaping () -> Date, listChildren: @escaping (String) -> [String]?, activity: ActivitySampling = .standard) {
        self.host = host
        activitySampling = activity
        collector = DiskCollector(host: host)
        scanner = DiskScanner(host: host, listChildren: listChildren, now: now)
        store = DiskLedgerStore.standard(dataDirectory: host.dataDirectory)
        self.plans = plans
        self.now = now
        let setting = Self.backgroundScansSetting(host.settings)
        let limit = DiskLowSpaceRule.limit(from: host.settings)
        lowSpaceRule = DiskLowSpaceRule(limitBytes: limit.bytes)
        scansWhileHidden = setting.isEnabled
        var initial = DiskSnapshot()
        initial.settingsProblem = [setting.problem, limit.problem].compactMap { $0 }.joined(separator: "; ").nilIfEmpty
        snapshot = initial
        if let problem = initial.settingsProblem { host.log("SystemBar Disk: \(problem)") }
        super.init()
        // The saved rows show as soon as the plugin exists, not at the first collect, which with
        // the tab hidden is a background interval away.
        requestLedgerLoad()
        scheduleActivityTimer(every: activity.hiddenInterval, startingNow: false)
    }

    /// `backgroundScans`: absent or true means on; false means off; anything else keeps the
    /// default and is reported, because a misspelt value must never silently do nothing.
    static func backgroundScansSetting(_ settings: PluginSettings) -> (isEnabled: Bool, problem: String?) {
        if let flag = settings.bool(forKey: backgroundScansKey) { return (flag, nil) }
        if settings[backgroundScansKey] != nil {
            return (true, "settings: \"\(backgroundScansKey)\" must be true or false; background scans stay on")
        }
        return (true, nil)
    }

    public func collect() {
        let reading = collector.readVolumes()
        publish { $0.applying(reading) }
        checkLowSpace(reading.volumes.first(where: \.isRoot))
        guard scanGateLock.withLock({ isShowing }) || scansWhileHidden else { return }
        requestScan(force: false)
    }

    /// Runs the free-space rule on the boot volume and hands any notification to the host.
    private func checkLowSpace(_ boot: DiskVolume?) {
        let notification = lowSpaceLock.withLock { () -> PluginNotification? in
            let step = lowSpaceRule.checking(boot)
            lowSpaceRule = step.rule
            return step.notification
        }
        if let notification { host.notify(id: notification.id, title: notification.title, body: notification.body) }
    }

    /// The panel's rescan button passes `force: true`; every collect asks without forcing. Runs
    /// behind any scan already going, which then finds nothing due unless forced.
    /// A click while a rescan is already queued or running is ignored rather than queuing
    /// another full run behind it.
    func requestScan(force: Bool) {
        if force {
            let isAlreadyQueued = forcedRunLock.withLock {
                defer { isForcedRunQueued = true }
                return isForcedRunQueued
            }
            guard !isAlreadyQueued else { return }
        }
        scanQueue.async { [self] in
            loadLedgerIfNeeded()
            runDuePlans(force: force)
            if force { forcedRunLock.withLock { isForcedRunQueued = false } }
        }
    }

    /// Not main-actor isolated, like `requestScan`, so the closure it queues is not checked as
    /// crossing from the main actor; the ledger is still touched only on `scanQueue`.
    private func requestLedgerLoad() {
        scanQueue.async { [self] in loadLedgerIfNeeded() }
    }

    /// For tests: returns once everything queued on the scan queue so far has finished, so a
    /// test can check that something did not happen without guessing how long to wait.
    func drainScanQueue() {
        dispatchPrecondition(condition: .notOnQueue(scanQueue))
        scanQueue.sync {}
    }

    // MARK: - Scan queue

    private func loadLedgerIfNeeded() {
        guard !isLedgerLoaded else { return }
        isLedgerLoaded = true
        switch store.load() {
        case .fresh:
            break
        case .loaded(let saved):
            ledger = saved
        case let .movedAside(to, reason):
            host.log("SystemBar Disk: the saved ledger could not be read (\(reason)); moved to \(to)")
            publish { $0.noting("Saved sizes could not be read (\(reason)); the file was moved to \(to) and a fresh one started") }
        }
        publishLedger()
    }

    private func runDuePlans(force: Bool) {
        let due = plans.filter { force || isDue($0) }
        guard !due.isEmpty else { return }
        for plan in due {
            lastAttempt[plan.kind] = now()
            publish { $0.scanning(true, status: "Measuring \(plan.kind.title.lowercased()) folders") }
            var fresh: [DiskSample] = []
            var lastPreview = -TimeInterval.infinity
            let outcome = scanner.run(plan: plan, previous: ledger) { sample in
                // Trees land in the list as they finish, at most once a second; the
                // `publishLedger()` after the plan always shows the final state.
                fresh.append(sample)
                let uptime = ProcessInfo.processInfo.systemUptime
                guard uptime - lastPreview >= DiskSampling.previewInterval else { return }
                lastPreview = uptime
                publishRows(from: ledger.appending(fresh))
            }
            ledger = ledger.appending(fresh).compacted(now: now())
            save()
            let summary = "\(plan.kind.title): \(outcome.status)"
            scanWarnings[plan.kind] = outcome.isComplete ? nil : summary
            let warning = DiskPlanKind.allCases.compactMap { scanWarnings[$0] }.joined(separator: " · ")
            publish { $0.scanning(false, status: summary).warning(warning.isEmpty ? nil : warning) }
            publishLedger()
        }
    }

    /// Due when the ledger's newest sample for the plan is a cadence old and so is its last
    /// attempt. Attempts count because a run can record nothing (no simulator folder, every row
    /// too slow), and the ledger alone would then call the plan due on every collect.
    private func isDue(_ plan: DiskScanPlan) -> Bool {
        let at = now()
        let hasWaitedSinceAttempt = lastAttempt[plan.kind].map { at.timeIntervalSince($0) >= plan.cadence } ?? true
        return hasWaitedSinceAttempt && ledger.isDue(plan.kind, cadence: plan.cadence, now: at)
    }

    private func save() {
        do {
            try store.save(ledger)
            publish { $0.savingProblem(nil) }
        } catch {
            let path = store.fileURL.path
            let reason = error.localizedDescription
            host.log("SystemBar Disk: could not save the ledger to \(path): \(reason)")
            publish { $0.savingProblem("Sizes could not be saved to \(path): \(reason)") }
        }
    }

    private func publishLedger() {
        publishRows(from: ledger)
    }

    /// Derives the rows here, on the scan queue, so main only copies the result in.
    private func publishRows(from ledger: DiskLedger) {
        let derived = DiskDerivedRows.derive(from: ledger, homeDirectory: host.homeDirectory, now: now())
        publish { $0.applying(derived) }
    }

    /// Showing the tab samples every second and hiding it every 5 s, so the graph keeps filling
    /// while the popover is closed and is full when it opens.
    @MainActor public func visibilityChanged(isVisible: Bool) {
        scanGateLock.withLock { isShowing = isVisible }
        scheduleActivityTimer(every: isVisible ? activitySampling.visibleInterval : activitySampling.hiddenInterval, startingNow: isVisible)
    }

    /// Replaces the timer. The first reading of a slow timer waits one interval, so a plugin made
    /// for a test or a preview does not read at once; showing the tab reads at once.
    @MainActor private func scheduleActivityTimer(every interval: TimeInterval, startingNow: Bool) {
        activityTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: activityQueue)
        timer.schedule(deadline: .now() + (startingNow ? 0 : interval), repeating: interval)
        timer.setEventHandler { [weak self] in self?.readActivity(at: Date()) }
        timer.resume()
        activityTimer = timer
    }

    /// One read, queued behind any other, published on main. A read that gives no counters keeps
    /// the graph and says why.
    func sampleActivity(at date: Date) {
        activityQueue.async { [self] in readActivity(at: date) }
    }

    private func readActivity(at date: Date) {
        let counters = activitySampling.read()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let counters {
                self.activity = self.activity.applying(counters, at: date)
            } else {
                self.activity = self.activity.failing(DiskActivity.unavailableProblem)
            }
        }
    }

    deinit {
        activityTimer?.cancel()
    }

    @MainActor public func makeView() -> AnyView {
        AnyView(DiskPanel(plugin: self))
    }

    /// Readings arrive on the plugin's queue and on the scan queue; the panel observes from main.
    private func publish(_ change: @escaping (DiskSnapshot) -> DiskSnapshot) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snapshot = change(self.snapshot)
        }
    }
}

/// How the activity graph is fed: the read, and how often. The app uses `standard`; a test passes
/// its own read and fast intervals.
struct ActivitySampling {
    let read: @Sendable () -> DiskCounters?
    let visibleInterval: TimeInterval
    let hiddenInterval: TimeInterval

    static let standard = ActivitySampling(
        read: { IOKitDiskReader.read() },
        visibleInterval: DiskSampling.activityVisibleInterval,
        hiddenInterval: DiskSampling.activityHiddenInterval
    )
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
