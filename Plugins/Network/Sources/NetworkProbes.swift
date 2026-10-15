import Foundation

/// What the plugin reads from the machine apart from its commands: the Wi-Fi link, pings, the
/// router's address, and the clock. Tests pass fakes; the app uses `live`.
struct NetworkProbes: Sendable {
    let readWiFi: @Sendable () -> WiFiSignal?
    let ping: Pinger
    let gateway: @Sendable () -> String?
    let now: @Sendable () -> Date

    static var live: NetworkProbes {
        let pinger = ICMPPinger()
        return NetworkProbes(
            readWiFi: { WiFiReader.current() },
            ping: { pinger.ping($0, timeout: $1) },
            gateway: { DefaultGateway.current() },
            now: { Date() }
        )
    }
}

/// Whether the tab is showing, and when nettop and lsof last ran. The host calls `collect()`
/// every 5 s for the pings, shown or hidden; traffic is sampled only while the tab shows, at
/// once when it is shown, then every 30 s. Set on main, read on the plugin's queue.
final class TrafficSchedule: @unchecked Sendable {
    /// A tick a moment early still counts, so 5-second ticks land the 30-second sample on the
    /// sixth, not the seventh.
    private static let tolerance: TimeInterval = 1

    private let lock = NSLock()
    private var isVisible = false
    private var lastSampleAt: Date?

    func setVisible(_ visible: Bool) {
        lock.withLock {
            isVisible = visible
            if visible { lastSampleAt = nil }
        }
    }

    /// Whether the tab shows, and whether traffic is due now; a due answer records the sample.
    func check(at now: Date) -> (isVisible: Bool, isTrafficDue: Bool) {
        lock.withLock {
            guard isVisible else { return (false, false) }
            if let lastSampleAt, now.timeIntervalSince(lastSampleAt) + Self.tolerance < NetworkSampling.trafficInterval {
                return (true, false)
            }
            lastSampleAt = now
            return (true, true)
        }
    }
}
