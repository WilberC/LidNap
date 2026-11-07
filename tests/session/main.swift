// Tests for SessionMarker and formatDuration. The binary is built as
// "LidNap" so the contract test can run failsafe.sh against a real marker
// written by this process. Run with: ./tests/run.sh
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

let fm = FileManager.default
let tmp = fm.temporaryDirectory.appendingPathComponent("lidnap-session-\(UUID().uuidString)")
defer { try? fm.removeItem(at: tmp) }
let stateDir = tmp.appendingPathComponent("state")

// formatDuration
check(formatDuration(30 * 60) == "30 min", "minutes only")
check(formatDuration(4 * 3600) == "4 h", "whole hours")
check(formatDuration(90 * 60) == "1 h 30 min", "hours and minutes")
check(formatDuration(59) == "1 min", "under a minute rounds up to 1 min")
check(formatDuration(0) == "0 min", "zero")

// SessionMarker lifecycle
let marker = SessionMarker(directory: stateDir)
check(!marker.isActive, "inactive before activation")
check((try? marker.activate()) != nil, "activate succeeds and creates the directory")
check(marker.isActive, "active after activation")
let pidText = (try? String(contentsOf: marker.markerURL, encoding: .utf8)) ?? ""
check(pidText == "\(ProcessInfo.processInfo.processIdentifier)\n", "marker holds this process id")
check(fm.fileExists(atPath: marker.heartbeatURL.path), "activation writes a heartbeat")

let old = Date(timeIntervalSinceNow: -600)
try? fm.setAttributes([.modificationDate: old], ofItemAtPath: marker.heartbeatURL.path)
marker.beat()
let beaten = (try? fm.attributesOfItem(atPath: marker.heartbeatURL.path)[.modificationDate] as? Date) ?? old
check(beaten.timeIntervalSinceNow > -5, "beat refreshes the heartbeat")

// Contract with failsafe.sh: a marker written by a live "LidNap" process
// with a fresh heartbeat is left alone; after clear(), nothing happens either.
let fakePmset = tmp.appendingPathComponent("pmset")
let calls = tmp.appendingPathComponent("calls")
try? "#!/bin/bash\necho \"$*\" >> \"\(calls.path)\"\n".write(to: fakePmset, atomically: true, encoding: .utf8)
try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakePmset.path)

func runFailsafe() -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["failsafe.sh"]
    var env = ProcessInfo.processInfo.environment
    env["LIDNAP_STATE_DIR"] = stateDir.path
    env["LIDNAP_LOG"] = tmp.appendingPathComponent("log").path
    env["LIDNAP_PMSET"] = fakePmset.path
    process.environment = env
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

check(runFailsafe() == 0 && !fm.fileExists(atPath: calls.path) && marker.isActive,
      "failsafe accepts a live marker written by the app")

marker.clear()
check(!marker.isActive && !fm.fileExists(atPath: marker.heartbeatURL.path), "clear removes marker and heartbeat")
check(runFailsafe() == 0 && !fm.fileExists(atPath: calls.path), "failsafe ignores a cleared session")

// The default directory is the one failsafe.sh uses by default.
check(SessionMarker().directory.path.hasSuffix("Library/Application Support/LidNap"),
      "default state directory matches failsafe.sh")

print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
