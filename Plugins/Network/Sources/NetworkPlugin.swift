import Combine
import Foundation
import SwiftUI
import SystemBarKit

/// The Network tab as a bundle. The host calls `collect()` on this plugin's queue every 5 s, shown
/// or hidden; each collect pings the router and the internet, then checks the notification rules
/// against that round, so they work with the window closed. While the tab shows, a collect
/// also reads the Wi-Fi link, and every 30 s runs nettop and lsof, publishes on main, then asks
/// the collector for the destinations' hostnames, which it looks up on its own DNS queue. The
/// rate cards and graph follow the host's 1-second feed, and the speed test runs only when the
/// panel's button is pressed, on its own queue.
@objc(SystemBarNetworkPlugin)
public final class NetworkPlugin: NSObject, TabPlugin, ObservableObject {
    public static let identifier = "network"
    public let title = "Network"
    public let systemImage = "arrow.up.arrow.down"
    public let accent = Palette.blue
    public let refreshInterval: TimeInterval = NetworkSampling.pingInterval
    public let backgroundInterval: TimeInterval? = NetworkSampling.pingInterval
    public let sharedFeeds: Set<SharedFeed> = [.fastStats]

    @Published private(set) var summary = NetworkSummary()
    @Published private(set) var fastStats = FastStatsSnapshot()
    @Published private(set) var speedTest = SpeedTestState()
    @Published private(set) var wifi: WiFiSignal?
    @Published private(set) var latency: LatencyState
    private let host: HostServices
    private let collector: NetworkCollector
    private let probes: NetworkProbes
    private let schedule = TrafficSchedule()
    /// From settings, once, so the plugin's queue reads it without touching `latency`.
    private let internetAddress: String
    /// The notification rules. Touched only in `collect()`, which the host never runs beside itself.
    private var rules: NetworkRules
    /// A speed test runs for up to 30 seconds, so it gets its own queue rather than holding up
    /// the plugin's collects.
    private let speedTestQueue = DispatchQueue(label: "systembar.network.speedtest", qos: .utility)
    private var feedSubscription: AnyCancellable?

    @MainActor public convenience init(host: HostServices) {
        self.init(host: host, probes: .live)
    }

    /// Tests pass fake probes in place of CoreWLAN, the socket, the routing table and the clock.
    @MainActor init(host: HostServices, probes: NetworkProbes) {
        self.host = host
        self.probes = probes
        collector = NetworkCollector(host: host)
        let setting = LatencySettings.internetAddress(host.settings)
        internetAddress = setting.address
        let ruleSettings = NetworkRuleSettings.read(host.settings)
        rules = NetworkRules(settings: ruleSettings.settings)
        let problems = [setting.problem].compactMap { $0 } + ruleSettings.problems
        problems.forEach { host.log("SystemBar: network \($0)") }
        latency = LatencyState(internetAddress: setting.address, settingsProblems: problems)
        super.init()
        fastStats = host.fastStats.value
        feedSubscription = host.fastStats.publisher.sink { [weak self] snapshot in
            self?.fastStats = snapshot
        }
    }

    public func collect() {
        let now = probes.now()
        let sample = LatencyProbe.measure(router: probes.gateway(), internet: internetAddress, at: now, ping: probes.ping)
        let checked = rules.checking(sample, internetAddress: internetAddress)
        rules = checked.rules
        checked.notifications.forEach { host.notify(id: $0.id, title: $0.title, body: $0.body) }
        let due = schedule.check(at: now)
        let reading = due.isTrafficDue ? collector.sample() : nil
        let wifi = due.isVisible ? probes.readWiFi() : nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.latency = self.latency.recording(sample)
            if due.isVisible { self.wifi = wifi }
            if let reading { self.show(reading) }
        }
    }

    /// Main thread: the host showing or hiding the tab, just before it changes the cadence.
    @MainActor public func visibilityChanged(isVisible: Bool) {
        schedule.setVisible(isVisible)
    }

    /// Main thread: the panel's button. Does nothing while a test is already running.
    func runSpeedTest() {
        guard !speedTest.isRunning else { return }
        speedTest = speedTest.started()
        let host = self.host
        let startedAt = Date()
        speedTestQueue.async { [weak self] in
            let outcome = SpeedTest.measure(using: host, startedAt: startedAt)
            DispatchQueue.main.async {
                guard let self else { return }
                self.speedTest = self.speedTest.finished(with: outcome)
            }
        }
    }

    @MainActor public func makeView() -> AnyView {
        AnyView(NetworkPanel(plugin: self))
    }

    /// Main thread: shows a sample, then asks for the names of its destinations. Both write
    /// `summary` as a change to its current value, so a lookup that finishes between two samples
    /// is never lost.
    private func show(_ reading: NetworkReading) {
        summary = summary.applying(reading)
        collector.resolveHostnames(for: reading.destinations) { [weak self] address, hostname in
            guard let self else { return }
            self.summary = self.summary.resolving(address, to: hostname)
        }
    }
}
