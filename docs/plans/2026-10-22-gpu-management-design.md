# GPU Management — Approved Design

## Context and approved scope

ClamOpen is a Swift/AppKit menu-bar app. `AppDelegate.rebuildMenu()` owns the menu;
`PowerManager` already uses administrator-authorized `osascript` for explicit pmset actions.
The display safety coordinator and its common-mode one-second watchdog must remain independent.

The user approved both status display and switching between discrete-preferred and automatic
policies. This is **not** a claim that every application uses the displayed GPU.

## Requirements

- FR-01: Show the **GPU currently driving the main display** in the main menu, separately from policy.
- FR-02: A GPU submenu shows separate battery/AC policy values, with unknown states explicit.
- FR-03: Explicit user actions apply `/usr/bin/pmset -a gpuswitch 1` or `2` through one system
  administrator-authentication request. Startup, refresh, polling, and wake never write policy.
- FR-04: Re-read both power policies after an action. Report success only if both match;
  report the fresh main-display GPU separately. Handle authentication cancellation without false success.
- FR-05: Refresh on startup, menu opening, and an explicit refresh action, using cached menu state.
- NFR-01: Queries and authentication run off the main thread. Do not overlap GPU operations.
- CON-01: Disable switching on Apple Silicon, single/unsupported GPUs, missing/unknown policy,
  and during display sleep, recovery, termination, or another GPU operation.
- CON-02: Preserve all display safety/recovery logic and existing sleep-optimization behavior.
- CON-03: Automated tests use fake backends and never change displays or real GPU policy.

## Architecture

Add a small injectable `GPUController` and Metal/pmset backend to ClamCore. Keep parsing and
verification testable without hardware. AppDelegate owns a serial background queue and cached
snapshot; menu updates modify existing GPU items in place while a menu is tracking.

The submenu contains status, battery and AC values, discrete/automatic actions, refresh, and
a short explanation of scope. No force-integrated action, browser launching, hidden daemon,
login configuration, or automatic policy enforcement is included.


### Evidence-driven design correction

The installed Apple SDK `Metal.framework/Headers/MTLDevice.h:123–135` documents that the default
Metal device query can switch automatic-graphics systems to high power, whereas enumeration
does not. A passive observer therefore uses `CGDirectDisplayCopyCurrentMetalDevice` and labels
the result as the main-display GPU. This correction was surfaced to the user rather than silently
claiming the default-device API is observational.

Pending writes are owned by a cancellable per-action request created before dispatch. The system
command checks a private marker and parent process after authorization. Sleep/recovery/quit
removes the marker and terminates the owned authorization process. A completed write is never
misrepresented as rolled back merely because cancellation raced its completion.

## Verification and delivery

Test whitespace, absent/unknown/duplicate policy values, unsupported hardware, command failures,
cancelled authentication, successful but unverified writes, mixed-source state, and automatic
mode retaining a discrete display GPU, plus marker/process cancellation. Run all existing Debug/Release tests and package/sign
both apps as v1.2.0. Do not replace or start the installed ClamOpen app or exercise real switching
as part of automated validation. Real menu/authentication acceptance is explicitly documented.
