import AIEngine
import AppKit
import ApplicationServices
import Clipboard
import ExtensionHost
import KeyboardShortcuts
import LizardCore
import Notes
import Observation
import Search
import SwiftUI

/// The root model: owns the engines, windows and hotkeys, and feeds the launcher.
@Observable
@MainActor
final class AppModel {
    enum OpenTarget {
        case chat(String?)
        case clipboard
        case newNote
        case notes
    }

    enum Period { case today, week }

    let setup = SetupModel()
    let ai = AIService()
    let accounts = AccountsModel()
    let extensions = ExtensionsModel()
    let launcher = LauncherModel()
    private(set) var knowledge: KnowledgeService!
    private(set) var sync: SyncService!

    @ObservationIgnored private(set) var notes = NotesStore(root: Preferences.notesFolder)
    @ObservationIgnored private(set) var workLog = WorkLogStore(root: Preferences.workLogFolder)
    @ObservationIgnored let quicklinks = QuicklinkStore()
    @ObservationIgnored let frecency = Frecency()
    @ObservationIgnored private let indexer = AppIndexer()
    @ObservationIgnored private var clipboardStore: ClipboardStore?
    @ObservationIgnored private var pasteboardMonitor: PasteboardMonitor?

    private(set) var indexedApps: [AppEntry] = []
    private(set) var quicklinkList: [Quicklink] = Quicklink.defaults
    /// The app that was in front before Lizard was summoned (paste target, work-log context).
    private(set) var previousApp: NSRunningApplication?
    private(set) var workLogContextApp: String?

    @ObservationIgnored private var launcherPanel: FloatingPanelController<AnyView>?
    @ObservationIgnored private var workLogPanel: FloatingPanelController<AnyView>?
    @ObservationIgnored private var hudPanel: NSPanel?
    @ObservationIgnored private var splashWindow: NSWindow?
    @ObservationIgnored private var setupWindow: NSWindow?
    @ObservationIgnored private var settingsWindow: NSWindow?

    init() {
        launcher.app = self
        extensions.app = self
        knowledge = KnowledgeService(app: self)
        sync = SyncService(app: self)
    }

    /// Notes/work-log folders moved (iCloud, setup): point the stores at the new place.
    func reloadNotesFolders() {
        notes = NotesStore(root: Preferences.notesFolder)
        workLog = WorkLogStore(root: Preferences.workLogFolder)
        knowledge.scheduleSync(after: 1)
    }

    /// Quicklinks were added, edited, restored or synced.
    func quicklinksChanged() {
        Task {
            quicklinkList = await quicklinks.links
            launcher.refresh()
            sync.scheduleWrite()
        }
    }

    // MARK: Lifecycle

    func start() {
        registerHotkeys()
        Task {
            indexedApps = await indexer.refresh()
            launcher.setApps(indexedApps)
            for await apps in await indexer.updates() {
                indexedApps = apps
                launcher.setApps(apps)
            }
        }
        Task { quicklinkList = await quicklinks.links }
        startClipboard()
        extensions.start()
        accounts.refreshGitHub()
        knowledge.start()
        sync.start()

        let firstRun = !SetupModel.hasCompletedSetup
        let hasArgFlag = CommandLine.arguments.contains { $0.hasPrefix("--") }
        // Debug flags (screenshots/testing): --show-launcher [query], --show-settings, --show-clipboard.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--show-launcher") {
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                showLauncher()
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") { launcher.query = arguments[index + 1] }
            }
        }
        if arguments.contains("--show-settings") { openSettings() }
        for flag in ["--show-knowledge", "--ask-notes"] {
            if let index = arguments.firstIndex(of: flag), index + 1 < arguments.count {
                let query = arguments[index + 1]
                Task {
                    try? await Task.sleep(for: .seconds(12))
                    showLauncher()
                    launcher.push(.knowledge(query: query, ask: flag == "--ask-notes"))
                }
            }
        }
        if arguments.contains("--show-clipboard") { Task { try? await Task.sleep(for: .seconds(1.5)); open(.clipboard) } }
        if !hasArgFlag {
            showSplash(firstLaunch: firstRun) { [weak self] in
                if firstRun { self?.showSetup() }
            }
        }
    }

    func prepareForTermination() async {
        extensions.stopAll()
        await ai.prepareForTermination()
    }

    // MARK: Hotkeys

    private func registerHotkeys() {
        KeyboardShortcuts.onKeyUp(for: .toggleLauncher) { [weak self] in
            guard let self else { return }
            if self.setupWindow?.isVisible == true, self.setup.page == .done { self.setup.hotkeyTestPassed = true }
            self.toggleLauncher()
        }
        KeyboardShortcuts.onKeyUp(for: .workLog) { [weak self] in self?.showWorkLog() }
        KeyboardShortcuts.onKeyUp(for: .clipboard) { [weak self] in self?.open(.clipboard) }
        KeyboardShortcuts.onKeyUp(for: .askAI) { [weak self] in self?.open(.chat(nil)) }
        KeyboardShortcuts.onKeyUp(for: .newNote) { [weak self] in self?.open(.newNote) }
        for layout in WindowManager.Layout.allCases {
            guard let name = layout.shortcutName else { continue }
            KeyboardShortcuts.onKeyDown(for: name) { [weak self] in
                // Global shortcut: act on whatever app is in front right now.
                if let message = WindowManager.apply(layout, to: NSWorkspace.shared.frontmostApplication) { self?.showHUD(message) }
            }
        }
    }

    // MARK: Launcher panel

    var isLauncherVisible: Bool { launcherPanel?.isVisible == true }

    private func ensureLauncherPanel() -> FloatingPanelController<AnyView> {
        if let launcherPanel { return launcherPanel }
        let controller = FloatingPanelController(size: Metrics.launcherSize, hidesOnResign: false) {
            AnyView(LauncherRootView().environment(self))
        }
        controller.panel.onResignKey = { [weak self] in
            // Popovers and alerts take key status briefly; hide only when focus left Lizard.
            DispatchQueue.main.async {
                guard let self, NSApp.keyWindow == nil || NSApp.keyWindow === self.settingsWindow else { return }
                self.hideLauncher()
            }
        }
        launcherPanel = controller
        return controller
    }

    private func rememberFrontApp() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier { previousApp = front }
    }

    func toggleLauncher() {
        if isLauncherVisible {
            hideLauncher()
        } else {
            showLauncher()
        }
    }

    func showLauncher() {
        rememberFrontApp()
        let controller = ensureLauncherPanel()
        launcher.summoned()
        controller.show()
        ai.prewarm()
    }

    func hideLauncher() {
        launcherPanel?.hide()
        // Coming back later starts fresh at search, like Raycast (after a short grace period).
        Task {
            try? await Task.sleep(for: .seconds(60))
            if !isLauncherVisible { launcher.resetToRoot() }
        }
    }

    func open(_ target: OpenTarget) {
        if !isLauncherVisible { showLauncher() }
        launcher.resetToRoot()
        switch target {
        case .chat(let text):
            let session = ChatSession(ai: ai)
            launcher.push(.chat(session))
            if let text { session.send(text) }
        case .clipboard:
            launcher.push(.clipboard)
        case .notes:
            launcher.push(.notes(nil))
        case .newNote:
            Task {
                let url = try? await notes.create(title: "Untitled")
                launcher.push(.notes(url))
            }
        }
    }

    // MARK: Search sources

    /// Everything the launcher can find, as rows.
    func searchSources(apps: [AppEntry]) -> [LauncherItem] {
        var items: [LauncherItem] = builtInCommands()
        for app in apps {
            let actions = [
                LauncherAction(title: "Show in Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([app.path]); return false },
                LauncherAction(title: "Copy Path", symbol: "doc.on.doc") { [weak self] in self?.copyText(app.path.path); return false },
                LauncherAction(title: "Quit App", symbol: "xmark.circle") {
                    NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier ?? "").forEach { $0.terminate() }
                    return false
                },
            ]
            items.append(LauncherItem(id: "app:\(app.path.path)", title: app.name, icon: .app(app.path), kind: .app, actions: actions) { [weak self] in
                NSWorkspace.shared.openApplication(at: app.path, configuration: NSWorkspace.OpenConfiguration())
                self?.hideLauncher()
                return false
            })
        }
        for (installed, command) in extensions.commands {
            let subtitle = extensions.subtitles["\(installed.name)/\(command.name)"] ?? installed.title
            let icon: LauncherItem.Icon = installed.iconURL.flatMap { NSImage(contentsOf: $0) }.map { .image($0) } ?? .symbol("puzzlepiece.extension", Brand.teal)
            items.append(LauncherItem(id: "ext:\(installed.name)/\(command.name)", title: command.title, subtitle: subtitle, icon: icon, kind: .extensionCommand,
                accessory: command.mode == .menuBar ? "Menu Bar" : nil) { [weak self] in
                self?.extensions.launch(installed, command)
                return command.mode == .view
            })
        }
        for link in quicklinkList {
            items.append(LauncherItem(id: "quicklink:\(link.id)", title: link.name, subtitle: link.keyword.map { "“\($0)” + text" }, icon: .symbol(link.symbol, .blue), kind: .quicklink) { [weak self] in
                guard let self else { return false }
                if link.needsQuery {
                    self.launcher.query = (link.keyword.map { "\($0) " }) ?? ""
                    return true
                }
                self.openQuicklink(link, query: "")
                return false
            })
        }
        return items
    }

    /// Fuzzy + frecency ranking; a quicklink keyword ("gh lizard") jumps to the top.
    func rank(_ items: [LauncherItem], query: String) -> [LauncherItem] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var direct: [LauncherItem] = []
        let parts = query.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count == 2, let link = quicklinkList.first(where: { $0.keyword?.lowercased() == parts[0].lowercased() }) {
            let text = parts[1]
            direct.append(LauncherItem(id: "quicklink.direct:\(link.id)", title: "\(link.name): \(text)", subtitle: nil, icon: .symbol(link.symbol, .blue), kind: .quicklink) { [weak self] in
                self?.openQuicklink(link, query: text)
                return false
            })
        }
        let candidates = items.map { item in
            SearchCandidate(id: item.id, title: item.title, keywords: item.subtitle.map { [$0] } ?? [], weight: item.kind == .app ? 0.4 : item.kind == .command ? 0.2 : 0)
        }
        let ranked = SearchEngine.rank(candidates, query: query, frecency: { self.frecency.boost(for: $0) }, limit: 40)
        let results = ranked.compactMap { result -> LauncherItem? in
            guard var item = byID[result.id] else { return nil }
            item.highlights = result.highlights
            return item
        }
        return direct + results
    }

    func quicklinkFallbacks(for query: String) -> [LauncherItem] {
        quicklinkList.filter(\.needsQuery).prefix(4).map { link in
            LauncherItem(id: "fallback.quicklink:\(link.id)", title: link.name, subtitle: query, icon: .symbol(link.symbol, .blue), kind: .quicklink) { [weak self] in
                self?.openQuicklink(link, query: query)
                return false
            }
        }
    }

    func recordUse(_ id: String) {
        guard !id.hasPrefix("fallback") else { return }
        frecency.record(id)
    }

    func openQuicklink(_ link: Quicklink, query: String) {
        let clipboard = NSPasteboard.general.string(forType: .string)
        guard let url = link.resolve(query: query, clipboard: clipboard, selection: nil) else { return showHUD("Invalid quicklink URL") }
        NSWorkspace.shared.open(url)
        hideLauncher()
    }

    private func command(_ id: String, _ title: String, _ subtitle: String, _ symbol: String, _ color: Color = Brand.moss, keepOpen: Bool = true, _ run: @escaping @MainActor () -> Void) -> LauncherItem {
        LauncherItem(id: "cmd:\(id)", title: title, subtitle: subtitle, icon: .symbol(symbol, color), kind: .command) {
            run()
            return keepOpen
        }
    }

    private func builtInCommands() -> [LauncherItem] {
        let windows = WindowManager.Layout.allCases.map { layout in
            LauncherItem(id: "window:\(layout.rawValue)", title: "Window: \(layout.title)", subtitle: nil, icon: .symbol(layout.symbol, .purple), kind: .command) { [weak self] in
                guard let self else { return false }
                self.hideLauncher()
                if let message = WindowManager.apply(layout, to: self.previousApp) { self.showHUD(message) }
                return false
            }
        }
        return windows + [
            command("ask-ai", "Ask AI", "Chat with your private AI", "sparkles") { [weak self] in self?.launcher.askAI() },
            command("ai-chats", "AI Chat History", "Past conversations", "bubble.left.and.text.bubble.right") { [weak self] in self?.launcher.push(.chats) },
            command("clipboard", "Clipboard History", "Search and paste anything you copied", "doc.on.clipboard") { [weak self] in self?.launcher.push(.clipboard) },
            command("notes", "Search Notes", "Your Markdown notes", "note.text") { [weak self] in self?.launcher.push(.notes(nil)) },
            command("semantic-search", "Search by Meaning", "Notes, work log, clipboard and chats — finds paraphrases too", "text.magnifyingglass") { [weak self] in
                self?.launcher.push(.knowledge(query: "", ask: false))
            },
            command("ask-notes", "Ask Your Notes", "Answers from your own notes and logs, with sources", "sparkle.magnifyingglass") { [weak self] in
                self?.launcher.push(.knowledge(query: "", ask: true))
            },
            command("new-note", "New Note", "Start a Markdown note", "square.and.pencil") { [weak self] in self?.open(.newNote) },
            command("work-log", "Log Work", "Add a timestamped work-log entry", "list.bullet.clipboard", keepOpen: false) { [weak self] in
                self?.hideLauncher()
                self?.showWorkLog()
            },
            command("work-today", "Summarize Today's Work", "AI summary of today's work log", "text.badge.star") { [weak self] in self?.summarizeWorkLog(period: .today) },
            command("work-week", "Weekly Work Summary", "AI status update for the last 7 days", "calendar") { [weak self] in self?.summarizeWorkLog(period: .week) },
            command("brag-doc", "Write Brag Document", "Performance-review highlights from 90 days of work logs", "medal") { [weak self] in
                guard let self else { return }
                let entries = self.workLog.entries(from: .now.addingTimeInterval(-90 * 86_400), to: .now)
                self.launcher.push(.aiJob(.bragDoc(entries: WorkLogStore.text(of: entries))))
            },
            command("summarize-clipboard", "Summarize Clipboard", "AI summary of what you copied", "text.append") { [weak self] in
                self?.launcher.push(.aiJob(.summarize(text: NSPasteboard.general.string(forType: .string) ?? "")))
            },
            command("explain-clipboard", "Explain Clipboard", "Explain copied code, errors or commands", "questionmark.bubble") { [weak self] in
                self?.launcher.push(.aiJob(.explain(text: NSPasteboard.general.string(forType: .string) ?? "")))
            },
            command("translate", "Translate", "On-device translation of what you type or select", "character.bubble", .blue) { [weak self] in
                self?.launcher.push(.translate(""))
            },
            command("window-layouts", "Window Layouts", "Halves, quarters, thirds, maximize, next display", "rectangle.split.2x1", .purple) { [weak self] in
                self?.launcher.query = "window "
            },
            command("dev-tools", "Developer Tools", "JSON, JWT, Base64, URL, hashes, timestamps", "wrench.and.screwdriver", .indigo) { [weak self] in self?.launcher.push(.devTools) },
            command("kill-process", "Kill Process", "Find and stop processes by CPU or memory", "xmark.octagon", .red) { [weak self] in self?.launcher.push(.processes) },
            command("ports", "Listening Ports", "Who's on :3000? Stop it", "network", .orange) { [weak self] in self?.launcher.push(.ports) },
            command("quicklinks", "Manage Quicklinks", "URL templates like gh {query}", "link", .blue) { [weak self] in self?.launcher.push(.quicklinks) },
            command("settings", "Lizard Settings", "Shortcuts, AI, accounts, extensions", "gearshape", .gray, keepOpen: false) { [weak self] in self?.openSettings() },
            command("setup", "Run Setup", "Shortcuts, permissions, AI, GitHub", "sparkles.rectangle.stack", .gray, keepOpen: false) { [weak self] in self?.showSetup() },
            command("quit", "Quit Lizard", "", "power", .gray, keepOpen: false) { NSApp.terminate(nil) },
        ]
    }

    // MARK: Windows

    func showSplash(firstLaunch: Bool, then: (() -> Void)? = nil) {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SplashView(firstLaunch: firstLaunch) { [weak self, weak window] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                window?.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated {
                    window?.orderOut(nil)
                    self?.splashWindow = nil
                    then?()
                }
            }
        })
        window.center()
        window.makeKeyAndOrderFront(nil)
        splashWindow = window
    }

    func showSetup() {
        if let setupWindow {
            Self.bringToFront(setupWindow)
            return
        }
        let window = makeWindow(title: "Welcome to Lizard", size: NSSize(width: 640, height: 560)) {
            SetupView { [weak self] in
                self?.setupWindow?.close()
                self?.setupWindow = nil
            }
            .environment(self)
        }
        setupWindow = window
    }

    func openSettings() {
        hideLauncher()
        if let settingsWindow {
            Self.bringToFront(settingsWindow)
            return
        }
        settingsWindow = makeWindow(title: "Lizard Settings", size: NSSize(width: 640, height: 560)) {
            SettingsView().environment(self)
        }
    }

    private func makeWindow<Content: View>(title: String, size: NSSize, @ViewBuilder content: () -> Content) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content())
        window.center()
        Self.bringToFront(window)
        return window
    }

    /// Accessory apps aren't activated by `activate()` without a user click; force it.
    static func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// A small transient message near the bottom of the screen (like Raycast's HUD).
    func showHUD(_ text: String) {
        guard !text.isEmpty else { return }
        hudPanel?.orderOut(nil)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView:
            HStack(spacing: 8) {
                LizardMarkView(size: 18)
                Text(text).font(.system(size: 14, weight: .medium)).lineLimit(2)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .glassEffect(.regular, in: Capsule())
            .fixedSize())
        panel.contentView = host
        let size = host.fittingSize
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.minY + 90, width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
        hudPanel = panel
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            if hudPanel === panel { panel.orderOut(nil) }
        }
    }

    // MARK: Work log

    func showWorkLog() {
        rememberFrontApp()
        workLogContextApp = previousApp?.localizedName
        if workLogPanel == nil {
            workLogPanel = FloatingPanelController(size: NSSize(width: 520, height: 150)) {
                AnyView(WorkLogHUD().environment(self))
            }
        }
        workLogPanel?.show()
    }

    func hideWorkLog() {
        workLogPanel?.hide()
        previousApp?.activate()
    }

    func appendWorkLog(_ text: String) {
        let app = workLogContextApp
        do {
            try workLog.append(text: text, app: app)
            knowledge.scheduleSync()
        } catch {
            showHUD("Couldn't save: \(error.localizedDescription)")
        }
    }

    func todayWorkLogText() -> String {
        WorkLogStore.text(of: workLog.entries(onDayOf: .now))
    }

    func summarizeWorkLog(period: Period) {
        workLogPanel?.hide()
        let entries: [WorkLogEntry]
        let label: String
        switch period {
        case .today:
            entries = workLog.entries(onDayOf: .now)
            label = "today"
        case .week:
            entries = workLog.entries(from: .now.addingTimeInterval(-7 * 86_400), to: .now)
            label = "the last 7 days"
        }
        guard !entries.isEmpty else { return showHUD("No work-log entries for \(label) yet") }
        if !isLauncherVisible { showLauncher() }
        launcher.push(.aiJob(.summarizeWorkLog(entries: WorkLogStore.text(of: entries), period: label)))
    }

    func openWorkLogFile() {
        let url = workLog.file(for: .now)
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) } else { NSWorkspace.shared.open(workLog.root) }
        workLogPanel?.hide()
    }

    // MARK: Clipboard

    private func startClipboard() {
        clipboardStore = try? ClipboardStore()
        let monitor = PasteboardMonitor { [weak self] content, source in
            guard let store = await self?.clipboardStore else { return }
            switch content {
            case .text(let text): try? await store.insert(kind: .text, text: text, sourceApp: source)
            case .url(let url): try? await store.insert(kind: .url, text: url, sourceApp: source)
            case .files(let paths): try? await store.insert(kind: .file, text: paths.joined(separator: "\n"), sourceApp: source)
            case .image(let png, let width, let height): try? await store.insertImage(png: png, description: "Image \(width)×\(height)", sourceApp: source)
            }
        }
        pasteboardMonitor = monitor
        if Preferences.clipboardEnabled { monitor.start() }
    }

    func clipboardEnabledChanged() {
        if Preferences.clipboardEnabled { pasteboardMonitor?.start() } else { pasteboardMonitor?.stop() }
    }

    func clipboardItems(matching query: String) async -> [ClipItem] {
        guard let store = clipboardStore else { return [] }
        return (try? await (query.isEmpty ? store.recent() : store.search(query))) ?? []
    }

    func copyClip(_ item: ClipItem) {
        AutoPaste.copy(item)
        pasteboardMonitor?.markOwnWrite()
        showHUD("Copied")
    }

    func pasteClip(_ item: ClipItem) {
        AutoPaste.copy(item)
        pasteboardMonitor?.markOwnWrite()
        hideLauncher()
        if !AutoPaste.paste(into: previousApp) {
            showHUD("Copied — allow Accessibility in Setup to paste directly")
        }
    }

    func togglePin(_ item: ClipItem) async {
        try? await clipboardStore?.setPinned(item.id, !item.pinned)
    }

    func deleteClip(_ item: ClipItem) async {
        try? await clipboardStore?.delete(item.id)
    }

    func copyText(_ text: String) {
        AutoPaste.copy(text: text)
        pasteboardMonitor?.markOwnWrite()
        showHUD("Copied")
    }

    func pasteText(_ text: String) {
        AutoPaste.copy(text: text)
        pasteboardMonitor?.markOwnWrite()
        hideLauncher()
        AutoPaste.paste(into: previousApp)
    }

    func appName(forBundleID bundleID: String?) -> String? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    // MARK: Extensions glue

    /// The selected text in the app that was in front, through Accessibility.
    func selectedTextInPreviousApp() -> String? {
        guard AXIsProcessTrusted(), let pid = previousApp?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let element = focused else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success else { return nil }
        let text = selected as? String
        return text?.isEmpty == false ? text : nil
    }

    func launchExtensionCommand(extension name: String, command: String, background: Bool) {
        guard let installed = extensions.installed.first(where: { $0.name == name }), let match = installed.commands.first(where: { $0.name == command }) else { return }
        if background, match.mode == .menuBar {
            extensions.setMenuBar(name, command, enabled: true)
            return
        }
        if match.mode == .view, !isLauncherVisible { showLauncher() }
        extensions.launch(installed, match)
    }
}
