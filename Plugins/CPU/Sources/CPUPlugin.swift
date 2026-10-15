import Combine
import Foundation
import SwiftUI
import SystemBarKit

/// The CPU tab as a bundle. The headline, graph, cluster bars and user/system split follow the
/// host's 1-second feed and the list follows its process feed. `collect()` reads what the feed
/// does not carry (load averages, uptime, thermal state, `pmset -g therm`) every ten seconds while the
/// tab is showing, and again whenever macOS says the thermal state changed while it is showing.
/// The one other command it runs is a `ps` when a row is tapped, which the panel calls off the
/// main thread.
/// This plugin also calls `collect()` from its own thermal queue, so the SDK's "never
/// concurrently with itself" promise does not cover it.
@objc(SystemBarCPUPlugin)
public final class CPUPlugin: NSObject, TabPlugin, ObservableObject {
    public static let identifier = "cpu"
    public let title = "CPU"
    public let systemImage = "cpu"
    public let accent = Palette.warning
    public let refreshInterval: TimeInterval = CPUSampling.refreshInterval
    public let sharedFeeds: Set<SharedFeed> = [.processes, .fastStats]

    @Published private(set) var fastStats = FastStatsSnapshot()
    @Published private(set) var processes = ProcessSummary()
    @Published private(set) var machineState = MachineState.empty
    /// Nil until the first GPU read, and after one that failed or found no accelerator.
    @Published private(set) var gpuReading: GPUReading?
    /// The device utilisation, once a second while the tab is showing; it does not grow while hidden.
    @Published private(set) var gpuHistory: [Double] = []
    /// Read once at init: a chip does not change. Nil means the view draws per-core bars with
    /// no cluster names.
    let clusters: [CPUCluster]?
    private let host: HostServices
    private let rules: CPURuleEngine
    private let now: @Sendable () -> Date
    /// Rules are evaluated off the main thread, one reading at a time and in order.
    private let ruleQueue = DispatchQueue(label: "systembar.cpu.rules", qos: .utility)
    private var ruleThermalObserver: NSObjectProtocol?
    private var feedSubscriptions: [AnyCancellable] = []
    private var thermalObserver: NSObjectProtocol?
    private var gpuTimer: DispatchSourceTimer?
    private let gpuQueue = DispatchQueue(label: "systembar.cpu.gpu", qos: .utility)
    /// Runs the thermal-change observer off the main thread, as the host's own calls are.
    private let thermalQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    @MainActor public convenience init(host: HostServices) {
        self.init(host: host, now: { Date() })
    }

    /// `now` is the rules' clock; a test moves it by hand.
    @MainActor init(host: HostServices, now: @escaping @Sendable () -> Date) {
        self.host = host
        self.now = now
        rules = CPURuleEngine(host: host, thermalState: ProcessInfo.processInfo.thermalState)
        clusters = CPUCollector.clusters()
        super.init()
        fastStats = host.fastStats.value
        processes = host.processes.value
        observeRuleThermalChanges()
        feedSubscriptions = [
            host.fastStats.publisher.sink { [weak self] snapshot in
                self?.fastStats = snapshot
                self?.evaluateCPURule(percent: snapshot.cpuUsagePercent)
            },
            host.processes.publisher.sink { [weak self] summary in self?.processes = summary },
        ]
    }

    deinit {
        stopObservingThermalChanges()
        if let ruleThermalObserver { NotificationCenter.default.removeObserver(ruleThermalObserver) }
        gpuTimer?.cancel()
    }

    /// The thermal rule works whether or not the window is open: this observer is an event (no
    /// sampling, no subprocess). The CPU rule rides the host's 1-second feed, which today stops when
    /// the popover closes, so that rule works only while the window is open until SystemBar's feed
    /// runs in the background (host issue swift-ui-system-monitor-125.6, H4). The tab does not work
    /// around that; `SustainedCPUTracker` treats the pause as a gap and starts its window again.
    private func observeRuleThermalChanges() {
        ruleThermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            let state = ProcessInfo.processInfo.thermalState
            self.ruleQueue.async { self.rules.observeThermal(state) }
        }
    }

    private func evaluateCPURule(percent: Double) {
        let moment = now()
        ruleQueue.async { [rules] in rules.observeCPU(percent: percent, at: moment) }
    }

    /// A change is worth one read now rather than up to ten seconds later. Registered from a
    /// plain method, not the main-actor init, so the compiler does not take `self` for a
    /// main-actor value being sent to the observer block.
    private func observeThermalChanges() {
        guard thermalObserver == nil else { return }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: thermalQueue
        ) { [weak self] _ in self?.collect() }
    }

    private func stopObservingThermalChanges() {
        guard let thermalObserver else { return }
        NotificationCenter.default.removeObserver(thermalObserver)
        self.thermalObserver = nil
    }

    /// The thermal observer and the GPU timer run only while the tab is showing: a hidden tab
    /// samples nothing unless it declares a `backgroundInterval`, and this one does not.
    @MainActor public func visibilityChanged(isVisible: Bool) {
        if isVisible {
            observeThermalChanges()
            startSamplingGPU()
        } else {
            stopObservingThermalChanges()
            stopSamplingGPU()
        }
    }

    private func startSamplingGPU() {
        guard gpuTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: gpuQueue)
        timer.schedule(deadline: .now(), repeating: CPUSampling.gpuInterval)
        timer.setEventHandler { [weak self] in self?.sampleGPU() }
        timer.resume()
        gpuTimer = timer
    }

    private func stopSamplingGPU() {
        gpuTimer?.cancel()
        gpuTimer = nil
    }

    /// One `ioreg` read, published on the main thread. A failed read leaves the history as it
    /// was and clears the latest reading, so the line goes away rather than showing a stale figure.
    private func sampleGPU() {
        let result = host.run(path: GPUParser.command, arguments: GPUParser.arguments)
        let reading = result.status == 0 ? GPUParser.parse(result.output) : nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.gpuReading = reading
            if let reading { self.gpuHistory = GPUHistory.appending(reading.device, to: self.gpuHistory) }
        }
    }

    /// Reads the load averages, uptime, thermal state and pmset's speed limit, and publishes them on the
    /// main thread, where the panel observes them. A reading older than the one showing is
    /// dropped, because the thermal observer can run a collect alongside the scheduled one.
    public func collect() {
        let state = CPUCollector.machineState(using: host)
        DispatchQueue.main.async { [weak self] in
            guard let self, state.sampledAt >= self.machineState.sampledAt else { return }
            self.machineState = state
        }
    }

    /// The tapped group's processes, from a fresh `ps`. Blocking: the panel calls it off main.
    func groupDetail(named name: String) -> [ProcessDetail] {
        ProcessDetail.fetchGroupDetail(name: name, using: host)
    }

    @MainActor public func makeView() -> AnyView {
        AnyView(CPUPanel(plugin: self))
    }
}
