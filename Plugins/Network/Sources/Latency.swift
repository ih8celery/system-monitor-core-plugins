import Darwin
import Foundation
import SystemBarKit

/// What one ping came back with.
enum PingOutcome: Equatable, Sendable {
    case reply(milliseconds: Double)
    case timeout
    case failed(String)
}

/// Sends one ping to an IPv4 address and waits no longer than the timeout.
typealias Pinger = @Sendable (_ address: String, _ timeout: TimeInterval) -> PingOutcome

/// One line's point on the latency graph. `unknown` is a router that could not be found, so no
/// ping was sent: a gap in the line, not a failure.
enum LatencyPoint: Equatable, Sendable {
    case reply(Double)
    case failed(String)
    case unknown

    init(_ outcome: PingOutcome) {
        switch outcome {
        case .reply(let milliseconds): self = .reply(milliseconds)
        case .timeout: self = .failed("timed out")
        case .failed(let reason): self = .failed(reason)
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

    private(set) var samples: [LatencySample] = []

    func appending(_ sample: LatencySample) -> LatencyHistory {
        LatencyHistory(samples: Array((samples + [sample]).suffix(Self.capacity)))
    }

    var latest: LatencySample? { samples.last }

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
        if let text = settings.string(forKey: key), isIPv4(text) { return (text, nil) }
        return (defaultAddress, "settings: \"\(key)\" must be an IPv4 address such as \(defaultAddress); pinging \(defaultAddress)")
    }

    private static func isIPv4(_ text: String) -> Bool {
        var address = in_addr()
        return inet_pton(AF_INET, text, &address) == 1
    }
}

/// One round: the router, when there is one, then the internet.
enum LatencyProbe {
    static func measure(router: String?, internet: String, at: Date, timeout: TimeInterval = NetworkSampling.pingTimeout, ping: Pinger) -> LatencySample {
        let routerPoint = router.map { LatencyPoint(ping($0, timeout)) } ?? .unknown
        return LatencySample(at: at, router: routerPoint, internet: LatencyPoint(ping(internet, timeout)))
    }
}
