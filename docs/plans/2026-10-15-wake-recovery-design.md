# Wake recovery safety design

Approved scope: wake safety, coordinated emergency recovery, verification/retries and diagnostics. Power-management changes and general performance work are deferred.

## Invariants

- Online is not sufficient to disable the built-in display: an external display must also be active and not asleep.
- Sleep notifications suspend display configuration. A system wake alone does not prove that displays have woken (maintenance/DarkWake); wait for screen wake or an awake display observation. Explicit emergency recovery can override the suspension.
- Wake, recovery and unexpected built-in activation clear the disabled intent and latch safe mode. Passive Auto evaluation cannot override safe mode. As amended by the approved 2026-10-17 interaction change, an explicit subsequent disable **or explicit user action enabling Auto** may release it after the same safety checks; passive preference loading never releases it.
- An independent recovery tool writes a persistent UUID request before changing the display. The main app checks it on notification, polling, and around disabling. Release writes a separate acknowledgement for the consumed UUID, rather than deleting the request; a concurrent newer UUID remains pending. Missing notifications or restarting the main app cannot silently cancel recovery.
- Restore success means a subsequent snapshot reports the built-in display active and awake, not merely CGError.success. Retry on a bounded schedule; expose failure without resuming automatic disable.

## Components

- `ClamCore`: shared display enumeration/control, file-backed recovery latch, and injectable safety coordinator. XCTest uses an in-memory display backend; tests never configure physical displays.
- Main app: workspace sleep/wake notifications, one coordinator for manual/automatic/watchdog decisions, Carbon global hotkey Control-Option-Command-R, status UI, bounded quit recovery.
- Restore app: independent synchronous bounded recovery using the same core and persistent latch; nonzero exit on unverified recovery.
- Unified logging (`com.clamopen.app`, category `DisplayRecovery`) records transitions, snapshots and errors, not continuous unchanged snapshots.

## Limits and validation

CoreGraphics state cannot guarantee that an external panel physically shows an image. Private API availability is not a compatibility guarantee. A user-space app cannot repair an OS/GPU hard hang. Global shortcuts require the main app and may be unavailable at the login/lock screen.

Automated regression tests cover sleep suspension, wake event order, disabled auto mode, recovery-vs-watchdog, stale/missing notifications, persisted recovery, unsafe external display, retries/exhaustion and shutdown. Build/package and signature checks are non-disruptive. Actual display sleep, overnight sleep and locked-session recovery require user-assisted acceptance testing; do not trigger them automatically.
