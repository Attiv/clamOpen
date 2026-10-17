# Wake Recovery Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Prevent ClamOpen from defeating wake/emergency recovery and provide observable, bounded recovery without changing pmset.

**Architecture:** A shared ClamCore target owns the display backend, persistent recovery latch and an injectable state coordinator. Both executables use the same recovery rules; AppKit/Carbon integration remains in the main app.

**Tech Stack:** Swift 5.9, SwiftPM/XCTest, AppKit, CoreGraphics, Carbon, Foundation, os.Logger.

---

### Task 1: Regression tests and shared state coordinator

Files: `Package.swift`, `Tests/ClamCoreTests/DisplaySafetyTests.swift`, `Sources/ClamCore/DisplaySafetyCoordinator.swift`.

1. Add the library/test targets and minimal declarations needed to express tests.
2. Write failing behavior tests for manual disable → sleep/wake → safe mode, emergency recovery winning over auto/watchdog, no configuration during sleep, and bounded verified retries.
3. Run `swift test --filter DisplaySafetyTests`; verify assertion failures for missing behavior, not toolchain errors.
4. Implement the coordinator with an injectable display backend/latch/clock and logging callback.
5. Re-run all tests; add regression cases for event order and retry exhaustion.

### Task 2: Cross-process latch and display backend

Files: `Sources/ClamCore/RecoveryLatch.swift`, `Sources/ClamCore/DisplayController.swift`, `Tests/ClamCoreTests/RecoveryLatchTests.swift`.

1. Write failing tests proving request persistence across instances, safe release, and fail-closed handling of unreadable latch state.
2. Move display control into the shared target. Enumerate private/all + online lists with error handling; require online/active/awake external state before disable.
3. Persist a recovery request atomically under the user's Application Support directory; post a distributed notification as an acceleration, never the sole signal.
4. Test the race where recovery arrives during disable; verify re-enabling and retained hold.
5. Run `swift test` and `swift build -c release`.

### Task 3: Main app and independent rescue

Files: `Sources/ClamOpen/AppDelegate.swift`, `Sources/ClamOpen/RecoveryHotKey.swift`, `Sources/ClamRestore/main.swift`.

1. Replace the three competing policy paths with the coordinator.
2. Register workspace sleep/wake/session events and the recovery signal; tick in common run-loop mode.
3. Add Control-Option-Command-R using Carbon, log registration errors, and show recovery status/retry action without blocking alerts in automatic recovery.
4. Make the restore executable request safe mode before enabling, verify through fresh snapshots, retry with a deadline, and exit nonzero on failure.
5. Restore on exit with bounded waiting; unregister callbacks/timers/hotkey during shutdown.
6. Run tests and release build; review source integration without launching display-changing code.

### Task 4: Documentation, review and packaging

Files: `README.md`, `README.zh-CN.md`, `scripts/diagnose_wake.sh`, `Info.plist`, `Info-Restore.plist`.

1. Document safe mode, shortcut limitations, log capture and manual acceptance scenarios; remove obsolete claims that watchdog re-closes restored screens.
2. Bump both bundles to 1.1. Package via `./build_app.sh`; verify both app signatures and versions.
3. Request independent code review, fix substantive findings and add regression tests first.
4. Run `swift test`, `swift build -c release`, `git diff --check` and packaging checks again.
5. Leave running `/Applications` apps untouched; report artifact paths and remaining real-hardware validation.

## Execution record

- Implemented tasks 1–4 on branch `fix/wake-recovery`; changes are left uncommitted for review.
- Verified red/green regression cycles for initial policy behavior, persistent requests, sleep polling, request/acknowledgement races, missing sleep events, late success, reversed wake events and stale asleep flags.
- `swift test`: 35 tests passed (29 coordinator tests, 6 file-latch tests).
- `swift test -c release`: the same 35 tests passed.
- `./build_app.sh`: both v1.1 x86_64 bundles built in the project root.
- `codesign --verify --deep --strict --verbose=2`: both bundles passed.
- `bash -n scripts/diagnose_wake.sh` and a read-only diagnostic smoke run passed.
- `git diff --check` passed. Independent review found no remaining Critical/Important blockers after its findings were covered by failing-then-passing regression tests.
- The installed `/Applications/ClamOpen.app` binary hash and running PID remained unchanged. No power settings, physical display configuration, installed apps or login items were changed.
- Pending acceptance: install both updated apps after quitting the old main app; verify real screen/full-system sleep, locked-session shortcut limitations, dock reconnect and overnight recovery. These are not claimed verified by unit tests.
