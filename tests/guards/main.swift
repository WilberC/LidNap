// Plain test harness: the Command Line Tools do not ship a working XCTest or
// Swift Testing setup, so tests are compiled with swiftc and run as a binary.
// Run with: ./tests/run.sh
import Foundation

var failures = 0
var passed = 0

func check(_ condition: Bool, _ name: String, file: String = #file, line: Int = #line) {
    if condition {
        passed += 1
    } else {
        failures += 1
        print("FAIL \(name) (\(file):\(line))")
    }
}

let t0 = Date(timeIntervalSince1970: 1_000_000)
let ac = PowerSnapshot(onBattery: false, batteryPercent: 80)

func evaluate(
    _ settings: GuardSettings = GuardSettings(),
    activatedAt: Date = t0,
    now: Date = t0,
    previous: PowerSnapshot? = ac,
    current: PowerSnapshot = ac
) -> GuardTrip? {
    evaluateGuards(settings: settings, activatedAt: activatedAt, now: now,
                   previous: previous, current: current)
}

// Defaults: every guard on, 20 %, 4 h.
let defaults = GuardSettings()
check(defaults.batteryEnabled && defaults.batteryThreshold == 20, "default battery guard 20 %")
check(defaults.timeEnabled && defaults.maxDuration == 4 * 3600, "default time guard 4 h")
check(defaults.unplugEnabled, "default unplug guard on")

// Nothing trips on AC power inside the time limit.
check(evaluate() == nil, "no trip on AC within limit")

// S2 battery guard.
let lowBattery = PowerSnapshot(onBattery: true, batteryPercent: 20)
var noUnplug = GuardSettings()
noUnplug.unplugEnabled = false
check(evaluate(noUnplug, previous: lowBattery, current: lowBattery) == .lowBattery(20),
      "battery at threshold trips")
check(evaluate(noUnplug, previous: lowBattery,
               current: PowerSnapshot(onBattery: true, batteryPercent: 21)) == nil,
      "battery above threshold does not trip")
check(evaluate(noUnplug, current: PowerSnapshot(onBattery: false, batteryPercent: 5)) == nil,
      "low battery while charging does not trip")
check(evaluate(noUnplug, previous: lowBattery,
               current: PowerSnapshot(onBattery: true, batteryPercent: nil)) == nil,
      "unknown battery level does not trip")
var batteryOff = noUnplug
batteryOff.batteryEnabled = false
check(evaluate(batteryOff, previous: lowBattery, current: lowBattery) == nil,
      "disabled battery guard does not trip")
var battery50 = noUnplug
battery50.batteryThreshold = 50
check(evaluate(battery50, previous: lowBattery,
               current: PowerSnapshot(onBattery: true, batteryPercent: 45)) == .lowBattery(45),
      "custom battery threshold is honored")

// S3 time guard.
check(evaluate(now: t0.addingTimeInterval(4 * 3600)) == .timeLimit, "time limit reached trips")
check(evaluate(now: t0.addingTimeInterval(4 * 3600 - 1)) == nil, "just under time limit does not trip")
var timeOff = GuardSettings()
timeOff.timeEnabled = false
check(evaluate(timeOff, now: t0.addingTimeInterval(100 * 3600)) == nil,
      "disabled time guard does not trip")
var oneHour = GuardSettings()
oneHour.maxDuration = 3600
check(evaluate(oneHour, now: t0.addingTimeInterval(3600)) == .timeLimit, "custom duration is honored")

// S4 unplug guard.
let battery = PowerSnapshot(onBattery: true, batteryPercent: 80)
check(evaluate(previous: ac, current: battery) == .unplugged, "AC to battery trips")
check(evaluate(previous: battery, current: battery) == nil,
      "already on battery is not an unplug event")
check(evaluate(previous: nil, current: battery) == nil, "no previous snapshot is not an unplug event")
var unplugOff = GuardSettings()
unplugOff.unplugEnabled = false
check(evaluate(unplugOff, previous: ac, current: battery) == nil, "disabled unplug guard does not trip")

// Priority: unplug is reported before the other guards.
check(evaluate(now: t0.addingTimeInterval(5 * 3600), previous: ac, current: lowBattery) == .unplugged,
      "unplug has priority")

// S5 persistence: settings round-trip through UserDefaults, and garbage falls back to defaults.
let suite = "lidawake.tests.\(UUID().uuidString)"
let store = UserDefaults(suiteName: suite)!
var custom = GuardSettings()
custom.batteryEnabled = false
custom.batteryThreshold = 35
custom.timeEnabled = false
custom.maxDuration = 2 * 3600
custom.unplugEnabled = false
custom.save(to: store)
check(GuardSettings.load(from: store) == custom, "settings round-trip")
store.set(Data("garbage".utf8), forKey: GuardSettings.storageKey)
check(GuardSettings.load(from: store) == GuardSettings(), "corrupt settings fall back to defaults")
store.removePersistentDomain(forName: suite)

// Descriptions shown to the user.
check(GuardTrip.lowBattery(15).message == "Battery dropped to 15 %.", "low battery message")
check(GuardTrip.timeLimit.message == "The maximum duration was reached.", "time limit message")
check(GuardTrip.unplugged.message == "The charger was disconnected.", "unplug message")

print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
