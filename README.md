# ClamOpen

<p align="center">
  <img src="docs/icon-clamopen.png" width="120" alt="ClamOpen icon">
  &nbsp;&nbsp;&nbsp;
  <img src="docs/icon-restore.png" width="120" alt="Restore icon">
</p>

<p align="center">
  <b>Use only your external display while the MacBook lid stays open</b><br>
  — the clamshell effect, without closing the lid.
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2012%2B-blue" alt="platform">
  <img src="https://img.shields.io/badge/Swift-5.9%2B-orange" alt="swift">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license">
</p>

---
---
> **📢 Fork Notes**
>
> I'm not a developer — just a regular user on a **2017 Intel MacBook Air running macOS 12.7.6**. The original version didn't work on my machine, so I fixed it step by step with the help of Codex (an AI coding assistant). Now it works perfectly on my setup.
>
> Huge thanks to [@Attiv](https://github.com/Attiv) for open-sourcing this! If the original version doesn't work for you either, give this fork a try. I can't help with other technical issues though — I'm just a user who got lucky with AI.
>
> **Tested on:** macOS 12.7.6 · Intel MacBook Air (2017) · External display via Thunderbolt
>

ClamOpen is a tiny menu-bar app that **truly turns off your MacBook's built-in display** (backlight off, the compositor stops rendering to it) while an external monitor is connected — **with the lid open**. The result is identical to clamshell mode, except you keep the webcam, Touch ID, the keyboard, and better airflow.

## Why

macOS only powers down the internal panel in *clamshell* mode (lid closed). If you want to keep the lid open — for the camera, Touch ID, the built-in keyboard, or just cooling — there is no native switch. ClamOpen is that switch.

## Features

- 🖥️ One click to turn the internal display off / on from the menu bar
- 🤖 **Auto mode** — disable the internal display when an external one is connected, restore it when unplugged
- 🔋 **Power management** — one-click optimization of sleep settings to prevent frequent wake-ups at night (disables TCP Keep Alive, network wake, etc.)
- 🛟 **Crash-proof recovery** — a standalone *Restore* app brings the internal display back even if the main app dies (works while the screen is black, via Spotlight)
- 🔒 **Safety first** — refuses to turn the internal display off when no external display is present; auto-restores on unplug / quit
- 🪶 Menu-bar only (no Dock icon), no background daemon, no permanent system changes

## How it works

ClamOpen disables the internal panel through a **private CoreGraphics / SkyLight symbol**:

```c
CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef config, CGDirectDisplayID display, bool enabled);
```

wrapped in a standard display-reconfiguration transaction:

```swift
var config: CGDisplayConfigRef?
CGBeginDisplayConfiguration(&config)
CGSConfigureDisplayEnabled(config, builtinDisplayID, false)   // false = disable
CGCompleteDisplayConfiguration(config, .forSession)
```

- `CGBeginDisplayConfiguration` / `CGCompleteDisplayConfiguration` are **public** CoreGraphics APIs.
- `CGSConfigureDisplayEnabled` is the **private** symbol that does the real work. It is resolved at
  runtime with `dlsym(RTLD_DEFAULT, "CGSConfigureDisplayEnabled")` (it ships inside CoreGraphics /
  SkyLight), so there is **no link-time dependency** on a private framework and nothing to entitle.
- Afterwards the internal display reports `CGDisplayIsActive == false`: the backlight turns off and
  nothing is rendered to it — visually identical to clamshell, lid open.
- The `forSession` scope means the change only lasts for the current login session, so a **logout or
  reboot always restores the internal display**.

This is the same low-level mechanism behind tools like [Lunar](https://lunar.fyi) and
[BetterDisplay](https://github.com/waydabber/BetterDisplay). (Apple Silicon additionally offers a
deeper "soft-disconnect" that releases the framebuffer; ClamOpen uses the `CGSConfigureDisplayEnabled`
path, which works on both Intel and Apple Silicon.)

> Verified on macOS 26.5.1 (Intel): disabling returns `CGError 0` and flips the built-in display to
> inactive; re-enabling restores it.

## Safety & recovery

Turning the internal display off and then **unplugging the external one** could, in theory, leave you
with no visible screen. ClamOpen guards against this with several **independent** layers:

- It **refuses** to disable the internal display when no external display is online.
- On unplug it **auto-restores** the internal display via three independent triggers: a low-level
  `CGDisplayRegisterReconfigurationCallback` (fires the instant the cable is pulled), the AppKit
  screen-parameters notification, and a 1.5 s watchdog.
- It **restores on quit**.
- On Intel, if the panel is occasionally woken at minimum brightness, the watchdog turns it back off
  within 1.5 s.

### If the screen ever goes black

Any one of these brings the internal display back:

1. **Spotlight blind-type (works while black)** — press `⌘ Space`, type `恢复内置屏` (the Restore
   app), press Enter. No need to see the screen.
2. **Unplug the external display** — auto-restores.
3. **Close and reopen the lid** — macOS re-enumerates displays.
4. **Log out / reboot** — the `forSession` scope guarantees a restore.

> Tested: with the main app *not running*, launching the Restore app alone brings a disabled internal
> display back to active.

## Build from source

Requirements: macOS 12+, Xcode / Swift 5.9+.

```bash
git clone https://github.com/Attiv/clamOpen.git
cd clamOpen
./build_app.sh        # generates icons, builds, and packages both apps
```

This produces:

- `ClamOpen.app` — the menu-bar app
- `恢复内置屏.app` ("Restore Internal Display") — the standalone emergency restore app

Or just compile the binaries: `swift build -c release`

## Install

Drag **both** `ClamOpen.app` and `恢复内置屏.app` into `/Applications`. Putting the Restore app there
lets Spotlight find it when the screen is black (strongly recommended). First launch may be blocked by
Gatekeeper (local ad-hoc signature) — right-click → **Open**.

Launch at login: System Settings → General → Login Items → add `ClamOpen.app`.

## Usage

### Display Control

1. Connect an external display.
2. Click the menu-bar icon → **Turn off the internal display**.
3. To bring it back → **Restore the internal display**, or enable **Auto** mode.

### Power Management (Prevent Night-time Battery Drain)

**Problem**: MacBook drains battery overnight while sleeping.

**Cause**: macOS enables TCP Keep Alive by default, which wakes the system every minute to maintain network connections, causing rapid battery drain.

**Solution**:

1. Click the menu-bar icon → **Power Management** (shows ⚠️ if issues detected)
2. Review current power settings
3. Click **Apply Power Saving Settings**, enter admin password
4. The following will be disabled:
   - TCP Keep Alive (prevents frequent wake-ups)
   - Wake on Magic Packet (network wake)
   - Proximity Wake
   - Adjust standby delay to 1 hour

**Normal use unaffected**: Opening the lid, pressing keys, or clicking the trackpad still wakes the Mac normally.

**Verify results**: Next morning, run in Terminal:
```bash
pmset -g log | grep -E "DarkWake" | tail -20
```
to check if night-time wake-ups have decreased significantly.

## Project structure

```
Sources/ClamOpen/      Menu-bar app
  ├── DisplayController.swift   Display control (private API calls)
  ├── PowerManager.swift         Power management (sleep optimization)
  ├── AppDelegate.swift          Main app logic
  └── main.swift
Sources/ClamRestore/   Standalone emergency restore tool
make_icon.swift        Programmatic icon generator
build_app.sh           Build + package both .apps
Info*.plist            Bundle metadata
scripts/               Dev / verification scripts (probe, toggle test, disable)
```

## Compatibility

- Tested on macOS 26.5.1, Intel (UHD 630 + Radeon Pro 5500M).
- The `CGSConfigureDisplayEnabled` path works on both Intel and Apple Silicon.
- Private APIs may change between macOS releases; stable on the above as of writing.

## Disclaimer

ClamOpen uses a private Apple API. It requires no special entitlements and makes no permanent system
changes (the setting is per-session), but private APIs are unsupported by Apple and may change between
releases. Use at your own risk.

## License

MIT — see [LICENSE](LICENSE).
