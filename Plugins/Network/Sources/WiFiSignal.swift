import Foundation

/// The radio band the Wi-Fi interface is on.
enum WiFiBand: Equatable {
    case ghz2, ghz5, ghz6, unknown

    var label: String? {
        switch self {
        case .ghz2: "2.4 GHz"
        case .ghz5: "5 GHz"
        case .ghz6: "6 GHz"
        case .unknown: nil
        }
    }
}

/// How usable the link is, judged from signal minus noise: above 25 dB is good, 15 to 25 fair,
/// below 15 poor.
enum WiFiVerdict: Equatable {
    case good, fair, poor

    static let goodAbove = 25
    static let poorBelow = 15

    init(snr: Int) {
        if snr > Self.goodAbove {
            self = .good
        } else if snr >= Self.poorBelow {
            self = .fair
        } else {
            self = .poor
        }
    }

    var label: String {
        switch self {
        case .good: "Good"
        case .fair: "Fair"
        case .poor: "Poor"
        }
    }
}

/// One reading of the Wi-Fi link. No network name: CoreWLAN gives that only with Location
/// permission.
struct WiFiSignal: Equatable {
    /// Received signal strength, dBm.
    let rssi: Int
    /// Background noise, dBm; nil when the interface does not report it.
    let noise: Int?
    /// Current transmit rate, Mbps; nil when unreported.
    let transmitRate: Double?
    let band: WiFiBand
    let channel: Int?

    /// Nil when the interface is off or not joined to a network, which CoreWLAN reports as a
    /// signal of 0 dBm. A noise or rate of 0 means the figure is unreported.
    init?(rssi: Int, noise: Int, transmitRate: Double, band: WiFiBand, channel: Int?) {
        guard rssi != 0 else { return nil }
        self.rssi = rssi
        self.noise = noise == 0 ? nil : noise
        self.transmitRate = transmitRate > 0 ? transmitRate : nil
        self.band = band
        self.channel = channel
    }

    /// Signal minus noise, dB.
    var snr: Int? { noise.map { rssi - $0 } }

    var verdict: WiFiVerdict? { snr.map(WiFiVerdict.init(snr:)) }

    var signalText: String {
        guard let noise, let snr else { return "\(rssi) dBm" }
        return "\(rssi) dBm, noise \(noise) dBm, SNR \(snr) dB"
    }

    var linkText: String {
        [
            band.label,
            channel.map { "channel \($0)" },
            transmitRate.map { String(format: "%.0f Mbps", $0) }
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}
