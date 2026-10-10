import AIEngine
import Clipboard
import SwiftUI

/// Clipboard history: search, preview, ↩ pastes into the app you were in, ⌘C copies.
struct ClipboardView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var items: [ClipItem] = []
    @State private var selectedID: Int64?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { app.launcher.pop() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Image(systemName: "doc.on.clipboard").foregroundStyle(Brand.moss)
                TextField("Search clipboard history…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
                    .onSubmit { paste(selected) }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            Divider()
            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    List(items, id: \.id, selection: $selectedID) { item in
                        ClipRow(item: item).tag(item.id).id(item.id)
                            .onTapGesture(count: 2) { paste(item) }
                            .contextMenu { contextActions(item) }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .onChange(of: selectedID) { _, id in if let id { proxy.scrollTo(id) } }
                }
                .frame(width: 300)
                Divider()
                preview
            }
            ActionBar(hints: [("Paste", "↩"), ("Copy", "⌘C"), ("Pin", "⌘P"), ("Summarize", "⌘S")]) {
                Text("\(items.count) items").font(.caption).foregroundStyle(.secondary)
            }
            .background {
                Group {
                    Button("") { if let selected { app.copyClip(selected) } }.keyboardShortcut("c", modifiers: .command)
                    Button("") { if let selected { Task { await app.togglePin(selected); await load() } } }.keyboardShortcut("p", modifiers: .command)
                    Button("") { if let selected { app.launcher.push(.aiJob(.summarize(text: selected.text))) } }.keyboardShortcut("s", modifiers: .command)
                    Button("") { if let selected { Task { await app.deleteClip(selected); await load() } } }.keyboardShortcut(.delete, modifiers: .command)
                }
                .opacity(0)
            }
        }
        .task(id: query) { await load() }
        .onAppear { focused = true }
    }

    private var selected: ClipItem? { items.first { $0.id == selectedID } ?? items.first }

    @ViewBuilder
    private var preview: some View {
        if let item = selected {
            VStack(alignment: .leading, spacing: 10) {
                if item.kind == .image, let path = item.imagePath, let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 260)
                } else {
                    ScrollView {
                        Text(item.text.prefix(20_000))
                            .font(item.kind == .text ? .system(.callout, design: .monospaced) : .callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow { Text("Type").foregroundStyle(.secondary); Text(item.kind.rawValue.capitalized) }
                    GridRow { Text("From").foregroundStyle(.secondary); Text(app.appName(forBundleID: item.sourceApp) ?? "Unknown") }
                    GridRow { Text("Copied").foregroundStyle(.secondary); Text(item.created, style: .relative) }
                    GridRow { Text("Size").foregroundStyle(.secondary); Text(ByteCountFormatter.string(fromByteCount: Int64(item.byteSize), countStyle: .file)) }
                }
                .font(.caption)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard").font(.largeTitle).foregroundStyle(.tertiary)
                Text(Preferences.clipboardEnabled ? "Copy something and it shows up here." : "Clipboard history is off (Settings › General).")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func contextActions(_ item: ClipItem) -> some View {
        Button("Paste") { paste(item) }
        Button("Copy") { app.copyClip(item) }
        Button(item.pinned ? "Unpin" : "Pin") { Task { await app.togglePin(item); await load() } }
        Button("Summarize with AI") { app.launcher.push(.aiJob(.summarize(text: item.text))) }
        Button("Explain with AI") { app.launcher.push(.aiJob(.explain(text: item.text))) }
        Divider()
        Button("Delete", role: .destructive) { Task { await app.deleteClip(item); await load() } }
    }

    private func load() async {
        items = await app.clipboardItems(matching: query)
        if !items.contains(where: { $0.id == selectedID }) { selectedID = items.first?.id }
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == selectedID } ?? 0
        selectedID = items[max(0, min(items.count - 1, index + delta))].id
    }

    private func paste(_ item: ClipItem?) {
        guard let item else { return }
        app.pasteClip(item)
    }
}

private struct ClipRow: View {
    let item: ClipItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            Text(item.kind == .image ? "Image" : item.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " "))
                .lineLimit(1)
            Spacer()
            if item.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Brand.moss) }
        }
    }

    private var symbol: String {
        switch item.kind {
        case .text: "text.alignleft"
        case .url: "link"
        case .image: "photo"
        case .file: "doc"
        case .color: "paintpalette"
        }
    }
}
