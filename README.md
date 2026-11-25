<div align="center">

# ☕ LidNap

**The lid naps. Your Mac doesn't.**<br>Keep your Mac awake with the lid closed, with a crash fail-safe and safety guards. One click from the menu bar.

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)](#requirements)
[![Language](https://img.shields.io/badge/language-Swift-F05138?logo=swift&logoColor=white)](main.swift)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen)](#contributing)

*Based on [LidAwake](https://github.com/deezeddd/LidAwake-Mac) by Vedant Maurya.*

*A native macOS menu bar utility with no Dock icon, no Electron, no root daemons,<br>and an entire codebase you can read in one sitting.*

<img src="assets/screenshot.png" width="560" alt="LidNap menu open in the macOS menu bar, with the filled coffee cup icon and the Keep Awake When Lid Is Closed item checked">

</div>

---

## Why LidNap?

macOS only keeps running with the lid closed when an external display is attached (clamshell mode). If you want to close the lid while a build finishes, a server runs, or music plays, your options are third-party apps or remembering `pmset` incantations. LidNap wraps the official Apple power-management flag in a one-click menu bar toggle, and adds one thing nothing else does: it remembers your display brightness across every lid close and reopen.

## Features

- ☕ **One-click toggle**: a coffee cup in the menu bar. Outline cup means normal sleep, filled cup means the Mac keeps running with the lid closed.
- 🔆 **Brightness memory**: on lid close, your current brightness is saved and the panel is set to zero. On reopen, it is restored to the exact level you had. Works around regular display sleep too.
- 🛟 **Crash fail-safe**: if the app quits, crashes or hangs while keeping the Mac awake, a small LaunchAgent restores normal sleep within seconds, including after a reboot.
- 🔋 **Safety guards**: turn closed-lid mode off automatically on low battery, after a time limit, or when the charger is disconnected. Each guard can be switched on or off and tuned from the menu.
- 🔁 **Always truthful**: the icon reflects the real system state every time the menu opens, even if you changed the setting from the terminal.
- 🚀 **Start at Login**: one menu item, implemented with Apple's `SMAppService`.
- 🪶 **Native and tiny**: AppKit, SF Symbols, standard dialogs. Adapts to light and dark mode. A few MB of RAM.
- 📜 **Audit trail**: every lid and brightness event is logged to `~/Library/Logs/LidNap.log`.

## Installation

### Requirements

- macOS 13 Ventura or newer (developed and tested on macOS 26)
- Xcode or the Xcode Command Line Tools (`xcode-select --install`)

### Quick install (one line)

```shell
curl -fsSL https://raw.githubusercontent.com/WilberC/LidNap/main/install.sh | bash
```

This downloads the source, builds it locally in a few seconds, and installs `~/Applications/LidNap.app`. Because the app is compiled on your own machine, there is no unsigned binary for Gatekeeper to complain about, and you can read every line of what you just ran, [including the installer](install.sh).

### Or build from a clone

```shell
git clone https://github.com/WilberC/LidNap.git
cd LidNap
./tests/run.sh          # optional: run the test suites
./build.sh              # compiles, installs ~/Applications/LidNap.app and loads the fail-safe agent
./setup-permissions.sh  # one-time rule so the toggle needs no password
open ~/Applications/LidNap.app
```

> [!NOTE]
> `setup-permissions.sh` installs a sudoers rule scoped to exactly two commands, `pmset -a disablesleep 1` and `pmset -a disablesleep 0`, for your user only. It is validated with `visudo` before being installed. If you skip this step, the app shows a dialog with the command whenever you try to toggle.

## Usage

| Menu item | What it does |
| --- | --- |
| **Keep Awake When Lid Is Closed** | Toggles closed-lid mode. Checkmark and filled cup when active. |
| *Status line* | Shows the time left, why a guard turned closed-lid mode off, or a warning when it was enabled outside the app. |
| **Safety Guards ▸** | Switch each guard on or off and pick its value (see below). |
| **Start at Login** | Registers or unregisters the app as a login item. |
| **Quit LidNap** | Quits the app and restores normal sleep if the app had enabled closed-lid mode. |

### Safety guards

| Guard | Default | Values |
| --- | --- | --- |
| **Turn Off on Low Battery** | On, 20 % | 10, 15, 20, 25, 30, 40 or 50 %. Applies only while running on battery. |
| **Turn Off After Time Limit** | On, 4 h | 30 min, 1, 2, 4, 8 or 12 h since you enabled closed-lid mode. |
| **Turn Off When Charger Is Disconnected** | On | Trips the moment the Mac switches from AC to battery. |

Settings persist across launches. If a guard would trip immediately (for example, the battery is already below the threshold), closed-lid mode is not enabled and the app tells you why. When a guard trips, normal sleep is restored, so a closed Mac goes to sleep right away.

> [!WARNING]
> While the toggle is ON, the Mac will not sleep for **any** reason except the safety guards above, including inside a bag. Keep the guards on, and toggle it off before you pack up. A lid-closed laptop also dissipates heat worse, so AC power is best.

## How it works

| Piece | Mechanism |
| --- | --- |
| Sleep toggle | Apple's supported `pmset disablesleep` flag, flipped via `sudo -n`. No kernel extensions, no SIP changes, no hacks. |
| Lid detection | Closing the lid does not fire a display-sleep notification; macOS disconnects the built-in display entirely. LidNap polls the `AppleClamshellState` property of `IOPMrootDomain` every 2 seconds to catch lid transitions reliably. |
| Fail-safe | While closed-lid mode is on, the app writes its pid to `~/Library/Application Support/LidNap/active` and touches a `heartbeat` file every 15 s. The LaunchAgent `com.wilberc.lidnap.failsafe` runs `failsafe.sh` at login and every 10 s: if the marker exists but the `LidNap` process is gone or the heartbeat is older than 60 s, it runs `pmset -a disablesleep 0` and removes the marker. Without a marker it does nothing, so a value you set manually with `pmset` is never touched. The app also restores sleep on launch if it finds a marker left by a previous run. |
| Guards | Power changes come from `IOPSNotificationCreateRunLoopSource`, so unplugging is handled instantly; battery and time limits are also checked every 30 s. The decision logic is a pure function in `Guards.swift`, covered by `tests/run.sh`. |
| Brightness | The private `DisplayServices` framework (`DisplayServicesGetBrightness` / `SetBrightness`), the same API used by [MonitorControl](https://github.com/MonitorControl/MonitorControl). The saved level lives in `UserDefaults` with a no-overwrite guard, so a crash between close and open never loses your original brightness. |

## FAQ

**Is this dangerous?**
No. `disablesleep` is an official power-management flag and is fully reversed by toggling off (or `sudo pmset -a disablesleep 0`). The app and the fail-safe agent run unprivileged; both only use the two `pmset` commands the sudoers rule allows. The only real caution is behavioral: see the warning above about bags and batteries.

**What if the app crashes?**
The fail-safe agent restores normal sleep within about 10 s of the app disappearing, or 60 s after it stops responding. The setting survives reboots, so the agent also checks at login. Every restore is written to `~/Library/Logs/LidNap.log`.

**Why does it need a sudoers rule?**
`pmset disablesleep` requires root. The rule lets exactly those two commands run without a password prompt, so the toggle is one click instead of a password dialog every time. Nothing else gains elevated rights.

**Could a macOS update break it?**
The sleep toggle uses only supported interfaces. The brightness feature relies on a private framework, so a future macOS release could break that part; the toggle would be unaffected.

**Why is there no Dock icon?**
By design. LidNap is a background menu bar utility (`LSUIElement`), the same convention Amphetamine and MonitorControl follow: it has no windows, so the coffee cup in the menu bar is its whole interface and the Dock stays uncluttered.

**Can I still launch it from the Dock?**
Yes. Open `~/Applications` in Finder and drag `LidNap.app` to the right side of the Dock (near the Trash). Clicking it launches the app if it is not already running. Note that as a background app it never shows the Dock's "running" indicator dot. If you prefer never thinking about launching at all, just enable **Start at Login** from the menu instead.

**Why not Amphetamine or KeepingYouAwake?**
Both are great. KeepingYouAwake (based on `caffeinate`) intentionally does not support closed-lid operation. Amphetamine does, but this project started the day the App Store refused to install it. Two hundred lines of Swift later, this exists, and it also restores your brightness.

## Uninstall

```shell
sudo pmset -a disablesleep 0
launchctl bootout gui/$(id -u)/com.wilberc.lidnap.failsafe
rm -f ~/Library/LaunchAgents/com.wilberc.lidnap.failsafe.plist
sudo rm /etc/sudoers.d/lidnap
rm -rf ~/Applications/LidNap.app "$HOME/Library/Application Support/LidNap"
rm -f ~/Library/Logs/LidNap.log
defaults delete com.wilberc.lidnap 2>/dev/null
```

No other traces are left on the system.

## Contributing

Issues and pull requests are welcome. The app lives in [`main.swift`](main.swift), with guard logic in [`Guards.swift`](Guards.swift), the fail-safe contract in [`Session.swift`](Session.swift) and the agent in [`failsafe.sh`](failsafe.sh). Run `./tests/run.sh` (Command Line Tools only, no Xcode needed); `build.sh` gives you a compile-install-run loop in a few seconds. Please keep changes native (AppKit, no dependencies) and update the README when behavior changes.

## License

LidNap is free and open source software, released under the [MIT License](LICENSE).
Copyright (c) 2026 Vedant Maurya and WilberC.

---

<div align="center">

Built by [WilberC](https://github.com/WilberC), on top of [LidAwake](https://github.com/deezeddd/LidAwake-Mac) by [Vedant Maurya](https://github.com/deezeddd)

If LidNap keeps your build alive, a ⭐ is appreciated!

</div>
