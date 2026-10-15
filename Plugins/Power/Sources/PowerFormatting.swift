import Foundation

/// The battery pill's text. Only the Power panel shows it, so it lives here rather than in the
/// Kit, whose public surface every plugin is built against. An unknown state shows the percent
/// alone rather than a guess.
func batteryStatLabel(percent: Int, state: ChargeState?) -> String {
    switch state {
    case .charging: return "\(percent)% Charging"
    case .discharging: return "\(percent)% Discharging"
    case .full: return "\(percent)% Full"
    case .heldAtLimit: return "Held at \(percent)% limit"
    case .onACNotCharging: return "\(percent)% On AC (not charging)"
    case nil: return "\(percent)%"
    }
}
