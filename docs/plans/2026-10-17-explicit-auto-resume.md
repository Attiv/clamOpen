# Explicit Auto Resume — Approved Interaction and Implementation

## Goal

Fix the confusing v1.1 behavior where deliberately enabling Auto leaves a verified recovery safety hold in place and does not close the built-in display.

## Approved behavior

- An explicit user action enabling Auto immediately attempts the same guarded disable as the manual display-off action, when an external display is usable.
- Passive preference loading and background polling do not acknowledge recovery or release its hold.
- Sleeping, pending recovery, an unavailable external display, unreadable recovery state, and a new/concurrent emergency request retain their existing safety guards.
- Enabling Auto without a usable external display arms the preference without changing displays or clearing a safety hold. A paused Auto preference is visibly labelled in the menu.
- Turning Auto off changes the preference only. Wake and emergency recovery continue to hold the internal display on until a later explicit, safe action.

## Implementation steps

1. Add a separate `setAutoModeByUser(_:now:)` entry point in `DisplaySafetyCoordinator`; initially retain the old behavior to demonstrate failing immediate-resume tests.
2. Add regression tests for explicit resume, post-wake resume, passive preference loading, disabled Auto, absent/sleeping external displays, ongoing recovery, and emergency requests before/during disable.
3. Run the tests red, then delegate explicit resume to `disableByUser` without duplicating or weakening recovery-token checks.
4. Wire only the menu action to the explicit entry point. Keep startup preference loading passive; label checked-but-held Auto as paused and show a useful error when activation is blocked.
5. Update current documentation and both bundle versions to 1.1.1. Run Debug/Release tests, package and verify signatures. Do not alter the installed/running app or real display state as part of automated testing.

## Verification record

- The old explicit-enable behavior produced 11 expected assertion failures in the new regression cases; all passed after routing explicit enable through the guarded manual disable.
- `swift test` and `swift test -c release`: 44 tests passed in each configuration (38 coordinator, 6 latch).
- `./build_app.sh`: both v1.1.1 bundles generated at the project root.
- `codesign --verify --deep --strict --verbose=2`: both bundles passed.
- Independent incremental review found no Critical/Important issues; `git diff --check` passed.
- Installed v1.1 main app was left running at PID 1692 with its binary hash unchanged (`f05114b6f6c64f52148c37c447834f5530facc894ca942e49be0f2f9e0ae775c`). Real display configuration and power settings were not changed.
- Install/restart is required to exercise the new interaction. If Auto is already checked, turn it off and back on after updating. This action is deliberately distinct from loading its saved preference on startup.
