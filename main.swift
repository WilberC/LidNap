import Cocoa
import IOKit
import IOKit.ps
import ServiceManagement

@_silgen_name("DisplayServicesGetBrightness")
func DisplayServicesGetBrightness(_ display: UInt32, _ brightness: UnsafeMutablePointer<Float>) -> Int32

@_silgen_name("DisplayServicesSetBrightness")
func DisplayServicesSetBrightness(_ display: UInt32, _ brightness: Float) -> Int32

let setupCommand = "sudo sh -c 'f=$(mktemp); echo \"\(NSUserName()) ALL=(ALL) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0\" > \"$f\"; visudo -cf \"$f\" && install -m 440 \"$f\" /etc/sudoers.d/lid-awake && echo INSTALLED'"

/// Reads the current power source and battery level through IOKit.
func currentPowerSnapshot() -> PowerSnapshot {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
        return PowerSnapshot(onBattery: false, batteryPercent: nil)
    }
    let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
    let onBattery = providing == kIOPSBatteryPowerValue
    var percent: Int?
    if let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            percent = Int((Double(current) / Double(max) * 100).rounded())
        }
    }
    return PowerSnapshot(onBattery: onBattery, batteryPercent: percent)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let toggleItem = NSMenuItem()
    private let statusLineItem = NSMenuItem()
    private let loginItem = NSMenuItem()

    // Safety guards
    private var settings = GuardSettings.load()
    private let session = SessionMarker()
    private var activatedAt: Date?
    private var lastPower: PowerSnapshot?
    private var lastTrip: GuardTrip?
    private var heartbeatTimer: Timer?
    private var guardTimer: Timer?
    private var powerSource: CFRunLoopSource?

    private let batteryToggleItem = NSMenuItem()
    private let batteryThresholdItem = NSMenuItem()
    private let timeToggleItem = NSMenuItem()
    private let timeLimitItem = NSMenuItem()
    private let unplugToggleItem = NSMenuItem()

    static let batteryChoices = [10, 15, 20, 25, 30, 40, 50]
    static let durationChoices: [TimeInterval] = [30 * 60, 3600, 2 * 3600, 4 * 3600, 8 * 3600, 12 * 3600]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()
        menu.delegate = self

        toggleItem.title = "Keep Awake When Lid Is Closed"
        toggleItem.action = #selector(toggleLidAwake)
        toggleItem.target = self
        menu.addItem(toggleItem)

        statusLineItem.isEnabled = false
        statusLineItem.isHidden = true
        menu.addItem(statusLineItem)

        menu.addItem(.separator())

        let guardsItem = NSMenuItem(title: "Safety Guards", action: nil, keyEquivalent: "")
        guardsItem.submenu = buildGuardsMenu()
        menu.addItem(guardsItem)

        loginItem.title = "Start at Login"
        loginItem.action = #selector(toggleStartAtLogin)
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Lid Awake", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu

        recoverFromPreviousSession()
        refreshUI()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(self, selector: #selector(handleScreensSleep),
                                    name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(handleScreensWake),
                                    name: NSWorkspace.screensDidWakeNotification, object: nil)

        lastClamshellClosed = isClamshellClosed()
        if let current = getBrightness() {
            lastKnownBrightness = current
        }
        logEvent("started (clamshell closed: \(lastClamshellClosed), brightness: \(lastKnownBrightness))")
        clamshellTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollClamshell()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Quitting always hands sleep control back to macOS.
        if session.isActive {
            disableLidAwake(reason: "app quit")
        }
    }

    // MARK: - Safety guards

    /// A marker left by a previous run means the app died while keeping the
    /// Mac awake. Restore sleep before anything else.
    private func recoverFromPreviousSession() {
        guard session.isActive else { return }
        if setDisableSleep(false) {
            session.clear()
            logEvent("launch: restored sleep left on by a previous session")
        } else {
            logEvent("launch: could not restore sleep left on by a previous session")
        }
    }

    private func startGuards() {
        activatedAt = Date()
        lastPower = currentPowerSnapshot()
        lastTrip = nil

        // Common run loop modes keep both timers firing while the menu is open;
        // otherwise the heartbeat would go stale and trip the fail-safe.
        let heartbeat = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            self?.session.beat()
        }
        let guards = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.checkGuards()
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        RunLoop.main.add(guards, forMode: .common)
        heartbeatTimer = heartbeat
        guardTimer = guards

        // React to charger and battery changes immediately.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().checkGuards()
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = source
        }
    }

    private func stopGuards() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        guardTimer?.invalidate()
        guardTimer = nil
        if let source = powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = nil
        }
        activatedAt = nil
        lastPower = nil
    }

    private func checkGuards() {
        guard let activatedAt, session.isActive else { return }
        let current = currentPowerSnapshot()
        let trip = evaluateGuards(settings: settings, activatedAt: activatedAt, now: Date(),
                                  previous: lastPower, current: current)
        lastPower = current
        guard let trip else { return }
        disableLidAwake(reason: "guard: \(trip.message)")
        lastTrip = trip
        refreshUI()
    }

    private func buildGuardsMenu() -> NSMenu {
        let menu = NSMenu()

        batteryToggleItem.title = "Turn Off on Low Battery"
        batteryToggleItem.action = #selector(toggleBatteryGuard)
        batteryToggleItem.target = self
        menu.addItem(batteryToggleItem)

        let batteryMenu = NSMenu()
        for percent in AppDelegate.batteryChoices {
            let item = NSMenuItem(title: "\(percent) %", action: #selector(selectBatteryThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.tag = percent
            batteryMenu.addItem(item)
        }
        batteryThresholdItem.submenu = batteryMenu
        menu.addItem(batteryThresholdItem)

        menu.addItem(.separator())

        timeToggleItem.title = "Turn Off After Time Limit"
        timeToggleItem.action = #selector(toggleTimeGuard)
        timeToggleItem.target = self
        menu.addItem(timeToggleItem)

        let timeMenu = NSMenu()
        for duration in AppDelegate.durationChoices {
            let item = NSMenuItem(title: formatDuration(duration), action: #selector(selectTimeLimit(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(duration)
            timeMenu.addItem(item)
        }
        timeLimitItem.submenu = timeMenu
        menu.addItem(timeLimitItem)

        menu.addItem(.separator())

        unplugToggleItem.title = "Turn Off When Charger Is Disconnected"
        unplugToggleItem.action = #selector(toggleUnplugGuard)
        unplugToggleItem.target = self
        menu.addItem(unplugToggleItem)

        return menu
    }

    private func updateSettings(_ change: (inout GuardSettings) -> Void) {
        change(&settings)
        settings.save()
        refreshUI()
        checkGuards()
    }

    @objc private func toggleBatteryGuard() { updateSettings { $0.batteryEnabled.toggle() } }
    @objc private func toggleTimeGuard() { updateSettings { $0.timeEnabled.toggle() } }
    @objc private func toggleUnplugGuard() { updateSettings { $0.unplugEnabled.toggle() } }

    @objc private func selectBatteryThreshold(_ sender: NSMenuItem) {
        updateSettings { $0.batteryThreshold = sender.tag }
    }

    @objc private func selectTimeLimit(_ sender: NSMenuItem) {
        updateSettings { $0.maxDuration = TimeInterval(sender.tag) }
    }

    // MARK: - Brightness save/restore around lid close

    private let savedBrightnessKey = "savedBrightness"
    private var lastKnownBrightness: Float = 0.5
    private var lastClamshellClosed = false
    private var clamshellTimer: Timer?

    private func logEvent(_ message: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/LidAwake.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(message)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private func isClamshellClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? Bool else { return false }
        return property
    }

    private func getBuiltinDisplayID() -> UInt32? {
        var displays = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(8, &displays, &count) == .success else { return nil }
        for i in 0..<Int(count) where CGDisplayIsBuiltin(displays[i]) != 0 {
            return displays[i]
        }
        return nil
    }

    private func getBrightness() -> Float? {
        guard let display = getBuiltinDisplayID() else { return nil }
        var value: Float = 0
        guard DisplayServicesGetBrightness(display, &value) == 0 else { return nil }
        return value
    }

    @discardableResult
    private func setBrightness(_ value: Float) -> Bool {
        guard let display = getBuiltinDisplayID() else { return false }
        return DisplayServicesSetBrightness(display, value) == 0
    }

    private func pollClamshell() {
        let closed = isClamshellClosed()
        if closed != lastClamshellClosed {
            lastClamshellClosed = closed
            if closed {
                saveBrightnessAndZero(reason: "lid closed")
            } else {
                restoreBrightness(reason: "lid opened")
            }
            return
        }
        if !closed {
            if UserDefaults.standard.object(forKey: savedBrightnessKey) != nil {
                restoreBrightness(reason: "retry after lid opened")
            } else if let current = getBrightness() {
                lastKnownBrightness = current
            }
        }
    }

    private func saveBrightnessAndZero(reason: String) {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: savedBrightnessKey) == nil {
            let toSave = getBrightness() ?? lastKnownBrightness
            defaults.set(toSave, forKey: savedBrightnessKey)
            logEvent("\(reason): saved brightness \(toSave)")
        }
        let ok = setBrightness(0)
        logEvent("\(reason): set brightness to 0 \(ok ? "ok" : "failed (display offline)")")
    }

    private func restoreBrightness(reason: String) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: savedBrightnessKey) != nil else { return }
        let saved = defaults.float(forKey: savedBrightnessKey)
        if setBrightness(saved) {
            defaults.removeObject(forKey: savedBrightnessKey)
            logEvent("\(reason): restored brightness \(saved)")
        } else {
            logEvent("\(reason): restore to \(saved) failed, will retry")
        }
    }

    @objc private func handleScreensSleep() {
        saveBrightnessAndZero(reason: "screens slept")
    }

    @objc private func handleScreensWake() {
        restoreBrightness(reason: "screens woke")
    }

    // MARK: - Sleep toggle

    private func runProcess(_ path: String, _ args: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do { try process.run() } catch { return (-1, "") }
        process.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func isLidAwakeOn() -> Bool {
        let (_, output) = runProcess("/usr/bin/pmset", ["-g"])
        for line in output.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.trimmingCharacters(in: .whitespaces).hasSuffix("1")
        }
        return false
    }

    private func setDisableSleep(_ disabled: Bool) -> Bool {
        let (status, _) = runProcess("/usr/bin/sudo",
                                     ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"])
        return status == 0
    }

    private func enableLidAwake() {
        // Refuse to start when a guard would trip right away.
        let power = currentPowerSnapshot()
        if let trip = evaluateGuards(settings: settings, activatedAt: Date(), now: Date(),
                                     previous: nil, current: power) {
            showInfoAlert(title: "Lid Awake Not Enabled",
                          message: "\(trip.message) Change the safety guards or connect the charger first.")
            return
        }
        do {
            try session.activate()
        } catch {
            logEvent("enable: could not write fail-safe marker: \(error.localizedDescription)")
            showInfoAlert(title: "Lid Awake Not Enabled",
                          message: "The fail-safe marker could not be written, so the Mac was left unchanged.")
            return
        }
        guard setDisableSleep(true) else {
            session.clear()
            showSetupAlert()
            return
        }
        startGuards()
        logEvent("enabled lid-awake")
    }

    private func disableLidAwake(reason: String) {
        stopGuards()
        if setDisableSleep(false) {
            session.clear()
            logEvent("disabled lid-awake (\(reason))")
        } else {
            // Keep the marker so the fail-safe agent keeps retrying.
            logEvent("disable failed (\(reason)); fail-safe will retry")
        }
    }

    @objc private func toggleLidAwake() {
        if isLidAwakeOn() {
            if session.isActive {
                disableLidAwake(reason: "user")
            } else if !setDisableSleep(false) {
                // Turned on outside the app; turn it off without a marker.
                showSetupAlert()
            }
        } else {
            enableLidAwake()
        }
        refreshUI()
    }

    // MARK: - UI

    private func statusImage(on: Bool) -> NSImage? {
        let candidates = on
            ? ["cup.and.saucer.fill", "moon.fill", "sun.max.fill"]
            : ["cup.and.saucer", "moon.zzz", "moon"]
        for name in candidates {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Lid Awake") {
                image.isTemplate = true
                return image
            }
        }
        return nil
    }

    private func refreshUI() {
        let on = isLidAwakeOn()
        statusItem.button?.image = statusImage(on: on)
        statusItem.button?.toolTip = on
            ? "Lid Awake: on. The Mac keeps running with the lid closed."
            : "Lid Awake: off. Closing the lid sleeps the Mac normally."
        toggleItem.state = on ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off

        if on, let activatedAt, settings.timeEnabled {
            let remaining = max(0, settings.maxDuration - Date().timeIntervalSince(activatedAt))
            statusLineItem.title = "Turns off in \(formatDuration(remaining))"
            statusLineItem.isHidden = false
        } else if on, !session.isActive {
            statusLineItem.title = "Enabled outside Lid Awake: no safety guards"
            statusLineItem.isHidden = false
        } else if !on, let lastTrip {
            statusLineItem.title = "Turned off: \(lastTrip.message)"
            statusLineItem.isHidden = false
        } else {
            statusLineItem.isHidden = true
        }

        batteryToggleItem.state = settings.batteryEnabled ? .on : .off
        batteryThresholdItem.title = "Battery Threshold: \(settings.batteryThreshold) %"
        batteryThresholdItem.isEnabled = settings.batteryEnabled
        for item in batteryThresholdItem.submenu?.items ?? [] {
            item.state = item.tag == settings.batteryThreshold ? .on : .off
        }

        timeToggleItem.state = settings.timeEnabled ? .on : .off
        timeLimitItem.title = "Time Limit: \(formatDuration(settings.maxDuration))"
        timeLimitItem.isEnabled = settings.timeEnabled
        for item in timeLimitItem.submenu?.items ?? [] {
            item.state = TimeInterval(item.tag) == settings.maxDuration ? .on : .off
        }

        unplugToggleItem.state = settings.unplugEnabled ? .on : .off
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshUI()
    }

    private func showInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showSetupAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "One-Time Setup Needed"
        alert.informativeText = "Lid Awake needs permission to change the sleep setting without asking for your password every time.\n\nClick \u{201C}Copy Command\u{201D}, paste it into Terminal, enter your password once, then use the toggle again."
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(setupCommand, forType: .string)
        }
    }

    @objc private func toggleStartAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSSound.beep()
        }
        refreshUI()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
