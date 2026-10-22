# Application GPU Management — Approved Design

## Approval and boundaries
The user approved a general application list with per-application adapters, rather than a
browser-only whitelist. ClamOpen remains a Swift/AppKit menu-bar app; existing display safety,
recovery, GPU system policies, original application bundles, Dock entries and processes must
not be changed by this addition. Installed ClamOpen must not be replaced or restarted implicitly.

## Requirements and acceptance
- APP-01: Scan /Applications, ~/Applications and /System/Applications, including nested app
  folders but not helpers inside bundles. Merge running applications and explicit .app additions;
  deduplicate canonical paths, not bundle IDs (this machine has duplicate IDs). Search/filter list.
- APP-02: Known Chrome/Arc/ego lite adapters offer default/high-performance launch preference.
  Detect Electron Framework bundles as **experimental**, with explicit acknowledgement before
  saving high-performance preference. Native/unknown apps remain read-only for GPU selection.
  Default means no additional flag, not force Intel; no force-integrated option.
- APP-03: Atomically persist versioned preferences and extra app paths under ClamOpen application
  support. Corrupt/unknown schema fails closed for writes and is never silently overwritten.
  No changes to signed applications, login agents, browser profiles, Dock or global GPU policy.
- APP-04: Launch only after explicit click, using NSWorkspace argument arrays without a shell.
  Revalidate capability/path and hardware at launch. Refuse if the app or another instance with
  the same bundle ID is already running. Never terminate an app or claim hot switching.
  Only launches from this window use its preferences; legacy Dock launchers remain independent.
- APP-05: Separate saved preference, observed main-process startup flag and actual rendering GPU.
  Only inspect selected main PIDs; never log/retain argv/environment. Missing permissions or
  raced process exit yields unknown. Startup flag is only a request, not rendering proof.
- APP-06: Import a user-selected GPU text report, extracting only unambiguous GL_RENDERER.
  Label the result as a manually assigned, non-live report with import time; do not infer all-app
  GPU usage from the main display, Metal default-device queries, or process flags. Do not store
  the full report. No remote debugging ports or browser automation needed.
- APP-07: Use a separate AppKit window via a menu item; scanning, storage and process queries
  happen on a background queue. Async UI updates preserve selection. No periodic scanning or
  policy enforcement. Opening/refreshing never launches apps, changes GPU policy or requests auth.
- APP-08: Tests exercise fixtures/fakes only: inventory, capability, storage errors, arguments,
  renderer reports and launch gates. Existing safety tests must remain unchanged and pass.

## Approach and alternatives
Recommended: native inventory + explicit adapters, experimental Electron launch requests and
read-only fallback. This expands beyond browsers without inventing a universal override.
Alternative: browser-only launchers would omit the requested desktop-app scope. Patching every
app Info.plist / injecting a GPU override is not chosen: it alters originals and is not a reliable
common contract for Metal/OpenGL/Chromium applications. Blender-style renderer-specific settings
require future per-app adapters; none is promised for applications absent from this machine.

## Architecture
ClamCore owns immutable app/capability models, filesystem inventory, strict settings store,
launch-plan validation, GPU flag and report parsers. A native backend supplies selected-process
argument observations and NSWorkspace launches. ClamOpen owns the window, serialized background
work and main-thread lifecycle/launch gates. All values are labeled by evidence scope.

## Verification / release
TDD for core logic, all Debug and Release suites, app packaging and strict signature/plist checks.
A standalone window harness may render only the new UI using fixture apps and temporary settings;
it must never run AppDelegate, launch a managed application or write pmset. Real managed-app GPU
verification remains manual because it requires quitting/relaunching the user’s applications.
Package v1.3.0 separately in Downloads. Retain existing v1.2.0 package and installed app.

## Evidence
- Sources/ClamOpen/AppDelegate.swift: appendGPUMenu, gpuChangeIsSafe, lifecycle.
- Sources/ClamCore/GPUController.swift: passive hardwareSnapshot; no default-device probe.
- Electron command-line documentation: unsupported flags may have no effect, so experimental
  detection is not labeled verified: https://www.electronjs.org/docs/latest/api/command-line-switches
- Chromium switch: https://chromium.googlesource.com/chromium/src/+/main/gpu/config/gpu_switches.cc
- Activity Monitor graphics-card requirement is not a renderer identity:
  https://support.apple.com/en-ca/guide/activity-monitor/actmntr43697/mac
