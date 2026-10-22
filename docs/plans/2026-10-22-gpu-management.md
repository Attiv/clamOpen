# GPU Management Implementation Plan

> Use the executing-plans workflow, with test-first implementation and independent review.

**Goal:** Add the approved GPU status and explicit discrete/automatic controls to ClamOpen.
**Architecture:** Injectable ClamCore controller/backend, cached AppKit menu, serial background
operations, passive main-display GPU query, cancellable authorization and read-back verification.
No changes to display recovery decisions or installed apps.
**Tech Stack:** Swift 5.9, AppKit, Metal, Foundation Process, XCTest, pmset/osascript.

## Task 1 — Core and tests (FR-02/03/04, CON-01/03)

- Create `Tests/ClamCoreTests/GPUControllerTests.swift` before implementation.
- Add `Sources/ClamCore/GPUController.swift`: typed preferences, strict per-source policy parser,
  hardware snapshot, injectable backend, read-only snapshot, verified explicit application.
- First demonstrate missing-feature/behavior failures, then implement until the targeted tests pass.
- Cover cancellation, process errors, missing capability, malformed reads, and mismatched read-back.

- Use a per-action cancellation token/marker and owned process; guard the privileged write after
  authorization and cancel pending requests on sleep, emergency recovery or quit.

## Task 2 — Menu integration (FR-01/02/05, NFR-01, CON-01/02)

- Modify `Sources/ClamOpen/AppDelegate.swift` only for a cached GPU section, actions, and lifecycle
  refresh hooks. Use a serial worker queue for every new backend call; update AppKit only on main.
- Keep menu items stable during asynchronous updates. Disable overlapping operations and actions
  during sleep/recovery/termination. Apply no GPU settings without an explicit menu action.
- Validate the existing recovery suite remains unchanged and all new command calls are off-main.

## Task 3 — Docs and package

- Update both READMEs with exact semantics, supported hardware, authentication, persistence,
  browser limitations, and real-hardware acceptance steps. Update both Info plists to v1.2.0.
- Run `swift test`, `swift test -c release`, `./build_app.sh`, signature verification and
  `git diff --check`. Independently review the implementation against the approved requirements.
- Record results and outstanding manual UI/hardware validation. Leave installed/running apps
  unchanged. Deliver the worktree and packaged app paths; no push/public release.

## Rollback

Source changes are isolated on `feat/gpu-management`. New GPU policy writes are only user-triggered;
removing the new app does not restore persistent pmset settings. The submenu's automatic action
explicitly sets both power sources to `gpuswitch=2`. Existing emergency recovery remains available.

## Verification record — 2026-10-22

- Baseline: 44 tests passed before feature work.
- Test-first parser stub produced 18 expected assertions; parser/controller tests then passed.
- Cancellation-before-start, during preflight, and during authorization produced 5 expected
  assertions before integration; all passed after request ownership/cancellation was wired.
- Final Debug and Release suites: 71 tests passed in each (38 display, 27 GPU, 6 latch).
- Production `./build_app.sh`: both v1.2.0 bundles generated and strict/deep signatures verified.
- Read-only native smoke using the actual backend reported AMD Radeon Pro 5500M as main-display
  GPU and discrete-preferred for both sources. Before/after pmset output was identical.
- Independent review: observation/lifecycle blockers fixed; no remaining Critical or Important
  findings. Known minor limitation: read-only pmset subprocesses have no timeout; a hung read
  can leave only the GPU controls busy until restart, not block display recovery.
- Package: `~/Downloads/ClamOpen-1.2.0-GPU.zip`; archive integrity and copied app signatures pass.
- Installed v1.1.1 app left running at PID 42708; no replacement, app launch, display configuration,
  or real policy write performed during feature validation. Current policies remained 1/1.
- Native menu rendering, real administrator cancellation and sleep/recovery interaction remain
  manual acceptance items. No merge, push or public release performed; worktree retained.
