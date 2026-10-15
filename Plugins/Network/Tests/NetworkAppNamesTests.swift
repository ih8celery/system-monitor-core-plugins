import Darwin
import Foundation
import SystemBarKit

/// Readable names for the Bandwidth list: a process nettop names by a version number, or by a name
/// it cut to 15 characters, takes its name from its executable's path, read through a resolver the
/// tests fake; anything else, and any path that cannot be read, keeps nettop's name.
@MainActor
enum NetworkAppNamesTests {
    static func runAll() {
        testVersionLikeIsNarrow()
        testVersionNamedProcessTakesItsToolsFolderName()
        testCutNameTakesTheAppOrTheFullFileName()
        testOtherNamesAndUnreadablePathsAreKept()
        testParsingResolvesOnlyTheNamesThatNeedIt()
        testRealPathOfThisProcess()
    }

    private static let claudePath = "/Users/someone/.local/share/claude/versions/2.1.296"
    private static let chromeHelperPath = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/155.0.8059.41/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
    private static let webKitPath = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking"

    private static func testVersionLikeIsNarrow() {
        for name in ["2.1.296", "2.1", "10.0.0.1"] {
            expect(AppNames.looksLikeVersion(name), "\(name) looks like a version")
        }
        for name in ["2", "v2.1", "2.1.3a", ".1", "1.", "1..2", "codex", ""] {
            expect(!AppNames.looksLikeVersion(name), "\(name) does not look like a version")
        }
    }

    private static func testVersionNamedProcessTakesItsToolsFolderName() {
        expect(AppNames.readable("2.1.296", path: claudePath) == "claude", "past the version file and its versions folder, got \(AppNames.readable("2.1.296", path: claudePath))")
        expect(AppNames.readable("1.2.3", path: "/Applications/Foo.app/Contents/MacOS/1.2.3") == "Foo", "inside an app, the app's name")
        expect(AppNames.readable("1.2.3", path: "/opt/tool/1.2/1.2.3") == "tool", "every version-like folder is skipped")
        expect(AppNames.readable("1.2.3", path: "/1.2.3") == "1.2.3", "with nothing readable above it, nettop's name stays")
    }

    private static func testCutNameTakesTheAppOrTheFullFileName() {
        expect(AppNames.readable("Google Chrome H", path: chromeHelperPath) == "Google Chrome", "a helper cut short takes its outermost app's name, got \(AppNames.readable("Google Chrome H", path: chromeHelperPath))")
        expect(AppNames.readable("com.apple.WebK", path: webKitPath) == "com.apple.WebK", "fourteen characters is not a cut name")
        expect(AppNames.readable("com.apple.WebKi", path: webKitPath) == "com.apple.WebKit.Networking", "outside any app, the full file name, got \(AppNames.readable("com.apple.WebKi", path: webKitPath))")
    }

    private static func testOtherNamesAndUnreadablePathsAreKept() {
        expect(AppNames.readable("codex", path: "/opt/homebrew/bin/codex-cli") == "codex", "a short name that happens to start the file name is not cut")
        expect(AppNames.readable("Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari") == "Safari", "an ordinary name stays")
        expect(AppNames.readable("Google Chrome H", path: "/Applications/Other.app/Contents/MacOS/Other") == "Google Chrome H", "a path that is not the cut name's file keeps nettop's name")
        expect(AppNames.readable("2.1.296", path: nil) == "2.1.296", "a path that cannot be read (exited, or another user's) keeps nettop's name")
    }

    private static func testParsingResolvesOnlyTheNamesThatNeedIt() {
        let csv = """
        ,bytes_in,bytes_out,
        2.1.296.75439,1000,500,
        2.1.300.1928,3000,700,
        Google Chrome H.33830,20138527,737364,
        codex.6108,2266416,2267188,
        2.1.299.4242,10,20,
        ,bytes_in,bytes_out,
        2.1.296.75439,100,50,
        2.1.300.1928,300,70,
        Google Chrome H.33830,0,0,
        codex.6108,1360,0,
        2.1.299.4242,0,0,
        """
        let asked = LogRecorder()
        let paths: [Int32: String] = [
            75439: claudePath,
            1928: "/Users/someone/.local/share/claude/versions/2.1.300",
            33830: chromeHelperPath,
        ]
        let rows = NetworkCollector.parseNettopCSV(csv) { pid in
            asked.record(String(pid))
            return paths[pid]
        }.reduce(into: [String: NetworkProcessSnapshot]()) { $0[$1.name] = $1 }

        expect(Set(asked.messages) == ["75439", "1928", "33830", "4242"], "only version-like and cut names are looked up, got \(asked.messages)")
        expect(Set(rows.keys) == ["claude", "Google Chrome", "codex", "2.1.299"], "got \(rows.keys.sorted())")
        expect(rows["claude"]?.totalDownloaded == 4_000 && rows["claude"]?.downloadRate == 400, "two versions of one tool add up under its name, got \(String(describing: rows["claude"]))")
        expect(rows["2.1.299"]?.totalUploaded == 20, "an exited process keeps nettop's name and its bytes")
    }

    private static func testRealPathOfThisProcess() {
        let path = ProcessPath.executable(pid: getpid())
        expect(path?.hasSuffix("/CorePluginTests") == true, "proc_pidpath reads this process's own executable, got \(String(describing: path))")
        expect(ProcessPath.executable(pid: -1) == nil, "a pid that cannot exist has no path")
    }
}
