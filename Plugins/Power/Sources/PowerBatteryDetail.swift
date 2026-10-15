import Foundation

/// The battery's own readings from the same ioreg entry as the charge state. Each is nil when
/// the driver does not report it, so the panel leaves it out rather than showing a guess.
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
    /// The driver's `TimeRemaining` while it has no estimate yet.
    static let noEstimate = 65535

    static func parseBatteryDetail(_ output: String) -> BatteryDetail? {
        batteryEntry(output).map(batteryDetail(from:))
    }

    static func batteryDetail(from battery: [String: Any]) -> BatteryDetail {
        let rawMax = battery["AppleRawMaxCapacity"] as? Int
        let design = battery["DesignCapacity"] as? Int
        let minutes = battery["TimeRemaining"] as? Int
        return BatteryDetail(
            healthPercent: rawMax.flatMap { raw in
                design.flatMap { $0 > 0 ? Int((Double(raw) / Double($0) * 100).rounded()) : nil }
            },
            cycleCount: battery["CycleCount"] as? Int,
            temperatureCelsius: (battery["Temperature"] as? Int).map { Double($0) / 100 },
            minutesRemaining: minutes.flatMap { $0 > 0 && $0 != noEstimate ? $0 : nil }
        )
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
