import Foundation
import SystemBarKit

/// Mac, battery and charger watts from the battery driver's entry. Run from `PowerTests.runAll()`.
@MainActor
enum PowerDrawTests {
    static func runAll() {
        testACIdleShowsChargerInputAndAnIdleBattery()
        testACChargingTakesTheBatteryShareOff()
        testACIgnoresTheTelemetrysBatteryAndLoadFigures()
        testOnBatteryTheMacIsTheBatteryDraw()
        testJustUnpluggedNeverShowsChargerInput()
        testJustPluggedInWaitsForTheTelemetry()
        testAmperageReadsAsSignedWhenPrintedUnsigned()
        testNoBatteryShowsInputOrNothing()
        testNoEntryMeansNoFigures()
        testLabels()
        testCollectTracksTheSourceBetweenSamples()
        testHoursOnTheChargerAreNotAFreshPlugIn()
        testReopeningWithinTheLagStillWaits()
        testTrackerOnlyTrustsAChangeItCanTime()
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

    /// The real capture: SystemPowerIn includes the charge current (19.556 V x 3.975 A in is the
    /// same 77.7 W), so the battery's share comes off it.
    private static func testACChargingTakesTheBatteryShareOff() {
        let reading = draw(PowerDrawFixtures.acCharging)
        expect(near(reading?.batteryWatts, 50.220), "11.529 V x 4.356 A into the battery is +50.2 W, got \(String(describing: reading?.batteryWatts))")
        expect(near(reading?.macWatts, 27.516), "77.7 W in less 50.2 W charging leaves the Mac 27.5 W, got \(String(describing: reading?.macWatts))")
    }

    /// In the capture the telemetry's BatteryPower is -6.2 W while the battery takes +50.2 W, and
    /// SystemLoad reads 83.9 W. Neither may move the figures.
    private static func testACIgnoresTheTelemetrysBatteryAndLoadFigures() {
        let reading = draw(PowerDrawFixtures.acCharging)
        expect(!near(reading?.batteryWatts, -6.199) && !near(reading?.macWatts, 83.935), "BatteryPower and SystemLoad are not the figures")
        let otherTelemetry = draw(PowerDrawFixtures.acChargingWith(systemLoad: 1000, batteryPower: 99000))
        expect(otherTelemetry == reading, "changing BatteryPower and SystemLoad changes nothing, got \(String(describing: otherTelemetry))")
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
        expect(near(reading?.batteryWatts, 50.220), "but the battery's own V x A still shows")
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

    /// A plugin whose ioreg answer and clock the test sets between samples.
    private static func samplingPlugin(_ start: String) -> (PowerPlugin, LockedText, LockedDate) {
        let ioreg = LockedText(start)
        let clock = LockedDate(Date(timeIntervalSince1970: 1_800_000_000))
        let host = makeHost { path, _, _, _ in
            CommandOutput(output: path == PowerCollector.ioregPath ? ioreg.value : "", error: "", status: 0, didTimeout: false)
        }
        return (PowerPlugin(host: host, clock: { clock.value }), ioreg, clock)
    }

    private static func testCollectTracksTheSourceBetweenSamples() {
        let (plugin, ioreg, clock) = samplingPlugin(PowerDrawFixtures.onBattery)
        expect(near(plugin.sample().powerDraw?.macWatts, 48.396), "the first sample has no change to wait out")
        clock.advance(by: 60)
        ioreg.value = PowerDrawFixtures.acCharging
        expect(plugin.sample().powerDraw?.macWatts == nil, "a minute after the last sample, a plug-in waits for the telemetry")
        clock.advance(by: 95)
        expect(near(plugin.sample().powerDraw?.macWatts, 27.516), "95 s after the change the telemetry is used")
    }

    /// Review scenario A: the tab was last shown on battery, then the Mac sat on the charger for
    /// three hours. The change happened long ago, so nothing is withheld.
    private static func testHoursOnTheChargerAreNotAFreshPlugIn() {
        let (plugin, ioreg, clock) = samplingPlugin(PowerDrawFixtures.onBattery)
        _ = plugin.sample()
        clock.advance(by: 3 * 60 * 60)
        ioreg.value = PowerDrawFixtures.acCharging
        expect(near(plugin.sample().powerDraw?.macWatts, 27.516), "after three hours unseen, the source change is not fresh")
    }

    /// Review scenario B: plugged in just before the tab opened, closed, reopened at 30 s.
    private static func testReopeningWithinTheLagStillWaits() {
        let (plugin, ioreg, clock) = samplingPlugin(PowerDrawFixtures.onBattery)
        _ = plugin.sample()
        clock.advance(by: 5)
        ioreg.value = PowerDrawFixtures.acCharging
        expect(plugin.sample().powerDraw?.macWatts == nil, "5 s after plugging in the Mac figure waits")
        clock.advance(by: 25)
        expect(plugin.sample().powerDraw?.macWatts == nil, "reopened 30 s after the change, it still waits: same source, but inside the lag")
    }

    private static func testTrackerOnlyTrustsAChangeItCanTime() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = SourceChangeTracker().observing(false, at: start)
        expect(!first.isSettling(at: start), "the first reading is not a change")
        let soon = first.observing(true, at: start + 30)
        expect(soon.isSettling(at: start + 30) && soon.isSettling(at: start + 119), "a change seen 30 s after the last sample settles for 90 s")
        expect(!soon.isSettling(at: start + 121), "and is settled after that")
        let late = first.observing(true, at: start + 600)
        expect(!late.isSettling(at: start + 600), "a change seen 10 minutes after the last sample cannot be timed, so it is trusted")
        let unknown = first.observing(nil, at: start + 30)
        expect(unknown == first, "a sample with no charger reading changes nothing")
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

/// A clock the test moves forward between samples.
private final class LockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date

    init(_ date: Date) { stored = date }

    var value: Date { lock.withLock { stored } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { stored = stored.addingTimeInterval(seconds) }
    }
}
