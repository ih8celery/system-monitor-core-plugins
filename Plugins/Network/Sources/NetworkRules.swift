import Foundation
import SystemBarKit

/// The Network tab's rule settings: keys in the tab's own `settings` in `plugins.json`. A value of
/// the wrong kind or out of range keeps the default and is reported, because a misspelt value
/// must never silently do nothing.
struct NetworkRuleSettings: Equatable {
    static let notifyUnreachableKey = "notifyUnreachable"
    static let unreachablePingsKey = "unreachablePings"
    static let notifySlowKey = "notifySlowInternet"
    static let slowMillisecondsKey = "slowInternetMilliseconds"
    static let slowMinutesKey = "slowInternetMinutes"

    static let pingsRange = 1...720
    static let millisecondsRange = 1.0...10_000
    static let minutesRange = 1.0...60

    var notifyUnreachable = true
    /// Failed pings in a row, one every 5 s, before the internet counts as unreachable.
    var unreachablePings = 3
    var notifySlow = true
    /// The average internet ping, in ms, above which the connection counts as slow.
    var slowMilliseconds = 200.0
    /// How long that average must hold.
    var slowMinutes = 5.0

    static func read(_ settings: PluginSettings) -> (settings: NetworkRuleSettings, problems: [String]) {
        var result = NetworkRuleSettings()
        var problems: [String] = []
        func take<T>(_ key: String, _ parse: (PluginSettings.Value) -> T?, _ rule: String, _ apply: (T) -> Void) {
            guard let value = settings[key] else { return }
            if let parsed = parse(value) { apply(parsed) } else { problems.append("settings: \"\(key)\" must be \(rule); keeping the default") }
        }
        take(notifyUnreachableKey, bool, "true or false") { result.notifyUnreachable = $0 }
        take(unreachablePingsKey, { wholeNumber($0, in: pingsRange) }, "a whole number of pings from 1 to 720") { result.unreachablePings = $0 }
        take(notifySlowKey, bool, "true or false") { result.notifySlow = $0 }
        take(slowMillisecondsKey, { number($0, in: millisecondsRange) }, "a number of ms from 1 to 10000") { result.slowMilliseconds = $0 }
        take(slowMinutesKey, { number($0, in: minutesRange) }, "a number of minutes from 1 to 60") { result.slowMinutes = $0 }
        return (result, problems)
    }

    private static func bool(_ value: PluginSettings.Value) -> Bool? {
        if case .bool(let flag) = value { return flag }
        return nil
    }

    private static func number(_ value: PluginSettings.Value, in range: ClosedRange<Double>) -> Double? {
        guard case .number(let number) = value, number.isFinite, range.contains(number) else { return nil }
        return number
    }

    private static func wholeNumber(_ value: PluginSettings.Value, in range: ClosedRange<Int>) -> Int? {
        guard let number = number(value, in: Double(range.lowerBound)...Double(range.upperBound)), number == number.rounded() else { return nil }
        return Int(number)
    }
}

/// "Internet unreachable": the internet ping failed so many rounds in a row. A round with no
/// IPv4 route sent nothing, so it breaks the run rather than extending it. Fires on reaching the
/// count, once per run of failures.
struct UnreachableRule {
    static let notificationID = "network.internet-unreachable"

    /// Nil when the rule is off.
    let pings: Int?
    private let failuresInARow: Int

    init(pings: Int?) {
        self.init(pings: pings, failuresInARow: 0)
    }

    private init(pings: Int?, failuresInARow: Int) {
        self.pings = pings
        self.failuresInARow = failuresInARow
    }

    func checking(_ sample: LatencySample, internetAddress: String) -> (rule: UnreachableRule, notification: PluginNotification?) {
        guard let pings else { return (self, nil) }
        let count = sample.internet.isFailure ? failuresInARow + 1 : 0
        let next = UnreachableRule(pings: pings, failuresInARow: count)
        guard count == pings else { return (next, nil) }
        let cause = sample.diagnosis.map { " \($0.text)." } ?? ""
        let failures = pings == 1 ? "A ping to \(internetAddress) failed." : "\(pings) pings in a row to \(internetAddress) failed."
        let body = failures + cause
        return (next, PluginNotification(id: Self.notificationID, title: "Internet unreachable", body: body))
    }
}

/// "Slow internet": the internet ping's average over the last few minutes above a limit. Failed
/// and unsent pings are left out of the average but still show the window was watched; the
/// window must span the full time, about half of it in rounds, so a wake from sleep or a
/// fresh start is not judged on a few pings. Fires on becoming slow, once per slow spell.
struct SlowInternetRule {
    static let notificationID = "network.slow-internet"

    /// Nil when the rule is off.
    let limitMilliseconds: Double?
    let window: TimeInterval
    private let rounds: [(at: Date, milliseconds: Double?)]
    private let wasSlow: Bool

    init(limitMilliseconds: Double?, minutes: Double) {
        self.init(limitMilliseconds: limitMilliseconds, window: minutes * 60, rounds: [], wasSlow: false)
    }

    private init(limitMilliseconds: Double?, window: TimeInterval, rounds: [(at: Date, milliseconds: Double?)], wasSlow: Bool) {
        self.limitMilliseconds = limitMilliseconds
        self.window = window
        self.rounds = rounds
        self.wasSlow = wasSlow
    }

    func checking(_ sample: LatencySample, internetAddress: String) -> (rule: SlowInternetRule, notification: PluginNotification?) {
        guard let limitMilliseconds else { return (self, nil) }
        let since = sample.at.addingTimeInterval(-window)
        let kept = (rounds + [(sample.at, sample.internet.milliseconds)]).filter { $0.at >= since }
        let average = averageIfWatched(kept, since: since)
        let isSlow = average.map { $0 > limitMilliseconds } ?? false
        let next = SlowInternetRule(limitMilliseconds: limitMilliseconds, window: window, rounds: kept, wasSlow: isSlow)
        guard isSlow, !wasSlow, let average else { return (next, nil) }
        let body = String(format: "Pings to %@ averaged %.0f ms over the last %@, above your %.0f ms limit.", internetAddress, average, minutesText, limitMilliseconds)
        return (next, PluginNotification(id: Self.notificationID, title: "Slow internet", body: body))
    }

    /// The average reply, when the rounds span the whole window, a ping interval of slack, and
    /// number at least half of what that window holds.
    private func averageIfWatched(_ kept: [(at: Date, milliseconds: Double?)], since: Date) -> Double? {
        guard let first = kept.first, first.at <= since.addingTimeInterval(NetworkSampling.pingInterval) else { return nil }
        guard Double(kept.count) >= window / NetworkSampling.pingInterval / 2 else { return nil }
        let replies = kept.compactMap(\.milliseconds)
        guard !replies.isEmpty else { return nil }
        return replies.reduce(0, +) / Double(replies.count)
    }

    private var minutesText: String {
        let minutes = window / 60
        let number = minutes == minutes.rounded() ? String(Int(minutes)) : String(format: "%.1f", minutes)
        return minutes == 1 ? "minute" : "\(number) minutes"
    }
}

/// Both rules, checked after every round of pings, shown or hidden. An immutable value:
/// `checking` returns the rules to use next and what that round earned.
struct NetworkRules {
    let unreachable: UnreachableRule
    let slow: SlowInternetRule

    init(settings: NetworkRuleSettings) {
        unreachable = UnreachableRule(pings: settings.notifyUnreachable ? settings.unreachablePings : nil)
        slow = SlowInternetRule(limitMilliseconds: settings.notifySlow ? settings.slowMilliseconds : nil, minutes: settings.slowMinutes)
    }

    private init(unreachable: UnreachableRule, slow: SlowInternetRule) {
        self.unreachable = unreachable
        self.slow = slow
    }

    func checking(_ sample: LatencySample, internetAddress: String) -> (rules: NetworkRules, notifications: [PluginNotification]) {
        let outage = unreachable.checking(sample, internetAddress: internetAddress)
        let slowness = slow.checking(sample, internetAddress: internetAddress)
        return (NetworkRules(unreachable: outage.rule, slow: slowness.rule), [outage.notification, slowness.notification].compactMap { $0 })
    }
}
