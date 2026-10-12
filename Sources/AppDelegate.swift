import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config: ConfigStore
    private var statuses: [String: ProjectStatus] = [:]
    private var statusError: ScriptError?
    /// Projects we just launched; panes sit at a shell prompt for a moment before their servers start.
    private var launchedAt: [String: Date] = [:]
    private var iconCache: [String: NSImage] = [:]
    /// Project rows of the menu currently on screen, refreshed in place as status arrives.
    private var visibleRows: [String: NSMenuItem] = [:]
    private var polling = false
    private var pickerPendingActivation = false
    private var pickerIsOpen = false
    /// Set when the picker's chosen action opens the editor, so the picker doesn't hide the app on the way out.
    private var openEditorAfterPicker = false
    private var editor: EditorWindowController?
    /// Projects being cloned from GitHub right now.
    private var installing: Set<String> = []
    private var pollCompletions: [() -> Void] = []
    /// Bumped when the config folder changes, so results of a scan started before then are ignored.
    private var scanGeneration = 0
    private var configPullInFlight = false
    private let pollQueue = DispatchQueue(label: "ProjectLauncher.poll")
    /// Only touched on `pollQueue`.
    nonisolated(unsafe) private let scanner = StatusScanner()

    private static let startupGrace: TimeInterval = 30
    private static let pollInterval: TimeInterval = 4
    private static let configPullInterval: TimeInterval = 300
    private static let cursorURL = URL(fileURLWithPath: "/Applications/Cursor.app")

    override init() {
        config = ConfigStore.current()
        super.init()
        NotificationCenter.default.addObserver(
            forName: .configFolderDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.configFolderDidChange() }
        }
    }

    private func configFolderDidChange() {
        config = ConfigStore.current()
        config.reloadIfChanged()
        iconCache.removeAll()
        statuses = [:]
        scanGeneration += 1  // A scan still in flight belongs to the old folder; its results are dropped.
        refresh(fresh: true)
    }

    /// Projects that are turned on and present on this Mac, i.e. the ones worth asking iTerm about.
    private var scannableProjects: [Project] {
        config.projects.filter { $0.isEnabled && FileManager.default.fileExists(atPath: $0.pathURL.path) }
    }

    // MARK: - App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        config.reloadIfChanged()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Common modes keep status fresh while a menu is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        let pullTimer = Timer(timeInterval: Self.configPullInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pullConfig() }
        }
        RunLoop.main.add(pullTimer, forMode: .common)
        pullConfig()

        // Opened by a click on the Dock icon: show the picker once status is in. Relaunches pass --background.
        let fromDock = !CommandLine.arguments.contains("--background")
        guard config.exists else {
            if fromDock { editProjects() }
            return
        }
        refresh(fresh: true) { [weak self] in if fromDock { self?.showPickerWhenActive() } }
    }

    /// A menu popped before launch activation completes is dismissed immediately, so wait for it.
    private func showPickerWhenActive() {
        if NSApp.isActive { return showPicker() }
        pickerPendingActivation = true
        NSApp.activate()
        // If macOS declines the activation, don't let the request pop a picker at some random later moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.pickerPendingActivation = false }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard pickerPendingActivation else { return }
        pickerPendingActivation = false
        DispatchQueue.main.async { self.showPicker() }
    }

    /// Left-click on the Dock icon while we're running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        pickerPendingActivation = false  // This click shows the picker; a pending launch request mustn't add another.
        DispatchQueue.main.async { self.showPicker() }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        editor?.confirmDiscardingChanges() == false ? .terminateCancel : .terminateNow
    }

    /// Right-click (or long-press) on the Dock icon.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        refresh(fresh: true)
        return buildMenu(forDock: true)
    }

    // MARK: - Config sync

    /// Brings in config edits pushed from another Mac. The picker re-reads the file on its next poll, and an open
    /// editor reloads if it has no unsaved changes.
    private func pullConfig() {
        guard config.exists, !configPullInFlight, editor?.hasUnsavedChanges != true else { return }
        configPullInFlight = true
        let folder = config.baseURL
        let file = config.fileURL
        DispatchQueue.global(qos: .utility).async {
            let before = try? Data(contentsOf: file)
            let result = GitHub.pull(folder)
            let changed = (try? Data(contentsOf: file)) != before
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.configPullInFlight = false
                    if case .failure(let failure) = result {
                        NSLog("ProjectLauncher: config pull failed: \(failure.message)")
                    } else if changed {
                        NotificationCenter.default.post(name: .configDidChangeOnDisk, object: nil)
                    }
                }
            }
        }
    }

    // MARK: - Status

    /// `fresh` re-examines every iTerm window; background polls only revisit known project windows.
    private func refresh(fresh: Bool = false, then completion: (() -> Void)? = nil) {
        if let completion { pollCompletions.append(completion) }
        guard !polling else { return }
        polling = true
        if config.reloadIfChanged() { iconCache.removeAll() }
        let projects = scannableProjects
        let generation = scanGeneration
        pollQueue.async {
            let result = self.scanner.scan(projects, fresh: fresh)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.apply(result, generation: generation) }
            }
        }
    }

    private func apply(_ result: Result<[String: ProjectStatus], ScriptError>, generation: Int) {
        polling = false
        guard generation == scanGeneration else {
            refresh(fresh: true)  // Stale: started before the config folder changed. Completions wait for this one.
            return
        }
        switch result {
        case .success(let updated):
            statusError = nil
            statuses = updated
        case .failure(let error):
            statusError = error
        }
        for (id, status) in statuses where status.health == .running {
            launchedAt[id] = nil
        }

        let running = Set(statuses.values.compactMap(\.windowID)).count
        NSApp.dockTile.badgeLabel = running > 0 ? "\(running)" : nil
        refreshVisibleRows()

        let completions = pollCompletions
        pollCompletions = []
        completions.forEach { $0() }
    }

    private func status(for project: Project) -> ProjectStatus {
        if installing.contains(project.id) { return ProjectStatus(health: .installing) }
        if !FileManager.default.fileExists(atPath: project.pathURL.path) { return ProjectStatus(health: .missing) }
        var status = statuses[project.id] ?? ProjectStatus()
        if let launched = launchedAt[project.id],
           Date().timeIntervalSince(launched) < Self.startupGrace,
           status.health != .running {
            status.health = .starting
        }
        return status
    }

    // MARK: - Menus

    private func showPicker() {
        // A status result delivered while the picker is tracking (e.g. the launch-time completion) must not
        // open a second picker inside the first.
        guard !pickerIsOpen else { return }
        let menu = buildMenu(forDock: false)
        NSApp.activate()
        refresh(fresh: true)
        pickerIsOpen = true
        menu.popUp(positioning: nil, at: pickerOrigin(for: menu), in: nil)
        pickerIsOpen = false
        visibleRows = [:]
        if openEditorAfterPicker {
            // Still the active app, so the editor can come forward. Hiding first would hand focus away for good:
            // macOS only lets an app reactivate when the active app yields to it.
            openEditorAfterPicker = false
            presentEditor()
        } else if editor?.window?.isVisible != true {
            // Hand focus back to whatever was frontmost (or to the app an action just opened).
            NSApp.hide(nil)
        }
    }

    /// Places the picker just above (or beside) the Dock, under the pointer.
    private func pickerOrigin(for menu: NSMenu) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
            return mouse
        }
        let frame = screen.frame, visible = screen.visibleFrame, size = menu.size
        var origin = NSPoint(x: mouse.x - 24, y: mouse.y)
        if visible.minX > frame.minX + 8 {
            origin = NSPoint(x: visible.minX + 4, y: mouse.y + size.height / 2)
        } else if visible.maxX < frame.maxX - 8 {
            origin = NSPoint(x: visible.maxX - size.width - 4, y: mouse.y + size.height / 2)
        } else {
            // Bottom Dock; when it auto-hides the visible frame doesn't account for it, so clear the pointer.
            let dockTop = visible.minY > frame.minY + 8 ? visible.minY : mouse.y + 40
            origin.y = dockTop + size.height + 4
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(origin.y, visible.maxY)
        return origin
    }

    /// The Dock draws its own copy of the menu without images or subtitles, so there status goes in the text.
    private func buildMenu(forDock: Bool) -> NSMenu {
        if config.reloadIfChanged() { iconCache.removeAll() }
        let menu = NSMenu()
        menu.autoenablesItems = false
        if !forDock { visibleRows = [:] }

        guard config.exists else {
            menu.addItem(actionItem("Set Up Project Launcher…", symbol: "gearshape", action: #selector(editProjects)))
            if !forDock {
                menu.addItem(actionItem("Quit Project Launcher", symbol: "power", action: #selector(NSApplication.terminate(_:)), target: NSApp))
            }
            return menu
        }
        if let error = config.error {
            menu.addItem(disabledItem(error))
        }
        let enabled = config.projects.filter(\.isEnabled)
        if enabled.isEmpty, config.error == nil {
            menu.addItem(disabledItem("No projects turned on"))
        }
        for project in enabled {
            let row = NSMenuItem(title: project.name, action: nil, keyEquivalent: "")
            if #available(macOS 27, *) {
                // macOS 27 hides menu images by default; the logos are how projects are told apart.
                row.preferredImageVisibility = .visible
            }
            row.submenu = NSMenu()
            decorate(row, for: project)
            if forDock {
                let status = status(for: project)
                row.title = "\(status.health.emoji)  \(project.name)"
                row.submenu?.insertItem(disabledItem(status.summary), at: 0)
                row.submenu?.insertItem(.separator(), at: 1)
            } else {
                visibleRows[project.id] = row
            }
            menu.addItem(row)
        }

        menu.addItem(.separator())
        if let statusError {
            let item = actionItem(
                statusError.isNotAuthorized ? "Allow Access to iTerm…" : "Can't Read iTerm Status",
                symbol: "exclamationmark.triangle", action: #selector(openAutomationSettings)
            )
            item.subtitle = statusError.isNotAuthorized ? "Needed to show what's running" : statusError.message
            menu.addItem(item)
        }
        menu.addItem(actionItem("Edit Projects…", symbol: "slider.horizontal.3", action: #selector(editProjects)))
        if !forDock {
            menu.addItem(actionItem("Quit Project Launcher", symbol: "power", action: #selector(NSApplication.terminate(_:)), target: NSApp))
        }
        return menu
    }

    /// Applies current status to a project row. Safe to call while the menu is open.
    private func decorate(_ row: NSMenuItem, for project: Project, rebuildActions: Bool = true) {
        let status = status(for: project)
        row.image = icon(for: project, health: status.health)
        row.subtitle = status.summary
        row.toolTip = project.description

        guard let submenu = row.submenu else { return }
        let kind = actionKind(for: status)
        // Rebuild actions only when they'd change, so an open submenu isn't disturbed needlessly.
        if submenu.items.isEmpty || (rebuildActions && submenu.title != kind.rawValue) {
            fillActions(submenu, for: project, kind: kind)
        }
        if kind == .running || kind == .stopped, let primary = submenu.items.first {
            primary.subtitle = kind == .running ? status.summary : project.description
        }
    }

    private enum ActionKind: String {
        case running, stopped, missing, installing
    }

    private func actionKind(for status: ProjectStatus) -> ActionKind {
        switch status.health {
        case .missing: .missing
        case .installing: .installing
        default: status.windowID != nil ? .running : .stopped
        }
    }

    private func fillActions(_ submenu: NSMenu, for project: Project, kind: ActionKind) {
        submenu.removeAllItems()
        submenu.autoenablesItems = false
        submenu.title = kind.rawValue
        @discardableResult func add(_ title: String, _ symbol: String, _ action: Selector) -> NSMenuItem {
            let item = actionItem(title, symbol: symbol, action: action)
            item.representedObject = project.id
            submenu.addItem(item)
            return item
        }

        switch kind {
        case .running:
            add("Switch to Window", "macwindow.and.cursorarrow", #selector(switchTo(_:)))
            add("Restart", "arrow.clockwise", #selector(restart(_:)))
            add("Stop", "stop.circle", #selector(stop(_:)))
        case .stopped:
            add("Launch", "play.fill", #selector(launch(_:)))
        case .missing:
            if let repo = project.repo {
                add("Install from GitHub", "arrow.down.circle", #selector(install(_:))).subtitle =
                    "\(repo) → \(project.path)"
            } else {
                submenu.addItem(disabledItem("Add its GitHub repo in Edit Projects to install it"))
            }
            submenu.addItem(.separator())
            add("Edit Projects…", "slider.horizontal.3", #selector(editProjects))
            return
        case .installing:
            submenu.addItem(disabledItem("Cloning \(project.repo ?? project.name)…"))
            return
        }
        submenu.addItem(.separator())
        if let url = project.url {
            add("Open in Browser", "safari", #selector(openInBrowser(_:))).subtitle =
                url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        }
        if FileManager.default.fileExists(atPath: Self.cursorURL.path) {
            add("Open in Cursor", "chevron.left.forwardslash.chevron.right", #selector(openInCursor(_:)))
        }
        add("Reveal in Finder", "folder", #selector(revealInFinder(_:)))
    }

    private func actionItem(_ title: String, symbol: String, action: Selector, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target ?? self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        let edit = actionItem("Edit Projects…", symbol: "slider.horizontal.3", action: #selector(editProjects))
        edit.keyEquivalent = ","
        appMenu.addItem(edit)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide Project Launcher", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Quit Project Launcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // Text fields in the editor rely on these for undo and the clipboard shortcuts.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        NSApp.windowsMenu = windowMenu

        let main = NSMenu()
        for submenu in [appMenu, editMenu, windowMenu] {
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            main.addItem(item)
        }
        return main
    }

    // MARK: - Icons

    private func icon(for project: Project, health: Health) -> NSImage {
        // The modification date keeps a replaced logo file from being served stale.
        let iconURL = config.iconURL(for: project)
        let modified = iconURL.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
        let key = "\(project.id)|\(health)|\(modified?.timeIntervalSince1970 ?? 0)"
        if let cached = iconCache[key] { return cached }

        let base = iconURL.flatMap { NSImage(contentsOf: $0) } ?? letterTile(project.name)
        let image = NSImage(size: NSSize(width: 28, height: 28), flipped: false) { rect in
            base.draw(in: rect.insetBy(dx: 1, dy: 1))
            if let color = health.dotColor {
                let dot = NSRect(x: rect.maxX - 11, y: rect.minY, width: 11, height: 11)
                NSColor.white.setFill()
                NSBezierPath(ovalIn: dot).fill()
                color.setFill()
                NSBezierPath(ovalIn: dot.insetBy(dx: 1.5, dy: 1.5)).fill()
            }
            return true
        }
        iconCache[key] = image
        return image
    }

    private func letterTile(_ name: String) -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.systemGray.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
            let letter = String(name.prefix(1)) as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 36, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let size = letter.size(withAttributes: attributes)
            letter.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            return true
        }
    }

    // MARK: - Actions

    private func project(for sender: NSMenuItem) -> Project? {
        (sender.representedObject as? String).flatMap(config.project(id:))
    }

    @objc private func launch(_ sender: NSMenuItem) {
        guard let project = project(for: sender) else { return }
        // Launch, or switch to it if it came up since the menu was built.
        if let windowID = statuses[project.id]?.windowID {
            ITerm.focus(windowID: windowID)
        } else {
            runLauncher(project)
        }
    }

    @objc private func switchTo(_ sender: NSMenuItem) {
        guard let project = project(for: sender) else { return }
        if let windowID = statuses[project.id]?.windowID {
            ITerm.focus(windowID: windowID)
        } else {
            runLauncher(project)
        }
    }

    /// Every launcher closes its previous window and frees its ports before starting fresh.
    @objc private func restart(_ sender: NSMenuItem) {
        guard let project = project(for: sender) else { return }
        runLauncher(project)
    }

    @objc private func stop(_ sender: NSMenuItem) {
        guard let project = project(for: sender), let windowID = statuses[project.id]?.windowID else { return }
        launchedAt[project.id] = nil
        ITerm.close(windowID: windowID) { [weak self] in self?.refresh() }
    }

    @objc private func install(_ sender: NSMenuItem) {
        guard let project = project(for: sender), let repo = project.repo, !installing.contains(project.id) else { return }
        installing.insert(project.id)
        refreshVisibleRows()
        let destination = project.pathURL
        DispatchQueue.global(qos: .userInitiated).async {
            let result = GitHub.clone(repo, to: destination)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.installing.remove(project.id)
                    if case .failure(let failure) = result {
                        self.presentAlert(
                            "Couldn't install \(project.name)",
                            "gh repo clone \(repo) \(project.path)\n\n\(failure.message)"
                        )
                    }
                    self.refresh(fresh: true)
                }
            }
        }
    }

    /// Live status updates for the menu on screen. While it's open, only icons and subtitles change: rebuilding a
    /// submenu under the pointer would move or remove the item being chosen. Actions re-check status when run.
    /// The picker hides the app after an action, and macOS may refuse to reactivate it, so unhide and force the
    /// alert in front; otherwise a modal alert could block the app while sitting invisible.
    private func presentAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.unhide(nil)
        NSApp.activate()
        alert.layout()
        alert.window.orderFrontRegardless()
        alert.runModal()
    }

    private func refreshVisibleRows() {
        for (id, item) in visibleRows {
            if let project = config.project(id: id) { decorate(item, for: project, rebuildActions: !pickerIsOpen) }
        }
    }

    @objc private func openInBrowser(_ sender: NSMenuItem) {
        guard let project = project(for: sender), let url = project.url.flatMap(URL.init(string:)) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openInCursor(_ sender: NSMenuItem) {
        guard let project = project(for: sender) else { return }
        NSWorkspace.shared.open([project.pathURL], withApplicationAt: Self.cursorURL, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func revealInFinder(_ sender: NSMenuItem) {
        guard let project = project(for: sender) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([project.pathURL])
    }

    @objc private func editProjects() {
        if pickerIsOpen {
            openEditorAfterPicker = true
        } else {
            presentEditor()
        }
    }

    private func presentEditor() {
        let editor = editor ?? EditorWindowController(configURL: ConfigStore.current().fileURL)
        self.editor = editor
        editor.show()
    }

    @objc private func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private func runLauncher(_ project: Project) {
        launchedAt[project.id] = Date()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: project.launcherURL, configuration: configuration) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.launchedAt[project.id] = nil
                    self.presentAlert("Couldn't launch \(project.name)", "\(project.launcherURL.path)\n\n\(error.localizedDescription)")
                }
            }
        }
        // Pick up the new window promptly rather than waiting for the next poll.
        for delay in [1.5, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.refresh() }
        }
    }
}
