import Foundation
import SystemBarKit

/// The Disk tab's one notification rule: free space, as Finder shows it, below a limit in the
/// tab's settings. Fires on crossing into the condition, through the host's `notify`.
@MainActor
enum DiskLowSpaceTests {
    static func runAll() {
        testTheLimitDefaultsToTenGigabytes()
        testTheLimitReadsDecimalGigabytes()
        testZeroTurnsTheRuleOff()
        testAWrongLimitKeepsTheDefaultAndSaysSo()
        testTheRuleFiresOnCrossingNotWhileItStaysTrue()
        testTheRuleRearmsAfterRecovering()
        testAFreeSpaceHoveringAtTheLimitFiresOnce()
        testTheBandIsTenPercentOfALargeLimit()
        testAFirstReadingBelowTheLimitFires()
        testNoVolumeReadingChangesNothing()
        testAnOffRuleNeverFires()
        testTheNotificationNamesTheVolumeAndTheFreeSpace()
        testThePluginPostsOnceThroughTheHost()
        testThePluginReportsABadLimitInTheFooter()
    }

    private static let gigabyte: UInt64 = 1_000_000_000

    private static func volume(freeGB: UInt64, purgeableGB: UInt64 = 0, name: String = "Macintosh HD") -> DiskVolume {
        DiskVolume(name: name, path: "/", total: 500 * gigabyte, free: freeGB * gigabyte, purgeable: purgeableGB * gigabyte, isRoot: true)
    }

    private static func settings(_ value: PluginSettings.Value) -> PluginSettings {
        PluginSettings(values: [DiskLowSpaceRule.limitKey: value])
    }

    private static func testTheLimitDefaultsToTenGigabytes() {
        let limit = DiskLowSpaceRule.limit(from: .empty)
        expect(limit.bytes == 10 * gigabyte && limit.problem == nil, "no setting means 10 GB and no complaint, got \(limit)")
    }

    private static func testTheLimitReadsDecimalGigabytes() {
        let limit = DiskLowSpaceRule.limit(from: settings(.number(2.5)))
        expect(limit.bytes == 2_500_000_000 && limit.problem == nil, "GB are 10^9 bytes, as Finder counts them, got \(limit)")
    }

    private static func testZeroTurnsTheRuleOff() {
        let limit = DiskLowSpaceRule.limit(from: settings(.number(0)))
        expect(limit.bytes == nil && limit.problem == nil, "0 is the off switch, not a problem, got \(limit)")
    }

    private static func testAWrongLimitKeepsTheDefaultAndSaysSo() {
        for wrong in [PluginSettings.Value.string("10"), .bool(true), .number(-5), .number(2_000_000), .list([]), .null] {
            let limit = DiskLowSpaceRule.limit(from: settings(wrong))
            expect(limit.bytes == 10 * gigabyte, "a limit that cannot be used keeps the default, got \(limit) for \(wrong)")
            expect(limit.problem?.contains(DiskLowSpaceRule.limitKey) == true, "and names the key, got \(String(describing: limit.problem)) for \(wrong)")
        }
    }

    private static func testTheRuleFiresOnCrossingNotWhileItStaysTrue() {
        var rule = DiskLowSpaceRule(limitBytes: 10 * gigabyte)
        var posted: [PluginNotification] = []
        for free in [50, 20, 9, 8, 7] as [UInt64] {
            let step = rule.checking(volume(freeGB: free))
            rule = step.rule
            posted += step.notification.map { [$0] } ?? []
        }
        expect(posted.count == 1, "one notification for the crossing, none while it stays below, got \(posted.count)")
    }

    /// Re-arming needs free space above the limit plus a band, max(1 GB, 10% of the limit), so a
    /// disk hovering at the limit does not fire on every wobble across it.
    private static func testTheRuleRearmsAfterRecovering() {
        var rule = DiskLowSpaceRule(limitBytes: 10 * gigabyte)
        var count = 0
        for free in [5, 50, 5, 5, 50, 5] as [UInt64] {
            let step = rule.checking(volume(freeGB: free))
            rule = step.rule
            if step.notification != nil { count += 1 }
        }
        expect(count == 3, "each fresh crossing after a real recovery fires again (the host's cooldown limits how often it is shown), got \(count)")
        expect(rule.checking(volume(freeGB: 10)).notification == nil, "exactly at the limit is not below it")
    }

    private static func testAFreeSpaceHoveringAtTheLimitFiresOnce() {
        var rule = DiskLowSpaceRule(limitBytes: 10 * gigabyte)
        var count = 0
        // 10 GB limit: the band is max(1 GB, 1 GB) = 1 GB, so 10.5 and 10.9 are not a recovery.
        for tenths in [95, 105, 95, 109, 95, 105, 95] as [UInt64] {
            let step = rule.checking(DiskVolume(name: "Macintosh HD", path: "/", total: 500 * gigabyte, free: tenths * gigabyte / 10, isRoot: true))
            rule = step.rule
            if step.notification != nil { count += 1 }
        }
        expect(count == 1, "wobbling across the limit without recovering past the band fires once, got \(count)")
        let recovered = rule.checking(volume(freeGB: 11)).rule
        expect(recovered.checking(volume(freeGB: 9)).notification != nil, "11 GB is past the band, so the next drop fires")
    }

    private static func testTheBandIsTenPercentOfALargeLimit() {
        // A 100 GB limit has a 10 GB band: 105 GB is not a recovery, 110 GB is.
        let low = DiskLowSpaceRule(limitBytes: 100 * gigabyte).checking(volume(freeGB: 90)).rule
        expect(low.checking(volume(freeGB: 105)).rule.checking(volume(freeGB: 90)).notification == nil, "105 GB is inside the band")
        expect(low.checking(volume(freeGB: 110)).rule.checking(volume(freeGB: 90)).notification != nil, "110 GB clears it")
    }

    private static func testAFirstReadingBelowTheLimitFires() {
        let step = DiskLowSpaceRule(limitBytes: 10 * gigabyte).checking(volume(freeGB: 3))
        expect(step.notification != nil, "a Mac already low when the tab starts is told")
    }

    private static func testNoVolumeReadingChangesNothing() {
        let low = DiskLowSpaceRule(limitBytes: 10 * gigabyte).checking(volume(freeGB: 3)).rule
        let step = low.checking(nil)
        expect(step.notification == nil, "no reading, no notification")
        expect(step.rule.checking(volume(freeGB: 3)).notification == nil, "and a missed reading does not make the next low one look like a new crossing")
    }

    private static func testAnOffRuleNeverFires() {
        let step = DiskLowSpaceRule(limitBytes: nil).checking(volume(freeGB: 0))
        expect(step.notification == nil, "a rule that is off posts nothing")
    }

    private static func testTheNotificationNamesTheVolumeAndTheFreeSpace() {
        let notification = DiskLowSpaceRule(limitBytes: 10 * gigabyte).checking(volume(freeGB: 3, purgeableGB: 2, name: "Macintosh HD")).notification
        expect(notification?.id == "disk.low-space", "the id is the rule's, with no reading in it, got \(String(describing: notification?.id))")
        expect(notification?.title == "Low disk space", "got \(String(describing: notification?.title))")
        expect(notification?.body == "Macintosh HD has 5.0 GB free, below your 10.0 GB limit", "free is Finder's, purgeable included, got \(String(describing: notification?.body))")
    }

    /// A plugin over the real volumes, with the limit set above any disk so the machine's own free
    /// space cannot change the result.
    private static func makePlugin(settings: PluginSettings, directory: URL, notify: @escaping @Sendable (PluginNotification) -> Void) -> DiskPlugin {
        let host = HostServices(
            homeDirectory: "/tmp/systembar-tests",
            processes: Feed(initial: ProcessSummary()),
            fastStats: Feed(initial: FastStatsSnapshot()),
            runner: { _, _, _, _ in CommandOutput(output: "", error: "", status: 0, didTimeout: false) },
            log: { _ in },
            settings: settings,
            dataDirectory: directory,
            notify: notify
        )
        return DiskPlugin(host: host, plans: [], now: { Date() }, listChildren: { _ in [] })
    }

    private static func testThePluginPostsOnceThroughTheHost() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recording = HostServices.recordingNotifications()
        let plugin = makePlugin(settings: settings(.number(900_000)), directory: directory, notify: recording.notify)
        plugin.collect()
        plugin.collect()
        let posted = recording.posted()
        expect(posted.count == 1 && posted.first?.id == "disk.low-space", "two collects below the limit post one notification, got \(posted)")

        let quiet = HostServices.recordingNotifications()
        makePlugin(settings: settings(.number(0.001)), directory: directory, notify: quiet.notify).collect()
        expect(quiet.posted().isEmpty, "a Mac with more than a megabyte free posts nothing")
    }

    private static func testThePluginReportsABadLimitInTheFooter() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let plugin = makePlugin(settings: settings(.string("lots")), directory: directory, notify: { _ in })
        expect(plugin.snapshot.settingsProblem?.contains(DiskLowSpaceRule.limitKey) == true, "a misspelt limit must never silently do nothing, got \(String(describing: plugin.snapshot.settingsProblem))")
    }
}
