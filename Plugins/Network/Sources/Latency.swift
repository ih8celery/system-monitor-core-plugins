import Darwin
import Foundation
import SystemBarKit

/// What one ping came back with.
enum PingOutcome: Equatable, Sendable {
    case reply(milliseconds: Double)
    case timeout
    case failed(String)
    /// The kernel refused the send at once: it has no IPv4 route to the address.
    case noRoute(String)
}

/// Sends one ping to an IPv4 address and waits no longer than the timeout.
typealias Pinger = @Sendable (_ address: String, _ timeout: TimeInterval) -> PingOutcome

/// One line's point on the latency graph. `unknown` is a gap, not a failure: the router line when
/// no router was found, and the internet line too when the kernel had no IPv4 route to send on.
enum LatencyPoint: Equatable, Sendable {
    case reply(Double)
    case failed(String)
    case unknown

    init(_ outcome: PingOutcome) {
        switch outcome {
        case .reply(let milliseconds): self = .reply(milliseconds)
        case .timeout: self = .failed("timed out")
        case .failed(let reason), .noRoute(let reason): self = .failed(reason)
        }
    }

    var milliseconds: Double? {
        if case .reply(let milliseconds) = self { return milliseconds }
        return nil
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// The router and the internet, pinged at one moment.
struct LatencySample: Equatable, Sendable {
    let at: Date
    let router: LatencyPoint
    let internet: LatencyPoint
}

/// What the latest sample suggests is at fault, when something is.
enum LatencyDiagnosis: Equatable {
    case internet
    case localNetwork

    var text: String {
        switch self {
        case .internet: "The router answers but the internet does not: likely your internet provider"
        case .localNetwork: "Neither the router nor the internet answers: likely the Wi-Fi or local network"
        }
    }
}

/// The last five minutes of pings, oldest first.
struct LatencyHistory: Equatable {
    static let capacity = 60
    static let noRouteNote = "No IPv4 route to the internet (an IPv6-only network, or none), so nothing is pinged"

    private(set) var samples: [LatencySample] = []

    func appending(_ sample: LatencySample) -> LatencyHistory {
        LatencyHistory(samples: Array((samples + [sample]).suffix(Self.capacity)))
    }

    var latest: LatencySample? { samples.last }

    /// The latest round sent nothing, for want of an IPv4 default route.
    var hasNoRoute: Bool {
        latest.map { $0.router == .unknown && $0.internet == .unknown } ?? false
    }

    /// Only a failing internet needs explaining: a router that answers puts the fault past it,
    /// and one that does not (or cannot be found) puts it on this side of it.
    var diagnosis: LatencyDiagnosis? {
        guard let latest, latest.internet.isFailure else { return nil }
        return latest.router.milliseconds == nil ? .localNetwork : .internet
    }
}

/// The latency line as the panel shows it.
struct LatencyState {
    var history = LatencyHistory()
    let internetAddress: String
    let settingsProblem: String?

    /// What the panel says under the graph: a settings problem and what the latest round
    /// suggests, each in its own line, so one never hides the other.
    var notes: [String] {
        let round = history.hasNoRoute ? LatencyHistory.noRouteNote : history.diagnosis?.text
        return [settingsProblem, round].compactMap { $0 }
    }

    func recording(_ sample: LatencySample) -> LatencyState {
        var next = self
        next.history = history.appending(sample)
        return next
    }
}

/// `pingAddress` in the tab's settings: the public address pinged for the internet line.
enum LatencySettings {
    static let key = "pingAddress"
    static let defaultAddress = "1.1.1.1"

    /// An IPv4 address in dotted form is used as given. Anything else, a hostname included,
    /// keeps the default and is reported, because a misspelt value must never silently do
    /// nothing; a hostname would also mean a DNS lookup every five seconds.
    static func internetAddress(_ settings: PluginSettings) -> (address: String, problem: String?) {
        guard settings[key] != nil else { return (defaultAddress, nil) }
        if let text = settings.string(forKey: key), let address = canonicalIPv4(text) { return (address, nil) }
        return (defaultAddress, "settings: \"\(key)\" must be an IPv4 address such as \(defaultAddress); pinging \(defaultAddress)")
    }

    /// The address as `inet_ntop` writes it, which is how a reply's source is compared with it.
    private static func canonicalIPv4(_ text: String) -> String? {
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
        var characters = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &characters, socklen_t(characters.count)) != nil else { return nil }
        return String(cString: characters)
    }
}

/// One round: the router and the internet, pinged at the same time, so two silent targets cost
/// one timeout. With no router found the internet is still pinged, because a full-tunnel VPN can
/// route IPv4 with no gateway address; only the kernel refusing that send for want of a route (an
/// IPv6-only network, or none) makes the internet line unknown rather than failed.
enum LatencyProbe {
    static func measure(router: String?, internet: String, at: Date, timeout: TimeInterval = NetworkSampling.pingTimeout, ping: Pinger) -> LatencySample {
        guard let router else {
            let outcome = ping(internet, timeout)
            if case .noRoute = outcome { return LatencySample(at: at, router: .unknown, internet: .unknown) }
            return LatencySample(at: at, router: .unknown, internet: LatencyPoint(outcome))
        }
        let targets = [router, internet]
        let results = PingResults(count: targets.count)
        DispatchQueue.concurrentPerform(iterations: targets.count) { index in
            results.set(index, ping(targets[index], timeout))
        }
        let outcomes = results.all
        return LatencySample(at: at, router: LatencyPoint(outcomes[0]), internet: LatencyPoint(outcomes[1]))
    }
}

/// The outcomes of pings running at once, each written by its own thread.
private final class PingResults: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [PingOutcome]

    init(count: Int) {
        outcomes = Array(repeating: .failed("not sent"), count: count)
    }

    func set(_ index: Int, _ outcome: PingOutcome) {
        lock.withLock { outcomes[index] = outcome }
    }

    var all: [PingOutcome] { lock.withLock { outcomes } }
}
