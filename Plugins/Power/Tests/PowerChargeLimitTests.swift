import Foundation
import SystemBarKit

/// The charge limit from powerd's charging preferences, and the marker and label that use it.
/// Run from `PowerTests.runAll()`.
@MainActor
enum PowerChargeLimitTests {
    /// Every file a test writes goes here, and the whole folder goes when the tests finish.
    private static let folder = temporaryDirectory()

    static func runAll() {
        defer { try? FileManager.default.removeItem(at: folder) }
        testTheCapturedFileReadsEighty()
        testAMissingFileHasNoLimit()
        testAGarbledFileHasNoLimit()
        testAPlistWithoutPoliciesHasNoLimit()
        testOnlyTheManualChargeLimitPolicyCounts()
        testAnImpossibleOrMistypedLimitIsNoLimit()
        testAnArchiveOfAnotherClassIsRefused()
        testTheMarkerShowsOnlyBelowOneHundred()
        testHeldUsesTheLimitWhenKnown()
        testCollectCarriesTheLimit()
    }

    private static func written(_ data: Data) -> URL {
        let url = folder.appendingPathComponent("charging-\(UUID().uuidString).plist")
        try? data.write(to: url)
        return url
    }

    /// A charging plist whose `policies` archive holds the given policies, each archived under
    /// powerd's class name.
    private static func chargingPlist(_ policies: [TestPolicy]) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.setClassName("ChargeCtrlPolicy", for: TestPolicy.self)
        archiver.encode(policies as NSArray, forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        return plist(["policies": archiver.encodedData])
    }

    private static func plist(_ top: [String: Any]) -> Data {
        (try? PropertyListSerialization.data(fromPropertyList: top, format: .binary, options: 0)) ?? Data()
    }

    private static func testTheCapturedFileReadsEighty() {
        let limit = PowerCollector.chargeLimit(fileAt: written(PowerChargeLimitFixtures.captured))
        expect(limit == 80, "this Mac's captured charging plist holds an 80% limit, got \(String(describing: limit))")
    }

    private static func testAMissingFileHasNoLimit() {
        let missing = folder.appendingPathComponent("absent.plist")
        expect(PowerCollector.chargeLimit(fileAt: missing) == nil, "no file means no limit, not a guess")
    }

    private static func testAGarbledFileHasNoLimit() {
        expect(PowerCollector.chargeLimit(fileAt: written(Data("garbage".utf8))) == nil, "a file that is not a plist has no limit")
        let truncated = PowerChargeLimitFixtures.captured.prefix(300)
        expect(PowerCollector.chargeLimit(fileAt: written(Data(truncated))) == nil, "a truncated plist has no limit")
        expect(PowerCollector.parseChargeLimit(plist(["policies": Data("garbage".utf8)])) == nil, "a garbled archive has no limit")
    }

    private static func testAPlistWithoutPoliciesHasNoLimit() {
        expect(PowerCollector.parseChargeLimit(plist(["bootSessionUUID": "x"])) == nil, "no policies key means no limit")
        expect(PowerCollector.parseChargeLimit(plist(["policies": "not data"])) == nil, "policies that are not an archive mean no limit")
        expect(PowerCollector.parseChargeLimit(chargingPlist([])) == nil, "no policies at all means no limit")
    }

    private static func testOnlyTheManualChargeLimitPolicyCounts() {
        let other = TestPolicy(reason: "optimizedCharging", socLimit: 80)
        expect(PowerCollector.parseChargeLimit(chargingPlist([other])) == nil, "a policy for another reason is not the user's limit")
        let manual = TestPolicy(reason: "manualChargeLimit", socLimit: 90)
        expect(PowerCollector.parseChargeLimit(chargingPlist([other, manual])) == 90, "the manual limit is found among others")
    }

    private static func testAnImpossibleOrMistypedLimitIsNoLimit() {
        for value: Any in [0, 150, -5, "eighty"] {
            let policy = TestPolicy(reason: "manualChargeLimit", socLimit: value)
            expect(PowerCollector.parseChargeLimit(chargingPlist([policy])) == nil, "a soclimit of \(value) is no limit")
        }
        let none = TestPolicy(reason: "manualChargeLimit", socLimit: nil)
        expect(PowerCollector.parseChargeLimit(chargingPlist([none])) == nil, "a manual policy without soclimit is no limit")
    }

    /// The decoder only ever builds an array and the one policy class, never what the file names.
    private static func testAnArchiveOfAnotherClassIsRefused() {
        let dictionary = try? NSKeyedArchiver.archivedData(withRootObject: ["soclimit": 80] as NSDictionary, requiringSecureCoding: true)
        expect(PowerCollector.parseChargeLimit(plist(["policies": dictionary ?? Data()])) == nil, "an archive rooted in another class is refused")
    }

    private static func testTheMarkerShowsOnlyBelowOneHundred() {
        expect(chargeLimitMarkerFraction(80) == 0.8, "an 80% limit sits at 0.8 of the bar")
        expect(chargeLimitMarkerFraction(100) == nil, "a 100% limit is no limit to mark")
        expect(chargeLimitMarkerFraction(nil) == nil, "no limit, no marker")
    }

    private static func testHeldUsesTheLimitWhenKnown() {
        expect(batteryStatLabel(percent: 79, state: .heldAtLimit, limit: 80) == "Held at 80% limit", "held names the limit, not the percent")
        expect(batteryStatLabel(percent: 79, state: .heldAtLimit, limit: nil) == "Held at 79% limit", "with no limit read, held falls back to the percent")
        expect(batteryStatLabel(percent: 79, state: .charging, limit: 80) == "79% Charging", "other states ignore the limit")
    }

    private static func testCollectCarriesTheLimit() {
        let file = written(PowerChargeLimitFixtures.captured)
        let snapshot = PowerCollector.collect(using: makeHost(), chargeLimitFile: file)
        expect(snapshot.chargeLimit == 80, "the snapshot carries the limit, got \(String(describing: snapshot.chargeLimit))")
    }
}

/// Stands in for powerd's ChargeCtrlPolicy when building archives: it writes `reason` and
/// whatever `soclimit` a test gives, including a wrong type.
@objc(SystemBarPowerTestChargePolicy)
private final class TestPolicy: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let reason: String
    let socLimit: Any?

    init(reason: String, socLimit: Any?) {
        self.reason = reason
        self.socLimit = socLimit
    }

    init?(coder: NSCoder) { nil }

    func encode(with coder: NSCoder) {
        coder.encode(reason, forKey: "reason")
        if let number = socLimit as? Int {
            coder.encode(number, forKey: "soclimit")
        } else if let text = socLimit as? String {
            coder.encode(text, forKey: "soclimit")
        }
    }
}
