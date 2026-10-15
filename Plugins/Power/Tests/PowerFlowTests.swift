import Foundation
import SystemBarKit

/// The flow picture's model, from the power draw. Run from `PowerTests.runAll()`.
@MainActor
enum PowerFlowTests {
    static func runAll() {
        testACChargingFlowsToTheMacAndTheBattery()
        testACHeldFlowsToTheMacWithTheBatteryIdle()
        testOnBatteryTheBatteryFeedsTheMac()
        testSettlingShowsTheArrowsWithoutNumbers()
        testAMissingFigureShowsItsArrowWithoutANumber()
        testABatteryHelpingTheChargerFeedsTheMacToo()
        testNoChargerReadingMeansNoPicture()
        testCollectCarriesTheSettleWindow()
    }

    private static func flow(_ ioreg: String, isSettling: Bool = false) -> PowerFlow? {
        let entry = PowerCollector.batteryEntry(ioreg)
        let draw = PowerCollector.powerDraw(from: entry, sourceJustChanged: isSettling)
        return PowerFlow(draw: draw, isExternal: entry?["ExternalConnected"] as? Bool, isSettling: isSettling)
    }

    private static func near(_ link: FlowLink?, _ expected: Double) -> Bool {
        guard case .active(let watts?) = link else { return false }
        return abs(watts - expected) < 0.01
    }

    private static func testACChargingFlowsToTheMacAndTheBattery() {
        let picture = flow(PowerDrawFixtures.acCharging)
        expect(near(picture?.chargerToMac, 27.516), "the charger feeds the Mac 27.5 W, got \(String(describing: picture))")
        expect(near(picture?.chargerToBattery, 50.220), "and the battery 50.2 W")
        expect(picture?.batteryToMac == .inactive, "the battery gives nothing while charging")
        expect(picture.flatMap(\.chargerInWatts).map { abs($0 - 77.736) < 0.01 } == true, "the charger puts in the sum, 77.7 W, as SystemPowerIn showed")
    }

    private static func testACHeldFlowsToTheMacWithTheBatteryIdle() {
        let picture = flow(PowerDrawFixtures.acIdle)
        expect(near(picture?.chargerToMac, 46.496), "held at the limit the charger feeds only the Mac, got \(String(describing: picture))")
        expect(picture?.chargerToBattery == .inactive && picture?.batteryToMac == .inactive, "the battery is idle")
        expect(picture?.hasBattery == true && picture?.isPluggedIn == true, "both ends are drawn")
    }

    private static func testOnBatteryTheBatteryFeedsTheMac() {
        let picture = flow(PowerDrawFixtures.onBattery)
        expect(near(picture?.batteryToMac, 48.396), "unplugged the battery feeds the Mac 48.4 W, got \(String(describing: picture))")
        expect(picture?.chargerToMac == .inactive && picture?.chargerToBattery == .inactive, "nothing comes from a charger that is not there")
        expect(picture?.isPluggedIn == false && picture?.chargerInWatts == nil, "and the charger is drawn unplugged")
    }

    private static func testSettlingShowsTheArrowsWithoutNumbers() {
        let plugged = flow(PowerDrawFixtures.acCharging, isSettling: true)
        expect(plugged?.chargerToMac == .active(nil) && plugged?.chargerToBattery == .active(nil),
               "just plugged in, the arrows show with no numbers, got \(String(describing: plugged))")
        expect(plugged?.chargerInWatts == nil, "and the charger's input is not guessed")
        let unplugged = flow(PowerDrawFixtures.justUnplugged, isSettling: true)
        expect(unplugged?.batteryToMac == .active(nil), "just unplugged, the stale 2.0 W is not drawn, got \(String(describing: unplugged))")
    }

    private static func testAMissingFigureShowsItsArrowWithoutANumber() {
        let draw = PowerDraw(macWatts: nil, batteryWatts: 0, chargerRatedWatts: 94)
        let picture = PowerFlow(draw: draw, isExternal: true, isSettling: false)
        expect(picture?.chargerToMac == .active(nil), "a missing Mac figure keeps its arrow without a number")
    }

    private static func testABatteryHelpingTheChargerFeedsTheMacToo() {
        let draw = PowerDraw(macWatts: 110, batteryWatts: -16, chargerRatedWatts: 94)
        let picture = PowerFlow(draw: draw, isExternal: true, isSettling: false)
        expect(picture?.batteryToMac == .active(16) && picture?.chargerToBattery == .inactive, "a battery topping up the charger feeds the Mac")
        expect(picture?.chargerInWatts == 94, "and the charger puts in the rest, 110 - 16 W")
    }

    private static func testNoChargerReadingMeansNoPicture() {
        expect(PowerFlow(draw: nil, isExternal: nil, isSettling: false) == nil, "no battery driver reading, no picture")
    }

    private static func testCollectCarriesTheSettleWindow() {
        let host = makeHost { path, _, _, _ in
            CommandOutput(output: path == PowerCollector.ioregPath ? PowerDrawFixtures.acCharging : "", error: "", status: 0, didTimeout: false)
        }
        expect(PowerCollector.collect(using: host, isSettling: { _ in true }).isSettling, "the snapshot says when the telemetry is settling")
        expect(!PowerCollector.collect(using: host).isSettling, "and when it is not")
    }
}
