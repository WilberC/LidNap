import Foundation

/// The contract with failsafe.sh: while the app keeps the Mac awake it writes
/// its pid to `active` and touches `heartbeat` regularly. If either goes
/// missing or stale while `active` exists, the fail-safe restores sleep.
struct SessionMarker {
    let directory: URL

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LidNap")) {
        self.directory = directory
    }

    var markerURL: URL { directory.appendingPathComponent("active") }
    var heartbeatURL: URL { directory.appendingPathComponent("heartbeat") }

    var isActive: Bool { FileManager.default.fileExists(atPath: markerURL.path) }

    func activate() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Heartbeat first, so the fail-safe never sees a marker without one.
        beat()
        let pid = ProcessInfo.processInfo.processIdentifier
        try "\(pid)\n".write(to: markerURL, atomically: true, encoding: .utf8)
    }

    func beat() {
        let fm = FileManager.default
        if fm.fileExists(atPath: heartbeatURL.path) {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: heartbeatURL.path)
        } else {
            fm.createFile(atPath: heartbeatURL.path, contents: nil)
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: markerURL)
        try? FileManager.default.removeItem(at: heartbeatURL)
    }
}

/// Short human-readable duration for menu titles, e.g. "1 h 30 min".
func formatDuration(_ seconds: TimeInterval) -> String {
    let totalMinutes = Int((seconds / 60).rounded(.up))
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    switch (hours, minutes) {
    case (0, _): return "\(minutes) min"
    case (_, 0): return "\(hours) h"
    default: return "\(hours) h \(minutes) min"
    }
}
