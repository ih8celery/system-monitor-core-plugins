import Foundation
import SystemBarKit

/// The ioreg arguments the collector must ask for, written out here rather than read back from
/// the collector, so a change to them shows up as a failing test.
private let ioregArguments = ["-r", "-n", "AppleSmartBattery", "-a"]

/// Main-actor because a plugin is constructed on the main thread, by contract.
@MainActor
enum PowerTests {
    static func runAll() {
        testBatteryParsing()
        testChargeStateComesFromTheBatteryDriver()
        testChargeStateIsAbsentWithoutABatteryReading()
        testBatteryStatLabel()
        testParseSleepAssertions()
        testContributorsComeFromTheProcessFeed()
        testContributorsShowTheSameCPUPercentAsTheCPUTab()
        testCollectRunsPmsetTwiceAndReadsTheAnswers()
        testCollectSaysWhatIsUnavailableWhenPmsetFails()
        testCollectReadsAMacHeldAtItsLimitAsHeld()
        testCollectReadsAMacOnBatteryAsDischarging()
        testContributorsFollowTheProcessFeed()
        testPluginIdentityMatchesTheOldTab()
        PowerBatteryDetailTests.runAll()
        PowerChargeLimitTests.runAll()
        PowerDrawTests.runAll()
        PowerFlowTests.runAll()
        PowerHistoryTests.runAll()
        PowerAlertTests.runAll()
        PowerNoBatteryTests.runAll()
    }

    private static func testBatteryParsing() {
        let sample = """
        Now drawing from 'AC Power'
         -InternalBattery-0 (id=1234567)\t92%; charging; 0:14 remaining present: true
        """
        let parsed = PowerCollector.parseBatteryStatus(sample)
        expect(parsed.powerSource == "AC Power", "battery parser should extract power source")
        expect(parsed.percent == 92, "battery parser should extract percentage")
    }

    private static func testChargeStateComesFromTheBatteryDriver() {
        let cases: [(String, ChargeState, String)] = [
            (PowerFixtures.ioregHeld, .heldAtLimit, "captured at the 80% limit"),
            (PowerFixtures.ioregDischarging, .discharging, "unplugged"),
            (PowerFixtures.ioregCharging, .charging, "charging"),
            (PowerFixtures.ioregFull, .full, "full on the charger"),
            (PowerFixtures.ioreg(external: true, fullyCharged: false, charging: false, capacity: 50, notChargingReason: 0),
             .onACNotCharging, "on the charger, not charging, no reason given"),
            (PowerFixtures.ioreg(external: true, fullyCharged: false, charging: false, capacity: 50, notChargingReason: 4),
             .onACNotCharging, "on the charger, not charging for a reason other than the limit"),
        ]
        for (output, expected, situation) in cases {
            let state = PowerCollector.parseChargeState(output)
            expect(state == expected, "\(situation) should read \(expected), got \(String(describing: state))")
        }
    }

    private static func testChargeStateIsAbsentWithoutABatteryReading() {
        // A Mac with no battery: ioreg finds nothing and prints nothing.
        expect(PowerCollector.parseChargeState("") == nil, "no ioreg output means no charge state")
        expect(PowerCollector.parseChargeState("<plist version=\"1.0\"><array/></plist>") == nil, "an empty battery list means no charge state")
        expect(PowerCollector.parseChargeState("not a plist") == nil, "unreadable output means no charge state, not a guess")
        let missingKeys = "<plist version=\"1.0\"><array><dict><key>CurrentCapacity</key><integer>80</integer></dict></array></plist>"
        expect(PowerCollector.parseChargeState(missingKeys) == nil, "a battery entry without the charging keys means no charge state")
    }

    private static func testBatteryStatLabel() {
        let cases: [(ChargeState?, String)] = [
            (.charging, "82% Charging"),
            (.discharging, "82% Discharging"),
            (.full, "82% Full"),
            (.heldAtLimit, "Held at 82% limit"),
            (.onACNotCharging, "82% On AC (not charging)"),
            (nil, "82%"),
        ]
        for (state, expected) in cases {
            let label = batteryStatLabel(percent: 82, state: state)
            expect(label == expected, "\(String(describing: state)) should read \(expected), got \(label)")
        }
    }

    private static func testParseSleepAssertions() {
        let output = """
                PreventUserIdleSystemSleep     1
                PreventUserIdleDisplaySleep    0
                UserIsActive                   1
                AssertionType: PreventSystemSleep = 0
        """
        let assertions = PowerCollector.parseSleepAssertions(output)
        expect(assertions.count == 2, "only lines mentioning 'prevent' that aren't explicitly zeroed should be kept")
        expect(assertions.contains { $0.contains("PreventUserIdleSystemSleep") }, "an active prevent-sleep assertion should be included")
        expect(!assertions.contains { $0.contains("UserIsActive") }, "a line not mentioning 'prevent' should be excluded")
        expect(!assertions.contains { $0.contains("= 0") }, "an assertion explicitly set to 0 should be excluded")
    }

    private static func testContributorsComeFromTheProcessFeed() {
        let rows = [
            ProcessSnapshot(name: "clang", count: 4, physical: 2_000_000, virtualSize: 0, cpu: 240),
            ProcessSnapshot(name: "idle", count: 1, physical: 1_000, virtualSize: 0, cpu: 0),
        ]
        let contributors = PowerCollector.contributors(from: rows)
        expect(contributors.map(\.name) == ["clang", "idle"], "contributors are the feed's top CPU rows in order")
        expect(contributors[0].evidence.contains("CPU") && contributors[0].evidence.contains("memory"), "each contributor says why, got \(contributors[0].evidence)")
        expect(contributors[0].evidence.hasSuffix("\(memoryByteString(2_000_000)) memory"), "memory is counted the way Activity Monitor counts it, got \(contributors[0].evidence)")
    }

    /// ps reports CPU per core, so a busy process can read 240%. The CPU tab's top-CPU row shows
    /// `percentString(machineCPUPercent(cpu))`; Power must show that same figure for that row.
    private static func testContributorsShowTheSameCPUPercentAsTheCPUTab() {
        let row = ProcessSnapshot(name: "clang", count: 4, physical: 2_000_000, virtualSize: 0, cpu: 240)
        let evidence = PowerCollector.contributors(from: [row])[0].evidence
        let cpuTabFigure = percentString(machineCPUPercent(row.cpu))
        expect(evidence.hasPrefix("\(cpuTabFigure) CPU"), "Power shows the CPU tab's figure \(cpuTabFigure), got \(evidence)")
        if ProcessInfo.processInfo.activeProcessorCount > 1 {
            expect(!evidence.contains(percentString(row.cpu)), "Power no longer shows the per-core figure, got \(evidence)")
        }
    }

    private static func testCollectRunsPmsetTwiceAndReadsTheAnswers() {
        let recorder = PowerCallRecorder()
        let batteryOutput = """
        Now drawing from 'AC Power'
         -InternalBattery-0 (id=1234567)\t77%; charging; 0:20 remaining present: true
        """
        let assertionsOutput = """
                PreventUserIdleSystemSleep     1
        """
        let host = makeHost { path, arguments, _, _ in
            recorder.record((path: path, arguments: arguments))
            if arguments == ["-g", "batt"] {
                return CommandOutput(output: batteryOutput, error: "", status: 0, didTimeout: false)
            }
            if arguments == ["-g", "assertions"] {
                return CommandOutput(output: assertionsOutput, error: "", status: 0, didTimeout: false)
            }
            if arguments == ioregArguments {
                return CommandOutput(output: PowerFixtures.ioregCharging, error: "", status: 0, didTimeout: false)
            }
            return CommandOutput(output: "", error: "unexpected arguments", status: 1, didTimeout: false)
        }

        let snapshot = PowerCollector.collect(using: host)
        let seen = recorder.seen

        expect(seen.count == 3, "collect reads battery, battery driver and assertions, got \(seen.count) calls")
        expect(seen.filter { $0.path == "/usr/bin/pmset" }.count == 2, "two reads go through pmset, got \(seen.map(\.path))")
        expect(seen.contains { $0.path == "/usr/sbin/ioreg" && $0.arguments == ioregArguments }, "one read asks ioreg for the battery driver")
        expect(seen.contains { $0.arguments == ["-g", "batt"] }, "one read asks pmset for battery status")
        expect(seen.contains { $0.arguments == ["-g", "assertions"] }, "the other asks pmset for sleep assertions")
        expect(snapshot.batteryPercent == 77, "the snapshot carries the parsed battery percent, got \(String(describing: snapshot.batteryPercent))")
        expect(snapshot.chargeState == .charging, "the snapshot carries the driver's charge state, got \(String(describing: snapshot.chargeState))")
        expect(snapshot.sleepAssertions.contains { $0.contains("PreventUserIdleSystemSleep") }, "the snapshot carries the parsed assertions, got \(snapshot.sleepAssertions)")
        expect(snapshot.status == "Power sample OK", "both reads succeeding reports OK, got \(snapshot.status)")
        expect(snapshot.health == .ok, "both reads succeeding is healthy")
    }

    private static func testCollectSaysWhatIsUnavailableWhenPmsetFails() {
        let host = makeHost { _, _, _, _ in
            CommandOutput(output: "", error: "boom", status: 1, didTimeout: false)
        }

        let snapshot = PowerCollector.collect(using: host)

        expect(snapshot.status == "battery unavailable, charge state unavailable, assertions unavailable", "every failure is named, got \(snapshot.status)")
        expect(snapshot.health == .degraded, "a failed pmset read is degraded")
        expect(snapshot.chargeState == nil, "a failed ioreg read asserts no charge state")
    }

    /// The bug this replaced: pmset says "not charging", which contains "charging".
    private static func testCollectReadsAMacHeldAtItsLimitAsHeld() {
        let snapshot = collectFrom(pmset: PowerFixtures.pmsetHeld, ioreg: PowerFixtures.ioregHeld)
        let label = snapshot.batteryPercent.map { batteryStatLabel(percent: $0, state: snapshot.chargeState) }
        expect(label == "Held at 80% limit", "the captured held Mac reads as held, got \(String(describing: label))")
        expect(snapshot.health == .ok, "every read succeeding is healthy, got \(snapshot.status)")
    }

    private static func testCollectReadsAMacOnBatteryAsDischarging() {
        let snapshot = collectFrom(pmset: PowerFixtures.pmsetDischarging, ioreg: PowerFixtures.ioregDischarging)
        let label = snapshot.batteryPercent.map { batteryStatLabel(percent: $0, state: snapshot.chargeState) }
        expect(label == "79% Discharging", "a Mac on battery reads as discharging, got \(String(describing: label))")
        expect(snapshot.powerSource == "Battery Power", "the source still comes from pmset, got \(snapshot.powerSource)")
    }

    private static func collectFrom(pmset: String, ioreg: String) -> PowerSnapshot {
        let host = makeHost { path, arguments, _, _ in
            switch (path, arguments) {
            case ("/usr/bin/pmset", ["-g", "batt"]):
                return CommandOutput(output: pmset, error: "", status: 0, didTimeout: false)
            case ("/usr/sbin/ioreg", ioregArguments):
                return CommandOutput(output: ioreg, error: "", status: 0, didTimeout: false)
            case ("/usr/bin/pmset", ["-g", "assertions"]):
                return CommandOutput(output: "", error: "", status: 0, didTimeout: false)
            default:
                return CommandOutput(output: "", error: "unexpected command", status: 1, didTimeout: false)
            }
        }
        return PowerCollector.collect(using: host)
    }

    private static func testContributorsFollowTheProcessFeed() {
        let (feed, send) = Feed.forTesting(initial: ProcessSummary())
        let host = makeHost(processes: feed)
        let plugin = PowerPlugin(host: host)
        let rows = [
            ProcessSnapshot(name: "clang", count: 1, physical: 1_000, virtualSize: 0, cpu: 50),
            ProcessSnapshot(name: "idle", count: 1, physical: 500, virtualSize: 0, cpu: 0),
        ]

        send(ProcessSummary(rows: rows, memoryLimit: rows.count, cpuLimit: rows.count))

        let deadline = Date().addingTimeInterval(1)
        while plugin.contributors.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        expect(plugin.contributors.map(\.name) == rows.map(\.name),
               "contributors track the process feed in order, got \(plugin.contributors.map(\.name))")
    }

    private static func testPluginIdentityMatchesTheOldTab() {
        let plugin = PowerPlugin(host: makeHost())
        expect(PowerPlugin.identifier == "power" && plugin.title == "Power" && plugin.systemImage == "bolt.heart", "the bundle keeps the tab's id, title and icon")
        expect(plugin.refreshInterval == 60 && plugin.sharedFeeds == [.processes], "the bundle keeps the tab's interval and its need for the process feed")
    }
}

/// Captures every `(path, arguments)` pair a `@Sendable` runner closure saw, under a lock,
/// mirroring `Recorder` in SystemBarConfigTests.swift — but keeping every call, since a single
/// `collect()` reads pmset twice and both calls need checking.
private final class PowerCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(path: String, arguments: [String])] = []

    func record(_ call: (path: String, arguments: [String])) {
        lock.withLock { calls.append(call) }
    }

    var seen: [(path: String, arguments: [String])] {
        lock.withLock { calls }
    }
}
