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
    /// Keep the display awake (at brightness 0) while the lid is closed, so
    /// idle display sleep never starts the screen saver or locks the screen.
    var preventScreenLock = false

    init() {}

    // Settings saved before a field existed keep their values; missing fields
    // take their defaults instead of discarding everything.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = GuardSettings()
        batteryEnabled = try container.decodeIfPresent(Bool.self, forKey: .batteryEnabled) ?? defaults.batteryEnabled
        batteryThreshold = try container.decodeIfPresent(Int.self, forKey: .batteryThreshold) ?? defaults.batteryThreshold
        timeEnabled = try container.decodeIfPresent(Bool.self, forKey: .timeEnabled) ?? defaults.timeEnabled
        maxDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .maxDuration) ?? defaults.maxDuration
        unplugEnabled = try container.decodeIfPresent(Bool.self, forKey: .unplugEnabled) ?? defaults.unplugEnabled
        preventScreenLock = try container.decodeIfPresent(Bool.self, forKey: .preventScreenLock) ?? defaults.preventScreenLock
    }

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

/// Whether the display-sleep assertion that avoids the screen lock should be held.
func shouldPreventScreenLock(settings: GuardSettings, keepAwakeActive: Bool, lidClosed: Bool) -> Bool {
    settings.preventScreenLock && keepAwakeActive && lidClosed
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
