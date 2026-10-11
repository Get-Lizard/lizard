import SwiftUI

/// Root of the launcher panel: shows the current route (search, chat, clipboard, …).
struct LauncherRootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let launcher = app.launcher
        Group {
            switch launcher.route {
            case .search:
                SearchView()
            case .chat(let session):
                ChatView(session: session) { launcher.pop() }
            case .chats:
                ChatHistoryView()
            case .clipboard:
                ClipboardView()
            case .notes(let selected):
                NotesView(initial: selected)
            case .devTools:
                DevToolsView()
            case .ports:
                PortsView()
            case .processes:
                ProcessesView()
            case .quicklinks:
                QuicklinksView()
            case .quicklinkEditor(let link, let isNew):
                QuicklinkEditorView(link: link, isNew: isNew).id(link.id)
            case .aiJob(let job):
                AIJobView(job: job)
            case .knowledge(let query, let ask):
                KnowledgeView(query: query, ask: ask)
            case .translate(let text):
                TranslateView(text: text)
            case .screenshots:
                ScreenshotsView()
            case .performanceReview:
                PerformanceReviewView()
            case .extensionView(let session):
                ExtensionView(session: session)
            }
        }
        .frame(width: launcher.panelSize.width, height: launcher.panelSize.height)
        .launcherGlass()
        .overlay { BioluminescentRim(pulse: launcher.summonCount) }
        .onChange(of: launcher.panelSize) { _, size in app.resizeLauncher(to: size) }
        .onChange(of: launcher.navigationCount) { app.focusLauncherField() }
        .onKeyPress(.escape) {
            launcher.escape()
            return .handled
        }
    }
}

/// The main search: field, results (or the home "den" when empty), action bar.
struct SearchView: View {
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool
    @State private var showActions = false
    @State private var typing = false
    @State private var typingTimer: Task<Void, Never>?
    @Namespace private var selection

    var body: some View {
        @Bindable var launcher = app.launcher
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // The gecko wags its tail while you type and flicks its tongue on summon.
                LizardMarkView(size: 26, summon: launcher.summonCount > 0, thinking: typing)
                    .id(launcher.summonCount)
                TextField("Search apps, commands, notes… or ask AI", text: $launcher.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .regular))
                    .focused($focused)
                    .onSubmit { launcher.performSelected() }
                    .onKeyPress(.downArrow) { launcher.move(1); return .handled }
                    .onKeyPress(.upArrow) { launcher.move(-1); return .handled }
                    .onKeyPress(.tab) { launcher.askAI(); return .handled }
                    .onKeyPress(characters: ["k"], phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        showActions.toggle()
                        return .handled
                    }
                    .onChange(of: launcher.query) { noteTyping() }
            }
            .padding(.horizontal, 16)
            .frame(height: 58)
            Divider().overlay(Brand.moss.opacity(0.15))
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if launcher.query.isEmpty { DenHeader() }
                        ForEach(launcher.sections, id: \.title) { section in
                            SectionLabel(title: section.title)
                            ForEach(section.items) { item in
                                ResultRow(item: item, selected: launcher.selectedID == item.id, namespace: selection)
                                    .id(item.id)
                                    .onTapGesture { launcher.select(item.id); launcher.performSelected() }
                            }
                        }
                    }
                    .padding(6)
                    .animation(.spring(response: 0.28, dampingFraction: 0.82), value: launcher.selectedID)
                }
                .onChange(of: launcher.selectedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            ActionBar(hints: [("Open", "↩"), ("Actions", "⌘K"), ("Ask AI", "⇥")]) {
                if let item = launcher.selectedItem {
                    Text(item.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .popover(isPresented: $showActions, arrowEdge: .bottom) {
            ActionsMenu(actions: launcher.selectedItem?.actions ?? []) { action in
                showActions = false
                if !action.perform() { app.hideLauncher() }
            }
        }
        .onAppear { focused = true }
        .onChange(of: launcher.summonCount) { focused = true }
    }

    private func noteTyping() {
        typing = true
        typingTimer?.cancel()
        typingTimer = Task {
            try? await Task.sleep(for: .milliseconds(650))
            if !Task.isCancelled { typing = false }
        }
    }
}

/// Section titles: small caps with a leaf of moss.
private struct SectionLabel: View {
    let title: String
    var body: some View {
        HStack(spacing: 6) {
            Capsule().fill(Brand.gradient).frame(width: 10, height: 3)
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }
}

/// The launcher's home when nothing is typed: a greeting and quick tiles (⌘1…⌘8).
private struct DenHeader: View {
    @Environment(AppModel.self) private var app

    private var tiles: [(String, String, [Color], () -> Void)] {
        let launcher = app.launcher
        return [
            ("Ask AI", "sparkles", [Brand.moss, Brand.teal], { launcher.askAI() }),
            ("Clipboard", "doc.on.clipboard", [.orange, .pink], { launcher.push(.clipboard) }),
            ("Notes", "note.text", [.yellow, .orange], { launcher.push(.notes(nil)) }),
            ("Screenshots", "camera.viewfinder", [.indigo, .purple], { launcher.push(.screenshots) }),
            ("Work Log", "list.bullet.clipboard", [.teal, .blue], { app.hideLauncher(); app.showWorkLog() }),
            ("Translate", "character.bubble", [.blue, .cyan], { launcher.push(.translate("")) }),
            ("By Meaning", "text.magnifyingglass", [Brand.teal, .green], { launcher.push(.knowledge(query: "", ask: false)) }),
            ("Kill Process", "xmark.octagon", [.red, .orange], { launcher.push(.processes) }),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(Greeting.text).font(.system(size: 17, weight: .semibold, design: .rounded))
                Spacer()
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(Array(tiles.enumerated()), id: \.offset) { index, tile in
                    DenTile(title: tile.0, symbol: tile.1, colors: tile.2, shortcut: "⌘\(index + 1)", action: tile.3)
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

struct ResultRow: View {
    let item: LauncherItem
    let selected: Bool
    var namespace: Namespace.ID?

    var body: some View {
        HStack(spacing: 10) {
            LauncherIconView(icon: item.icon)
            highlightedTitle
                .lineLimit(1)
            if let subtitle = item.subtitle {
                Text(subtitle).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let accessory = item.accessory {
                Text(accessory).font(.caption).foregroundStyle(.secondary)
            }
            Text(item.kind.rawValue).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: Metrics.rowHeight)
        .contentShape(Rectangle())
        .background {
            if selected {
                // The highlight glides between rows; a moss "scale" stripe marks the current one.
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                ZStack(alignment: .leading) {
                    shape.fill(LinearGradient(colors: [Brand.moss.opacity(0.26), Brand.teal.opacity(0.10)], startPoint: .leading, endPoint: .trailing))
                    shape.strokeBorder(Brand.moss.opacity(0.35), lineWidth: 0.6)
                    Capsule().fill(Brand.gradient).frame(width: 3, height: 18).padding(.leading, 3)
                }
                .modifier(MatchedSelection(namespace: namespace))
            }
        }
    }

    private var highlightedTitle: Text {
        guard !item.highlights.isEmpty else { return Text(item.title) }
        let marks = Set(item.highlights)
        var result = AttributedString()
        for (index, character) in item.title.enumerated() {
            var piece = AttributedString(String(character))
            if marks.contains(index) {
                piece.font = .body.weight(.bold)
                piece.foregroundColor = Brand.moss
            }
            result += piece
        }
        return Text(result)
    }
}

private struct MatchedSelection: ViewModifier {
    let namespace: Namespace.ID?
    func body(content: Content) -> some View {
        if let namespace { content.matchedGeometryEffect(id: "selection", in: namespace) } else { content }
    }
}

struct ActionsMenu: View {
    let actions: [LauncherAction]
    let run: (LauncherAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if actions.isEmpty {
                Text("No actions").foregroundStyle(.secondary).padding(8)
            }
            ForEach(actions) { action in
                Button { run(action) } label: {
                    Label(action.title, systemImage: action.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(minWidth: 240)
    }
}
