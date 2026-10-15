import Combine
import Foundation
import SwiftUI
import SystemBarKit

/// The Memory tab as a bundle. The host calls `collect()` on this plugin's queue every 3 seconds
/// while the tab shows and every 10 seconds while it is hidden, which keeps the pressure graph full; each collect reads the kernel's memory figures and pressure level (ioreg
/// only every 30 seconds, and only while showing) and publishes on main. The top-memory list follows the process feed.
@objc(SystemBarMemoryPlugin)
public final class MemoryPlugin: NSObject, TabPlugin, ObservableObject {
    public static let identifier = "memory"
    public let title = "Memory"
    public let systemImage = "memorychip"
    public let accent = Palette.good
    public let refreshInterval: TimeInterval = MemorySampling.refreshInterval
    public let sharedFeeds: Set<SharedFeed> = [.processes]
    public let backgroundInterval: TimeInterval? = MemorySampling.backgroundInterval

    @Published private(set) var stats = MemoryStatsSnapshot()
    @Published private(set) var processes = ProcessSummary()
    private let collector: MemoryCollector
    private let host: HostServices
    /// What the notification rules remember. Touched only by `collect`, which the host calls one at a time.
    private var alerts: MemoryAlertRules
    private var feedSubscription: AnyCancellable?

    @MainActor public convenience init(host: HostServices) {
        self.init(host: host, kernelPressureLevel: MemoryCollector.readKernelPressureLevel)
    }

    /// The kernel's pressure level is a parameter so a test can walk it through the levels.
    @MainActor init(host: HostServices, kernelPressureLevel: @escaping () -> Int32?) {
        collector = MemoryCollector(host: host, kernelPressureLevel: kernelPressureLevel)
        self.host = host
        let parsed = MemoryAlertConfig.parse(host.settings)
        parsed.problems.forEach { host.log($0) }
        alerts = MemoryAlertRules(config: parsed.config)
        super.init()
        processes = host.processes.value
        feedSubscription = host.processes.publisher.sink { [weak self] summary in
            self?.processes = summary
        }
    }

    public func collect() {
        let reading = collector.sample()
        let result = alerts.evaluating(reading)
        alerts = result.rules
        result.notifications.forEach { host.notify(id: $0.id, title: $0.title, body: $0.body) }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stats = self.stats.recording(reading)
        }
    }

    /// Main thread: the host showing or hiding the tab. Hidden, the GPU pills' ioreg is not run.
    @MainActor public func visibilityChanged(isVisible: Bool) {
        collector.setShowing(isVisible)
    }

    @MainActor public func makeView() -> AnyView {
        AnyView(MemoryPanel(plugin: self))
    }
}
