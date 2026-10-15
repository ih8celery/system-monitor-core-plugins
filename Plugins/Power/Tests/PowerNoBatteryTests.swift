import Foundation
import SystemBarKit

/// A Mac with no battery, now that Power installs by default: no battery bar, section, rules or
/// flow arrow to a battery, and the Mac's draw or a plain "no power figures". Run from
/// `PowerTests.runAll()`.
/// What `pmset -g batt` prints on a desktop Mac: the source line and no battery line. File
/// scope, so the `@Sendable` runners can read it.
private let pmsetDesktop = "Now drawing from 'AC Power'\n"

@MainActor
enum PowerNoBatteryTests {

    static func runAll() {
        testAnEmptyDriverReplyShowsNoBatteryAndNoFigures()
        testADriverEntryWithInputShowsOnlyTheMacsDraw()
        testNoBatteryNeverNotifies()
    }

    private static func snapshot(ioreg: String) -> PowerSnapshot {
        let host = makeHost { path, arguments, _, _ in
            let output = path == PowerCollector.ioregPath ? ioreg : (arguments == ["-g", "batt"] ? pmsetDesktop : "")
            return CommandOutput(output: output, error: "", status: 0, didTimeout: false)
        }
        return PowerCollector.collect(using: host)
    }

    private static func testAnEmptyDriverReplyShowsNoBatteryAndNoFigures() {
        let reading = snapshot(ioreg: "")
        expect(reading.powerSource == "AC Power", "the source still reads, got \(reading.powerSource)")
        expect(reading.batteryPercent == nil, "no battery percent, so no battery pill or bar")
        expect(reading.batteryDetail == nil && reading.chargeState == nil, "no battery section and no charge state")
        expect(reading.batteryAlert == nil, "nothing for the battery rules to read")
        expect(reading.hasDriverReading && reading.powerDraw == nil, "ioreg ran and found nothing, so the panel says this Mac reports no power figures")
        expect(PowerFlow(draw: reading.powerDraw, isExternal: reading.isExternal, isSettling: reading.isSettling) == nil, "and draws no flow picture")
    }

    private static func testADriverEntryWithInputShowsOnlyTheMacsDraw() {
        let reading = snapshot(ioreg: PowerDrawFixtures.noBatteryWithInput)
        expect(reading.batteryPercent == nil && reading.batteryAlert == nil, "an entry with no battery installed is still no battery")
        expect(reading.powerDraw.map { abs(($0.macWatts ?? 0) - 31.6) < 0.01 } == true && reading.powerDraw?.batteryWatts == nil, "the Mac's draw shows, and no battery figure, got \(String(describing: reading.powerDraw))")
        let flow = PowerFlow(draw: reading.powerDraw, isExternal: reading.isExternal, isSettling: reading.isSettling)
        expect(flow?.hasBattery == false && flow?.chargerToBattery == .inactive && flow?.batteryToMac == .inactive, "the flow has no battery and no arrow to or from one, got \(String(describing: flow))")
        guard case .active(let watts)? = flow?.chargerToMac else { return expect(false, "the charger-to-Mac arrow is lit") }
        expect(abs((watts ?? 0) - 31.6) < 0.01, "only the charger-to-Mac arrow, with the Mac's draw, got \(String(describing: watts))")
    }

    private static func testNoBatteryNeverNotifies() {
        let recorder = HostServices.recordingNotifications()
        let dataDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        let host = HostServices(
            homeDirectory: "/tmp/systembar-tests",
            processes: Feed(initial: ProcessSummary()), fastStats: Feed(initial: FastStatsSnapshot()),
            runner: { path, _, _, _ in CommandOutput(output: path == PowerCollector.ioregPath ? "" : pmsetDesktop, error: "", status: 0, didTimeout: false) },
            log: { _ in }, settings: .empty,
            dataDirectory: dataDirectory,
            notify: recorder.notify
        )
        let plugin = PowerPlugin(host: host)
        for _ in 0..<20 { plugin.collect() }
        expect(recorder.posted().isEmpty, "a Mac with no battery never gets a battery notification, got \(recorder.posted())")
    }
}
