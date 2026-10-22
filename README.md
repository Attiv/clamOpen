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

ClamOpen is a tiny menu-bar app that **truly turns off your MacBook's built-in display** (backlight off, the compositor stops rendering to it) while an external monitor is connected — **with the lid open**. The result is identical to clamshell mode, except you keep the webcam, Touch ID, the keyboard, and better airflow.

## Why

macOS only powers down the internal panel in *clamshell* mode (lid closed). If you want to keep the lid open — for the camera, Touch ID, the built-in keyboard, or just cooling — there is no native switch. ClamOpen is that switch.

## Features

- 🖥️ One click to turn the internal display off / on from the menu bar
- 🤖 **Auto mode** — disable the internal display when an external one is connected, restore it when unplugged
- 🔋 **Power management** — one-click optimization of sleep settings to prevent frequent wake-ups at night (disables TCP Keep Alive, network wake, etc.)
- 🎛️ **GPU management** — inspect the GPU driving the main display and separate battery/AC policies; explicitly choose discrete-preferred or automatic mode on supported dual-GPU Intel Macs
- 🧩 **Application GPU manager** — app inventory, supported browser launch preferences, experimental Electron requests and read-only fallback
- 🛟 **Independent recovery** — a standalone *Restore* app works without the main app; the main app also provides the `⌃⌥⌘R` global recovery shortcut
- 🔒 **Safety first** — refuses to turn the internal display off when no external display is present; auto-restores on unplug / quit
- 🪶 Menu-bar only (no Dock icon), no background daemon; display changes are session-scoped (optional power settings persist)

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

### v1.1.1: wake-safe mode and explicit Auto resume

- Disabling requires an external display that is **online, active and not asleep**. This is a software-state check, not proof that the physical panel shows an image.
- System/display sleep suspends configuration. System wake without screen-wake evidence waits rather than treating maintenance/DarkWake as a user-visible wake.
- Wake, manual/independent recovery, or unexpected built-in activation enters **safe mode**. Auto mode and the watchdog will not disable the restored screen again.
- Explicitly choose **Turn off the internal display**, or deliberately **enable Auto**, to leave safe mode. If the external display is usable and recovery/emergency guards allow it, Auto immediately disables the built-in display. Passive startup preference loading never releases the safety hold.
- A checked but held Auto preference is labelled **paused** in the menu. Turn it off and back on to explicitly resume. Without a usable external display, enabling Auto only arms the preference; it neither forces display-off nor clears an existing safety hold.
- CoreGraphics callbacks, AppKit screen notifications and an approximately one-second watchdog use the same coordinator.
- Recovery submits at most four configuration attempts (approximately at 0, 1, 3 and 7 seconds under normal scheduling). Success requires a subsequent snapshot showing the built-in display active and awake, not just API success. Failure is visible in the menu/logs; request recovery again to retry.
- Normal quit performs bounded recovery and verification. Force-killing the app cannot run its quit handler.

The independent tool atomically writes a UUID request before enabling the built-in display. The main app receives it through notifications and polling. Releasing safe mode acknowledges only a consumed UUID; it does not delete a newer concurrent request. This state persists under `~/Library/Application Support/ClamOpen/`, including across app restarts.

### If both screens go black

1. Press **Control + Option + Command + R** (`⌃⌥⌘R`) while the main app runs. Registration failure is shown in the menu. Availability at the lock/login screen is not guaranteed.
2. Use Spotlight (`⌘ Space`) to launch `恢复内置屏`. The tool does not require the main app, and the updated main app will not fight its recovery.
3. Unplug the external display to let the running main app attempt recovery.
4. If necessary, close/reopen the lid or log out/reboot to establish a new display session.

These are recovery attempts, not a guarantee against OS/GPU hangs or private-API failures.

### Diagnostics and acceptance testing

```bash
swift test                           # simulated backend; no physical display changes
./scripts/diagnose_wake.sh > ~/clamopen-wake.txt
```

The diagnostic script reads system/version information, power settings, recent sleep/wake events, display state and ClamOpen logs. It changes no configuration. Review device/process information before sharing logs.

After saving work, manually verify: screen-only and full-system sleep/wake with Auto both off/on; the shortcut and independent tool followed by at least ten seconds without re-disable; external unplug/reconnect; normal quit/restart; and overnight/locked-session behavior. Night-time logs should not show repeated enable attempts caused by polling. Unit tests do not establish real-hardware overnight reliability.

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

**Upgrading:** quit the old main app, confirm the internal display is restored, replace **both** app bundles, then reopen the main app. v1.0 does not understand recovery requests and must not be used to validate the new recovery behavior.

Launch at login: System Settings → General → Login Items → add `ClamOpen.app`.

## Usage

### Display Control

1. Connect an external display.
2. Click the menu-bar icon → **Turn off the internal display**.
3. To bring it back → **Emergency restore**, or press `⌃⌥⌘R`. Wake/recovery pauses automatic display-off; deliberately re-enabling Auto resumes it immediately after its safety checks pass.

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

### GPU Management (v1.2)

The menu displays **the GPU currently driving the main display**. Its GPU submenu shows separate
battery/AC `gpuswitch` values, discrete-preferred and automatic actions, and a refresh command.

- Status uses `CGDirectDisplayCopyCurrentMetalDevice(CGMainDisplayID())`, not an application's
  rendering context. It does **not** claim all applications are using that GPU.
- The default Metal device API is deliberately not used as a status probe: Apple's SDK documents
  that calling it can activate the high-power GPU on graphics-switching Macs. Enumeration uses
  `MTLCopyAllDevices()`, which does not request a GPU switch.
- Explicit actions run `pmset -a gpuswitch 1` (discrete-preferred) or `2` (automatic) through one
  system administrator-authentication request. They persist for **both battery and AC power**.
  Discrete graphics can increase power consumption and heat.
- Both policy values are read back before reporting success. The display GPU is reported separately;
  automatic mode can still use AMD while an external display is connected.
- Queries and authentication run serially off the main run loop. Sleep, recovery, or termination
  cancels pending requests. The privileged command also checks a private request marker and parent
  process liveness after authentication, preventing stale authorization from applying a queued
  change. Cancellation does not undo a write that already completed.
- Single-GPU devices, Apple Silicon, and unreadable/unknown policy states are read-only. There is
  no force-integrated action. Startup, menu opening, refresh and wake never automatically write a
  GPU policy. Quit/uninstall does not restore persistent policies; choose automatic explicitly.

**Browser limitation:** Chromium apps may select GPUs independently. Inspect `GL_RENDERER` in
`chrome://gpu` and, if needed, restart through a high-performance GPU launcher.

Automated tests use fake GPU backends and benign process-cancellation checks, never real GPU
switches or administrator prompts. After installing the update, manually verify menu values,
authentication cancellation, recovery responsiveness while authentication is pending, both policy
values in `pmset -g custom`, and cancellation of pending requests during sleep/recovery/quit.

### Application GPU Manager (v1.3)

Open **GPU management → 应用显卡管理…**. The independent searchable/filterable window scans
`/Applications`, `~/Applications`, `/System/Applications`, running app URLs and explicitly added
`.app` bundles. Canonical paths, not bundle IDs, distinguish installed copies.

- **Known browser adapters:** Chrome, Arc and ego lite can save default/high-performance preference.
- **Experimental Electron:** bundles containing Electron Framework can try the same fixed
  `--force-high-performance-gpu` request after explicit acknowledgement. Detection is not verification
  that the app/version honors the flag. Other native/unknown apps are GPU-selection read-only.
- Preferences apply **only to launches from this window**, not original Dock/Finder/file-association
  entry points or previously created discrete launchers. Default means no appended flag, not force Intel.
  Saving never launches/quits apps. Running instances with the same path or bundle ID block launching;
  quit manually first. No force-integrated mode, injection, signed-bundle edits, daemon or hot switching.
- Saved preference, selected main-process external argv observation and actual rendering are separate.
  External flags do not prove actual GPU selection; apps may configure internal switches not in argv.
  Unreadable/exited processes are unknown. Raw argv/environment are neither retained nor logged.
- Actual GPU is **unknown** unless a user imports an unambiguous `GL_RENDERER` text report (UTF-8,
  maximum 2 MB). Browser reports can be downloaded from `chrome://gpu`. The user assigns the report
  to the selected app; provenance is not automatically checked. Renderer/import time are explicitly
  historical and non-live, not evidence for every rendering context. Reports remain only in memory.
- Versioned settings live in `~/Library/Application Support/ClamOpen/application-gpu.json`; saves are
  atomic/private. Corrupt/unknown-version settings disable saves and preference launches without
  overwriting the file. Scans, storage and process queries run off-main; UI identities are cached.
  Recovery/sleep/topology/quit events permanently invalidate queued, not-yet-submitted launches.
  A submitted launch cannot be rolled back; no automatic app termination is performed.

Run `swift test`. With a logged-in macOS GUI session, `bash scripts/test_application_gpu_window.sh`
uses only temporary fixture bundles/settings and a fake launcher, and renders the new window without
running the original AppDelegate, launching real applications or writing pmset. For manual acceptance:
verify read-only/experimental controls, no launches on save/refresh, running-app launch refusal, then
quit one target app yourself and verify its renderer after an explicit managed launch. Confirm that
original Dock entries are untouched and imported reports remain clearly non-live.

## Project structure

```
Sources/ClamOpen/      Menu-bar app
  ├── RecoveryHotKey.swift       Global recovery shortcut
  ├── PowerManager.swift         Power management (sleep optimization)
  ├── AppDelegate.swift          Main app logic
  ├── ApplicationGPUWindowController.swift  Independent application GPU window
  └── main.swift
Sources/ClamCore/      Shared display safety/recovery, GPU policies, application inventory/preferences/launch validation
Sources/ClamRestore/   Standalone emergency restore tool
Tests/ClamCoreTests/   Regression tests without physical display changes
make_icon.swift        Programmatic icon generator
build_app.sh           Build + package both .apps
Info*.plist            Bundle metadata
scripts/               Dev / verification scripts (probe, toggle test, disable)
```

## Compatibility

- Original display-toggle API tested on macOS 26.5.1, Intel (UHD 630 + Radeon Pro 5500M).
- v1.3 builds, simulated-state, application GPU window and GPU policy tests run on macOS 26.7.1 Intel; overnight/lock-screen recovery and real GPU authentication still require hardware acceptance testing.
- The `CGSConfigureDisplayEnabled` path works on both Intel and Apple Silicon.
- Private APIs may change between macOS releases; stable on the above as of writing.

## Disclaimer

ClamOpen uses a private Apple API. It requires no special entitlements. Display changes are per-session (optional power-management settings persist), but private APIs are unsupported by Apple and may change between
releases. Use at your own risk.

## License

MIT — see [LICENSE](LICENSE).
