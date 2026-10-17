import Search
import SwiftUI

/// Create or edit a snippet: name, the text (with placeholders you can insert and a live
/// preview), and an optional keyword that expands it in any app. ⌘↩ saves. Typing `{` or
/// clicking + opens the placeholder picker.
struct SnippetEditorView: View {
    @Environment(AppModel.self) private var app
    @State private var snippet: Snippet
    @State private var selection: TextSelection?
    @State private var showPicker = false
    /// Where the `{` that opened the picker sits; choosing a placeholder replaces it.
    @State private var braceOffset: Int?
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
                                TextEditor(text: $snippet.text, selection: $selection)
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
                                Button { braceOffset = nil; showPicker.toggle() } label: {
                                    Image(systemName: "plus.circle.fill").font(.title3)
                                }
                                .buttonStyle(.borderless)
                                .help("Insert a placeholder (or type {)")
                                .padding(8)
                            }
                            .popover(isPresented: $showPicker, attachmentAnchor: .point(UnitPoint(x: 0.97, y: 0.92)), arrowEdge: .bottom) {
                                PlaceholderPicker(items: pickerItems) { item in
                                    showPicker = false
                                    choose(item)
                                }
                            }
                            .onChange(of: snippet.text) { old, new in openPickerIfBraceTyped(old: old, new: new) }
                            .onChange(of: showPicker) { _, shown in if !shown { braceOffset = nil; focus = .text } }
                            Text("Include {Dynamic Placeholders} for context like the copied text, the date, or an {argument} you fill in when pasting: + inserts one at the caret.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if !snippet.arguments.isEmpty {
                                Text("Asks for: \(snippet.arguments.map { $0.options.isEmpty ? $0.label : "\($0.label) (\($0.options.joined(separator: " / ")))" }.joined(separator: ", "))")
                                    .font(.caption).foregroundStyle(.green)
                            }
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

            ActionBar(actions: [.init(title: isNew ? "Save Snippet" : "Save Changes", key: "⌘↩") { save() }, .init(title: "Back", key: "esc") { app.launcher.pop() }]) {
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
        let arguments = Dictionary(snippet.arguments.map { ($0.key, $0.defaultValue ?? "‹\($0.label)›") }, uniquingKeysWith: { first, _ in first })
        return Snippet.expand(snippet.text, clipboard: "‹copied text›", selection: "‹selected text›", snippets: app.savedSnippets, arguments: arguments).text
            .replacingOccurrences(of: "\n", with: " ⏎ ")
    }

    // MARK: Insert placeholders

    /// Raycast's "+" menu: each item drops its placeholder at the caret (replacing a selection).
    private var pickerItems: [PlaceholderPicker.Item] {
        let now = Date.now
        var items: [PlaceholderPicker.Item] = [
            .init(title: "Cursor Position", symbol: "character.cursor.ibeam", token: "{cursor}"),
            .init(title: "Clipboard Text", symbol: "clipboard", token: "{clipboard}"),
            .init(title: "Previous Clipboard Text", symbol: "clock.arrow.circlepath", token: "{clipboard offset=1}"),
            .init(title: "Selected Text", symbol: "selection.pin.in.out", token: "{selection}"),
            .init(title: "Argument", symbol: "character.textbox", token: PlaceholderPicker.Item.argumentToken),
            .init(title: "UUID", symbol: "touchid", token: "{uuid}"),
        ]
        let date = "Date & Time"
        items += [
            .init(title: "Time", symbol: "clock", token: "{time}", example: now.formatted(date: .omitted, time: .shortened), section: date),
            .init(title: "Date", symbol: "calendar", token: "{date}", example: now.formatted(date: .abbreviated, time: .omitted), section: date),
            .init(title: "Date & Time", symbol: "calendar.badge.clock", token: "{datetime}", example: now.formatted(date: .abbreviated, time: .shortened), section: date),
            .init(title: "Weekday", symbol: "calendar.day.timeline.left", token: "{day}", example: now.formatted(.dateTime.weekday(.wide)), section: date),
            .init(title: "Tomorrow", symbol: "sunrise", token: #"{date offset="+1d"}"#, example: now.addingTimeInterval(86_400).formatted(date: .abbreviated, time: .omitted), section: date),
            .init(title: "Custom Format", symbol: "calendar.badge.plus", token: #"{date format="yyyy-MM-dd"}"#, example: now.formatted(.iso8601.year().month().day()), section: date),
        ]
        items += app.savedSnippets.filter { $0.id != snippet.id }.map { other in
            .init(title: other.name, symbol: "text.quote", token: "{snippet name=\"\(other.name.replacingOccurrences(of: "\"", with: ""))\"}", section: "Snippets")
        }
        return items
    }

    /// A single `{` typed into the editor opens the picker; dismissing it keeps the brace.
    private func openPickerIfBraceTyped(old: String, new: String) {
        guard !showPicker, new.count == old.count + 1 else { return }
        let offset = zip(old, new).prefix { $0 == $1 }.count
        guard new[new.index(new.startIndex, offsetBy: offset)] == "{" else { return }
        braceOffset = offset
        showPicker = true
    }

    private func choose(_ item: PlaceholderPicker.Item) {
        // Replace the typed `{` (if it's still there) rather than nesting a second brace.
        if let braceOffset, braceOffset < snippet.text.count {
            let index = snippet.text.index(snippet.text.startIndex, offsetBy: braceOffset)
            if snippet.text[index] == "{" { selection = TextSelection(range: index..<snippet.text.index(after: index)) }
        }
        braceOffset = nil
        if item.token == PlaceholderPicker.Item.argumentToken { insertArgument() } else { insert(item.token) }
    }

    /// `{argument name="argument"}` with the name selected, so typing renames it.
    private func insertArgument() {
        let used = Set(snippet.arguments.compactMap(\.name))
        let name = (1...).lazy.map { $0 == 1 ? "argument" : "argument\($0)" }.first { !used.contains($0) } ?? "argument"
        insert("{argument name=\"\(name)\"}", select: 16..<(16 + name.count))
    }

    /// Replaces the selection (or inserts at the caret; at the end when the editor never had focus).
    /// `select` is a range inside `token` to select afterwards; otherwise the caret goes after it.
    private func insert(_ token: String, select: Range<Int>? = nil) {
        var text = snippet.text
        let range: Range<String.Index> = switch selection?.indices {
        case .selection(let range)? where range.upperBound <= text.endIndex: range
        default: text.endIndex..<text.endIndex
        }
        let start = text.distance(from: text.startIndex, to: range.lowerBound)
        text.replaceSubrange(range, with: token)
        snippet.text = text
        let offsets = select.map { (start + $0.lowerBound)..<(start + $0.upperBound) } ?? (start + token.count)..<(start + token.count)
        let lower = snippet.text.index(snippet.text.startIndex, offsetBy: offsets.lowerBound)
        let upper = snippet.text.index(snippet.text.startIndex, offsetBy: offsets.upperBound)
        selection = lower == upper ? TextSelection(insertionPoint: lower) : TextSelection(range: lower..<upper)
        focus = .text
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
