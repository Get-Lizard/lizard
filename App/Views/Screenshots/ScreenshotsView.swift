import Screenshots
import SwiftUI

/// Screenshot gallery: category chips, search over titles, tags and the text inside images.
struct ScreenshotsView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var category: ScreenshotCategory?
    @State private var results: [Screenshot] = []
    @State private var selectedID: UUID?
    @FocusState private var focused: Bool

    var body: some View {
        let service = app.screenshots!
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { app.launcher.pop() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Image(systemName: "camera.viewfinder").foregroundStyle(Brand.moss)
                TextField("Search screenshots, even the text inside them…", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 17)).focused($focused)
                Menu {
                    Button("Capture Area  ⌃⇧S") { service.capture(.area) }
                    Button("Capture Window") { service.capture(.window) }
                    Button("Capture Screen") { service.capture(.screen) }
                } label: {
                    Label("Capture", systemImage: "plus.viewfinder")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Chip(title: "All", symbol: "square.grid.2x2", selected: category == nil, count: service.items.count) { category = nil }
                    ForEach(ScreenshotCategory.allCases) { kind in
                        let count = service.items.filter { $0.category == kind }.count
                        if count > 0 {
                            Chip(title: kind.title, symbol: kind.symbol, selected: category == kind, count: count) { category = kind }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
            Divider()
            if results.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "camera.viewfinder").font(.system(size: 40)).foregroundStyle(.tertiary)
                    Text(service.items.isEmpty ? "No screenshots yet" : "Nothing matches").font(.headline)
                    Text("Press ⌃⇧S to capture an area. Lizard reads the text, names it and files it by category in Pictures › Lizard Screenshots.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], spacing: 10) {
                            ForEach(results) { item in
                                Thumbnail(item: item, selected: item.id == selected?.id)
                                    .onTapGesture { selectedID = item.id }
                                    .onTapGesture(count: 2) { service.copy(item) }
                                    .contextMenu { actions(for: item) }
                            }
                        }
                        .padding(12)
                    }
                    if let item = selected {
                        Divider()
                        Detail(item: item).frame(width: 250)
                    }
                }
            }
            ActionBar(hints: [("Copy", "↩"), ("Annotate", "⌘E")]) {
                if service.processing {
                    ProgressView().controlSize(.small)
                    Text("Reading and filing…").font(.caption).foregroundStyle(.secondary)
                }
                Button("") { if let selected { service.copy(selected) } }.keyboardShortcut(.return, modifiers: []).opacity(0)
                Button("") { if let selected { service.annotate(selected) } }.keyboardShortcut("e", modifiers: .command).opacity(0)
            }
        }
        .task(id: "\(query)|\(category?.rawValue ?? "")|\(service.items.count)") {
            results = await service.search(query, category: category)
            if !results.contains(where: { $0.id == selectedID }) { selectedID = results.first?.id }
        }
        .onAppear { focused = true }
    }

    private var selected: Screenshot? { results.first { $0.id == selectedID } }

    @ViewBuilder
    private func actions(for item: Screenshot) -> some View {
        let service = app.screenshots!
        Button("Copy Image") { service.copy(item) }
        Button("Copy Text") { app.copyText(item.text) }.disabled(item.text.isEmpty)
        Button("Annotate in Preview") { service.annotate(item) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Menu("Move to") {
            ForEach(ScreenshotCategory.allCases) { kind in
                Button(kind.title) { service.recategorize(item, to: kind) }.disabled(kind == item.category)
            }
        }
        Button("Explain with AI") { app.launcher.push(.aiJob(.explain(text: item.text))) }.disabled(item.text.isEmpty)
        Divider()
        Button("Move to Trash", role: .destructive) { service.delete(item) }
    }
}

private struct Chip: View {
    let title: String
    let symbol: String
    let selected: Bool
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                Text(title)
                Text("\(count)").foregroundStyle(.secondary)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(selected ? AnyShapeStyle(Brand.moss.opacity(0.25)) : AnyShapeStyle(.fill.tertiary), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Brand.moss.opacity(0.6) : .clear))
        }
        .buttonStyle(.plain)
    }
}

private struct Thumbnail: View {
    let item: Screenshot
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // A fixed-size frame the image fills and is clipped to, so a wide screenshot can't
            // stretch the grid cell (it used to spill out of its column and get cut on the left).
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 96)
                .overlay { AsyncThumbnail(url: item.url) }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? Brand.moss : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 0.5))
            Text(item.title).font(.caption).lineLimit(1)
            Text(item.date, style: .relative).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Loads a downscaled thumbnail off the main thread.
struct AsyncThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.secondary.opacity(0.08)
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .task(id: url) {
            image = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                    let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 400,
                    ] as CFDictionary)
                else { return nil }
                return NSImage(cgImage: thumbnail, size: .zero)
            }.value
        }
    }
}

private struct Detail: View {
    let item: Screenshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                AsyncThumbnail(url: item.url).frame(maxWidth: .infinity).frame(height: 140).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(item.title).font(.headline)
                Label(item.category.title, systemImage: item.category.symbol).font(.caption).foregroundStyle(Brand.moss)
                Text("\(item.app ?? "Unknown app") · \(item.width)×\(item.height) · \(item.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                if !item.tags.isEmpty {
                    HStack { ForEach(item.tags, id: \.self) { Text("#\($0)").font(.caption).foregroundStyle(Brand.teal) } }
                }
                if !item.text.isEmpty {
                    Divider()
                    Text(item.text).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .padding(12)
        }
    }
}
