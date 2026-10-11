import Search
import SwiftUI

/// Search Snippets: filter by name, keyword or text; ↩ pastes into the app you were in.
struct SnippetsView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var selectedID: UUID?
    @FocusState private var focused: Bool

    var body: some View {
        let items = filtered
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { app.launcher.pop() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Image(systemName: "text.quote").foregroundStyle(.red)
                TextField("Search snippets…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
                    .onSubmit { if let selected = selected(in: items) { app.pasteSnippet(selected) } }
                    .onKeyPress(.downArrow) { move(1, in: items); return .handled }
                    .onKeyPress(.upArrow) { move(-1, in: items); return .handled }
                Button { app.launcher.push(.snippetEditor(Snippet(name: "", text: ""), isNew: true)) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).keyboardShortcut("n", modifiers: .command).help("Create Snippet (⌘N)")
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            Divider()

            if app.savedSnippets.isEmpty {
                empty
            } else {
                HStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        List(items, id: \.id, selection: $selectedID) { snippet in
                            HStack {
                                Text(snippet.name).lineLimit(1)
                                Spacer()
                                if let keyword = snippet.keyword { KeyCap(text: keyword) }
                            }
                            .tag(snippet.id).id(snippet.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { app.pasteSnippet(snippet) }
                            .contextMenu { actions(for: snippet) }
                        }
                        .listStyle(.sidebar)
                        .scrollContentBackground(.hidden)
                        .onChange(of: selectedID) { _, id in if let id { proxy.scrollTo(id) } }
                    }
                    .frame(width: 280)
                    Divider()
                    preview(selected(in: items))
                }
            }

            ActionBar(hints: [("Paste", "↩"), ("Copy", "⌘C"), ("Edit", "⌘E"), ("New", "⌘N")]) {
                Text("\(app.savedSnippets.count) snippets").font(.caption).foregroundStyle(.secondary)
            }
            .background {
                Group {
                    Button("") { if let selected = selected(in: items) { app.copySnippet(selected) } }.keyboardShortcut("c", modifiers: .command)
                    Button("") { if let selected = selected(in: items) { app.launcher.push(.snippetEditor(selected, isNew: false)) } }.keyboardShortcut("e", modifiers: .command)
                    Button("") { if let selected = selected(in: items) { delete(selected) } }.keyboardShortcut(.delete, modifiers: .command)
                }
                .opacity(0)
            }
        }
        .onAppear { focused = true }
    }

    private var filtered: [Snippet] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = app.savedSnippets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !text.isEmpty else { return all }
        return all.filter { $0.name.lowercased().contains(text) || ($0.keyword?.lowercased().contains(text) ?? false) || $0.text.lowercased().contains(text) }
    }

    private func selected(in items: [Snippet]) -> Snippet? {
        items.first { $0.id == selectedID } ?? items.first
    }

    private func move(_ delta: Int, in items: [Snippet]) {
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == selected(in: items)?.id } ?? 0
        selectedID = items[max(0, min(items.count - 1, index + delta))].id
    }

    @ViewBuilder
    private func preview(_ snippet: Snippet?) -> some View {
        if let snippet {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView {
                    Text(Snippet.expand(snippet.text, clipboard: NSPasteboard.general.string(forType: .string)).text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow { Text("Name").foregroundStyle(.secondary); Text(snippet.name) }
                    GridRow { Text("Keyword").foregroundStyle(.secondary); Text(snippet.keyword ?? "None") }
                    GridRow { Text("Characters").foregroundStyle(.secondary); Text("\(snippet.text.count)") }
                }
                .font(.caption)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Text("No snippets match “\(query)”.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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

    @ViewBuilder
    private func actions(for snippet: Snippet) -> some View {
        Button("Paste") { app.pasteSnippet(snippet) }
        Button("Copy") { app.copySnippet(snippet) }
        Button("Edit") { app.launcher.push(.snippetEditor(snippet, isNew: false)) }
        Divider()
        Button("Delete", role: .destructive) { delete(snippet) }
    }

    private func delete(_ snippet: Snippet) {
        Task {
            await app.snippetStore.delete(snippet.id)
            app.snippetsChanged()
        }
    }
}
