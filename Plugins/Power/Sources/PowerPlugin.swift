import Combine
import Foundation
import SwiftUI
import SystemBarKit

/// The Power tab as a bundle. The host calls `collect()` on this plugin's queue once a minute
/// while the tab shows; the snapshot is published on the main thread and the panel observes it.
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

    @Published private(set) var snapshot = PowerSnapshot()
    @Published private(set) var contributors: [PowerContributor] = []
    private let host: HostServices
    private var feedSubscription: AnyCancellable?
    /// The last sample's charger state. Only `sample()` touches it, and the host calls
    /// `collect()` on this plugin's one queue, so samples never overlap.
    private var lastExternal: Bool?

    @MainActor public init(host: HostServices) {
        self.host = host
        super.init()
        contributors = PowerCollector.contributors(from: host.processes.value.topCPU)
        feedSubscription = host.processes.publisher.sink { [weak self] summary in
            self?.contributors = PowerCollector.contributors(from: summary.topCPU)
        }
    }

    public func collect() {
        let next = sample()
        DispatchQueue.main.async { [weak self] in
            self?.snapshot = next
        }
    }

    /// One reading, remembering the charger state so the next can tell a plug or unplug.
    func sample() -> PowerSnapshot {
        let next = PowerCollector.collect(using: host, previousExternal: lastExternal)
        lastExternal = next.isExternal ?? lastExternal
        return next
    }

    @MainActor public func makeView() -> AnyView {
        AnyView(PowerPanel(plugin: self))
    }
}
