import XCTest
@testable import ClamCore

final class ApplicationGPUTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ClamAppGPUTests-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporary)
    }

    @discardableResult
    private func fixture(_ path: String, id: String = "test.native", electron: Bool = false) throws -> URL {
        let app = temporary.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": app.deletingPathExtension().lastPathComponent,
                                   "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        if electron {
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Frameworks/Electron Framework.framework"),
                                                    withIntermediateDirectories: true)
        }
        return app
    }

    func testKnownBrowserAndExperimentalElectronAreDistinctFromNative() throws {
        let chrome = try fixture("Chrome.app", id: "com.google.Chrome")
        let arc = try fixture("Arc.app", id: "company.thebrowser.Browser")
        let ego = try fixture("Ego.app", id: "com.citrolabs.ego.lite")
        let editor = try fixture("Editor.app", id: "test.editor", electron: true)
        let native = try fixture("Native.app")
        let inventory = ApplicationGPUInventory(roots: [])
        XCTAssertEqual(inventory.application(at: chrome)?.support, .browser)
        XCTAssertEqual(inventory.application(at: arc)?.support, .browser)
        XCTAssertEqual(inventory.application(at: ego)?.support, .browser)
        XCTAssertEqual(inventory.application(at: editor)?.support, .experimentalElectron)
        XCTAssertEqual(inventory.application(at: native)?.support, .readOnly)
    }

    func testInventoryScansNestedFoldersButNotAppHelpersOrHiddenFolders() throws {
        try fixture("Apps/Tools/Editor.app", electron: true)
        try fixture("Apps/Tools/Editor.app/Contents/Helper.app")
        try fixture("Apps/.Hidden/Hidden.app")
        try fixture("Apps/Native.app")
        let apps = ApplicationGPUInventory(roots: [temporary.appendingPathComponent("Apps")]).scan()
        XCTAssertEqual(Set(apps.map(\.name)), ["Editor", "Native"])
    }

    func testRunningOrExplicitAppHelperDoesNotPolluteGeneralApplicationList() throws {
        let main = try fixture("Main.app")
        let helper = try fixture("Main.app/Contents/Frameworks/Helper.app", id: "test.helper")
        let apps = ApplicationGPUInventory(roots: [temporary]).scan(additionalURLs: [helper],
            running: [RunningGPUApplication(url: helper, bundleIdentifier: "test.helper", pid: 88)])
        XCTAssertEqual(apps.map(\.id), [main.path])
    }

    func testMergesRunningAndAddedAppsByCanonicalPathNotBundleID() throws {
        let a = try fixture("Apps/One.app", id: "test.same")
        let b = try fixture("Elsewhere/Two.app", id: "test.same")
        let alias = temporary.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: a)
        let inventory = ApplicationGPUInventory(roots: [temporary.appendingPathComponent("Apps")])
        let apps = inventory.scan(additionalURLs: [a, alias], running: [RunningGPUApplication(url: b, bundleIdentifier: "test.same", pid: 42)])
        XCTAssertEqual(apps.count, 2)
        XCTAssertEqual(Set(apps.map(\.id)), [a.path, b.path])
    }

    func testRejectsMalformedOrNonApplicationBundles() throws {
        let missingID = try fixture("Invalid.app")
        try Data("not a plist".utf8).write(to: missingID.appendingPathComponent("Contents/Info.plist"))
        let notApp = try fixture("NotAnApp.bundle")
        let inventory = ApplicationGPUInventory(roots: [temporary])
        XCTAssertNil(inventory.application(at: missingID))
        XCTAssertNil(inventory.application(at: notApp))
        XCTAssertTrue(inventory.scan().isEmpty)
    }

    func testAppIdentityIsCachedEvenIfPathLaterBecomesASymlink() throws {
        let original = try fixture("Original.app")
        let replacement = try fixture("Replacement.app")
        let captured = try XCTUnwrap(ApplicationGPUInventory(roots: []).application(at: original))
        try FileManager.default.moveItem(at: original, to: temporary.appendingPathComponent("Moved.app"))
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: replacement)
        XCTAssertEqual(captured.id, original.path, "Identity reads on the main thread must be pure cached values")
    }

    func testRunningSnapshotDoesNotResolveSymlinksOnTheMainThread() throws {
        let target = try fixture("Target.app")
        let alias = temporary.appendingPathComponent("RunningAlias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        XCTAssertEqual(RunningGPUApplication(url: alias, bundleIdentifier: "test.native", pid: 1).url.path, alias.path)
    }

    private func app(_ support: ApplicationGPUSupport = .browser, id: String = "test.app") -> ApplicationGPUApp {
        ApplicationGPUApp(name: "App ' with spaces", bundleIdentifier: id,
                          url: temporary.appendingPathComponent("App ' with spaces.app"), support: support)
    }

    func testDefaultLaunchUsesNoFlagAndNeverMeansForceIntel() throws {
        let plan = try ApplicationGPULaunchPlan.make(app: app(.readOnly), preference: .automatic,
            running: [], supportsHighPerformance: false, experimentalConfirmed: false)
        XCTAssertEqual(plan.arguments, [])
        XCTAssertEqual(plan.url, app().url)
    }

    func testBrowserLaunchHasOnlyWhitelistedHighPerformanceArgument() throws {
        let plan = try ApplicationGPULaunchPlan.make(app: app(), preference: .highPerformance,
            running: [], supportsHighPerformance: true, experimentalConfirmed: false)
        XCTAssertEqual(plan.arguments, ["--force-high-performance-gpu"])
        XCTAssertEqual(plan.url.path, app().id)
    }

    func testNativeHighPerformancePreferenceIsRejectedEvenIfPreviouslySaved() {
        XCTAssertThrowsError(try ApplicationGPULaunchPlan.make(app: app(.readOnly), preference: .highPerformance,
            running: [], supportsHighPerformance: true, experimentalConfirmed: true))
    }

    func testExperimentalElectronRequiresExplicitConsent() throws {
        XCTAssertThrowsError(try ApplicationGPULaunchPlan.make(app: app(.experimentalElectron), preference: .highPerformance,
            running: [], supportsHighPerformance: true, experimentalConfirmed: false))
        let plan = try ApplicationGPULaunchPlan.make(app: app(.experimentalElectron), preference: .highPerformance,
            running: [], supportsHighPerformance: true, experimentalConfirmed: true)
        XCTAssertEqual(plan.arguments, ["--force-high-performance-gpu"])
    }

    func testUnavailableDualGPUHardwareRejectsHighPerformanceRequest() {
        XCTAssertThrowsError(try ApplicationGPULaunchPlan.make(app: app(), preference: .highPerformance,
            running: [], supportsHighPerformance: false, experimentalConfirmed: true))
    }

    func testRunningSamePathOrBundleIdentifierBlocksLaunchWithoutTerminatingAnything() {
        for running in [RunningGPUApplication(url: app().url, bundleIdentifier: "different.id", pid: 100),
                        RunningGPUApplication(url: temporary.appendingPathComponent("Other.app"), bundleIdentifier: "test.app", pid: 200)] {
            XCTAssertThrowsError(try ApplicationGPULaunchPlan.make(app: app(), preference: .automatic,
                running: [running], supportsHighPerformance: true, experimentalConfirmed: false))
        }
    }

    func testAppReplacementOrChangedCapabilityRequiresRefresh() {
        XCTAssertThrowsError(try ApplicationGPULaunchPlan.validateIdentity(original: app(), current: nil))
        XCTAssertThrowsError(try ApplicationGPULaunchPlan.validateIdentity(original: app(), current: app(.readOnly)))
        XCTAssertThrowsError(try ApplicationGPULaunchPlan.validateIdentity(original: app(), current: app(id: "changed.id")))
        XCTAssertNoThrow(try ApplicationGPULaunchPlan.validateIdentity(original: app(), current: app()))
    }

    func testSettingsRoundtripAndPathIsolationAcrossEqualBundleIdentifiers() throws {
        let store = ApplicationGPUSettingsStore(url: temporary.appendingPathComponent("Private/settings.json"))
        XCTAssertEqual(try store.load(), ApplicationGPUSettings())
        var settings = ApplicationGPUSettings()
        settings.preferences[app().id] = .highPerformance
        settings.experimentalConsent.insert(app().id)
        settings.additionalPaths = [app().id]
        try store.save(settings)
        XCTAssertEqual(try store.load(), settings)
        XCTAssertEqual(try store.load().preference(for: app()), .highPerformance)
        let other = ApplicationGPUApp(name: "Another", bundleIdentifier: "test.app",
                                     url: temporary.appendingPathComponent("Another.app"), support: .browser)
        XCTAssertEqual(try store.load().preference(for: other), .automatic)
        let permissions = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testCorruptSettingsCannotBeSilentlyOverwritten() throws {
        let url = temporary.appendingPathComponent("bad.json")
        let corrupt = Data("{bad".utf8)
        try corrupt.write(to: url)
        let store = ApplicationGPUSettingsStore(url: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(ApplicationGPUSettings()))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testUnknownSchemaAndUnknownPreferenceFailClosed() throws {
        let url = temporary.appendingPathComponent("settings.json")
        let store = ApplicationGPUSettingsStore(url: url)
        for text in ["{\"version\":9,\"preferences\":{},\"additionalPaths\":[],\"experimentalConsent\":[]}",
                     "{\"version\":1,\"preferences\":{\"/A.app\":\"forceIntel\"},\"additionalPaths\":[],\"experimentalConsent\":[]}"] {
            try Data(text.utf8).write(to: url)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(ApplicationGPUSettings()))
        }
    }

    private func argv(_ args: [String], environment: String = "TOKEN=private") -> Data {
        var argc = Int32(args.count)
        var data = withUnsafeBytes(of: &argc) { Data($0) }
        data.append(Data("/Applications/Test.app/Contents/MacOS/Test\0\0".utf8))
        data.append(Data((args.joined(separator: "\0") + "\0" + environment + "\0").utf8))
        return data
    }

    func testObservesExactGPUFlagButNotSubstringOrEnvironment() {
        XCTAssertEqual(ApplicationGPUProcessArguments.highPerformanceRequested(in: argv(["Test", "--force-high-performance-gpu"])), true)
        XCTAssertEqual(ApplicationGPUProcessArguments.highPerformanceRequested(in: argv(["Test", "--example=--force-high-performance-gpu"])), false)
        XCTAssertEqual(ApplicationGPUProcessArguments.highPerformanceRequested(in: argv(["Test"], environment: "--force-high-performance-gpu")), false)
    }

    func testTruncatedOrInvalidProcessArgumentsRemainUnknown() {
        XCTAssertNil(ApplicationGPUProcessArguments.highPerformanceRequested(in: Data()))
        var truncated = argv(["Test", "--force-high-performance-gpu"])
        truncated.removeLast(25)
        XCTAssertNil(ApplicationGPUProcessArguments.highPerformanceRequested(in: truncated))
        XCTAssertNil(ApplicationGPUProcessArguments.highPerformanceRequested(in: Data(repeating: 255, count: 20)))
    }

    func testNativeArgumentObservationForOwnProcessIsReadOnly() {
        XCTAssertEqual(ApplicationGPUBackend.highPerformanceRequest(pid: ProcessInfo.processInfo.processIdentifier), false)
        XCTAssertNil(ApplicationGPUBackend.highPerformanceRequest(pid: -1))
    }

    func testRendererReportAcceptsANGLEButNotTheActiveGPUOrStartupFlagAsProof() {
        let amd = "ANGLE (AMD, ANGLE Metal Renderer: AMD Radeon Pro 5500M, Version 26.7.1)"
        XCTAssertEqual(ApplicationGPURendererReport.renderer(from: "GPU1: Intel *ACTIVE*\nGL_RENDERER     : \(amd)\n"), amd)
        XCTAssertNil(ApplicationGPURendererReport.renderer(from: "GPU0: AMD *ACTIVE*\nCommand Line: --force-high-performance-gpu"))
    }

    func testReportKeepsSoftwareRendererAndRejectsAmbiguousOrOversizeData() {
        XCTAssertEqual(ApplicationGPURendererReport.renderer(from: "GL_RENDERER: Google SwiftShader"), "Google SwiftShader")
        XCTAssertNil(ApplicationGPURendererReport.renderer(from: "GL_RENDERER: Intel\nGL_RENDERER: AMD"))
        XCTAssertNil(ApplicationGPURendererReport.renderer(from: "NOT_GL_RENDERER: AMD"))
        XCTAssertNil(ApplicationGPURendererReport.renderer(from: "GL_RENDERER: AMD\u{1B}[31m"))
        XCTAssertNil(ApplicationGPURendererReport.renderer(from: String(repeating: "x", count: 2_100_000)))
    }

    func testReportFileReaderIsBoundedAndKeepsOnlyRenderer() throws {
        let url = temporary.appendingPathComponent("report.txt")
        try Data("Secret metadata should not be retained\nGL_RENDERER: ANGLE (AMD)\n".utf8).write(to: url)
        XCTAssertEqual(try ApplicationGPUBackend.readRendererReport(at: url), "ANGLE (AMD)")
        try Data(repeating: 120, count: 2_097_153).write(to: url)
        XCTAssertThrowsError(try ApplicationGPUBackend.readRendererReport(at: url))
        try Data([0xff, 0xfe, 0xfd]).write(to: url)
        XCTAssertNil(try ApplicationGPUBackend.readRendererReport(at: url))
        XCTAssertThrowsError(try ApplicationGPUBackend.readRendererReport(at: temporary))
    }
}
