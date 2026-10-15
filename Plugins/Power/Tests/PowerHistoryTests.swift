import Foundation
import SystemBarKit

/// The Mac's power draw over the last day: one-minute averages, saved in the tab's data folder,
/// filled by a cheap ioreg-only read every 10 s while the tab is hidden. Run from `PowerTests.runAll()`.
@MainActor
enum PowerHistoryTests {
    /// Every file a test writes goes here, and the whole folder goes when the tests finish.
    private static let folder = temporaryDirectory()
    /// A whole minute, so offsets below land where the test says.
    private static let start = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 60))

    static func runAll() {
        defer { try? FileManager.default.removeItem(at: folder) }
        testReadingsInAMinuteAverage()
        testANilReadingIsLeftOut()
        testAMinuteWithNoReadingIsAGap()
        testOnlyTheLastDayIsKept()
        testAtMostOneDayOfPointsIsKept()
        testTheStoreRoundTrips()
        testAMissingOrCorruptFileIsEmptyWithALogLine()
        testLoadAndSaveDropOldPoints()
        testHistorySurvivesARelaunch()
        testAHiddenCollectRunsOnlyIoreg()
        testAShowingCollectRunsEverythingAndRecords()
        testHiddenSamplesKeepTheSettleWindow()
        testTheGraphBreaksAtGaps()
        testTheHourViewShowsOnlyTheLastHour()
        testTheScaleTopIsARoundNumber()
    }

    private static func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private static func near(_ value: Double?, _ expected: Double) -> Bool {
        value.map { abs($0 - expected) < 0.01 } ?? false
    }

    private static func recorded(_ readings: [(TimeInterval, Double?)]) -> PowerHistory {
        readings.reduce(PowerHistory()) { $0.recording($1.1, at: at($1.0)) }
    }

    private static func testReadingsInAMinuteAverage() {
        let history = recorded([(0, 30), (10, 40), (20, 50)])
        expect(history.points.count == 1, "three readings in one minute are one point, got \(history.points)")
        expect(near(history.points.first?.watts, 40) && history.points.first?.minute == start, "the point is their average at the minute's start")
        let before = PowerHistory()
        _ = before.recording(10, at: start)
        expect(before.points.isEmpty, "recording returns a new history and leaves the old one as it was")
    }

    private static func testANilReadingIsLeftOut() {
        let history = recorded([(0, 30), (10, nil), (20, 50)])
        expect(near(history.points.first?.watts, 40), "a nil reading (settling) is left out of the average, not counted as 0")
    }

    private static func testAMinuteWithNoReadingIsAGap() {
        let history = recorded([(0, 30), (70, nil), (80, nil), (130, 20)])
        expect(history.points.map(\.minute) == [start, at(120)], "a minute with only nil readings has no point, got \(history.points.map(\.minute))")
    }

    private static func testOnlyTheLastDayIsKept() {
        let history = recorded([(0, 30), (60, 31), (PowerHistory.window + 60, 40)])
        expect(history.points.map(\.minute) == [at(60), at(PowerHistory.window + 60)], "points older than 24 h go, got \(history.points.map(\.minute))")
    }

    private static func testAtMostOneDayOfPointsIsKept() {
        let full = PowerHistory(points: (0..<PowerHistory.pointLimit + 5).map { MinutePoint(minute: at(Double($0) * 60), watts: 10, samples: 1) }, now: at(Double(PowerHistory.pointLimit + 4) * 60))
        expect(full.points.count == PowerHistory.pointLimit, "at most 1440 one-minute points, got \(full.points.count)")
        expect(full.points.last?.minute == at(Double(PowerHistory.pointLimit + 4) * 60), "the newest are kept")
    }

    private static func store(_ name: String = UUID().uuidString) -> PowerHistoryStore {
        PowerHistoryStore(fileURL: folder.appendingPathComponent(name).appendingPathComponent(PowerHistoryStore.fileName))
    }

    private static func testTheStoreRoundTrips() {
        let history = recorded([(0, 30.25), (10, 40.25), (65, 12.5)])
        let file = store()
        let log = LogRecorder()
        expect((try? file.save(history.points, now: at(65))) != nil, "saving into a folder that does not exist yet creates it")
        let loaded = file.load(now: at(70), log: log.record)
        expect(loaded == history.points, "what was saved loads back the same, got \(loaded)")
        expect(log.count == 0, "a good file logs nothing, got \(log.messages)")
    }

    private static func testAMissingOrCorruptFileIsEmptyWithALogLine() {
        let missing = store()
        let log = LogRecorder()
        expect(missing.load(now: start, log: log.record).isEmpty && log.count == 1, "a missing file is an empty history with a log line, got \(log.messages)")
        let corrupt = store()
        try? FileManager.default.createDirectory(at: corrupt.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("not json".utf8).write(to: corrupt.fileURL)
        let corruptLog = LogRecorder()
        expect(corrupt.load(now: start, log: corruptLog.record).isEmpty, "a corrupt file is an empty history, not a crash")
        expect(corruptLog.messages.first?.contains("power history") == true, "and says so in the log, got \(corruptLog.messages)")
    }

    private static func testLoadAndSaveDropOldPoints() {
        let old = MinutePoint(minute: at(0), watts: 9, samples: 1)
        let recent = MinutePoint(minute: at(PowerHistory.window), watts: 11, samples: 1)
        let file = store()
        try? file.save([old, recent], now: at(PowerHistory.window + 30))
        let data = (try? Data(contentsOf: file.fileURL)) ?? Data()
        expect(!String(decoding: data, as: UTF8.self).contains("\"watts\" : 9"), "save leaves out points older than 24 h")
        let raw = store()
        try? FileManager.default.createDirectory(at: raw.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? PowerHistoryStore.encoder.encode(PowerHistoryFile(version: PowerHistoryFile.currentVersion, points: [old, recent])).write(to: raw.fileURL)
        expect(raw.load(now: at(PowerHistory.window + 30), log: { _ in }) == [recent], "load drops points older than 24 h")
    }

    /// A plugin whose ioreg answer, clock and data folder the test sets.
    private static func plugin(_ ioreg: String, folder dataDirectory: URL, clock: LockedDate, commands: LogRecorder = LogRecorder()) -> PowerPlugin {
        let answer = LockedText(ioreg)
        let host = makeHost(runner: { path, arguments, _, _ in
            commands.record(([path] + arguments).joined(separator: " "))
            return CommandOutput(output: path == PowerCollector.ioregPath ? answer.value : "", error: "", status: 0, didTimeout: false)
        }, dataDirectory: dataDirectory)
        return PowerPlugin(host: host, clock: { clock.value })
    }

    private static func testHistorySurvivesARelaunch() {
        let dataDirectory = folder.appendingPathComponent("relaunch")
        let clock = LockedDate(start)
        let first = plugin(PowerDrawFixtures.acIdle, folder: dataDirectory, clock: clock)
        first.collect()
        clock.advance(by: 60)
        first.collect()
        waitUntil { first.history.points.count == 2 }
        expect(FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent(PowerHistoryStore.fileName).path), "the history is saved in the tab's data folder")
        let relaunched = plugin(PowerDrawFixtures.acIdle, folder: dataDirectory, clock: clock)
        expect(relaunched.history.points.map(\.minute) == [start, at(60)], "a relaunch loads the saved minutes, got \(relaunched.history.points)")
        expect(near(relaunched.history.points.first?.watts, 46.496), "with their watts")
    }

    private static func testAHiddenCollectRunsOnlyIoreg() {
        let commands = LogRecorder()
        let hidden = plugin(PowerDrawFixtures.onBattery, folder: folder.appendingPathComponent("hidden"), clock: LockedDate(start), commands: commands)
        hidden.collect()
        waitUntil { !hidden.history.points.isEmpty }
        expect(commands.messages == ["/usr/sbin/ioreg -r -n AppleSmartBattery -a"], "hidden, only the battery driver is read, got \(commands.messages)")
        expect(near(hidden.history.points.first?.watts, 48.396), "and the Mac's draw is recorded")
    }

    private static func testAShowingCollectRunsEverythingAndRecords() {
        let commands = LogRecorder()
        let showing = plugin(PowerDrawFixtures.onBattery, folder: folder.appendingPathComponent("showing"), clock: LockedDate(start), commands: commands)
        showing.visibilityChanged(isVisible: true)
        showing.collect()
        waitUntil { !showing.history.points.isEmpty }
        expect(commands.messages.filter { $0.hasPrefix("/usr/bin/pmset") }.count == 2, "showing, both pmset reads still run, got \(commands.messages)")
        expect(near(showing.snapshot.powerDraw?.macWatts, 48.396), "the panel's snapshot is updated")
        expect(near(showing.history.points.first?.watts, 48.396), "and the reading joins the history")
    }

    /// Unplugged while hidden, then opened 40 s later: the open still waits out the lag.
    private static func testHiddenSamplesKeepTheSettleWindow() {
        let clock = LockedDate(start)
        let answer = LockedText(PowerDrawFixtures.onBattery)
        let host = makeHost(runner: { path, _, _, _ in
            CommandOutput(output: path == PowerCollector.ioregPath ? answer.value : "", error: "", status: 0, didTimeout: false)
        }, dataDirectory: folder.appendingPathComponent("settle"))
        let tab = PowerPlugin(host: host, clock: { clock.value })
        _ = tab.hiddenSample()
        clock.advance(by: 10)
        answer.value = PowerDrawFixtures.acCharging
        expect(tab.hiddenSample() == nil, "a hidden sample just after plugging in records nothing")
        clock.advance(by: 30)
        expect(tab.sample().powerDraw?.macWatts == nil, "opened 40 s after the change, the Mac figure still waits")
        clock.advance(by: 70)
        expect(near(tab.hiddenSample(), 27.516), "100 s after the change, hidden samples use the telemetry")
    }

    private static func testTheGraphBreaksAtGaps() {
        let history = recorded([(0, 10), (60, 20), (120, 30), (300, 40), (360, 50)])
        let runs = history.runs(in: .day)
        expect(runs.map { $0.map(\.watts) } == [[10, 20, 30], [40, 50]], "a missing minute (the Mac slept, the app was closed) breaks the line, got \(runs)")
    }

    private static func testTheHourViewShowsOnlyTheLastHour() {
        let history = recorded([(0, 10), (60, 20), (3 * 60 * 60, 30), (3 * 60 * 60 + 60, 40)])
        expect(history.runs(in: .hour).flatMap { $0 }.map(\.watts) == [30, 40], "the hour view ends at the newest minute and starts an hour before")
        expect(history.runs(in: .day).flatMap { $0 }.count == 4, "the day view shows all of it")
        expect(history.windowEnd == at(3 * 60 * 60 + 120), "the window ends where the newest minute ends")
    }

    private static func testTheScaleTopIsARoundNumber() {
        expect(historyScaleTop(46.5) == 50, "46.5 W tops out at 50 W, got \(historyScaleTop(46.5))")
        expect(historyScaleTop(0) == 10, "an idle Mac still gets a 10 W scale")
        expect(historyScaleTop(101) == 110, "101 W tops out at 110 W")
    }
}
