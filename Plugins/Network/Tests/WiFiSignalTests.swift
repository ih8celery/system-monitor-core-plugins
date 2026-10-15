import Foundation
import SystemBarKit

/// The Network tab's Wi-Fi card: the verdict from signal minus noise, what a reading needs before
/// it is shown, how it reads, and the plugin publishing it (or nothing, on Ethernet).
@MainActor
enum NetworkWiFiTests {
    static func runAll() {
        testVerdictAtTheBandEdges()
        testReadingNeedsAnAssociatedInterface()
        testSignalWithoutNoiseHasNoVerdict()
        testDetailText()
        testPluginPublishesTheWiFiReading()
        testPluginShowsNoWiFiWithoutAnInterface()
    }

    private static func signal(rssi: Int = -50, noise: Int = -90, rate: Double = 866, band: WiFiBand = .ghz5, channel: Int? = 149) -> WiFiSignal? {
        WiFiSignal(rssi: rssi, noise: noise, transmitRate: rate, band: band, channel: channel)
    }

    private static func testVerdictAtTheBandEdges() {
        let cases: [(snr: Int, verdict: WiFiVerdict)] = [
            (40, .good), (26, .good), (25, .fair), (20, .fair), (15, .fair), (14, .poor), (0, .poor), (-3, .poor)
        ]
        for (snr, verdict) in cases {
            expect(WiFiVerdict(snr: snr) == verdict, "SNR \(snr) dB should be \(verdict), got \(WiFiVerdict(snr: snr))")
        }
        expect(signal(rssi: -64, noise: -90)?.verdict == .good, "-64 dBm over -90 dBm noise is 26 dB, good")
        expect(signal(rssi: -65, noise: -90)?.verdict == .fair, "-65 dBm over -90 dBm noise is 25 dB, fair")
        expect(signal(rssi: -75, noise: -90)?.verdict == .fair, "-75 dBm over -90 dBm noise is 15 dB, fair")
        expect(signal(rssi: -76, noise: -90)?.verdict == .poor, "-76 dBm over -90 dBm noise is 14 dB, poor")
    }

    /// CoreWLAN answers 0 dBm when the interface is off or not joined to a network.
    private static func testReadingNeedsAnAssociatedInterface() {
        expect(signal(rssi: 0) == nil, "an interface that is not joined to a network has no reading")
        expect(signal(rssi: -50)?.snr == 40, "a joined interface reads signal minus noise, got \(String(describing: signal()?.snr))")
    }

    private static func testSignalWithoutNoiseHasNoVerdict() {
        let quiet = signal(rssi: -50, noise: 0)
        expect(quiet != nil && quiet?.snr == nil && quiet?.verdict == nil, "with no noise figure there is no SNR and no verdict to guess")
    }

    private static func testDetailText() {
        expect(WiFiBand.ghz2.label == "2.4 GHz" && WiFiBand.ghz5.label == "5 GHz" && WiFiBand.ghz6.label == "6 GHz", "bands read in GHz")
        expect(signal()?.signalText == "-50 dBm, noise -90 dBm, SNR 40 dB", "got \(String(describing: signal()?.signalText))")
        expect(signal()?.linkText == "5 GHz, channel 149, 866 Mbps", "got \(String(describing: signal()?.linkText))")
        let sparse = signal(noise: 0, rate: 0, band: .unknown, channel: nil)
        expect(sparse?.signalText == "-50 dBm", "missing noise is left out, got \(String(describing: sparse?.signalText))")
        expect(sparse?.linkText == "", "missing link details are left out, got \(String(describing: sparse?.linkText))")
        expect(WiFiVerdict.good.label == "Good" && WiFiVerdict.fair.label == "Fair" && WiFiVerdict.poor.label == "Poor", "verdicts read as one word")
    }

    private static func testPluginPublishesTheWiFiReading() {
        let reading = signal(rssi: -60)
        let plugin = NetworkPlugin(host: makeHost(), probes: .fake(readWiFi: { reading }))
        expect(plugin.wifi == nil, "nothing is shown before the first collect")
        plugin.visibilityChanged(isVisible: true)
        plugin.collect()
        waitUntil { plugin.wifi != nil }
        expect(plugin.wifi == reading, "collect() publishes the Wi-Fi reading for the panel, got \(String(describing: plugin.wifi))")
    }

    private static func testPluginShowsNoWiFiWithoutAnInterface() {
        let plugin = NetworkPlugin(host: makeHost(), probes: .fake())
        plugin.visibilityChanged(isVisible: true)
        plugin.collect()
        waitUntil { plugin.summary.status != NetworkSummary().status }
        expect(plugin.wifi == nil, "on Ethernet, or with Wi-Fi off, the card stays hidden")
    }
}
