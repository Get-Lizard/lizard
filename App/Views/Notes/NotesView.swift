import AppKit
import Notes
import SwiftUI

/// Markdown notes: list on the left, live-highlighted editor on the right. Files live in the
/// notes folder, so edits from other editors show up here too.
struct NotesView: View {
    @Environment(AppModel.self) private var app
    let initial: URL?

    @State private var notes: [Note] = []
    @State private var query = ""
    @State private var selected: URL?
    @State private var text = ""
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { app.launcher.pop() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Image(systemName: "note.text").foregroundStyle(Brand.moss)
                TextField("Search notes…", text: $query).textFieldStyle(.plain).font(.system(size: 17))
                Button { Task { await newNote() } } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("n", modifiers: .command)
                    .help("New note (⌘N)")
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            Divider()
            HStack(spacing: 0) {
                List(notes, selection: $selected) { note in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.title).lineLimit(1)
                        Text(note.preview.isEmpty ? note.modified.formatted(date: .abbreviated, time: .shortened) : note.preview)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(note.url)
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([note.url]) }
                        Button("Summarize with AI") { app.launcher.push(.aiJob(.summarize(text: (try? String(contentsOf: note.url, encoding: .utf8)) ?? ""))) }
                        Divider()
                        Button("Move to Trash", role: .destructive) { Task { await delete(note) } }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .frame(width: 230)
                Divider()
                if selected != nil {
                    MarkdownEditor(text: $text)
                        .onChange(of: text) { scheduleSave() }
                } else {
                    Text("No note selected").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task {
            await reload()
            if let initial { await open(initial) } else if selected == nil, let first = notes.first { await open(first.url) }
            for await _ in await app.notes.changes() { await reload() }
        }
        .task(id: query) { await reload() }
        .onChange(of: selected) { old, new in
            if let old, old != new { saveNow(to: old) }
            if let new { Task { await open(new) } }
        }
        .onDisappear { if let selected { saveNow(to: selected) } }
    }

    private func reload() async {
        notes = query.isEmpty ? await app.notes.list() : await app.notes.search(query)
    }

    private func open(_ url: URL) async {
        selected = url
        text = await app.notes.read(url)
    }

    private func newNote() async {
        if let url = try? await app.notes.create(title: query.isEmpty ? "Untitled" : query) {
            query = ""
            await reload()
            await open(url)
        }
    }

    private func delete(_ note: Note) async {
        try? await app.notes.delete(note.url)
        if selected == note.url { selected = nil; text = "" }
        await reload()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        guard let url = selected else { return }
        let snapshot = text
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            try? await app.notes.save(snapshot, to: url)
        }
    }

    private func saveNow(to url: URL) {
        saveTask?.cancel()
        let snapshot = text
        Task { try? await app.notes.save(snapshot, to: url) }
    }
}

/// NSTextView with incremental Markdown highlighting (only the edited paragraph is re-tokenized).
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = Coordinator.bodyFont
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.drawsBackground = false
        scroll.drawsBackground = false
        textView.string = text
        context.coordinator.highlight(textView, range: NSRange(location: 0, length: (text as NSString).length))
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let textView = scroll.documentView as! NSTextView
        if textView.string != text {
            textView.string = text
            context.coordinator.highlight(textView, range: NSRange(location: 0, length: (text as NSString).length))
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        static let bodyFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)

        init(_ parent: MarkdownEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            let edited = (textView.string as NSString).paragraphRange(for: textView.selectedRange())
            // A fence toggle changes everything after it.
            let paragraph = (textView.string as NSString).substring(with: edited)
            let range = paragraph.contains("```") ? NSRange(location: edited.location, length: (textView.string as NSString).length - edited.location) : edited
            highlight(textView, range: range)
        }

        func highlight(_ textView: NSTextView, range: NSRange) {
            guard let storage = textView.textStorage else { return }
            let text = textView.string
            let full = (text as NSString).paragraphRange(for: range)
            let inFence = MarkdownTokenizer.fenceState(text, upTo: full.location)
            storage.beginEditing()
            storage.setAttributes([.font: Self.bodyFont, .foregroundColor: NSColor.labelColor], range: full)
            for token in MarkdownTokenizer.tokenize(text, in: full, startsInFence: inFence) where NSMaxRange(token.range) <= storage.length {
                storage.addAttributes(attributes(for: token.kind), range: token.range)
            }
            storage.endEditing()
        }

        private func attributes(for kind: MarkdownTokenizer.Kind) -> [NSAttributedString.Key: Any] {
            let accent = NSColor(Brand.moss)
            switch kind {
            case .heading(let level):
                return [.font: NSFont.monospacedSystemFont(ofSize: [22, 19, 17, 15, 14, 14][min(level, 6) - 1], weight: .bold), .foregroundColor: accent]
            case .bold: return [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)]
            case .italic: return [.obliqueness: 0.15]
            case .inlineCode, .codeBlock: return [.foregroundColor: NSColor.systemOrange, .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.15)]
            case .fence: return [.foregroundColor: NSColor.tertiaryLabelColor]
            case .link: return [.foregroundColor: NSColor.linkColor]
            case .listMarker: return [.foregroundColor: accent]
            case .blockquote: return [.foregroundColor: NSColor.secondaryLabelColor]
            case .taskOpen: return [.foregroundColor: accent]
            case .taskDone: return [.foregroundColor: NSColor.tertiaryLabelColor, .strikethroughStyle: NSUnderlineStyle.single.rawValue]
            case .rule: return [.foregroundColor: NSColor.tertiaryLabelColor]
            }
        }
    }
}
