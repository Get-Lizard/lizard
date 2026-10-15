import AIEngine
import AppKit
import Carbon.HIToolbox
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
    private(set) var screenshots: ScreenshotService!
    private(set) var updates: UpdateService!
    private(set) var voice: VoiceTypist!
    @ObservationIgnored private(set) lazy var statusItem = LizardStatusItem(app: self)

    @ObservationIgnored private(set) var notes = NotesStore(root: Preferences.notesFolder)
    @ObservationIgnored private(set) var workLog = WorkLogStore(root: Preferences.workLogFolder)
    @ObservationIgnored let quicklinks = QuicklinkStore()
    /// Saved snippets (Create Snippet / Search Snippets; keywords expand anywhere).
    @ObservationIgnored let snippetStore = SnippetStore()
    private(set) var savedSnippets: [Snippet] = []
    @ObservationIgnored private(set) lazy var snippetExpander = SnippetExpander(app: self)
    @ObservationIgnored let frecency = Frecency()
    @ObservationIgnored private let indexer = AppIndexer()
    @ObservationIgnored private var clipboardStore: ClipboardStore?
    @ObservationIgnored private var pasteboardMonitor: PasteboardMonitor?

    private(set) var indexedApps: [AppEntry] = []
    private(set) var quicklinkList: [Quicklink] = Quicklink.defaults
    /// Notes that are a command/code snippet: findable from the launcher, ↩ copies.
    private(set) var snippetNotes: [Note] = []
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
        screenshots = ScreenshotService(app: self)
        updates = UpdateService(app: self)
        voice = VoiceTypist(app: self)
    }

    func markOwnPasteboardWrite() {
        pasteboardMonitor?.markOwnWrite()
    }

    /// Notes/work-log folders moved (iCloud, setup): point the stores at the new place.
    func reloadNotesFolders() {
        notes = NotesStore(root: Preferences.notesFolder)
        workLog = WorkLogStore(root: Preferences.workLogFolder)
        knowledge.scheduleSync(after: 1)
    }

    func refreshSnippets() async {
        snippetNotes = await notes.list().filter { $0.snippet != nil }
        launcher.refresh()
    }

    /// Quicklinks were added, edited, restored or synced.
    func snippetsChanged() {
        Task {
            savedSnippets = await snippetStore.snippets
            snippetExpander.update(savedSnippets)
            launcher.refresh()
            sync.scheduleWrite()
        }
    }

    /// Fills a snippet's placeholders with the clipboard (and its history, for `offset=N`), the
    /// selection, the date, and other snippets.
    func expandSnippet(_ snippet: Snippet, selection: String? = nil) async -> Snippet.Expansion {
        let history = snippet.text.contains("offset=") ? await clipboardItems(matching: "").map(\.text) : []
        return Snippet.expand(
            snippet.text, clipboard: NSPasteboard.general.string(forType: .string), selection: selection,
            snippets: savedSnippets, clipboardHistory: { history.indices.contains($0) ? history[$0] : nil })
    }

    /// Pastes a snippet into the app you were in: placeholders filled, caret moved to `{cursor}`.
    func pasteSnippet(_ snippet: Snippet) {
        let selection = selectedTextInPreviousApp()
        Task {
            let expansion = await expandSnippet(snippet, selection: selection)
            pasteText(expansion.text)
            if let back = expansion.cursorFromEnd, back > 0 {
                try? await Task.sleep(for: .milliseconds(250))
                SnippetExpander.press(kVK_LeftArrow, times: back)
            }
        }
    }

    func copySnippet(_ snippet: Snippet) {
        Task { copyText(await expandSnippet(snippet).text) }
    }

    func importSnippets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a snippets file (Raycast's Export Snippets, or one from Lizard)"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let incoming = Snippet.fromRaycastExport(data)
        guard !incoming.isEmpty else { return showHUD("That file doesn't contain snippets") }
        Task {
            let added = await snippetStore.merge(incoming)
            snippetsChanged()
            showHUD(added == 0 ? "All \(incoming.count) snippets are already in Lizard" : "Imported \(added) snippet\(added == 1 ? "" : "s")")
        }
    }

    func exportSnippets() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Lizard Snippets.json"
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Snippet.raycastExport(savedSnippets).write(to: url, options: .atomic)
            showHUD("Exported \(savedSnippets.count) snippets (Raycast can import this file too)")
        } catch {
            showHUD("Couldn't export: \(error.localizedDescription)")
        }
    }

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
            // After the first app scan, so the prebuilt panel already has real content.
            try? await Task.sleep(for: .milliseconds(800))
            if !isLauncherVisible { prebuildLauncher() }
        }
        Task {
            indexedApps = await indexer.refresh()
            launcher.setApps(indexedApps)
            for await apps in await indexer.updates() {
                indexedApps = apps
                launcher.setApps(apps)
            }
        }
        Task { quicklinkList = await quicklinks.links }
        Task {
            savedSnippets = await snippetStore.snippets
            snippetExpander.update(savedSnippets)
        }
        Task {
            await refreshSnippets()
            for await _ in await notes.changes() { await refreshSnippets() }
        }
        startClipboard()
        extensions.start()
        accounts.refreshGitHub()
        knowledge.start()
        sync.start()
        updates.start()
        updates.verifyAfterUpdate()
        ShortcutConflictCheck.start()

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
        // Marketing/test captures: --show-notes, --show-translate <text>, --show-route <name>.
        if arguments.contains("--show-notes") {
            Task { try? await Task.sleep(for: .seconds(2)); showLauncher(); launcher.push(.notes(nil)) }
        }
        if let index = arguments.firstIndex(of: "--show-translate"), index + 1 < arguments.count {
            let text = arguments[index + 1]
            Task { try? await Task.sleep(for: .seconds(2)); showLauncher(); launcher.push(.translate(text)) }
        }
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
        if arguments.contains("--bench-summon") { Task { try? await Task.sleep(for: .seconds(3)); await benchSummon() } }
        if let index = arguments.firstIndex(of: "--new-quicklink") {
            let text = index + 1 < arguments.count ? arguments[index + 1] : nil
            Task { try? await Task.sleep(for: .seconds(1.5)); showLauncher(); createQuicklink(from: text) }
        }
        if arguments.contains("--new-snippet") {
            Task { try? await Task.sleep(for: .seconds(1.5)); showLauncher(); launcher.push(.snippetEditor(Snippet(name: "Email signature", text: "Best,\nVitor\n{date}", keyword: ";sig"), isNew: true)) }
        }
        if arguments.contains("--show-snippets") { Task { try? await Task.sleep(for: .seconds(1.5)); showLauncher(); launcher.push(.snippets) } }
        // Testing the updater end to end: check now and install whatever is newer.
        if arguments.contains("--update-now") { Task { await updates.check(); updates.install() } }
        if let index = arguments.firstIndex(of: "--chat") {
            let text = index + 1 < arguments.count && !arguments[index + 1].hasPrefix("--") ? arguments[index + 1] : nil
            Task { try? await Task.sleep(for: .seconds(1.5)); open(.chat(text)) }
        }
        if arguments.contains("--show-worklog") { Task { try? await Task.sleep(for: .seconds(1.5)); showWorkLog() } }
        if arguments.contains("--show-review") { Task { try? await Task.sleep(for: .seconds(1.5)); openPerformanceReview() } }
        if let index = arguments.firstIndex(of: "--show-setup") {
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if index + 1 < arguments.count, let page = SetupModel.Page.allCases.first(where: { "\($0)" == arguments[index + 1] }) { setup.page = page }
                showSetup()
            }
        }
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

    /// `--bench-summon`: time hotkey-to-typing for a cold and several warm summons
    /// (written to the scratch file in `LIZARD_BENCH_OUT`, else /tmp/lizard-bench.txt).
    private func benchSummon() async {
        var lines: [String] = []
        func ms(_ duration: Duration) -> String { String(format: "%.1f", Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000) }
        for round in 0..<12 {
            hideLauncher()
            try? await Task.sleep(for: .milliseconds(400))
            let start = ContinuousClock.now
            showLauncher()
            let shown = ContinuousClock.now
            while !(launcherPanel?.panel.firstResponder is NSText) { try? await Task.sleep(for: .milliseconds(1)) }
            lines.append("round \(round): ordered front \(ms(shown - start)) ms, typing ready \(ms(ContinuousClock.now - start)) ms")
        }
        hideLauncher()
        let out = ProcessInfo.processInfo.environment["LIZARD_BENCH_OUT"] ?? "/tmp/lizard-bench.txt"
        try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
    }

    // MARK: Hotkeys

    private func registerHotkeys() {
        // Key *down*: acting on release adds the whole time the keys are held (often 100 ms+).
        KeyboardShortcuts.onKeyDown(for: .toggleLauncher) { [weak self] in
            guard let self else { return }
            if self.setupWindow?.isVisible == true, self.setup.page == .done { self.setup.hotkeyTestPassed = true }
            self.toggleLauncher()
        }
        KeyboardShortcuts.onKeyDown(for: .voiceTyping) { [weak self] in self?.voice.shortcutDown() }
        KeyboardShortcuts.onKeyUp(for: .voiceTyping) { [weak self] in self?.voice.shortcutUp() }
        KeyboardShortcuts.onKeyDown(for: .workLog) { [weak self] in self?.showWorkLog() }
        KeyboardShortcuts.onKeyDown(for: .clipboard) { [weak self] in self?.open(.clipboard) }
        KeyboardShortcuts.onKeyDown(for: .askAI) { [weak self] in self?.open(.chat(nil)) }
        KeyboardShortcuts.onKeyDown(for: .newNote) { [weak self] in self?.open(.newNote) }
        KeyboardShortcuts.onKeyUp(for: .screenshotArea) { [weak self] in self?.screenshots.capture(.area) }
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
    var isLauncherKey: Bool { launcherPanel?.panel.isKeyWindow == true }

    /// Voice typing into Lizard: inserts at the caret of the focused field. `make` gets the text
    /// left of the caret and whether it's the main search, and returns what to insert.
    func insertIntoLauncher(_ make: (String, Bool) -> String) {
        guard let panel = launcherPanel?.panel else { return }
        if !(panel.firstResponder is NSTextView) { focusLauncherField() }
        guard let editor = panel.firstResponder as? NSTextView else { return }
        let range = editor.selectedRange()
        let before = (editor.string as NSString).substring(to: min(range.location, (editor.string as NSString).length))
        let isSearch = { if case .search = launcher.route { true } else { false } }()
        editor.insertText(make(before, isSearch), replacementRange: range)
    }

    private func ensureLauncherPanel() -> FloatingPanelController<AnyView> {
        if let launcherPanel { return launcherPanel }
        let controller = FloatingPanelController(size: Metrics.launcherSize, hidesOnResign: false) {
            AnyView(LauncherRootView().environment(self))
        }
        // `--keep-open` (screenshots): stay up while another app has focus.
        if CommandLine.arguments.contains("--keep-open") { launcherPanel = controller; return controller }
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

    /// Speed is the point: put the panel (with what it showed last) on screen and focus the field
    /// first, then refresh results and warm the AI on the next run-loop turn.
    func showLauncher() {
        rememberFrontApp()
        let controller = ensureLauncherPanel()
        controller.show(size: launcher.panelSize)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.launcher.summoned()
                self.prewarmAIIfIdle()
                self.snippetExpander.refreshMonitoring()  // picks up a newly granted Accessibility
            }
        }
    }

    @ObservationIgnored private var lastAIPrewarm = Date.distantPast

    /// Warming Apple's model is only worth it once in a while, and never while showing the panel.
    private func prewarmAIIfIdle() {
        guard Date.now.timeIntervalSince(lastAIPrewarm) > 120 else { return }
        lastAIPrewarm = .now
        ai.prewarm()
    }

    /// Build and render the launcher once at launch, invisibly, so the first hotkey press is as
    /// fast as every other one (otherwise SwiftUI builds the whole tree on that first press).
    private func prebuildLauncher() {
        let controller = ensureLauncherPanel()
        launcher.refresh()
        controller.prerender(size: launcher.panelSize)
    }

    /// After navigation inside the panel, focus the new screen's text field.
    func focusLauncherField() {
        launcherPanel?.focusTypingField(newScreen: true)
    }

    func resizeLauncher(to size: CGSize) {
        launcherPanel?.resize(to: size)
    }

    func hideLauncher() {
        launcherPanel?.hide()
        // By default the launcher reopens exactly where it was left (same screen, note, query).
        if !Preferences.resumeLauncher { launcher.resetToRoot() }
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

    /// Extension icons, loaded once (search sources are rebuilt on every keystroke).
    @ObservationIgnored private let extensionIcons = NSCache<NSURL, NSImage>()

    private func extensionIcon(_ url: URL) -> NSImage? {
        if let cached = extensionIcons.object(forKey: url as NSURL) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        extensionIcons.setObject(image, forKey: url as NSURL)
        return image
    }

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
            let icon: LauncherItem.Icon = installed.iconURL.flatMap(extensionIcon).map { .image($0) } ?? .symbol("puzzlepiece.extension", Brand.teal)
            items.append(LauncherItem(id: "ext:\(installed.name)/\(command.name)", title: command.title, subtitle: subtitle, icon: icon, kind: .extensionCommand,
                accessory: command.mode == .menuBar ? "Menu Bar" : nil) { [weak self] in
                self?.extensions.launch(installed, command)
                return command.mode == .view
            })
        }
        for note in snippetNotes {
            items.append(LauncherItem(id: "snippet:\(note.url.path)", title: note.title, subtitle: note.snippet?.split(separator: "\n").first.map(String.init),
                icon: .symbol("terminal", Brand.teal), kind: .note, accessory: "Copy",
                actions: [LauncherAction(title: "Paste Snippet", symbol: "doc.on.clipboard") { [weak self] in
                    self?.pasteText(note.snippet ?? "")
                    return false
                }]) { [weak self] in
                self?.copyText(note.snippet ?? "")
                return false
            })
        }
        for snippet in savedSnippets {
            let preview = snippet.text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
            items.append(LauncherItem(id: "snippet.saved:\(snippet.id)", title: snippet.name, subtitle: snippet.keyword.map { "\($0)  ·  \(preview ?? "")" } ?? preview,
                icon: .symbol("text.quote", .red), kind: .snippet, accessory: "Paste",
                actions: [
                    LauncherAction(title: "Copy", symbol: "doc.on.doc") { [weak self] in self?.copySnippet(snippet); return false },
                    LauncherAction(title: "Edit Snippet", symbol: "pencil") { [weak self] in self?.launcher.push(.snippetEditor(snippet, isNew: false)); return true },
                ]) { [weak self] in
                self?.pasteSnippet(snippet)
                return false
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

    /// Opens the quicklink editor, prefilled from a typed or copied link when there is one.
    func createQuicklink(from text: String?) {
        let clipboard = NSPasteboard.general.string(forType: .string)
        let draft = text.flatMap(Quicklink.draft(from:)) ?? clipboard.flatMap(Quicklink.draft(from:))
            ?? Quicklink(name: "", template: "https://")
        launcher.push(.quicklinkEditor(draft, isNew: true))
    }

    func openQuicklink(_ link: Quicklink, query: String) {
        let clipboard = NSPasteboard.general.string(forType: .string)
        guard let url = link.resolve(query: query, clipboard: clipboard, selection: nil) else { return showHUD("Invalid quicklink URL") }
        if let appURL = OpenWithApps.appURL(for: link.openWith) {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
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
            command("semantic-search", "Search by Meaning", "Notes, work log, clipboard and chats. Finds paraphrases too", "text.magnifyingglass") { [weak self] in
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
            command("performance-review", "Performance Review", "Pick a period; AI writes a self-review from your work log", "medal") { [weak self] in
                self?.launcher.push(.performanceReview)
            },
            command("summarize-clipboard", "Summarize Clipboard", "AI summary of what you copied", "text.append") { [weak self] in
                self?.launcher.push(.aiJob(.summarize(text: NSPasteboard.general.string(forType: .string) ?? "")))
            },
            command("explain-clipboard", "Explain Clipboard", "Explain copied code, errors or commands", "questionmark.bubble") { [weak self] in
                self?.launcher.push(.aiJob(.explain(text: NSPasteboard.general.string(forType: .string) ?? "")))
            },
            command("screenshots", "Screenshots", "Your captures, filed by category, with searchable text", "photo.on.rectangle.angled", .indigo) { [weak self] in
                self?.launcher.push(.screenshots)
            },
            command("capture-area", "Capture Area", "Screenshot a region; Lizard names and files it", "plus.viewfinder", .indigo, keepOpen: false) { [weak self] in
                self?.screenshots.capture(.area)
            },
            command("capture-window", "Capture Window", "Screenshot one window", "macwindow.badge.plus", .indigo, keepOpen: false) { [weak self] in
                self?.screenshots.capture(.window)
            },
            command("capture-screen", "Capture Screen", "Screenshot the whole screen", "display", .indigo, keepOpen: false) { [weak self] in
                self?.screenshots.capture(.screen)
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
            command("create-snippet", "Create Snippet", "Save text you type often; give it a keyword to expand anywhere", "text.badge.plus", .red) { [weak self] in
                self?.launcher.push(.snippetEditor(Snippet(name: "", text: ""), isNew: true))
            },
            command("search-snippets", "Search Snippets", "Find a snippet and paste it into your app", "text.page.badge.magnifyingglass", .red) { [weak self] in
                self?.launcher.push(.snippets)
            },
            command("import-snippets", "Import Snippets", "From Raycast's Export Snippets or a Lizard file", "square.and.arrow.down", .red, keepOpen: false) { [weak self] in
                self?.hideLauncher()
                self?.importSnippets()
            },
            command("export-snippets", "Export Snippets", "Save all snippets to a file (Raycast can import it)", "square.and.arrow.up", .red, keepOpen: false) { [weak self] in
                self?.hideLauncher()
                self?.exportSnippets()
            },
            command("create-quicklink", "Create Quicklink", "Add a link you open often, with an optional keyword", "link.badge.plus", .blue) { [weak self] in
                self?.createQuicklink(from: nil)
            },
            command("settings", "Lizard Settings", "Shortcuts, AI, accounts, extensions", "gearshape", .gray, keepOpen: false) { [weak self] in self?.openSettings() },
            command("voice-typing", "Voice Typing", "Talk instead of typing, anywhere (hold \(voiceShortcutText))", "waveform", .pink, keepOpen: false) { [weak self] in
                guard let self else { return }
                self.hideLauncher()
                self.previousApp?.activate()
                Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    self.voice.toggleFromButton()
                }
            },
            command("check-updates", "Check for Updates", "See if a newer Lizard is out, and install it", "arrow.down.circle", .gray, keepOpen: false) { [weak self] in
                guard let self else { return }
                self.hideLauncher()
                Task {
                    await self.updates.check()
                    switch self.updates.state {
                    case .available(let release): self.showHUD("Lizard \(release.version) is available. Install it from the menu bar or Settings")
                    case .upToDate: self.showHUD("You're on the latest Lizard (\(self.updates.currentVersion))")
                    case .failed(let message): self.showHUD(message)
                    default: break
                    }
                }
            },
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
            updateDockPresence()
            return
        }
        // Assigned before makeWindow returns its first activation, so the Dock icon appears at once.
        setupWindow = makeWindow(title: "Welcome to Lizard", size: NSSize(width: 640, height: 560)) {
            SetupView { [weak self] in
                self?.setupWindow?.close()
                self?.setupWindow = nil
                self?.updateDockPresence()
            }
            .environment(self)
        }
        updateDockPresence()
    }

    func openSettings() {
        hideLauncher()
        if let settingsWindow {
            Self.bringToFront(settingsWindow)
            updateDockPresence()
            return
        }
        settingsWindow = makeWindow(title: "Lizard Settings", size: NSSize(width: 640, height: 560)) {
            SettingsView().environment(self)
        }
        updateDockPresence()
    }

    private func makeWindow<Content: View>(title: String, size: NSSize, @ViewBuilder content: () -> Content) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content())
        window.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Wait until the window is actually gone before deciding.
                DispatchQueue.main.async { self?.updateDockPresence() }
            }
        }
        Self.bringToFront(window)
        updateDockPresence()
        return window
    }

    /// Lizard is a menu-bar app, but while Setup or Settings is open it behaves like a normal app:
    /// a Dock icon and a ⌘Tab entry, so the window can't get lost behind other apps.
    func updateDockPresence() {
        let windowOpen = [setupWindow, settingsWindow].contains { $0?.isVisible == true }
        let policy: NSApplication.ActivationPolicy = windowOpen ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if windowOpen { NSApp.activate(ignoringOtherApps: true) }
    }

    /// Dock icon clicked: bring back whichever window is open. False when none is.
    @discardableResult
    func reopenWindows() -> Bool {
        if let setupWindow, setupWindow.isVisible || !SetupModel.hasCompletedSetup {
            Self.bringToFront(setupWindow)
        } else if let settingsWindow, settingsWindow.isVisible {
            Self.bringToFront(settingsWindow)
        } else {
            return false
        }
        updateDockPresence()
        return true
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
            workLogPanel = FloatingPanelController(size: NSSize(width: 560, height: 168), hidesOnResign: !CommandLine.arguments.contains("--keep-open")) {
                AnyView(WorkLogHUD().environment(self))
            }
        }
        workLogPanel?.show()
    }

    func hideWorkLog() {
        workLogPanel?.hide()
        previousApp?.activate()
    }

    func resizeWorkLog(toHeight height: CGFloat) {
        workLogPanel?.resize(to: NSSize(width: 560, height: height))
    }

    /// `date` nil means now; a back-dated entry isn't tagged with the app you're in today.
    func appendWorkLog(_ text: String, date: Date? = nil) {
        let app = date == nil ? workLogContextApp : nil
        do {
            try workLog.append(text: text, app: app, date: date ?? .now)
            knowledge.scheduleSync()
        } catch {
            showHUD("Couldn't save: \(error.localizedDescription)")
        }
    }

    /// From the Work Log HUD: open the launcher on the review screen.
    func openPerformanceReview() {
        workLogPanel?.hide()
        if !isLauncherVisible { showLauncher() }
        launcher.push(.performanceReview)
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
            showHUD("Copied. Allow Accessibility in Setup to paste directly")
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
