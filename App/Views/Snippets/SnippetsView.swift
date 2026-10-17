import Search
import SwiftUI

/// Search Snippets, like Raycast's: filter by name, keyword or text and by type; snippets grouped
/// by when they were last used or changed; the selected one's `{argument}`s become fields next to
/// the search, filled live into the preview. ↩ pastes into the app you were in, ⌘K lists actions.
struct SnippetsView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var type: Snippet.ContentType?
    @State private var selectedID: UUID?
    /// Values typed for the selected snippet's arguments, by `Argument.key`.
    @State private var values: [String: String] = [:]
    @State private var showActions = false
    @FocusState private var focus: Field?
    /// Opened for this snippet (a keyword with arguments, or ↩ in the main search).
    private let initialID: UUID?

    private enum Field: Hashable {
        case search
        case argument(String)
    }

    init(focus: UUID? = nil) {
        initialID = focus
        _selectedID = State(initialValue: focus)
    }

    var body: some View {
        let groups = grouped
        let items = groups.flatMap(\.items)
        let selected = items.first { $0.id == selectedID } ?? items.first
        VStack(spacing: 0) {
            header(selected, items: items)
            Divider()

            if app.savedSnippets.isEmpty {
                empty
            } else {
                HStack(spacing: 0) {
                    list(groups)
                        .frame(width: 330)
                    Divider()
                    detail(selected)
                }
            }

            ActionBar(actions: selected.map { selected in
                [.init(title: "Paste to \(targetName)", key: "↩") { paste(selected) }, .init(title: "Actions", key: "⌘K") { showActions.toggle() }]
            } ?? [.init(title: "New", key: "⌘N") { app.launcher.push(.snippetEditor(Snippet(name: "", text: ""), isNew: true)) }]) {
                Label("Search Snippets", systemImage: "text.quote").font(.caption).foregroundStyle(.secondary)
            }
            .background {
                Group {
                    Button("") { showActions.toggle() }.keyboardShortcut("k", modifiers: .command)
                    Button("") { if let selected { copy(selected) } }.keyboardShortcut(.return, modifiers: .command)
                    Button("") { if let selected { app.launcher.push(.snippetEditor(selected, isNew: false)) } }.keyboardShortcut("e", modifiers: .command)
                    Button("") { if let selected { app.duplicateSnippet(selected) } }.keyboardShortcut("d", modifiers: .command)
                    Button("") { if let selected { app.deleteSnippet(selected) } }.keyboardShortcut(.delete, modifiers: .command)
                    Button("") { app.launcher.push(.snippetEditor(Snippet(name: "", text: ""), isNew: true)) }.keyboardShortcut("n", modifiers: .command)
                }
                .opacity(0)
            }
        }
        .popover(isPresented: $showActions, arrowEdge: .bottom) {
            ActionsMenu(actions: selected.map(actions) ?? []) { action in
                showActions = false
                if !action.perform() { app.hideLauncher() }
            }
        }
        .onAppear {
            let arguments = items.first { $0.id == initialID }?.arguments ?? []
            focus = arguments.first.map { .argument($0.key) } ?? .search
        }
        .onChange(of: selected?.id) { values = [:] }
    }

    // MARK: Header

    private func header(_ selected: Snippet?, items: [Snippet]) -> some View {
        HStack(spacing: 10) {
            Button { app.launcher.pop() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
            TextField("Search snippets…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($focus, equals: .search)
                .frame(minWidth: 140)
                .onSubmit { if let selected { paste(selected) } }
                .onKeyPress(.downArrow) { move(1, in: items); return .handled }
                .onKeyPress(.upArrow) { move(-1, in: items); return .handled }
            if let selected {
                ForEach(selected.arguments) { argument in
                    argumentField(argument, of: selected)
                }
            }
            Spacer(minLength: 0)
            Picker("Type", selection: $type) {
                Text("All Types").tag(Snippet.ContentType?.none)
                Divider()
                ForEach(Snippet.ContentType.allCases, id: \.self) { kind in
                    Label(kind.rawValue, systemImage: kind.symbol).tag(Optional(kind))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
    }

    /// One argument: a menu when it has `options`, otherwise a small field showing its name.
    @ViewBuilder
    private func argumentField(_ argument: Snippet.Argument, of snippet: Snippet) -> some View {
        if argument.options.isEmpty {
            TextField(argument.defaultValue ?? argument.label, text: Binding(get: { values[argument.key] ?? "" }, set: { values[argument.key] = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($focus, equals: .argument(argument.key))
                .onSubmit { paste(snippet) }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .frame(width: 130)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(focus == .argument(argument.key) ? Brand.moss : Color.primary.opacity(0.25), lineWidth: 1))
                .help(argument.label)
        } else {
            Picker(argument.label, selection: Binding(get: { values[argument.key] ?? argument.defaultValue ?? "" }, set: { values[argument.key] = $0 })) {
                ForEach(argument.options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .help(argument.label)
        }
    }

    // MARK: List

    private func list(_ groups: [(title: String, items: [Snippet])]) -> some View {
        ScrollViewReader { proxy in
            List(selection: $selectedID) {
                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.items) { snippet in
                            SnippetRow(snippet: snippet)
                                .tag(snippet.id).id(snippet.id)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { paste(snippet) }
                                .contextMenu {
                                    ForEach(actions(for: snippet)) { action in
                                        Button(action.title, systemImage: action.symbol) { if !action.perform() { app.hideLauncher() } }
                                    }
                                }
                        }
                    }
                }
                if groups.isEmpty {
                    Text(query.isEmpty ? "No \(type?.rawValue.lowercased() ?? "") snippets." : "No snippets match “\(query)”.")
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onChange(of: selectedID) { _, id in if let id { proxy.scrollTo(id) } }
            .onAppear { if let initialID { proxy.scrollTo(initialID) } }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private func detail(_ snippet: Snippet?) -> some View {
        if let snippet {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    Text(preview(snippet))
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .frame(maxHeight: .infinity)
                Divider()
                information(snippet)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The pasted text, with argument values in green (unfilled ones show their name, dimmed).
    private func preview(_ snippet: Snippet) -> AttributedString {
        let arguments = snippet.arguments
        var shown: [String: String] = [:]
        for argument in arguments {
            shown[argument.key] = filled(argument) ?? argument.defaultValue ?? argument.label
        }
        let expansion = Snippet.expand(snippet.text, clipboard: NSPasteboard.general.string(forType: .string), snippets: app.savedSnippets, arguments: shown)
        var result = AttributedString(expansion.text)
        let characters = Array(result.characters.indices)
        for mark in expansion.argumentRanges where !mark.range.isEmpty && mark.range.upperBound <= characters.count {
            let end = mark.range.upperBound == characters.count ? result.endIndex : characters[mark.range.upperBound]
            let range = characters[mark.range.lowerBound]..<end
            let isFilled = arguments.first { $0.key == mark.key }.map { filled($0) != nil || $0.defaultValue != nil } ?? false
            result[range].foregroundColor = isFilled ? Color.green : Color.secondary
            if !isFilled { result[range].backgroundColor = Color.primary.opacity(0.08) }
        }
        return result
    }

    private func information(_ snippet: Snippet) -> some View {
        let usage = app.snippetUsage[snippet.id]
        return VStack(alignment: .leading, spacing: 0) {
            Text("Information").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 6)
            infoRow("Name", snippet.name)
            infoRow("Content type", snippet.contentType.rawValue)
            if let keyword = snippet.keyword { infoRow("Keyword", keyword) }
            if !snippet.arguments.isEmpty { infoRow("Arguments", snippet.arguments.map(\.label).joined(separator: ", ")) }
            infoRow("Times used", "\(usage?.count ?? 0)")
            if let lastUsed = usage?.lastUsed { infoRow("Last used", Self.format(lastUsed)) }
            if let modified = snippet.modified { infoRow("Modified", Self.format(modified)) }
            if let created = snippet.created { infoRow("Created", Self.format(created), divider: false) }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func infoRow(_ label: String, _ value: String, divider: Bool = true) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value).lineLimit(1).truncationMode(.middle)
            }
            .padding(.vertical, 5)
            if divider { Divider() }
        }
    }

    /// "Today at 08:46", "Yesterday at 17:02", "Oct 9, 2026 at 10:00".
    private static func format(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "Today at \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday at \(time)" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: Data

    /// Matching snippets in sections by their latest activity (used, edited or created), newest first.
    private var grouped: [(title: String, items: [Snippet])] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = app.savedSnippets.filter { snippet in
            (type == nil || snippet.contentType == type)
                && (text.isEmpty || snippet.name.lowercased().contains(text) || (snippet.keyword?.lowercased().contains(text) ?? false) || snippet.text.lowercased().contains(text))
        }
        let calendar = Calendar.current
        let now = Date.now
        var buckets: [String: [(Snippet, Date?)]] = [:]
        for snippet in matches {
            let date = [app.snippetUsage[snippet.id]?.lastUsed, snippet.modified, snippet.created].compactMap(\.self).max()
            let title: String
            if let date, calendar.isDateInToday(date) {
                title = "Today"
            } else if let date, calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
                title = "This Week"
            } else if let date, calendar.isDate(date, equalTo: now, toGranularity: .month) {
                title = "This Month"
            } else {
                title = "Earlier"
            }
            buckets[title, default: []].append((snippet, date))
        }
        return ["Today", "This Week", "This Month", "Earlier"].compactMap { title in
            guard let entries = buckets[title] else { return nil }
            let sorted = entries.sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return (lhs.1 ?? .distantPast) > (rhs.1 ?? .distantPast) }
                return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
            }
            return (title, sorted.map(\.0))
        }
    }

    private var targetName: String { app.previousApp?.localizedName ?? "App" }

    private func filled(_ argument: Snippet.Argument) -> String? {
        values[argument.key].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Typed values; arguments left empty fall back to their default.
    private func argumentValues(_ snippet: Snippet) -> [String: String]? {
        var result: [String: String] = [:]
        for argument in snippet.arguments {
            if let value = filled(argument) {
                result[argument.key] = value
            } else if argument.defaultValue == nil {
                // Required: send the caret there instead of pasting a hole.
                focus = .argument(argument.key)
                NSSound.beep()
                return nil
            }
        }
        return result
    }

    private func paste(_ snippet: Snippet) {
        guard let arguments = argumentValues(snippet) else { return }
        app.pasteSnippet(snippet, arguments: arguments)
    }

    private func copy(_ snippet: Snippet) {
        guard let arguments = argumentValues(snippet) else { return }
        app.copySnippet(snippet, arguments: arguments)
    }

    private func move(_ delta: Int, in items: [Snippet]) {
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == selectedID } ?? 0
        selectedID = items[max(0, min(items.count - 1, index + delta))].id
    }

    /// ⌘K and the context menu. `perform` returns true to keep the launcher open.
    private func actions(for snippet: Snippet) -> [LauncherAction] {
        [
            LauncherAction(title: "Paste to \(targetName)", symbol: "doc.on.clipboard") { paste(snippet); return true },
            LauncherAction(title: "Copy to Clipboard  ⌘↩", symbol: "doc.on.doc") { copy(snippet); return true },
            LauncherAction(title: "Edit Snippet  ⌘E", symbol: "pencil") { app.launcher.push(.snippetEditor(snippet, isNew: false)); return true },
            LauncherAction(title: "Duplicate Snippet  ⌘D", symbol: "plus.square.on.square") { app.duplicateSnippet(snippet); return true },
            LauncherAction(title: "Create Snippet  ⌘N", symbol: "text.badge.plus") { app.launcher.push(.snippetEditor(Snippet(name: "", text: ""), isNew: true)); return true },
            LauncherAction(title: "Export Snippets…", symbol: "square.and.arrow.up") { app.exportSnippets(); return true },
            LauncherAction(title: "Delete Snippet  ⌘⌫", symbol: "trash") { app.deleteSnippet(snippet); return true },
        ]
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.quote").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("No snippets yet").font(.headline)
            Text("Save text you type often: replies, signatures, commands. Give one a keyword like ;sig and it expands in any app.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
            HStack {
                Button("Create Snippet") { app.launcher.push(.snippetEditor(Snippet(name: "", text: ""), isNew: true)) }
                    .buttonStyle(.borderedProminent).tint(Brand.moss)
                Button("Import Snippets…") { app.importSnippets() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SnippetRow: View {
    let snippet: Snippet

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: snippet.contentType.symbol).foregroundStyle(.secondary).frame(width: 18)
            Text(snippet.name).lineLimit(1)
            if let keyword = snippet.keyword {
                Text(keyword)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.25)))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}

extension Snippet.ContentType {
    var symbol: String {
        switch self {
        case .text: "doc.text"
        case .link: "link"
        case .dynamic: "wand.and.stars"
        case .arguments: "character.cursor.ibeam"
        }
    }
}
