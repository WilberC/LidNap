import Foundation

/// User-configurable safety guards. Each guard can be switched on or off and
/// tuned from the menu; values persist in UserDefaults.
struct GuardSettings: Codable, Equatable {
    static let storageKey = "guardSettings"

    var batteryEnabled = true
    /// Turn closed-lid mode off when on battery at or below this percentage.
    var batteryThreshold = 20
    var timeEnabled = true
    /// Turn closed-lid mode off after this many seconds since it was enabled.
    var maxDuration: TimeInterval = 4 * 3600
    var unplugEnabled = true

    static func load(from defaults: UserDefaults = .standard) -> GuardSettings {
        guard let data = defaults.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(GuardSettings.self, from: data)
        else { return GuardSettings() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: GuardSettings.storageKey)
        }
    }
}

/// A point-in-time view of the power source.
struct PowerSnapshot: Equatable {
    var onBattery: Bool
    /// Battery charge in percent, or nil when unknown (e.g. no battery).
    var batteryPercent: Int?
}

/// Why a guard turned closed-lid mode off.
enum GuardTrip: Equatable {
    case unplugged
    case lowBattery(Int)
    case timeLimit

    var message: String {
        switch self {
        case .unplugged: return "The charger was disconnected."
        case .lowBattery(let percent): return "Battery dropped to \(percent) %."
        case .timeLimit: return "The maximum duration was reached."
        }
    }
}

/// Pure decision function: returns the first guard that should turn
/// closed-lid mode off, or nil to keep it on.
func evaluateGuards(
    settings: GuardSettings,
    activatedAt: Date,
    now: Date,
    previous: PowerSnapshot?,
    current: PowerSnapshot
) -> GuardTrip? {
    if settings.unplugEnabled, let previous, !previous.onBattery, current.onBattery {
        return .unplugged
    }
    if settings.batteryEnabled, current.onBattery, let percent = current.batteryPercent,
       percent <= settings.batteryThreshold {
        return .lowBattery(percent)
    }
    if settings.timeEnabled, now.timeIntervalSince(activatedAt) >= settings.maxDuration {
        return .timeLimit
    }
    return nil
}
