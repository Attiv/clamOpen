# Application GPU Management Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add an honest, capability-aware application GPU manager beyond browsers.

**Architecture:** Put testable inventory, persistence, parser and launch gates in ClamCore.
Use a separate AppKit window in ClamOpen; original display safety and GPU policy code stays intact.
Known browser requests and experimental Electron requests use one fixed argument, never a shell.

**Tech Stack:** Swift 5.9, AppKit, Foundation, Darwin sysctl, SwiftPM XCTest, macOS 12+.

---

### Task 1: Inventory and capability (APP-01, APP-02)
Files: create Sources/ClamCore/ApplicationGPU.swift and Tests/ClamCoreTests/ApplicationGPUTests.swift.
1. Write fixture tests for native/browser/Electron support, nested directories, helper exclusion,
   canonical-path deduplication and equal bundle IDs at different paths.
2. Add only compile-time model stubs, run `swift test --filter ApplicationGPUTests`; expect assertions
   failing for empty scan and missing capability, not compilation errors.
3. Implement canonical .app metadata reads and bounded package-skipping inventory.
4. Re-run targeted tests until green.

### Task 2: Persistence, launch planning and evidence (APP-03 through APP-06)
Files: extend above; create Sources/ClamCore/ApplicationGPUBackend.swift.
1. Add failing tests for preference roundtrip/default, corrupt/unknown schema, stale unsupported
   preferences, running path/ID guards, hardware and experimental consent, fixed argv,
   KERN_PROCARGS2 truncation/environment/substrings, ambiguous report and software renderer.
2. Run targeted suite and observe new assertion failures.
3. Implement atomic private-file settings, pure launch-plan validation, parsers. Native launcher
   revalidates app metadata and running status immediately before NSWorkspace open.
4. Re-run tests; use only fake launch backends and temporary fixture apps.

### Task 3: Native window and menu integration (APP-07)
Files: create Sources/ClamOpen/ApplicationGPUWindowController.swift; modify AppDelegate.swift.
1. Build the independent resizable window with search/filter/table, details, preference save,
   explicit launch, refresh, add-app, reveal and report import controls.
2. Use background queue for IO, main-only NSWorkspace snapshots/UI, stable selected-path identity.
   Failed settings reads disable writes. Experimental save asks confirmation; never auto-quit.
3. Add menu action and retained window; delegate safety closure gates explicit launches.
4. Build and use standalone fixture-only window harness for rendering and control checks; no
   original AppDelegate, real apps, pmset, accessibility or screen reconfiguration.

### Task 4: Review, documentation and package (APP-08)
Files: README.md, README.zh-CN.md, Info.plist, Info-Restore.plist and this plan.
1. Document support levels, launch-only scope, unknown/live/report distinctions and manual checks.
2. Version both apps to 1.3.0; run `swift test`, `swift test -c release`, `./build_app.sh`,
   `git diff --check`, plist lint and deep/strict codesign verification.
3. Request independent read-only code review, fix significant findings with regression tests.
4. Copy verified artifacts to Downloads/ClamOpen-1.3.0-GPU-Apps and zip without overwriting prior
   releases. Verify archive, signatures and SHA256. Do not install or restart running ClamOpen.

## Rollback
All source changes stay on feat/gpu-management worktree. New settings are independent of
system pmset and original applications; removing/ignoring them does not undo system policies.
Older packages and installed app remain untouched. No remote publishing/integration requested.

## Progress
- Baseline before new feature: 71 Debug tests passed, 0 failures.
