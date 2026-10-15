import Foundation
import SystemBarKit

/// Health, cycles, temperature and time remaining, read from the same ioreg capture as the
/// charge state. Run from `PowerTests.runAll()`.
@MainActor
enum PowerBatteryDetailTests {
    static func runAll() {
        testTheCapturedBatteryReadsAsCaptured()
        testHealthIsRawMaxOverDesignAndMayPassOneHundred()
        testHealthIsAbsentWithoutBothCapacities()
        testCyclesAndTemperatureAreAbsentWhenMissing()
        testTimeRemainingIsUnknownAt65535ZeroOrMissing()
        testNoBatteryMeansNoDetail()
        testTimeRemainingLabelNeverReadsZero()
        testTimeRemainingShowsOnlyWhileChargingOrDischarging()
        testTemperatureLabelSaysWhoseItIs()
        testHealthLabel()
        testCollectCarriesTheDetail()
    }

    private static func detail(
        rawMaxCapacity: Int? = 6262, designCapacity: Int? = 6249, cycleCount: Int? = 24,
        temperature: Int? = 3069, timeRemaining: Int? = 65535
    ) -> BatteryDetail? {
        PowerCollector.parseBatteryDetail(PowerFixtures.ioreg(
            external: false, fullyCharged: false, charging: false, capacity: 79, notChargingReason: 0,
            rawMaxCapacity: rawMaxCapacity, designCapacity: designCapacity, cycleCount: cycleCount,
            temperature: temperature, timeRemaining: timeRemaining
        ))
    }

    private static func testTheCapturedBatteryReadsAsCaptured() {
        let parsed = PowerCollector.parseBatteryDetail(PowerFixtures.ioregHeld)
        let expected = BatteryDetail(healthPercent: 100, cycleCount: 24, temperatureCelsius: 30.69, minutesRemaining: nil)
        expect(parsed == expected, "this Mac's battery: 6262 of 6249 mAh, 24 cycles, 30.69 °C, no estimate; got \(String(describing: parsed))")
    }

    private static func testHealthIsRawMaxOverDesignAndMayPassOneHundred() {
        expect(detail(rawMaxCapacity: 6600, designCapacity: 6249)?.healthPercent == 106, "a new battery can read over 100%")
        expect(detail(rawMaxCapacity: 5000, designCapacity: 6249)?.healthPercent == 80, "5000 of 6249 rounds to 80%")
    }

    private static func testHealthIsAbsentWithoutBothCapacities() {
        expect(detail(rawMaxCapacity: nil)?.healthPercent == nil, "no raw max capacity means no health")
        expect(detail(designCapacity: nil)?.healthPercent == nil, "no design capacity means no health")
        expect(detail(designCapacity: 0)?.healthPercent == nil, "a zero design capacity means no health, not a division by zero")
    }

    private static func testCyclesAndTemperatureAreAbsentWhenMissing() {
        expect(detail(cycleCount: nil)?.cycleCount == nil, "no CycleCount means no cycles")
        expect(detail(cycleCount: 0)?.cycleCount == 0, "a new battery's zero cycles is a reading")
        expect(detail(temperature: nil)?.temperatureCelsius == nil, "no Temperature means no temperature")
    }

    private static func testTimeRemainingIsUnknownAt65535ZeroOrMissing() {
        expect(detail(timeRemaining: 65535)?.minutesRemaining == nil, "65535 is the driver's 'still calculating'")
        expect(detail(timeRemaining: nil)?.minutesRemaining == nil, "a missing TimeRemaining is not an estimate")
        expect(detail(timeRemaining: 0)?.minutesRemaining == nil, "zero is never shown as 0:00")
        expect(detail(timeRemaining: 245)?.minutesRemaining == 245, "a real estimate is kept in minutes")
    }

    private static func testNoBatteryMeansNoDetail() {
        expect(PowerCollector.parseBatteryDetail("") == nil, "a Mac with no battery has no battery detail")
        expect(PowerCollector.parseBatteryDetail("not a plist") == nil, "unreadable output has no battery detail")
    }

    private static func testTimeRemainingLabelNeverReadsZero() {
        expect(timeRemainingLabel(minutes: nil) == "Calculating…", "no estimate reads Calculating…")
        expect(timeRemainingLabel(minutes: 245) == "4:05", "245 minutes reads 4:05")
        expect(timeRemainingLabel(minutes: 7) == "0:07", "7 minutes reads 0:07")
    }

    private static func testTimeRemainingShowsOnlyWhileChargingOrDischarging() {
        expect(timeRemainingPill(state: .discharging, minutes: 245)?.label == "Time remaining", "on battery it is time to empty")
        expect(timeRemainingPill(state: .charging, minutes: nil)?.value == "Calculating…", "charging with no estimate yet says so")
        expect(timeRemainingPill(state: .charging, minutes: 30)?.label == "Until full", "charging it is time to full")
        for state: ChargeState? in [.full, .heldAtLimit, .onACNotCharging, nil] {
            expect(timeRemainingPill(state: state, minutes: nil) == nil, "\(String(describing: state)) has nothing counting down, so no pill")
        }
    }

    private static func testTemperatureLabelSaysWhoseItIs() {
        expect(batteryTemperatureLabel(30.69) == "30.7 °C", "temperature to one decimal, got \(batteryTemperatureLabel(30.69))")
    }

    private static func testHealthLabel() {
        expect(batteryHealthLabel(106) == "106%", "health reads as a percent")
    }

    private static func testCollectCarriesTheDetail() {
        let host = makeHost { path, arguments, _, _ in
            let output = path == PowerCollector.ioregPath ? PowerFixtures.ioregHeld : ""
            return CommandOutput(output: output, error: "", status: 0, didTimeout: false)
        }
        let snapshot = PowerCollector.collect(using: host)
        expect(snapshot.batteryDetail?.cycleCount == 24, "the snapshot carries the battery detail, got \(String(describing: snapshot.batteryDetail))")

        let failing = makeHost { _, _, _, _ in CommandOutput(output: "", error: "boom", status: 1, didTimeout: false) }
        expect(PowerCollector.collect(using: failing).batteryDetail == nil, "a failed ioreg read asserts no battery detail")
    }
}
