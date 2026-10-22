// Standalone fixture-only AppKit harness. Never link or run ClamOpen's AppDelegate.
import AppKit
import ClamCore

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("PASS: \(message)")
}

func waitUntil(_ message: String, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(8)
    while !condition() && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    require(condition(), message)
}

func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ClamGPUWindowHarness-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

func fixture(_ name: String, electron: Bool) throws {
    let url = temporary.appendingPathComponent(name + ".app")
    try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "fixture.\(name)",
                               "CFBundleExecutable": "NeverExecute", "CFBundleName": name]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: url.appendingPathComponent("Contents/Info.plist"))
    if electron {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework"),
                                               withIntermediateDirectories: true)
    }
}
try fixture("Editor Fixture", electron: true)
try fixture("Native Fixture", electron: false)

let lock = NSLock()
var blockingHardware = false
let entered = DispatchSemaphore(value: 0)
let release = DispatchSemaphore(value: 0)
var launchCount = 0
var safeToLaunch = true
let store = ApplicationGPUSettingsStore(url: temporary.appendingPathComponent("Settings/preferences.json"))
let controller = ApplicationGPUWindowController(inventory: ApplicationGPUInventory(roots: [temporary]), store: store,
    hardwareCheck: {
        lock.lock(); let block = blockingHardware; lock.unlock()
        if block { entered.signal(); _ = release.wait(timeout: .now() + 10) }
        return true
    }, runningProvider: { [] }, openApplication: { plan, completion in
        require(plan.arguments == ["--force-high-performance-gpu"], "fake launch receives exact GPU argument")
        launchCount += 1
        completion(nil)
    }, canLaunch: { safeToLaunch })
controller.present()
let window = controller.window!
let content = window.contentView!
let table = views(content).compactMap { $0 as? NSTableView }.first!
func button(_ title: String) -> NSButton { views(content).compactMap { $0 as? NSButton }.first { $0.title == title }! }
let preference = views(content).compactMap { $0 as? NSPopUpButton }.first { $0.numberOfItems == 2 }!
waitUntil("fixture inventory loads", { table.numberOfRows == 2 && button("刷新").isEnabled })
let search = views(content).compactMap { $0 as? NSSearchField }.first!
search.stringValue = "native"
controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
require(table.numberOfRows == 1, "search filters fixture applications")
search.stringValue = ""
controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
let filter = views(content).compactMap { $0 as? NSPopUpButton }.first { $0.numberOfItems == 3 }!
filter.selectItem(at: 1)
NSApp.sendAction(filter.action!, to: filter.target, from: filter)
require(table.numberOfRows == 1, "capability filter includes Electron and excludes read-only native apps")
filter.selectItem(at: 0)
NSApp.sendAction(filter.action!, to: filter.target, from: filter)
table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
require(preference.item(at: 1)?.isEnabled == false, "native app cannot request unsupported GPU selection")
require(!button("保存偏好").isEnabled, "read-only native app does not offer a meaningless GPU save")
table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
require(preference.item(at: 1)?.isEnabled == true, "Electron candidate offers experimental preference")
preference.selectItem(at: 1)
button("保存偏好").performClick(nil)
waitUntil("experimental save requires acknowledgement", { window.attachedSheet != nil })
let confirm = views(window.attachedSheet!.contentView!).compactMap { $0 as? NSButton }
    .first { $0.title == "了解并保存实验性偏好" }!
confirm.performClick(nil)
waitUntil("preference persists without launching", {
    button("刷新").isEnabled && (try? store.load().preferences.values.first) == .highPerformance
})
require(launchCount == 0, "saving never launches an app")

// Reproduce recovery completing before the queued validation returns.
lock.lock(); blockingHardware = true; lock.unlock()
button("按已保存偏好启动").performClick(nil)
var didEnter = false
waitUntil("launch validation reaches controlled background checkpoint", {
    if !didEnter { didEnter = entered.wait(timeout: .now()) == .success }
    return didEnter
})
safeToLaunch = false
controller.cancelPendingLaunch()
safeToLaunch = true
controller.updateLaunchAvailability()
lock.lock(); blockingHardware = false; lock.unlock()
release.signal()
let quiet = Date().addingTimeInterval(0.4)
while Date() < quiet { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
require(launchCount == 0, "recovery permanently cancels queued launch even after safety becomes true")

button("按已保存偏好启动").performClick(nil)
waitUntil("explicit later launch is permitted", { launchCount == 1 && button("刷新").isEnabled })
require(!FileManager.default.fileExists(atPath: temporary.appendingPathComponent("Editor Fixture.app/Contents/MacOS/NeverExecute").path),
        "fixture apps have no executable and native launcher was never called")

lock.lock(); blockingHardware = true; lock.unlock()
button("按已保存偏好启动").performClick(nil)
didEnter = false
waitUntil("second queued launch reaches checkpoint", {
    if !didEnter { didEnter = entered.wait(timeout: .now()) == .success }
    return didEnter
})
window.close()
lock.lock(); blockingHardware = false; lock.unlock()
release.signal()
let closedDeadline = Date().addingTimeInterval(0.3)
while Date() < closedDeadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
require(launchCount == 1, "closing the window cancels its queued launch")
controller.present()
waitUntil("window reopens and reloads saved preferences", { button("刷新").isEnabled && table.numberOfRows == 2 })
table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

if CommandLine.arguments.count > 1 {
    content.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: output)!
        context.cgContext.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.cgContext.fill(CGRect(x: 0, y: 0, width: output.pixelsWide, height: output.pixelsHigh))
        context.cgContext.draw(bitmap.cgImage!, in: CGRect(x: 0, y: 0, width: output.pixelsWide, height: output.pixelsHigh))
        try output.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("PASS: rendered fixture-only window")
    } else { require(false, "window can render") }
}
window.close()
try Data("{corrupt".utf8).write(to: store.url)
controller.present()
waitUntil("corrupt settings refresh completes", { button("刷新").isEnabled })
table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
require(!button("保存偏好").isEnabled && !button("按已保存偏好启动").isEnabled,
        "corrupt settings disable writes and launches instead of using stale preferences")
let corruptContents = try String(contentsOf: store.url, encoding: .utf8)
require(corruptContents == "{corrupt", "corrupt fixture settings are not overwritten")
window.close()
print("All fixture-only window checks passed.")
