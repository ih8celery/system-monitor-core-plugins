import Foundation
import SystemBarKit

/// The Bandwidth list's running totals: nettop's first block, read from output captured on a real
/// Mac, carried through a sample to the rows the panel shows, and written the way Finder writes
/// sizes.
@MainActor
enum NetworkTotalsTests {
    static func runAll() {
        testCapturedNettopOutputGivesEachAppItsTotals()
        testSampleKeepsTheTotalsOfTheRowsItShows()
        testTotalsReadLikeFinder()
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
}
