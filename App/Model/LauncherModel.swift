import AIEngine
import AppKit
import DevTools
import Foundation
import Observation
import Search

/// The launcher's state: the search query and results, and a stack of pushed views (routes).
@Observable
@MainActor
final class LauncherModel {
    enum Route {
        case search
        case chat(ChatSession)
        case chats
        case clipboard
        case notes(URL?)
        case devTools
        case ports
        case processes
        case quicklinks
        case aiJob(AIJob)
        case knowledge(query: String, ask: Bool)
        case translate(String)
        case screenshots
        case extensionView(ExtensionSession)
    }

    struct Section {
        let title: String
        let items: [LauncherItem]
    }

    var query = "" {
        didSet {
            if query != oldValue {
                semanticItems = []
                refresh()
                searchSemantically()
            }
        }
    }
    private(set) var sections: [Section] = []
    /// Semantic matches for the current query (filled in asynchronously).
    private(set) var semanticItems: [LauncherItem] = []
    @ObservationIgnored private var semanticTask: Task<Void, Never>?
    private(set) var selectedID: String?
    private(set) var stack: [Route] = []
    /// Bumped each time the panel is summoned (the mark flicks its tongue, focus returns).
    private(set) var summonCount = 0

    var route: Route { stack.last ?? .search }

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var apps: [AppEntry] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    var allItems: [LauncherItem] { sections.flatMap(\.items) }
    var selectedItem: LauncherItem? { allItems.first { $0.id == selectedID } ?? allItems.first }

    func summoned() {
        summonCount += 1
        refresh()
    }

    func setApps(_ apps: [AppEntry]) {
        self.apps = apps
        refresh()
    }

    // MARK: Navigation

    func push(_ route: Route) { stack.append(route) }

    /// Whether an extension session is still on the stack (it keeps running while pushed under).
    func isShowing(_ session: ExtensionSession) -> Bool {
        stack.contains { if case .extensionView(let other) = $0 { other === session } else { false } }
    }

    func pop() {
        if !stack.isEmpty { stack.removeLast() }
    }

    /// Esc: pop a level, clear the query, then hide.
    func escape() {
        if !stack.isEmpty {
            pop()
        } else if !query.isEmpty {
            query = ""
        } else {
            app?.hideLauncher()
        }
    }

    func resetToRoot() {
        stack.removeAll()
        query = ""
    }

    func move(_ delta: Int) {
        let items = allItems
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedID } ?? 0
        selectedID = items[max(0, min(items.count - 1, current + delta))].id
    }

    func select(_ id: String) { selectedID = id }

    func performSelected() {
        guard let item = selectedItem else { return }
        app?.recordUse(item.id)
        if !item.perform() { app?.hideLauncher() }
    }

    func askAI() {
        guard let app else { return }
        let session = ChatSession(ai: app.ai)
        let text = query
        push(.chat(session))
        if !text.trimmingCharacters(in: .whitespaces).isEmpty { session.send(text) }
        query = ""
    }

    // MARK: Results

    func refresh() {
        guard let app else { return }
        let query = query
        let sources = app.searchSources(apps: apps)
        let ranked = query.isEmpty ? [] : app.rank(sources, query: query)
        var sections: [Section] = []
        if query.isEmpty {
            // Suggestions = things you actually use (frecency), then the built-in commands.
            let used = sources.filter { app.frecency.boost(for: $0.id) > 0.05 }
                .sorted { app.frecency.boost(for: $0.id) > app.frecency.boost(for: $1.id) }
            if !used.isEmpty { sections.append(Section(title: "Recent", items: Array(used.prefix(6)))) }
            let usedIDs = Set(used.prefix(6).map(\.id))
            sections.append(Section(title: "Commands", items: sources.filter { $0.kind == .command && !usedIDs.contains($0.id) }))
            let extensionCommands = sources.filter { $0.kind == .extensionCommand && !usedIDs.contains($0.id) }
            if !extensionCommands.isEmpty { sections.append(Section(title: "Extensions", items: extensionCommands)) }
        } else {
            if let result = Calculator.evaluate(query) {
                sections.append(Section(title: "Calculator", items: [
                    LauncherItem(id: "calculator", title: "= \(result.display)", subtitle: query, icon: .symbol("equal.square.fill", .orange), kind: .command,
                        actions: [LauncherAction(title: "Paste Result", symbol: "doc.on.clipboard") { [weak app] in app?.pasteText(result.copyText); return false }]) { [weak app] in
                        app?.copyText(result.copyText)
                        return false
                    },
                ]))
            }
            if !ranked.isEmpty { sections.append(Section(title: "Results", items: Array(ranked.prefix(30)))) }
            if !semanticItems.isEmpty { sections.append(Section(title: "From your notes", items: semanticItems)) }
            sections.append(Section(title: "Use “\(query)” with…", items: fallbacks(for: query)))
        }
        self.sections = sections
        if !allItems.contains(where: { $0.id == selectedID }) { selectedID = allItems.first?.id }
    }

    /// Top passages by meaning, shown under the regular results (debounced; 4+ characters).
    private func searchSemantically() {
        semanticTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 4, let app else { return }
        semanticTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let hits = await app.knowledge.search(text, limit: 3).filter { $0.similarity > 0.45 || $0.similarity == 0 }
            guard !Task.isCancelled, text == query.trimmingCharacters(in: .whitespaces) else { return }
            semanticItems = hits.map { hit in
                LauncherItem(id: "knowledge:\(hit.id)", title: hit.title, subtitle: hit.text.replacingOccurrences(of: "\n", with: " "),
                    icon: .symbol(hit.source.symbol, Brand.teal), kind: .note) { [weak app] in
                    app?.knowledge.open(hit)
                    return hit.source == .note || hit.source == .chat
                }
            }
            refresh()
        }
    }

    /// Always-present actions for typed text: ask AI, quicklinks.
    private func fallbacks(for query: String) -> [LauncherItem] {
        guard let app else { return [] }
        var items = [
            LauncherItem(id: "fallback.ai", title: "Ask AI", subtitle: query, icon: .symbol("sparkles", Brand.moss), kind: .ai) { [weak self] in
                self?.askAI()
                return true
            }
        ]
        items.append(LauncherItem(id: "fallback.translate", title: "Translate", subtitle: query, icon: .symbol("character.bubble", .blue), kind: .command) { [weak self] in
            self?.push(.translate(query))
            return true
        })
        items.append(LauncherItem(id: "fallback.ask-notes", title: "Ask Your Notes", subtitle: query, icon: .symbol("sparkle.magnifyingglass", Brand.teal), kind: .ai) { [weak self] in
            self?.push(.knowledge(query: query, ask: true))
            return true
        })
        items += app.quicklinkFallbacks(for: query)
        return items
    }
}
