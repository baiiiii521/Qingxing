<div align="center">

<img src="docs/icon.png" width="120" alt="Qingxing"/>

# Qingxing 清醒

**A macOS menu-bar keep-awake utility**

**Work with the lid closed · Screen off without interrupting · Power-conditioned**

[简体中文](README.md) ｜ English

![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)
![Architecture](https://img.shields.io/badge/arch-arm64%20(Apple%20Silicon)-green)
![Swift](https://img.shields.io/badge/Swift-5-orange)
![License](https://img.shields.io/badge/License-MIT-blue)

</div>

---

## ✨ Features

- 🌙 **Keep working with the lid closed** — close the lid and your Mac keeps running (screen turns off automatically, tasks continue)
- 🌑 **Screen off, system awake** — lid open, display sleeps on schedule, but downloads / builds / agents keep going
- ☀️ **Display always on** — neither the display nor the system sleeps
- ⚡ **Power conditions** — **Always / Only on AC power / Only on battery**, switching automatically when you plug in or unplug (the core differentiator of this project)
- ⏻ **One click: screen off & keep working**
- ↩️ **One-click restore to macOS defaults** — everything back to normal sleep behavior
- 🇨🇳 Fully Chinese UI · Single-file Swift · Zero dependencies · No network access · No daemons

## 📦 Install

Only Command Line Tools (`swiftc`) required — **no Xcode project**:

```zsh
git clone https://github.com/baiiiii521/Qingxing.git
cd Qingxing
./build.sh          # produces dist/Qingxing.app
open dist/Qingxing.app
```

Tip: drag `Qingxing.app` into /Applications before enabling "Launch at Login".

Toggling "lid closed" mode prompts for the **admin password once** (see How it works).

## 🚀 Usage

Click the 🌙 / ☕ icon in the menu bar:

| Menu item | What it does |
|---|---|
| 🌙 Keep working with lid closed | Lid-closed no-sleep; screen auto-off, tasks continue |
| 🌑 Screen off, keep working | Lid open, display may sleep, system stays awake |
| ☀️ Display always on | Neither display nor system sleeps |
| ⏻ One click: screen off & keep working | Enables system-awake mode and turns the display off immediately |
| ⚡ Power condition | Always / Only on AC / Only on battery |
| ↩️ Restore macOS defaults | Disables all modes and clears pmset settings |
| 🚀 Launch at login | Login item via SMAppService |

Icon states: 🌙 = normal sleep allowed; ☕ = at least one mode active. The menu header shows the current power source and active modes in real time.

> 💡 **Which mode?** Idle downloads with the Mac sitting open → just "Screen off, keep working" (no password, auto-released on quit). Using the Mac closed / in a bag → "Keep working with lid closed" (it already implies screen-off behavior). Both can be on at once — they don't conflict.

## 🔧 How it works

| Mode | Mechanism | Privileges | Lifetime |
|---|---|---|---|
| Lid closed | `pmset disablesleep` (kernel SleepDisabled flag, written per power source via `-c` / `-b` / `-a`) | One-time admin authorization | System-wide, persists across reboots |
| Screen off | IOKit assertion `PreventUserIdleSystemSleep` | None | Released automatically when the app exits |
| Display on | IOKit assertion `PreventUserIdleDisplaySleep` | None | Released automatically when the app exits |

`caffeinate` / IOKit assertions only prevent *idle* sleep — **they cannot block lid-close sleep**, which is a hardware-triggered kernel path. Flipping the kernel `SleepDisabled` flag is the only reliable approach without kernel extensions (the same route taken by Sleepless, Owly, etc.).

Power conditions: assertion-based modes are held/released in real time via IOPS power-source notifications; lid mode maps to the corresponding pmset profile. When enabling lid mode, the app records your original idle-sleep timers and temporarily sets `sleep 0` (needed on macOS 26/27 in battery scenarios), restoring the originals on disable.

## 🆚 Comparison

| | Qingxing | [Sleepless](https://github.com/Aboudjem/Sleepless) | [Owly](https://github.com/Aarontaken/owly) | [StayAwake](https://github.com/TY-teo/StayAwake) | [KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake) | [Amphetamine](https://apps.apple.com/app/amphetamine/id937984704) |
|---|---|---|---|---|---|---|
| Lid-closed no-sleep | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| Screen-off keep-awake | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Power-conditioned (AC only / battery only)** | ✅ | ❌ | ❌ | ❌ | ❌ | ⚠️ Partial |
| Chinese UI | ✅ | ❌ | ✅ | ✅ | ❌ | ❌ |
| No sudoers rule / daemon required | ✅ | ❌ | ❌ | ❌ | ✅ | ✅ |
| Open source | ✅ MIT | ✅ | ✅ | ✅ | ✅ | ❌ |

## ⚠️ macOS 26 / 27 notes

- `pmset -g custom` no longer lists `disablesleep` on recent macOS; status must be read from `SleepDisabled` in `pmset -g` (live). This project handles that.
- Multiple reports indicate that on battery, `disablesleep` alone may still be overridden by sleep policy on macOS 26/27 unless `sleep 0` is also set — handled automatically when enabling lid mode. If your model still sleeps when closed on battery, using AC power is the most reliable path ([Apple community thread](https://discussions.apple.com/thread/256305994)).
- Running with the lid closed reduces heat dissipation and drains the battery — use your own judgment.

## 🛠 Build & development

```zsh
./build.sh                              # compile + generate icon + bundle + ad-hoc sign
swiftc test_core.swift -o t && ./t      # core-logic self-test (no privileges needed)
```

```
├── main.swift      # entire app: single-file AppKit menu-bar app (~600 lines)
├── Info.plist      # LSUIElement=1, pure menu-bar app, no Dock icon
├── gen_icon.swift  # icon generation (CoreGraphics coffee cup)
├── build.sh        # one-shot build
├── test_core.swift # core-logic self-test
└── docs/           # docs assets
```

- The build produces an arm64 (Apple Silicon) binary; add `-arch x86_64` in `build.sh` for Intel.
- Inspect live state with `pmset -g assertions` (assertions) and `pmset -g | grep SleepDisabled` (lid flag).

## 🧹 Uninstall & restore

1. Menu → ↩️ Restore macOS defaults (or run `sudo pmset -a disablesleep 0` manually)
2. Quit the app and delete `Qingxing.app`; assertion-based modes auto-release when the process exits.

## ❓ FAQ

**Why does lid mode need my admin password?**
It modifies a system-wide power-management setting (`pmset disablesleep`) — the same as running `sudo pmset ...` in a terminal. You're prompted once per toggle.

**What happens when I unplug the power adapter?**
Depends on the selected power condition: assertion-based modes attach/release automatically in real time; lid mode follows the pmset profile of the active power source.

**Do settings survive after the app quits?**
Assertion-based modes stop immediately (safe). Lid mode is persistent and survives reboots — use "Restore macOS defaults" to undo it.

## 🙏 Acknowledgements

Built on technical routes validated by: [Sleepless](https://github.com/Aboudjem/Sleepless) · [Owly](https://github.com/Aarontaken/owly) · [StayAwake](https://github.com/TY-teo/StayAwake) · [KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake)

## 📄 License

[MIT](LICENSE) © 2026 baiiiii521
