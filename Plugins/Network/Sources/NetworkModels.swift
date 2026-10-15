import Foundation
import SystemBarKit

struct NetworkProcessSnapshot: Identifiable {
    let id: String
    let name: String
    let downloadRate: Double
    let uploadRate: Double
    let totalDownloaded: UInt64
    let totalUploaded: UInt64

    var combinedRate: Double { downloadRate + uploadRate }

    var combinedRateText: String { networkRateText(combinedRate) }
    var downloadRateText: String { "D \(networkRateText(downloadRate))" }
    var uploadRateText: String { "U \(networkRateText(uploadRate))" }

    /// What nettop's first block counts: bytes since each process started, added up over the
    /// processes that share a name.
    static let totalsHelp = "Received and sent since each app started, by nettop's count; an app with several processes adds them up"

    var totalsText: String {
        "\(fileByteString(totalDownloaded)) in, \(fileByteString(totalUploaded)) out"
    }
}

struct NetworkDestination: Identifiable {
    var id: String { "\(process)|\(endpoint)" }
    let process: String
    let endpoint: String
    let remoteAddress: String
    let count: Int
}

struct HostnameCacheEntry {
    let hostname: String
    let cachedAt: Date
}

struct NetworkSummary {
    var processes: [NetworkProcessSnapshot] = []
    var totalProcessCount = 0
    var maxCombinedRate: Double = 1
    var destinations: [NetworkDestination] = []
    /// The newest reverse lookups by address, capped, since a tab open for days meets many.
    var resolvedHostnames = BoundedCache<String, String>()
    var status = "Waiting for network sample"
    var health = SampleHealth.degraded

    init() {}

    init(
        processes: [NetworkProcessSnapshot],
        destinations: [NetworkDestination],
        resolvedHostnames: BoundedCache<String, String>,
        status: String,
        health: SampleHealth,
        limit: Int = 28
    ) {
        self.totalProcessCount = processes.count
        self.maxCombinedRate = max(processes.map(\.combinedRate).max() ?? 1, 1)
        self.processes = Array(processes.prefix(limit))
        self.destinations = destinations
        self.resolvedHostnames = resolvedHostnames
        self.status = status
        self.health = health
    }
}

struct SpeedTestResult {
    let downloadMbps: Double?
    let uploadMbps: Double?
    let latencyMS: Double?
    let interfaceName: String
    let endpoint: String
    let measuredAt: Date
    let duration: TimeInterval
}

struct TCPConnection {
    let process: String
    let localEndpoint: String
    let remoteEndpoint: String
    let remoteAddress: String
    let isInternet: Bool

    var dedupeKey: String {
        "\(process)|\(localEndpoint)|\(remoteEndpoint)"
    }
}

/// How often the Network tab samples.
enum NetworkSampling {
    /// The router and the internet are pinged this often, shown or hidden: the host calls
    /// `collect()` at this interval either way.
    static let pingInterval: TimeInterval = 5
    /// How long one ping waits for its reply. Two in a row stay inside one ping interval.
    static let pingTimeout: TimeInterval = 2
    /// Rounds further apart than this were not in a row: the Mac slept, or the host stopped
    /// calling. A round or two late is still in a row.
    static let maximumRoundGap: TimeInterval = 3 * pingInterval
    /// nettop alone takes about a second by design, so it and lsof run this often, and only while
    /// the tab shows.
    static let trafficInterval: TimeInterval = 30
}

/// What one nettop and lsof sample found.
struct NetworkReading {
    let processes: [NetworkProcessSnapshot]
    let destinations: [NetworkDestination]
    let status: String
    let health: SampleHealth
}

extension NetworkSummary {
    /// A copy showing a new sample. Hostnames already resolved are kept: lookups outlive samples.
    func applying(_ reading: NetworkReading) -> NetworkSummary {
        NetworkSummary(
            processes: reading.processes,
            destinations: reading.destinations,
            resolvedHostnames: resolvedHostnames,
            status: reading.status,
            health: reading.health
        )
    }

    /// A copy with one finished reverse lookup recorded by address.
    func resolving(_ address: String, to hostname: String) -> NetworkSummary {
        var next = self
        next.resolvedHostnames = resolvedHostnames.setting(hostname, for: address)
        return next
    }
}

/// One networkQuality run: a result, or the one-line reason there is none.
struct SpeedTestOutcome {
    let result: SpeedTestResult?
    let failure: String
}

/// The speed test as the panel shows it.
struct SpeedTestState {
    var isRunning = false
    var status = "Ready"
    var health = SampleHealth.ok
    var result: SpeedTestResult?

    func started() -> SpeedTestState {
        var next = self
        next.isRunning = true
        next.status = "Testing"
        next.health = .ok
        return next
    }

    /// A failed run says why and keeps the last good result on screen.
    func finished(with outcome: SpeedTestOutcome) -> SpeedTestState {
        var next = self
        next.isRunning = false
        if let result = outcome.result {
            next.result = result
            next.status = "Last run \(SpeedTest.shortTimeString(result.measuredAt))"
            next.health = .ok
        } else {
            next.status = outcome.failure
            next.health = .degraded
        }
        return next
    }
}
