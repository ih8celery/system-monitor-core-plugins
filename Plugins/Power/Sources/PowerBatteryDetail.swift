import Foundation

/// The battery's own readings from the same ioreg entry as the charge state. Each is nil when
/// the driver does not report it or reports something impossible, so the panel leaves it out
/// rather than showing a guess.
struct BatteryDetail: Equatable {
    /// Full-charge capacity over design capacity. Can pass 100% on a new battery, and will not
    /// match System Settings exactly, which rounds and weighs it its own way.
    var healthPercent: Int?
    var cycleCount: Int?
    /// The battery's temperature, not the chip's.
    var temperatureCelsius: Double?
    /// Nil while the driver is still estimating.
    var minutesRemaining: Int?
}

/// One pill's label and value.
struct PillText: Equatable {
    let label: String
    let value: String
}

extension PowerCollector {
    /// The longest `TimeRemaining` taken as an estimate. The driver writes 65535 while it has
    /// none, and has published idle averages like 32360 minutes; neither should read as hours.
    static let longestEstimateMinutes = 24 * 60

    static func parseBatteryDetail(_ output: String) -> BatteryDetail? {
        batteryEntry(output).flatMap(batteryDetail(from:))
    }

    /// Nil when the entry holds none of the readings, so no empty Battery section is drawn.
    static func batteryDetail(from battery: [String: Any]) -> BatteryDetail? {
        let rawMax = reading(battery["AppleRawMaxCapacity"], in: 1...Int.max)
        let design = reading(battery["DesignCapacity"], in: 1...Int.max)
        let detail = BatteryDetail(
            healthPercent: rawMax.flatMap { raw in design.map { Int((Double(raw) / Double($0) * 100).rounded()) } },
            cycleCount: reading(battery["CycleCount"], in: 0...Int.max),
            temperatureCelsius: reading(battery["Temperature"], in: 1...Int.max).map { Double($0) / 100 },
            minutesRemaining: reading(battery["TimeRemaining"], in: 1...longestEstimateMinutes)
        )
        return detail == BatteryDetail() ? nil : detail
    }

    /// An integer reading, or nil when it is missing or outside what the battery can report.
    static func reading(_ value: Any?, in plausible: ClosedRange<Int>) -> Int? {
        (value as? Int).flatMap { plausible.contains($0) ? $0 : nil }
    }
}

func batteryHealthLabel(_ percent: Int) -> String {
    "\(percent)%"
}

func batteryTemperatureLabel(_ celsius: Double) -> String {
    String(format: "%.1f °C", celsius)
}

/// Hours and minutes, as pmset writes them. No estimate reads "Calculating…", never 0:00.
func timeRemainingLabel(minutes: Int?) -> String {
    guard let minutes else { return "Calculating…" }
    return String(format: "%d:%02d", minutes / 60, minutes % 60)
}

/// Time to empty on battery, time to full while charging, and nothing otherwise: a battery
/// that is full or held has nothing counting down.
func timeRemainingPill(state: ChargeState?, minutes: Int?) -> PillText? {
    switch state {
    case .discharging: return PillText(label: "Time remaining", value: timeRemainingLabel(minutes: minutes))
    case .charging: return PillText(label: "Until full", value: timeRemainingLabel(minutes: minutes))
    default: return nil
    }
}
