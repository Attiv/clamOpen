import AppKit
import ClamCore
import UniformTypeIdentifiers

/// Independent of display recovery: no timers, pmset writes, app termination or bundle edits.
final class ApplicationGPUWindowController: NSWindowController, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let inventory: ApplicationGPUInventory
    private let store: ApplicationGPUSettingsStore
    private let hardwareCheck: () -> Bool
    private let runningProvider: () -> [RunningGPUApplication]
    private let openApplication: (ApplicationGPULaunchPlan, @escaping (Error?) -> Void) -> Void
    private let canLaunch: () -> Bool
    private let queue = DispatchQueue(label: "com.clamopen.application-gpu", qos: .userInitiated)

    private var apps: [ApplicationGPUApp] = []
    private var visibleApps: [ApplicationGPUApp] = []
    private var running: [RunningGPUApplication] = []
    private var settings = ApplicationGPUSettings()
    private var settingsError: String?
    private var supportsHighPerformance = false
    private var busy = false
    private var generation = 0
    private var observationGeneration = 0
    private var pendingLaunch: UUID?
    private var observers: [NSObjectProtocol] = []
    private var reports: [String: (renderer: String, imported: Date)] = [:]
    private var flagObservation = "未读取"

    private let search = NSSearchField()
    private let filter = NSPopUpButton()
    private let table = NSTableView()
    private let countLabel = NSTextField(labelWithString: "读取应用列表…")
    private let detail = NSTextField(wrappingLabelWithString: "请选择一个应用。")
    private let message = NSTextField(wrappingLabelWithString: "仅查看不会启动应用或更改显卡策略。")
    private let preference = NSPopUpButton()
    private lazy var refreshButton = button("刷新", #selector(refreshInventory))
    private lazy var addButton = button("添加应用…", #selector(addApplication))
    private lazy var saveButton = button("保存偏好", #selector(savePreference))
    private lazy var launchButton = button("按已保存偏好启动", #selector(launchApplication))
    private lazy var reportButton = button("导入 GPU 报告…", #selector(importReport))
    private lazy var revealButton = button("在 Finder 中显示", #selector(revealApplication))

    init(inventory: ApplicationGPUInventory = ApplicationGPUInventory(),
         store: ApplicationGPUSettingsStore = ApplicationGPUSettingsStore(),
         hardwareCheck: @escaping () -> Bool = ApplicationGPUBackend.supportsHighPerformanceLaunch,
         runningProvider: @escaping () -> [RunningGPUApplication] = ApplicationGPUBackend.runningApplications,
         openApplication: @escaping (ApplicationGPULaunchPlan, @escaping (Error?) -> Void) -> Void = ApplicationGPUBackend.open,
         canLaunch: @escaping () -> Bool) {
        self.inventory = inventory
        self.store = store
        self.hardwareCheck = hardwareCheck
        self.runningProvider = runningProvider
        self.openApplication = openApplication
        self.canLaunch = canLaunch
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "ClamOpen · 应用显卡管理"
        window.minSize = NSSize(width: 980, height: 760)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
        window.center()
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                guard let self, self.window?.isVisible == true else { return }
                self.running = self.runningProvider()
                self.applyFilter()
            })
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver) }

    func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshInventory()
    }

    /// Invalidates the intent permanently, even if recovery finishes before IO returns.
    func cancelPendingLaunch() {
        guard pendingLaunch != nil else { return }
        pendingLaunch = nil
        busy = false
        updateControls()
        showMessage("显示恢复、睡眠或退出事件已取消此前的启动请求；需要时请重新点击启动。")
    }

    /// Cached control state only; safe to call from the display watchdog.
    func updateLaunchAvailability() {
        if window?.isVisible == true { updateControls() }
    }

    func windowWillClose(_ notification: Notification) {
        cancelPendingLaunch()
        generation += 1 // A closed window cannot leave a queued launch behind.
        observationGeneration += 1
        busy = false
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        search.placeholderString = "搜索应用名称、标识或路径"
        search.delegate = self
        filter.addItems(withTitles: ["全部应用", "可设置／实验性", "正在运行"])
        filter.target = self
        filter.action = #selector(filterChanged)
        let top = NSStackView(views: [search, filter, refreshButton, addButton])
        top.spacing = 10
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true

        table.delegate = self
        table.dataSource = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.rowHeight = 28
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (id, title, width) in [("app", "应用", 330.0), ("running", "运行状态", 130.0),
                                   ("support", "适配能力", 220.0), ("preference", "已保存启动偏好", 270.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "app" ? 200 : 110
            table.addTableColumn(column)
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        detail.font = .systemFont(ofSize: 12)
        detail.isSelectable = true
        detail.maximumNumberOfLines = 9
        detail.heightAnchor.constraint(greaterThanOrEqualToConstant: 125).isActive = true
        preference.addItems(withTitles: [ApplicationGPUPreference.automatic.title, "优先高性能 GPU（本机 AMD）"])
        preference.autoenablesItems = false
        let actions = NSStackView(views: [preference, saveButton, launchButton, reportButton, revealButton])
        actions.spacing = 8
        let notes = NSTextField(wrappingLabelWithString: "偏好仅用于从本窗口启动；原 Dock／Finder 入口和此前的独显启动器不会改变。更改后请先手动完全退出应用。\n“默认”不保证使用 Intel。Electron 为实验性请求，可能被应用忽略。主屏 GPU、启动参数和历史报告都不是逐应用实时渲染状态。")
        notes.font = .systemFont(ofSize: 11)
        notes.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: 12)
        message.maximumNumberOfLines = 3
        message.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: 11)

        let layout = NSStackView(views: [top, countLabel, scroll, detail, actions, notes, message])
        layout.orientation = .vertical
        layout.alignment = .leading
        layout.spacing = 12
        layout.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            layout.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            layout.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            layout.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        for view in [top, scroll, detail, notes, message] { view.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        updateControls()
    }

    private var selected: ApplicationGPUApp? {
        visibleApps.indices.contains(table.selectedRow) ? visibleApps[table.selectedRow] : nil
    }

    private func instances(of app: ApplicationGPUApp) -> [RunningGPUApplication] {
        running.filter { $0.url.path == app.id }
    }

    private func anyInstance(of app: ApplicationGPUApp) -> Bool {
        running.contains { $0.url.path == app.id || $0.bundleIdentifier == app.bundleIdentifier }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleApps.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleApps.indices.contains(row), let column = tableColumn else { return nil }
        let app = visibleApps[row]
        let text: String
        switch column.identifier.rawValue {
        case "app": text = app.name
        case "running": text = !instances(of: app).isEmpty ? "运行中" : (anyInstance(of: app) ? "同标识实例（路径未确认）" : "未运行")
        case "support": text = app.support.title
        default: text = settings.preference(for: app).title
        }
        let cell = (tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTextField)
            ?? NSTextField(labelWithString: "")
        cell.identifier = column.identifier
        cell.stringValue = text
        cell.lineBreakMode = .byTruncatingTail
        cell.toolTip = column.identifier.rawValue == "app" ? app.id : text
        cell.textColor = app.support == .experimentalElectron && column.identifier.rawValue == "support" ? .systemOrange : .labelColor
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
    func controlTextDidChange(_ obj: Notification) { applyFilter() }
    @objc private func filterChanged() { applyFilter() }

    private func applyFilter(selectID: String? = nil) {
        let retained = selectID ?? selected?.id
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleApps = apps.filter { app in
            (query.isEmpty || [app.name, app.bundleIdentifier, app.id].contains(where: { $0.localizedCaseInsensitiveContains(query) }))
                && (filter.indexOfSelectedItem != 1 || app.support.allowsHighPerformanceRequest)
                && (filter.indexOfSelectedItem != 2 || anyInstance(of: app))
        }
        table.reloadData()
        if let retained, let row = visibleApps.firstIndex(where: { $0.id == retained }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
        countLabel.stringValue = "显示 \(visibleApps.count) / \(apps.count) 个应用 · 高性能请求\(supportsHighPerformance ? "可用（AMD）" : "不可用")"
        updateSelection()
    }

    private func updateControls() {
        let editable = !busy && settingsError == nil
        let hasPreferenceControl = selected.map {
            $0.support.allowsHighPerformanceRequest || settings.preference(for: $0) == .highPerformance
        } == true
        refreshButton.isEnabled = !busy
        addButton.isEnabled = editable
        preference.isEnabled = editable && hasPreferenceControl
        preference.item(at: 1)?.title = supportsHighPerformance ? "优先高性能 GPU（本机 AMD）" : "优先高性能 GPU（此设备不可用）"
        preference.item(at: 1)?.isEnabled = supportsHighPerformance && selected?.support.allowsHighPerformanceRequest == true
        saveButton.isEnabled = editable && hasPreferenceControl
        launchButton.isEnabled = editable && selected.map { !anyInstance(of: $0) } == true && canLaunch()
        reportButton.isEnabled = !busy && selected != nil
        revealButton.isEnabled = selected != nil
    }

    private func showMessage(_ text: String, error: Bool = false) {
        message.stringValue = text
        message.textColor = error ? .systemRed : .secondaryLabelColor
    }

    private func updateSelection() {
        observationGeneration += 1
        let token = observationGeneration
        guard let app = selected else {
            detail.stringValue = "请选择一个应用。原生／未知应用可加入列表，但没有已适配的选卡接口时不提供高性能设置。"
            updateControls()
            return
        }
        preference.selectItem(at: settings.preference(for: app) == .automatic ? 0 : 1)
        let processes = instances(of: app)
        flagObservation = processes.isEmpty
            ? (anyInstance(of: app) ? "存在同标识实例，路径归属未知；需先退出" : "未运行")
            : "读取所选应用主进程参数中…"
        renderDetail(app)
        updateControls()
        guard !processes.isEmpty else { return }
        queue.async { [weak self] in
            let observations = processes.map { process -> String in
                let value = ApplicationGPUBackend.highPerformanceRequest(pid: process.pid)
                let text = value.map { $0 ? "带高性能请求参数" : "未发现外部高性能参数" } ?? "未知（权限或进程变化）"
                return "PID \(process.pid)：\(text)"
            }.joined(separator: "；")
            DispatchQueue.main.async {
                guard let self, self.observationGeneration == token, self.selected?.id == app.id else { return }
                let current = self.runningProvider().filter { $0.url.path == app.id }.map(\.pid).sorted()
                guard current == processes.map(\.pid).sorted() else {
                    self.running = self.runningProvider()
                    self.applyFilter()
                    return
                }
                self.flagObservation = observations
                self.renderDetail(app)
            }
        }
    }

    private func renderDetail(_ app: ApplicationGPUApp) {
        var text = "\(app.name) · \(app.support.title)\n\(app.id)\n主进程启动参数：\(flagObservation)\n实际渲染 GPU：未知。应用内部设置可能不出现在外部启动参数里。"
        if let report = reports[app.id] {
            let date = DateFormatter.localizedString(from: report.imported, dateStyle: .short, timeStyle: .medium)
            text += "\n手动归属的报告 GL_RENDERER（非实时，导入于 \(date)）：\(report.renderer)"
        } else {
            text += "\n可导入所选应用的 GPU 文本报告查看 GL_RENDERER；不代表整个应用的所有渲染任务。"
        }
        detail.stringValue = text
        detail.toolTip = text
    }

    @objc private func refreshInventory() {
        guard !busy else { return }
        busy = true
        generation += 1
        let token = generation
        let previous = settings
        let retained = selected?.id
        running = runningProvider()
        let processes = running
        showMessage("正在读取应用列表和已保存偏好…")
        updateControls()
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.store.load() }
            let loaded = (try? result.get()) ?? previous
            let apps = self.inventory.scan(additionalURLs: loaded.additionalPaths.map { URL(fileURLWithPath: $0) }, running: processes)
            let hardware = self.hardwareCheck()
            DispatchQueue.main.async {
                guard self.generation == token else { return }
                self.busy = false
                self.apps = apps
                self.supportsHighPerformance = hardware
                switch result {
                case .success(let settings): self.settings = settings; self.settingsError = nil
                case .failure(let error): self.settingsError = error.localizedDescription
                }
                self.running = self.runningProvider()
                self.applyFilter(selectID: self.selected?.id ?? retained)
                self.showMessage(self.settingsError ?? "列表已刷新。仅在你点击启动时附加已保存参数；不会改原应用。", error: self.settingsError != nil)
            }
        }
    }

    @objc private func savePreference() {
        guard !busy, settingsError == nil, let app = selected else { return }
        let value: ApplicationGPUPreference = preference.indexOfSelectedItem == 1 ? .highPerformance : .automatic
        let confirmed = settings.experimentalConsent.contains(app.id)
        if app.support == .experimentalElectron && value == .highPerformance && !confirmed {
            let alert = NSAlert()
            alert.messageText = "此应用的高性能启动为实验性功能"
            alert.informativeText = "仅传入 --force-high-performance-gpu。应用可能忽略或覆盖它，不能保证使用 AMD。不会结束运行中的应用；保存后请手动退出，再从本窗口启动。"
            alert.addButton(withTitle: "了解并保存实验性偏好")
            alert.addButton(withTitle: "取消")
            guard let window else { return }
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn, self?.window?.isVisible == true {
                    self?.persistPreference(app: app, value: value, confirmed: true)
                }
            }
        } else { persistPreference(app: app, value: value, confirmed: confirmed) }
    }

    private func persistPreference(app: ApplicationGPUApp, value: ApplicationGPUPreference, confirmed: Bool) {
        guard !busy, settingsError == nil else { return }
        do {
            try ApplicationGPULaunchPlan.validatePreference(app: app, preference: value,
                supportsHighPerformance: supportsHighPerformance, experimentalConfirmed: confirmed)
        } catch { showMessage(error.localizedDescription, error: true); return }
        var updated = settings
        if value == .automatic { updated.preferences.removeValue(forKey: app.id); updated.experimentalConsent.remove(app.id) }
        else {
            updated.preferences[app.id] = value
            if confirmed { updated.experimentalConsent.insert(app.id) }
        }
        persist(updated, selectedID: app.id, validation: {
            try ApplicationGPULaunchPlan.validateIdentity(original: app, current: self.inventory.application(at: app.url))
        })
    }

    private func persist(_ updated: ApplicationGPUSettings, selectedID: String, validation: @escaping () throws -> Void = {}) {
        busy = true
        let token = generation
        updateControls()
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try validation(); try self.store.save(updated) }
            DispatchQueue.main.async {
                guard self.generation == token else { return }
                self.busy = false
                switch result {
                case .success:
                    self.settings = updated
                    self.applyFilter(selectID: self.selected?.id ?? selectedID)
                    self.showMessage("偏好已保存，但没有切换运行中的应用。请手动完全退出后，从本窗口启动。")
                case .failure(let error):
                    self.showMessage(error.localizedDescription, error: true)
                    self.updateControls()
                }
            }
        }
    }

    @objc private func launchApplication() {
        guard !busy, settingsError == nil, let app = selected, canLaunch() else { return }
        let value = settings.preference(for: app)
        guard (preference.indexOfSelectedItem == 1) == (value == .highPerformance) else {
            showMessage("当前选择尚未保存。请先保存偏好，再启动。", error: true)
            return
        }
        busy = true
        let token = generation
        let intent = UUID()
        pendingLaunch = intent
        let confirmed = settings.experimentalConsent.contains(app.id)
        updateControls()
        showMessage("正在核对应用和运行状态…")
        queue.async { [weak self] in
            guard let self else { return }
            let identity = Result { try ApplicationGPULaunchPlan.validateIdentity(original: app,
                current: self.inventory.application(at: app.url)) }
            let hardware = self.hardwareCheck()
            DispatchQueue.main.async {
                guard self.generation == token, self.pendingLaunch == intent, self.window?.isVisible == true else { return }
                do {
                    guard self.canLaunch() else {
                        self.pendingLaunch = nil
                        self.busy = false
                        self.updateControls()
                        self.showMessage("显示器正在睡眠、恢复或应用正在退出，已取消启动。", error: true)
                        return
                    }
                    try identity.get()
                    let plan = try ApplicationGPULaunchPlan.make(app: app, preference: value,
                        running: self.runningProvider(), supportsHighPerformance: hardware, experimentalConfirmed: confirmed)
                    self.pendingLaunch = nil // Once submitted, do not claim it can be rolled back.
                    self.openApplication(plan) { [weak self] error in
                        guard let self, self.generation == token else { return }
                        self.busy = false
                        self.running = self.runningProvider()
                        self.applyFilter(selectID: app.id)
                        self.showMessage(error?.localizedDescription ?? "启动请求已提交（\(value.title)）。参数不保证实际选卡，请用应用诊断确认。", error: error != nil)
                    }
                } catch {
                    self.pendingLaunch = nil
                    self.busy = false
                    self.running = self.runningProvider()
                    self.applyFilter(selectID: app.id)
                    self.showMessage(error.localizedDescription, error: true)
                }
            }
        }
    }

    @objc private func addApplication() {
        guard !busy, settingsError == nil, let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "添加应用到列表；不会移动、修改或启动该应用。"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            self.busy = true
            self.updateControls()
            let token = self.generation
            self.queue.async {
                let app = self.inventory.application(at: url)
                DispatchQueue.main.async {
                    guard self.generation == token else { return }
                    self.busy = false
                    guard let app else { self.showMessage("无法读取有效的 .app 应用信息。", error: true); self.updateControls(); return }
                    var updated = self.settings
                    if !updated.additionalPaths.contains(app.id) { updated.additionalPaths.append(app.id) }
                    if !self.apps.contains(where: { $0.id == app.id }) {
                        self.apps.append(app)
                        self.apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    }
                    self.persist(updated, selectedID: app.id)
                }
            }
        }
    }

    @objc private func importReport() {
        guard !busy, let app = selected, let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "log") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.message = "请选取属于「\(app.name)」的 GPU 文本报告。归属由你指定，不会自动验证来源；结果是历史报告，不是实时状态。浏览器可在 chrome://gpu 选择 Download Report。"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            self.busy = true
            self.updateControls()
            let token = self.generation
            self.queue.async {
                let result = Result { try ApplicationGPUBackend.readRendererReport(at: url) }
                DispatchQueue.main.async {
                    guard self.generation == token else { return }
                    self.busy = false
                    switch result {
                    case .success(.some(let renderer)):
                        self.reports[app.id] = (renderer, Date())
                        if self.selected?.id == app.id { self.renderDetail(app) }
                        self.showMessage("已读取报告 GL_RENDERER；报告由你归属到此应用，非实时检测，仅保留在本次 ClamOpen 运行期间。")
                    case .success(.none): self.showMessage("报告没有唯一、可识别的 GL_RENDERER。未把 GPU ACTIVE 标记或启动参数当作实际渲染器。", error: true)
                    case .failure(let error): self.showMessage("报告读取失败（UTF-8 文本，最大 2 MB）：\(error.localizedDescription)", error: true)
                    }
                    self.updateControls()
                }
            }
        }
    }

    @objc private func revealApplication() {
        if let app = selected { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
    }
}
