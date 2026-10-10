import AIEngine
import AppKit
import MarkdownUI
import Notes
import SwiftUI

/// Notes: a library sidebar (pinned, snippets, folders, tags), the note list, and an editor that
/// flips to a reading view where every code block has a copy button.
struct NotesView: View {
    @Environment(AppModel.self) private var app
    let initial: URL?

    enum Scope: Hashable {
        case all, pinned, snippets
        case folder(String)
        case tag(String)
    }

    @State private var notes: [Note] = []
    @State private var folders: [String] = []
    @State private var scope = Scope.all
    @State private var query = ""
    @State private var selected: URL?
    @State private var text = ""
    @State private var reading = false
    @State private var saveTask: Task<Void, Never>?
    @State private var suggestion: AppleIntelligence.NoteOrganization?
    @State private var organizing = false
    @State private var newFolderName: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 150)
                Divider()
                list.frame(width: 215)
                Divider()
                editor
            }
        }
        .task {
            await reload()
            if let initial { await open(initial) } else if selected == nil, let first = visible.first { await open(first.url) }
            for await _ in await app.notes.changes() { await reload() }
        }
        .onChange(of: selected) { old, new in
            if let old, old != new { saveNow(to: old) }
            if let new { Task { await open(new) } }
        }
        .onDisappear { if let selected { saveNow(to: selected) } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Button { app.launcher.pop() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
            Image(systemName: "note.text").foregroundStyle(Brand.moss)
            TextField("Search notes, #tags, folders…", text: $query).textFieldStyle(.plain).font(.system(size: 17))
            Button { Task { await newNote() } } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless).keyboardShortcut("n", modifiers: .command).help("New note (⌘N)")
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                SidebarRow(title: "All Notes", symbol: "tray.full", count: notes.count, selected: scope == .all) { scope = .all }
                SidebarRow(title: "Pinned", symbol: "pin", count: notes.filter(\.pinned).count, selected: scope == .pinned) { scope = .pinned }
                SidebarRow(title: "Snippets", symbol: "terminal", count: notes.filter { $0.snippet != nil }.count, selected: scope == .snippets) { scope = .snippets }

                SectionTitle(text: "Folders") {
                    Button { newFolderName = "" } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("New folder")
                }
                if let name = newFolderName {
                    TextField("Folder name", text: Binding(get: { name }, set: { newFolderName = $0 }))
                        .textFieldStyle(.roundedBorder).font(.caption)
                        .onSubmit {
                            let folderName = newFolderName ?? ""
                            newFolderName = nil
                            guard !folderName.isEmpty else { return }
                            Task {
                                if let created = try? await app.notes.createFolder(folderName) { scope = .folder(created) }
                                await reload()
                            }
                        }
                        .onExitCommand { newFolderName = nil }
                }
                ForEach(folders, id: \.self) { folder in
                    let depth = folder.filter { $0 == "/" }.count
                    SidebarRow(title: (folder as NSString).lastPathComponent, symbol: "folder", count: notes.filter { $0.folder == folder }.count, selected: scope == .folder(folder)) {
                        scope = .folder(folder)
                    }
                    .padding(.leading, CGFloat(depth) * 10)
                    .dropDestination(for: URL.self) { urls, _ in
                        Task {
                            for url in urls { _ = try? await app.notes.move(url, toFolder: folder) }
                            await reload()
                        }
                        return true
                    }
                    .contextMenu {
                        Button("New Note Here") { Task { await newNote(in: folder) } }
                        Button("Show in Finder") { NSWorkspace.shared.open(app.notes.root.appending(path: folder)) }
                        Divider()
                        Button("Move Folder to Trash", role: .destructive) {
                            Task {
                                try? await app.notes.deleteFolder(folder)
                                scope = .all
                                await reload()
                            }
                        }
                    }
                }

                let tags = tagCounts
                if !tags.isEmpty {
                    SectionTitle(text: "Tags") { EmptyView() }
                    ForEach(tags, id: \.0) { tag, count in
                        SidebarRow(title: "#\(tag)", symbol: nil, count: count, selected: scope == .tag(tag)) { scope = .tag(tag) }
                    }
                }
            }
            .padding(6)
        }
        .background(Brand.moss.opacity(0.03))
    }

    private var tagCounts: [(String, Int)] {
        var counts: [String: Int] = [:]
        for note in notes { for tag in note.tags { counts[tag, default: 0] += 1 } }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
    }

    // MARK: List

    private var visible: [Note] {
        let scoped: [Note] = switch scope {
        case .all: notes
        case .pinned: notes.filter(\.pinned)
        case .snippets: notes.filter { $0.snippet != nil }
        case .folder(let folder): notes.filter { $0.folder == folder || $0.folder.hasPrefix(folder + "/") }
        case .tag(let tag): notes.filter { $0.tags.contains(tag) }
        }
        return scoped
    }

    private var list: some View {
        List(visible, selection: $selected) { note in
            NoteRow(note: note) { snippet in
                app.copyText(snippet)
            }
            .tag(note.url)
            .draggable(note.url)
            .contextMenu { noteMenu(note) }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .overlay {
            if visible.isEmpty {
                Text(query.isEmpty ? "No notes here yet.\n⌘N to write one." : "No matches").multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
            }
        }
        .task(id: query) { await reload() }
    }

    @ViewBuilder
    private func noteMenu(_ note: Note) -> some View {
        Button(note.pinned ? "Unpin" : "Pin") { Task { try? await app.notes.setPinned(!note.pinned, for: note.url); await reload() } }
        if let snippet = note.snippet { Button("Copy Snippet") { app.copyText(snippet) } }
        Menu("Move to") {
            Button("Top Level") { move(note, to: "") }
            ForEach(folders, id: \.self) { folder in Button(folder) { move(note, to: folder) } }
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([note.url]) }
        Button("Summarize with AI") { app.launcher.push(.aiJob(.summarize(text: (try? String(contentsOf: note.url, encoding: .utf8)) ?? ""))) }
        Divider()
        Button("Move to Trash", role: .destructive) { Task { await delete(note) } }
    }

    // MARK: Editor

    private var current: Note? { notes.first { $0.url == selected } }

    @ViewBuilder
    private var editor: some View {
        if let note = current {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if !note.folder.isEmpty { Label(note.folder, systemImage: "folder").font(.caption).foregroundStyle(.secondary) }
                    ForEach(note.tags.prefix(4), id: \.self) { Text("#\($0)").font(.caption).foregroundStyle(Brand.teal) }
                    Spacer()
                    if let suggestion { suggestionChip(suggestion, note: note) }
                    Button { Task { await organize(note) } } label: {
                        if organizing { ProgressView().controlSize(.mini) } else { Image(systemName: "wand.and.sparkles") }
                    }
                    .buttonStyle(.borderless).help("Suggest folder and tags (on-device AI)")
                    .disabled(organizing || !AppleIntelligence.isAvailable)
                    Button { Task { try? await app.notes.setPinned(!note.pinned, for: note.url); await reload(); text = await app.notes.read(note.url) } } label: {
                        Image(systemName: note.pinned ? "pin.fill" : "pin")
                    }
                    .buttonStyle(.borderless).help(note.pinned ? "Unpin" : "Pin")
                    Picker("", selection: $reading) {
                        Image(systemName: "pencil").tag(false)
                        Image(systemName: "book").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 74)
                    .help("Edit / Read (⌘E)")
                    Button("") { reading.toggle() }.keyboardShortcut("e", modifiers: .command).opacity(0).frame(width: 0)
                }
                .padding(.horizontal, 12).frame(height: 32)
                Divider()
                if reading {
                    ScrollView {
                        Markdown(NoteMetadata.parse(text).body)
                            .markdownBlockStyle(\.codeBlock) { configuration in
                                CopyableCodeBlock(language: configuration.language, code: configuration.content) { code in app.copyText(code) }
                            }
                            .textSelection(.enabled)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    LiveMarkdownEditor(text: $text) { code in app.copyText(code) }
                        .onChange(of: text) { scheduleSave() }
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "note.text").font(.largeTitle).foregroundStyle(.tertiary)
                Text("Pick a note or press ⌘N").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func suggestionChip(_ suggestion: AppleIntelligence.NoteOrganization, note: Note) -> some View {
        Button {
            Task {
                var url = note.url
                if suggestion.folder != note.folder, let moved = try? await app.notes.move(url, toFolder: suggestion.folder) { url = moved }
                try? await app.notes.setTags(Array(Set(note.tags + suggestion.tags)).sorted(), for: url)
                self.suggestion = nil
                await reload()
                selected = url
                text = await app.notes.read(url)
            }
        } label: {
            Label("\(suggestion.folder) · \(suggestion.tags.map { "#\($0)" }.joined(separator: " "))", systemImage: "checkmark.circle")
                .font(.caption).lineLimit(1)
        }
        .buttonStyle(.bordered).controlSize(.small).tint(Brand.moss)
        .help("Apply the suggested folder and tags")
    }

    // MARK: Actions

    private func reload() async {
        notes = query.isEmpty ? await app.notes.list() : await app.notes.search(query)
        folders = await app.notes.folders()
    }

    private func open(_ url: URL) async {
        selected = url
        suggestion = nil
        text = await app.notes.read(url)
        reading = NoteMetadata.parse(text).snippet != nil
    }

    private func newNote(in folder: String? = nil) async {
        let target: String = folder ?? { if case .folder(let current) = scope { return current } else { return "" } }()
        if let url = try? await app.notes.create(title: query.isEmpty ? "Untitled" : query, folder: target) {
            query = ""
            await reload()
            await open(url)
            reading = false
        }
    }

    private func move(_ note: Note, to folder: String) {
        Task {
            let url = try? await app.notes.move(note.url, toFolder: folder)
            await reload()
            if selected == note.url { selected = url }
        }
    }

    private func delete(_ note: Note) async {
        try? await app.notes.delete(note.url)
        if selected == note.url { selected = nil; text = "" }
        await reload()
    }

    private func organize(_ note: Note) async {
        organizing = true
        defer { organizing = false }
        suggestion = await AppleIntelligence.organizeNote(
            title: note.title, text: text, existingFolders: folders, existingTags: tagCounts.map(\.0))
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

// MARK: - Pieces

private struct SidebarRow: View {
    let title: String
    let symbol: String?
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).frame(width: 14).foregroundStyle(selected ? Brand.moss : .secondary) }
                Text(title).lineLimit(1)
                Spacer(minLength: 2)
                if count > 0 { Text("\(count)").font(.caption2).foregroundStyle(.tertiary) }
            }
            .font(.callout)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(selected ? Brand.moss.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct SectionTitle<Accessory: View>: View {
    let text: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack {
            Text(text.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            Spacer()
            accessory.font(.caption)
        }
        .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 2)
    }
}

private struct NoteRow: View {
    let note: Note
    let copy: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if note.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Brand.moss) }
                    Text(note.title).lineLimit(1)
                }
                if let snippet = note.snippet {
                    Text(snippet.split(separator: "\n").first.map(String.init) ?? snippet)
                        .font(.caption.monospaced()).foregroundStyle(Brand.teal).lineLimit(1)
                } else {
                    Text(note.preview.isEmpty ? note.modified.formatted(date: .abbreviated, time: .shortened) : note.preview)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let snippet = note.snippet {
                Button { copy(snippet) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy snippet")
            }
        }
    }
}

/// A code block with its language and a copy button — terminal commands are one click away.
struct CopyableCodeBlock: View {
    let language: String?
    let code: String
    let copy: (String) -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code").font(.caption2.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button {
                    copy(code.trimmingCharacters(in: .newlines))
                    withAnimation(.spring) { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        withAnimation { copied = false }
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(copied ? Brand.moss : .secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Brand.ink.opacity(0.06))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.trimmingCharacters(in: .newlines))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Brand.moss.opacity(0.25), lineWidth: 0.5))
        .padding(.vertical, 4)
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
