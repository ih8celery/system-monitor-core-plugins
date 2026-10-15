import Foundation
import SystemBarKit

/// The Bandwidth list's running totals: nettop's first block, read from output captured on a real
/// Mac, carried through a sample to the rows the panel shows, and written the way Finder writes
/// sizes; every rate on the tab written the way Finder writes speeds; and the Down/Up cards'
/// totals since the Mac started up, from the host's 1-second feed.
@MainActor
enum NetworkTotalsTests {
    static func runAll() {
        testCapturedNettopOutputGivesEachAppItsTotals()
        testSampleKeepsTheTotalsOfTheRowsItShows()
        testTotalsReadLikeFinder()
        testRatesReadLikeFinder()
        testSinceStartupTotalsReadLikeFinderAndSayWhatTheyCount()
        testSinceStartupTotalsShowNothingBeforeTheFirstReading()
        testPluginFollowsTheFeedsSinceStartupTotals()
    }

    private static let nettopCommand = "/usr/bin/nettop -d -P -L 2 -s 1 -x -n -J bytes_in,bytes_out"
    private static let lsofCommand = "/usr/sbin/lsof -n -P -iTCP"

    /// Lines from `nettop -d -P -L 2 -s 1 -x -n -J bytes_in,bytes_out` on macOS 26: a header with an
    /// empty name column, a trailing comma on every line, names cut to 15 characters, the first
    /// block in bytes since each process started and the second in bytes over the last second.
    private static let capturedNettop = """
    ,bytes_in,bytes_out,
    airportd.453,0,0,
    mDNSResponder.500,16167180,4523731,
    codex.80248,2148717,9891234,
    Google Chrome H.33830,20138527,737364,
    codex.6108,2266416,2267188,
    ,bytes_in,bytes_out,
    airportd.453,0,0,
    mDNSResponder.500,0,0,
    codex.80248,0,0,
    Google Chrome H.33830,0,0,
    codex.6108,1360,0,
    """

    private static func testCapturedNettopOutputGivesEachAppItsTotals() {
        let rows = NetworkCollector.parseNettopCSV(capturedNettop).reduce(into: [String: NetworkProcessSnapshot]()) { $0[$1.name] = $1 }
        expect(rows["Google Chrome H"]?.totalDownloaded == 20_138_527 && rows["Google Chrome H"]?.totalUploaded == 737_364, "the first block is each app's total, got \(String(describing: rows["Google Chrome H"]))")
        expect(rows["codex"]?.totalDownloaded == 4_415_133 && rows["codex"]?.totalUploaded == 12_158_422, "two processes of one app add up, got \(String(describing: rows["codex"]))")
        expect(rows["codex"]?.downloadRate == 1_360 && rows["mDNSResponder"]?.downloadRate == 0, "the second block is the rate")
        expect(rows["airportd"]?.totalDownloaded == 0, "an app that moved nothing totals zero")
        expect(rows[""] == nil, "the header's empty name is not an app")
    }

    private static func testSampleKeepsTheTotalsOfTheRowsItShows() {
        let host = makeHost(runner: recordingRunner(LogRecorder(), answers: [nettopCommand: capturedNettop, lsofCommand: ""]))
        let reading = NetworkCollector(host: host).sample()
        expect(reading.processes.map(\.name) == ["codex"], "the list shows apps moving data now, got \(reading.processes.map(\.name))")
        expect(reading.processes.first?.totalUploaded == 12_158_422, "with their totals, got \(String(describing: reading.processes.first))")
    }

    private static func testTotalsReadLikeFinder() {
        let row = NetworkProcessSnapshot(id: "codex", name: "codex", downloadRate: 1_360, uploadRate: 0, totalDownloaded: 4_415_133, totalUploaded: 12_158_422)
        expect(row.totalsText == "\(fileByteString(4_415_133)) in, \(fileByteString(12_158_422)) out", "totals use the SDK's Finder-style sizes, got \(row.totalsText)")
        expect(NetworkProcessSnapshot.totalsHelp.contains("since each app started"), "the list says what the totals count, got \(NetworkProcessSnapshot.totalsHelp)")
    }

    /// 1000-based, as Finder and Activity Monitor's Network tab count: 2 500 000 B/s is 2.5 MB/s,
    /// not the 2.4 MB/s a 1024-based rate gives.
    private static func testRatesReadLikeFinder() {
        expect(networkRateText(2_500_000) == fileRateString(2_500_000) && networkRateText(2_500_000) == "2.5 MB/s", "rates use the SDK's Finder-style speeds, got \(networkRateText(2_500_000))")
        let row = NetworkProcessSnapshot(id: "codex", name: "codex", downloadRate: 1_500, uploadRate: 12_000, totalDownloaded: 0, totalUploaded: 0)
        expect(row.combinedRateText == fileRateString(13_500), "a row's combined rate, got \(row.combinedRateText)")
        expect(row.downloadRateText == "D \(fileRateString(1_500))" && row.uploadRateText == "U \(fileRateString(12_000))", "and its download and upload, got \(row.downloadRateText) \(row.uploadRateText)")
    }

    /// 1000-based like the rest of the tab: 1 500 000 000 bytes is 1.5 GB, not the 1.4 GB a
    /// 1024-based size gives; and worded so nobody reads it as SystemBar's own session.
    private static func testSinceStartupTotalsReadLikeFinderAndSayWhatTheyCount() {
        expect(sinceStartupText(1_500_000_000) == "1.5 GB since the Mac started up", "got \(String(describing: sinceStartupText(1_500_000_000)))")
        expect(sinceStartupText(4_415_133) == "\(fileByteString(4_415_133)) since the Mac started up", "the SDK's Finder-style sizes, got \(String(describing: sinceStartupText(4_415_133)))")
        expect(sinceStartupHelp.contains("since the Mac started up") && sinceStartupHelp.contains("unplug"), "the help says what is counted and why it can drop, got \(sinceStartupHelp)")
    }

    /// The feed holds 0 until the host's first reading; 0 B there would be a false figure.
    private static func testSinceStartupTotalsShowNothingBeforeTheFirstReading() {
        expect(sinceStartupText(0) == nil, "no reading yet shows nothing, got \(String(describing: sinceStartupText(0)))")
        expect(sinceStartupText(1) != nil, "any reading shows")
    }

    private static func testPluginFollowsTheFeedsSinceStartupTotals() {
        let (feed, send) = Feed.forTesting(initial: FastStatsSnapshot())
        let plugin = NetworkPlugin(host: makeHost(fastStats: feed))
        expect(sinceStartupText(plugin.fastStats.bytesReceivedSinceBoot) == nil, "a tab opened before the host's first reading shows no total")

        var reading = FastStatsSnapshot()
        reading.bytesReceivedSinceBoot = 113_000_000_000
        reading.bytesSentSinceBoot = 9_000_000_000
        send(reading)
        waitUntil { plugin.fastStats.bytesReceivedSinceBoot == 113_000_000_000 }
        expect(sinceStartupText(plugin.fastStats.bytesReceivedSinceBoot) == "113.0 GB since the Mac started up", "received follows the feed, got \(plugin.fastStats.bytesReceivedSinceBoot)")
        expect(sinceStartupText(plugin.fastStats.bytesSentSinceBoot) == "9.0 GB since the Mac started up", "and sent, got \(plugin.fastStats.bytesSentSinceBoot)")
    }
}
