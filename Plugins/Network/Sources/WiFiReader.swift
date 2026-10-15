import CoreWLAN
import Foundation

/// Reads the Wi-Fi link from CoreWLAN. Nil when the Mac has no Wi-Fi interface, or it is off or
/// not joined to a network, so the card hides then; a Mac on Ethernet with Wi-Fi also joined
/// still shows it.
enum WiFiReader {
    static func current() -> WiFiSignal? {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else { return nil }
        let channel = interface.wlanChannel()
        return WiFiSignal(
            rssi: interface.rssiValue(),
            noise: interface.noiseMeasurement(),
            transmitRate: interface.transmitRate(),
            band: band(channel?.channelBand),
            channel: channel?.channelNumber
        )
    }

    private static func band(_ band: CWChannelBand?) -> WiFiBand {
        switch band {
        case .band2GHz: .ghz2
        case .band5GHz: .ghz5
        case .band6GHz: .ghz6
        default: .unknown
        }
    }
}
