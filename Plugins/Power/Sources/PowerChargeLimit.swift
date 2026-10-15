import Foundation

/// One ChargeCtrlPolicy from powerd's charging preferences, decoded through secure coding with
/// only the three keys read. It stands in for powerd's class name in one unarchiver at a time,
/// so nothing the file names is ever built.
@objc(SystemBarPowerChargePolicy)
final class ChargePolicyRecord: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let reason: String?
    let socLimit: Int?
    /// powerd can leave an ended policy in the list with this set.
    let isTerminated: Bool

    init?(coder: NSCoder) {
        reason = coder.decodeObject(of: NSString.self, forKey: "reason") as String?
        let value = coder.containsValue(forKey: "soclimit") ? coder.decodeInteger(forKey: "soclimit") : nil
        isTerminated = coder.decodeBool(forKey: "terminated")
        // A key of the wrong type decodes as 0 or false and sets the coder's error, which
        // `parseChargeLimit` then refuses as a whole.
        socLimit = coder.error == nil ? value : nil
        super.init()
    }

    /// Only ever read from powerd's file, never written.
    func encode(with coder: NSCoder) {}
}

extension PowerCollector {
    /// World-readable, so it is read directly: no root, no subprocess.
    static let chargeLimitFile = URL(fileURLWithPath: "/Library/Preferences/com.apple.powerd.charging.plist")
    static let manualChargeLimitReason = "manualChargeLimit"

    /// The user's charge limit in percent. Nil when the file is missing, does not parse, or
    /// holds no plausible manual limit: never guessed.
    static func chargeLimit(fileAt url: URL) -> Int? {
        (try? Data(contentsOf: url)).flatMap(parseChargeLimit)
    }

    /// The `soclimit` of the live `manualChargeLimit` policy in the plist's `policies` keyed
    /// archive. A terminated one is ignored.
    static func parseChargeLimit(_ data: Data) -> Int? {
        guard let top = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let archive = top["policies"] as? Data,
              let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: archive)
        else { return nil }
        unarchiver.setClass(ChargePolicyRecord.self, forClassName: "ChargeCtrlPolicy")
        let decoded = unarchiver.decodeObject(of: [NSArray.self, ChargePolicyRecord.self], forKey: NSKeyedArchiveRootObjectKey)
        unarchiver.finishDecoding()
        guard unarchiver.error == nil, let policies = decoded as? [ChargePolicyRecord] else { return nil }
        return policies
            .first { $0.reason == manualChargeLimitReason && !$0.isTerminated }?
            .socLimit
            .flatMap { (1...100).contains($0) ? $0 : nil }
    }
}

/// Where the limit sits along the battery bar, from 0 to 1. Nil at 100%, which limits nothing.
func chargeLimitMarkerFraction(_ limit: Int?) -> Double? {
    limit.flatMap { $0 < 100 ? Double($0) / 100 : nil }
}
