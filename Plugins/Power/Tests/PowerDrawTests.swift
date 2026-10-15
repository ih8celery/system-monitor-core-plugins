import Foundation
import SystemBarKit

/// Mac, battery and charger watts from the battery driver's entry. Run from `PowerTests.runAll()`.
@MainActor
enum PowerDrawTests {
    static func runAll() {
        testACIdleShowsChargerInputAndAnIdleBattery()
        testACChargingTakesTheBatteryShareOff()
        testOnBatteryTheMacIsTheBatteryDraw()
        testJustUnpluggedNeverShowsChargerInput()
        testJustPluggedInWaitsForTheTelemetry()
        testAmperageReadsAsSignedWhenPrintedUnsigned()
        testNoBatteryShowsInputOrNothing()
        testNoEntryMeansNoFigures()
        testLabels()
        testCollectTracksTheSourceBetweenSamples()
    }

    private static func draw(_ output: String, sourceJustChanged: Bool = false) -> PowerDraw? {
        PowerCollector.powerDraw(from: PowerCollector.batteryEntry(output), sourceJustChanged: sourceJustChanged)
    }

    private static func near(_ value: Double?, _ expected: Double) -> Bool {
        value.map { abs($0 - expected) < 0.01 } ?? false
    }

    private static func testACIdleShowsChargerInputAndAnIdleBattery() {
        let reading = draw(PowerDrawFixtures.acIdle)
        expect(near(reading?.macWatts, 46.496), "on AC with the battery idle the Mac is SystemPowerIn, got \(String(describing: reading))")
        expect(reading?.batteryWatts == 0, "an idle battery reads 0 W, a real reading, got \(String(describing: reading?.batteryWatts))")
        expect(reading?.chargerRatedWatts == 94, "the charger is its rated 94 W, got \(String(describing: reading?.chargerRatedWatts))")
    }

    private static func testACChargingTakesTheBatteryShareOff() {
        let reading = draw(PowerDrawFixtures.acCharging)
        expect(near(reading?.batteryWatts, 24.6), "12.3 V x 2 A into the battery is +24.6 W, got \(String(describing: reading?.batteryWatts))")
        expect(near(reading?.macWatts, 45.4), "70 W in less 24.6 W charging leaves the Mac 45.4 W, got \(String(describing: reading?.macWatts))")
    }

    /// The probe: telemetry said -12.1 W while the battery was giving 48.4 W.
    private static func testOnBatteryTheMacIsTheBatteryDraw() {
        let reading = draw(PowerDrawFixtures.onBattery)
        expect(near(reading?.batteryWatts, -48.396), "11.398 V x -4.246 A is -48.4 W, got \(String(describing: reading?.batteryWatts))")
        expect(near(reading?.macWatts, 48.396), "on battery the Mac draws what the battery gives, got \(String(describing: reading?.macWatts))")
        expect(reading?.chargerRatedWatts == nil, "no charger is shown on battery")
    }

    private static func testJustUnpluggedNeverShowsChargerInput() {
        for justChanged in [true, false] {
            let reading = draw(PowerDrawFixtures.justUnplugged, sourceJustChanged: justChanged)
            expect(!near(reading?.macWatts, 84.81) && !near(reading?.macWatts, 87.03),
                   "stale charger input is never the Mac's figure while unplugged, got \(String(describing: reading?.macWatts))")
            expect(near(reading?.macWatts, 1.973), "it is the battery's V x |A| instead, got \(String(describing: reading?.macWatts))")
        }
    }

    private static func testJustPluggedInWaitsForTheTelemetry() {
        let reading = draw(PowerDrawFixtures.acCharging, sourceJustChanged: true)
        expect(reading?.macWatts == nil, "the minute after plugging in, the lagging telemetry is not used, got \(String(describing: reading?.macWatts))")
        expect(near(reading?.batteryWatts, 24.6), "but the battery's own V x A still shows")
    }

    private static func testAmperageReadsAsSignedWhenPrintedUnsigned() {
        let reading = draw(PowerDrawFixtures.onBatteryUnsignedAmperage)
        expect(near(reading?.batteryWatts, -48.396), "18446744073709547370 is -4246 mA, got \(String(describing: reading?.batteryWatts))")
    }

    private static func testNoBatteryShowsInputOrNothing() {
        let input = draw(PowerDrawFixtures.noBatteryWithInput)
        expect(near(input?.macWatts, 31.6) && input?.batteryWatts == nil, "a Mac with no battery shows SystemPowerIn, got \(String(describing: input))")
        expect(draw(PowerDrawFixtures.noBatteryNoFigures) == nil, "with no input figure either, there are no power figures, not 0 W")
    }

    private static func testNoEntryMeansNoFigures() {
        expect(draw("") == nil, "no AppleSmartBattery entry means no power figures")
        expect(PowerCollector.powerDraw(from: nil, sourceJustChanged: false) == nil, "and nothing is made up")
    }

    private static func testLabels() {
        expect(wattsLabel(48.396) == "48.4 W", "watts to one decimal, got \(wattsLabel(48.396))")
        expect(batteryFlowLabel(-48.396) == "48.4 W out", "a discharging battery gives watts out")
        expect(batteryFlowLabel(24.6) == "24.6 W in", "a charging battery takes watts in")
        expect(batteryFlowLabel(0) == "Idle", "an idle battery says so")
        expect(chargerLabel(94) == "94 W rated", "the charger is its rating, not a measurement")
    }

    private static func testCollectTracksTheSourceBetweenSamples() {
        let ioreg = LockedText(PowerDrawFixtures.onBattery)
        let host = makeHost { path, _, _, _ in
            CommandOutput(output: path == PowerCollector.ioregPath ? ioreg.value : "", error: "", status: 0, didTimeout: false)
        }
        let plugin = PowerPlugin(host: host)
        let first = plugin.sample()
        expect(near(first.powerDraw?.macWatts, 48.396), "the first sample has no change to wait out")
        ioreg.value = PowerDrawFixtures.acCharging
        expect(plugin.sample().powerDraw?.macWatts == nil, "the sample after plugging in waits for the telemetry")
        expect(near(plugin.sample().powerDraw?.macWatts, 45.4), "the one after that uses it")
    }
}

/// Text a `@Sendable` runner reads while the test changes it between samples.
private final class LockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String

    init(_ text: String) { stored = text }

    var value: String {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
