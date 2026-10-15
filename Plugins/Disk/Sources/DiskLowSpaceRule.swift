import Foundation
import SystemBarKit

/// The Disk tab's notification rule: the boot volume's free space, as Finder shows it, below the
/// limit in the tab's settings. It fires on crossing into the condition, not on every reading
/// while it stays true; the host adds its own cooldown and per-tab cap on top. An immutable
/// value: `checking` returns the rule to use next.
struct DiskLowSpaceRule {
    /// The key in this tab's `settings`: the limit in GB (10^9 bytes, as Finder counts them).
    static let limitKey = "lowSpaceGB"
    static let defaultLimitBytes: UInt64 = 10_000_000_000
    /// Beyond any disk, and small enough that the byte count cannot overflow.
    static let maximumGigabytes = 1_000_000.0
    /// The host keys its cooldown and cap on this, so it never holds a reading or a time.
    static let notificationID = "disk.low-space"

    /// Nil when the rule is off.
    let limitBytes: UInt64?
    /// Whether the last reading was below the limit; nil before the first, so a Mac that is
    /// already low when the tab starts is told once.
    private let wasLow: Bool?

    init(limitBytes: UInt64?) {
        self.init(limitBytes: limitBytes, wasLow: nil)
    }

    private init(limitBytes: UInt64?, wasLow: Bool?) {
        self.limitBytes = limitBytes
        self.wasLow = wasLow
    }

    /// `lowSpaceGB`: absent means 10; a positive number is the limit; 0 turns the rule off;
    /// anything else keeps the default and is reported, because a misspelt value must never
    /// silently do nothing.
    static func limit(from settings: PluginSettings) -> (bytes: UInt64?, problem: String?) {
        guard let value = settings[limitKey] else { return (defaultLimitBytes, nil) }
        if case .number(let gigabytes) = value, gigabytes.isFinite, gigabytes >= 0, gigabytes <= maximumGigabytes {
            return (gigabytes == 0 ? nil : UInt64(gigabytes * 1_000_000_000), nil)
        }
        return (defaultLimitBytes, "settings: \"\(limitKey)\" must be a number of GB from 0 to \(Int(maximumGigabytes)) (0 turns it off); the limit stays 10 GB")
    }

    /// The rule after a reading, and the notification that reading earns, if any. A missing
    /// reading changes nothing.
    func checking(_ volume: DiskVolume?) -> (rule: DiskLowSpaceRule, notification: PluginNotification?) {
        guard let limitBytes, let volume else { return (self, nil) }
        let isLow = volume.finderFree < limitBytes
        let next = DiskLowSpaceRule(limitBytes: limitBytes, wasLow: isLow)
        guard isLow, wasLow != true else { return (next, nil) }
        let body = "\(volume.name) has \(fileByteString(volume.finderFree)) free, below your \(fileByteString(limitBytes)) limit"
        return (next, PluginNotification(id: Self.notificationID, title: "Low disk space", body: body))
    }
}
