import Search
import SwiftUI

/// Create or edit a snippet: name, the text (with placeholders you can insert and a live
/// preview), and an optional keyword that expands it in any app. ⌘↩ saves.
struct SnippetEditorView: View {
    @Environment(AppModel.self) private var app
    @State private var snippet: Snippet
    private let isNew: Bool

    private enum Field { case name, text, keyword }
    @FocusState private var focus: Field?

    init(snippet: Snippet, isNew: Bool) {
        _snippet = State(initialValue: snippet)
        self.isNew = isNew
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { app.launcher.pop() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Image(systemName: "text.quote").foregroundStyle(.red)
                Text(isNew ? "Create Snippet" : "Edit Snippet").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            Divider()

            ScrollView {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 18) {
                    row("Name") {
                        TextField("Snippet name", text: $snippet.name)
                            .textFieldStyle(.roundedBorder).controlSize(.large)
                            .focused($focus, equals: .name)
                    }
                    row("Snippet") {
                        VStack(alignment: .leading, spacing: 8) {
                            ZStack(alignment: .topLeading) {
                                TextEditor(text: $snippet.text)
                                    .font(.body)
                                    .scrollContentBackground(.hidden)
                                    .focused($focus, equals: .text)
                                    .padding(8)
                                if snippet.text.isEmpty {
                                    Text("Find your inner Shakespeare…").foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.vertical, 8).allowsHitTesting(false)
                                }
                            }
                            .frame(minHeight: 130)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(focus == .text ? Brand.moss : Color.primary.opacity(0.12)))
                            .overlay(alignment: .bottomTrailing) {
                                Menu {
                                    ForEach(Snippet.placeholders, id: \.token) { item in
                                        Button("\(item.token)  \(item.meaning)") { snippet.text += item.token; focus = .text }
                                    }
                                } label: {
                                    Image(systemName: "plus.circle.fill").font(.title3)
                                }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                .help("Insert a placeholder")
                                .padding(8)
                            }
                            Text("Include {placeholders} for context like the copied text or today's date: + inserts one.")
                                .font(.caption).foregroundStyle(.secondary)
                            if let preview {
                                Text("Pastes: \(preview)").font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                            }
                        }
                    }
                    row("Keyword") {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Optional keyword, e.g. ;sig", text: Binding(get: { snippet.keyword ?? "" }, set: { snippet.keyword = $0.isEmpty ? nil : $0 }))
                                .textFieldStyle(.roundedBorder).controlSize(.large).frame(maxWidth: 220)
                                .focused($focus, equals: .keyword)
                            Text(keywordHint).font(.caption).foregroundStyle(keywordClash == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 26)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }

            ActionBar(hints: [(isNew ? "Save Snippet" : "Save Changes", "⌘↩"), ("Back", "esc")]) {
                Label(isNew ? "Create Snippet" : "Edit Snippet", systemImage: "text.quote").font(.caption).foregroundStyle(.secondary)
            }
            .background {
                Button("") { save() }.keyboardShortcut(.return, modifiers: .command).opacity(0)
            }
        }
        .onAppear { focus = snippet.name.isEmpty ? .name : .text }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing).frame(minWidth: 80, alignment: .trailing)
            content()
        }
    }

    private var preview: String? {
        guard snippet.text.contains("{") else { return nil }
        return Snippet.expand(snippet.text, clipboard: "‹copied text›", selection: "‹selected text›").text
            .replacingOccurrences(of: "\n", with: " ⏎ ")
    }

    private var keywordClash: Snippet? {
        guard let keyword = snippet.keyword, !keyword.isEmpty else { return nil }
        return app.savedSnippets.first { $0.id != snippet.id && $0.keyword == keyword }
    }

    private var keywordHint: String {
        if let clash = keywordClash { return "“\(clash.name)” already uses this keyword." }
        if let keyword = snippet.keyword, !keyword.isEmpty {
            return SnippetExpander.isEnabled
                ? "Type “\(keyword)” in any app and it turns into this snippet."
                : "Keyword expansion is off (Settings › General); the keyword still finds it in search."
        }
        return "Typed in any app, it expands into the snippet. Start it with a symbol like ; so it never fires by accident."
    }

    private func save() {
        snippet.name = snippet.name.trimmingCharacters(in: .whitespaces)
        guard !snippet.name.isEmpty, !snippet.text.isEmpty, keywordClash == nil else {
            focus = snippet.name.isEmpty ? .name : snippet.text.isEmpty ? .text : .keyword
            NSSound.beep()
            return
        }
        let saved = snippet
        Task {
            await app.snippetStore.save(saved)
            app.snippetsChanged()
            app.showHUD("Saved snippet “\(saved.name)”")
            app.launcher.pop()
        }
    }
}
