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
            case .aiJob(let job):
                AIJobView(job: job)
            case .knowledge(let query, let ask):
                KnowledgeView(query: query, ask: ask)
            case .translate(let text):
                TranslateView(text: text)
            case .extensionView(let session):
                ExtensionView(session: session)
            }
        }
        .frame(width: Metrics.launcherSize.width, height: Metrics.launcherSize.height)
        .launcherGlass()
        .onKeyPress(.escape) {
            launcher.escape()
            return .handled
        }
    }
}

/// The main search: field, results, action bar.
struct SearchView: View {
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool
    @State private var showActions = false

    var body: some View {
        @Bindable var launcher = app.launcher
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                LizardMarkView(size: 24, summon: launcher.summonCount > 0)
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
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(launcher.sections, id: \.title) { section in
                            Text(section.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, 8)
                            ForEach(section.items) { item in
                                ResultRow(item: item, selected: launcher.selectedID == item.id)
                                    .id(item.id)
                                    .onTapGesture { launcher.select(item.id); launcher.performSelected() }
                            }
                        }
                    }
                    .padding(6)
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
}

struct ResultRow: View {
    let item: LauncherItem
    let selected: Bool

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
        .selectableRow(selected)
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
