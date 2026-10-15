import Foundation

/// The battery pill's text. Only the Power panel shows it, so it lives here rather than in the
/// Kit, whose public surface every plugin is built against. An unknown state shows the percent
/// alone rather than a guess. Held names the charge limit, or the percent when none was read.
func batteryStatLabel(percent: Int, state: ChargeState?, limit: Int? = nil) -> String {
    switch state {
    case .charging: return "\(percent)% Charging"
    case .discharging: return "\(percent)% Discharging"
    case .full: return "\(percent)% Full"
    case .heldAtLimit: return "Held at \(limit ?? percent)% limit"
    case .onACNotCharging: return "\(percent)% On AC (not charging)"
    case nil: return "\(percent)%"
    }
}
