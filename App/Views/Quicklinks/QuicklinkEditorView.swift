import AppKit
import Search
import SwiftUI

/// Create or edit a quicklink in the launcher panel: labelled fields, placeholders you can insert,
/// the app to open it with (your browsers, default first), an icon, and ⌘↩ to save.
struct QuicklinkEditorView: View {
    @Environment(AppModel.self) private var app
    @State private var link: Quicklink
    private let isNew: Bool

    private enum Field { case name, link, keyword }
    @FocusState private var focus: Field?

    init(link: Quicklink, isNew: Bool) {
        _link = State(initialValue: link)
        self.isNew = isNew
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { app.launcher.pop() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Image(systemName: "link").foregroundStyle(Brand.moss)
                Text(isNew ? "Create Quicklink" : "Edit Quicklink").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            Divider()

            ScrollView {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 18) {
                    row("Name") {
                        TextField("Quicklink name", text: $link.name)
                            .textFieldStyle(.roundedBorder).controlSize(.large)
                            .focused($focus, equals: .name)
                    }
                    row("Link") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                TextField("https://google.com/search?q={query}", text: $link.template)
                                    .textFieldStyle(.roundedBorder).controlSize(.large)
                                    .font(.system(.body, design: .monospaced))
                                    .focused($focus, equals: .link)
                                Menu {
                                    Button("{query}  what you type after the name") { insert("{query}") }
                                    Button("{clipboard}  the text you copied") { insert("{clipboard}") }
                                    Button("{selection}  text selected in the app you were in") { insert("{selection}") }
                                } label: {
                                    Image(systemName: "curlybraces")
                                }
                                .menuStyle(.borderlessButton).fixedSize()
                                .help("Insert a placeholder")
                            }
                            Text(placeholderHint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if let preview { Text("Opens \(preview)").font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle) }
                        }
                    }
                    row("Open With") { OpenWithPicker(template: link.template, selection: $link.openWith) }
                    row("Icon") { IconPicker(symbol: $link.symbol) }
                    row("Keyword") {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Optional, e.g. gh", text: Binding(get: { link.keyword ?? "" }, set: { link.keyword = $0.isEmpty ? nil : $0.lowercased() }))
                                .textFieldStyle(.roundedBorder).controlSize(.large).frame(maxWidth: 180)
                                .focused($focus, equals: .keyword)
                            Text(keywordHint).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 26)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }

            ActionBar(hints: [(isNew ? "Save Quicklink" : "Save Changes", "⌘↩"), ("Back", "esc")]) {
                Label(isNew ? "Create Quicklink" : "Edit Quicklink", systemImage: link.symbol).font(.caption).foregroundStyle(.secondary)
            }
            .background {
                Button("") { save() }.keyboardShortcut(.return, modifiers: .command).opacity(0)
            }
        }
        .onAppear { focus = link.name.isEmpty ? .name : .link }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing).frame(minWidth: 80, alignment: .trailing)
            content()
        }
    }

    private var placeholderHint: String {
        "Add {query} where the text you type goes, e.g. “\(link.keyword ?? "name") lizard”. {clipboard} and {selection} use copied or selected text."
    }

    private var keywordHint: String {
        guard let keyword = link.keyword, !keyword.isEmpty else { return "Type it before your text to jump straight to this link." }
        return link.needsQuery ? "Type “\(keyword) something” in Lizard to open it with “something”." : "Type “\(keyword)” in Lizard to open it."
    }

    private var preview: String? {
        guard !link.template.isEmpty, link.template != "https://" else { return nil }
        return link.resolve(query: "lizard", clipboard: "copied", selection: "selected")?.absoluteString
    }

    private func insert(_ placeholder: String) {
        link.template += placeholder
        focus = .link
    }

    private func save() {
        link.name = link.name.trimmingCharacters(in: .whitespaces)
        link.template = link.template.trimmingCharacters(in: .whitespaces)
        guard !link.name.isEmpty, !link.template.isEmpty, link.template != "https://" else {
            focus = link.name.isEmpty ? .name : .link
            NSSound.beep()
            return
        }
        let saved = link
        Task {
            await app.quicklinks.save(saved)
            app.quicklinksChanged()
            app.showHUD("Saved quicklink “\(saved.name)”")
            app.launcher.pop()
        }
    }
}

/// Apps that can open the link: for web links your browsers, the default first and labelled.
private struct OpenWithPicker: View {
    let template: String
    @Binding var selection: String?

    var body: some View {
        let apps = OpenWithApps.candidates(for: template)
        Picker("", selection: Binding(get: { OpenWithApps.normalized(selection, in: apps) }, set: { selection = $0 })) {
            if let fallback = apps.first(where: \.isDefault) {
                Label { Text("\(fallback.name) (Default)") } icon: { Image(nsImage: fallback.icon) }.tag(String?.none)
            } else {
                Label("System default", systemImage: "app.dashed").tag(String?.none)
            }
            Divider()
            ForEach(apps.filter { !$0.isDefault }) { app in
                Label { Text(app.name) } icon: { Image(nsImage: app.icon) }.tag(String?.some(app.id))
            }
        }
        .labelsHidden()
        .controlSize(.large)
        .frame(maxWidth: 320, alignment: .leading)
    }
}

enum OpenWithApps {
    struct App: Identifiable {
        let id: String  // bundle identifier
        let name: String
        let icon: NSImage
        let isDefault: Bool
    }

    /// Apps registered for the link's scheme (http(s) → browsers), default first.
    static func candidates(for template: String) -> [App] {
        let sample = Quicklink(name: "", template: template).resolve(query: "x") ?? URL(string: "https://example.com")!
        let probe = sample.isFileURL || sample.scheme == nil ? URL(string: "https://example.com")! : sample
        let defaultURL = NSWorkspace.shared.urlForApplication(toOpen: probe)
        var seen: Set<String> = []
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: probe).compactMap { url -> App? in
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, seen.insert(id).inserted else { return nil }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            return App(id: id, name: name, icon: icon, isDefault: url == defaultURL)
        }
        return apps.sorted { $0.isDefault != $1.isDefault ? $0.isDefault : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Maps a stored value (bundle id, path, or a name from Raycast) to a picker tag.
    static func normalized(_ value: String?, in apps: [App]) -> String? {
        guard let value else { return nil }
        if let match = apps.first(where: { $0.id == value || $0.name.caseInsensitiveCompare(value) == .orderedSame }) {
            return match.isDefault ? nil : match.id
        }
        return value
    }

    /// The app to open with, or nil for the system default.
    static func appURL(for value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        if value.hasPrefix("/") { return URL(filePath: value) }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: value) { return url }
        for folder in ["/Applications", "/System/Applications", "\(NSHomeDirectory())/Applications"] {
            let url = URL(filePath: "\(folder)/\(value).app")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}

private struct IconPicker: View {
    @Binding var symbol: String

    static let symbols: [(String, String)] = [
        ("link", "Default"), ("magnifyingglass", "Search"), ("globe", "Website"), ("chevron.left.forwardslash.chevron.right", "Code"),
        ("book", "Docs"), ("doc.text", "Document"), ("folder", "Folder"), ("calendar", "Calendar"), ("envelope", "Mail"),
        ("bubble.left.and.bubble.right", "Chat"), ("person.crop.circle", "Profile"), ("cart", "Shopping"), ("play.rectangle", "Video"),
        ("music.note", "Music"), ("map", "Maps"), ("chart.bar", "Dashboard"), ("server.rack", "Server"), ("terminal", "Terminal"),
        ("ticket", "Tickets"), ("star", "Favorite"), ("bolt", "Fast"), ("sparkles", "AI"),
    ]

    var body: some View {
        Picker("", selection: $symbol) {
            ForEach(Self.symbols, id: \.0) { item in
                Label(item.1, systemImage: item.0).tag(item.0)
            }
            if !Self.symbols.contains(where: { $0.0 == symbol }) {
                Label("Current", systemImage: symbol).tag(symbol)
            }
        }
        .labelsHidden()
        .controlSize(.large)
        .frame(maxWidth: 320, alignment: .leading)
    }
}
