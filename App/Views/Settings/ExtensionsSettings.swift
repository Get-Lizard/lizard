import ExtensionHost
import Search
import SwiftUI

/// Install from GitHub/a file/Raycast, update, share and remove extensions.
struct ExtensionsSettings: View {
    @Environment(AppModel.self) private var app
    @State private var installSource = ""
    @State private var showRaycastImport = false

    var body: some View {
        let extensions = app.extensions
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("github.com/owner/repo, owner/repo/path@ref, or a Raycast extension name", text: $installSource)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(install)
                Button("Install", action: install).disabled(installSource.isEmpty || extensions.isBusy)
            }
            HStack(spacing: 10) {
                Button("Install from File…") { extensions.installPackageFile() }
                if !ExtensionStore.raycastExtensions().isEmpty {
                    Button("Import from Raycast…") { showRaycastImport = true }
                }
                Button("Check for Updates") { Task { await extensions.checkForUpdates() } }
                if !extensions.updates.isEmpty {
                    Button("Update All (\(extensions.updates.count))") { extensions.updateAll() }.buttonStyle(.borderedProminent).tint(Brand.moss)
                }
                Spacer()
                Link("Build your own", destination: URL(string: "https://github.com/Get-Lizard/lizard/blob/main/docs/EXTENSIONS.md")!)
            }
            .controlSize(.small)
            if let message = extensions.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            List {
                Section("Installed") {
                    ForEach(extensions.installed) { item in
                        ExtensionRow(item: item)
                    }
                }
                Section("Suggested") {
                    ForEach(ExtensionsModel.suggested, id: \.name) { suggestion in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(suggestion.title).font(.headline)
                                Text(suggestion.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if extensions.installed.contains(where: { $0.name == suggestion.name }) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.moss)
                            } else {
                                Button("Add") { extensions.install(suggestion.source) }.disabled(extensions.isBusy)
                            }
                        }
                    }
                }
            }
            Text("Extensions marked External are made by third parties and aren't reviewed by Lizard. They run with your permissions; install only from people you trust.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(20)
        .sheet(isPresented: $showRaycastImport) {
            RaycastImportView { showRaycastImport = false }
                .environment(app)
                .frame(width: 520, height: 480)
        }
    }

    private func install() {
        app.extensions.install(installSource)
        installSource = ""
    }
}

private struct ExtensionRow: View {
    @Environment(AppModel.self) private var app
    let item: InstalledExtension

    var body: some View {
        let extensions = app.extensions
        HStack(spacing: 10) {
            if let icon = item.iconURL, let image = NSImage(contentsOf: icon) {
                Image(nsImage: image).resizable().frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: "puzzlepiece.extension").frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).font(.headline)
                    if item.isExternal { Badge(text: "External", color: .orange) }
                    if extensions.updates[item.name] != nil { Badge(text: "Update", color: Brand.moss) }
                    if extensions.hiddenMenuBars.contains(where: { $0.hasPrefix(item.name + "/") }) {
                        Badge(text: "Hidden in menu bar", color: .secondary)
                            .help("macOS hid this menu-bar item because the menu bar is full. ⌘-drag other icons out, or run the command from Lizard to open its menu.")
                    }
                }
                Text("\(item.commands.count) commands · \(item.source.description)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if extensions.updating.contains(item.name) {
                ProgressView().controlSize(.small)
            } else if extensions.updates[item.name] != nil {
                Button("Update") { extensions.update(item.name) }
            }
            Menu {
                if let location = item.source.github {
                    Button("Open on GitHub") { NSWorkspace.shared.open(location.webURL) }
                }
                Button("Share Extension (no data)…") { extensions.exportPackage(item.name) }
                Button("Show Files") { NSWorkspace.shared.activateFileViewerSelecting([item.directory]) }
                Divider()
                Button("Remove", role: .destructive) { extensions.uninstall(item.name) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// Pick Raycast extensions (and a quicklinks export) to bring into Lizard. Used by Settings and Setup.
struct RaycastImportView: View {
    @Environment(AppModel.self) private var app
    var onDone: () -> Void
    @State private var available = ExtensionStore.raycastExtensions()
    @State private var selected: Set<URL> = []
    @State private var working = false
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from Raycast").font(.title2.weight(.semibold))
            Text("Your Raycast extensions run in Lizard as they are. Raycast keeps quicklinks encrypted, so they come over through Raycast's own export, guided below.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            RaycastExtensionPicker(available: available, selected: $selected)
            RaycastQuicklinksImport()
            if let result { Text(result).font(.callout).foregroundStyle(Brand.moss) }
            HStack {
                Spacer()
                Button("Close", action: onDone).keyboardShortcut(.cancelAction)
                Button(working ? "Importing…" : "Import \(selected.count) Extensions") {
                    guard ExtensionsModel.confirmExternalInstall("These Raycast extensions") else { return }
                    working = true
                    Task {
                        let count = await app.extensions.importFromRaycast(Array(selected))
                        working = false
                        result = "Imported \(count) extension\(count == 1 ? "" : "s")."
                        selected = []
                    }
                }
                .buttonStyle(.borderedProminent).tint(Brand.moss)
                .disabled(selected.isEmpty || working)
            }
        }
        .padding(20)
        .onAppear {
            let installed = Set(app.extensions.installed.map(\.name))
            selected = Set(available.filter { !installed.contains($0.manifest.name) }.map(\.folder))
        }
    }
}

/// Quicklinks from Raycast in three guided steps. Raycast encrypts its database, so its own
/// "Export Quicklinks" is the only way out. After "Open Raycast", Lizard watches Downloads for the
/// export (macOS asks once for Downloads access, so watching never starts before that click);
/// files saved elsewhere come in by drop or "Choose File…".
struct RaycastQuicklinksImport: View {
    @Environment(AppModel.self) private var app

    enum Phase: Equatable { case idle, waiting, imported(added: Int, total: Int), failed(String) }

    @State private var phase: Phase = .idle
    @State private var since = Date.now.addingTimeInterval(-5)
    @State private var dropping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Quicklinks", systemImage: "link").font(.headline)
                Spacer()
                status
            }
            step(1) {
                HStack(spacing: 8) {
                    Text("Open Raycast")
                    Button("Open Raycast") { openRaycast() }.controlSize(.small)
                }
            }
            step(2) {
                HStack(spacing: 4) {
                    Text("Type")
                    Text("Search Quicklinks").fontWeight(.semibold)
                    Text("and press ↩, then")
                    KeyCap(text: "⌘K")
                    Text("and choose")
                    Text("Export Quicklinks").fontWeight(.semibold)
                }
            }
            step(3) {
                HStack(spacing: 8) {
                    Text("Save it to Downloads and Lizard imports it by itself. Elsewhere? Drop it here or")
                    Button("Choose File…") { chooseFile() }.controlSize(.small)
                }
            }
            if phase == .idle {
                Text("macOS will ask once to let Lizard look in your Downloads folder.")
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 30)
            }
        }
        .font(.callout)
        .padding(12)
        .background(dropping ? Brand.moss.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .surface()
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in importFile(url, explicit: true) }
            }
            return true
        }
        .task(id: phase == .waiting) { if phase == .waiting { await watchForExport() } }
    }

    @ViewBuilder
    private var status: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .waiting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Watching Downloads for your export…").font(.caption).foregroundStyle(.secondary)
            }
        case .imported(let added, let total):
            Label(Self.summary(added: added, total: total), systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(Brand.moss)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        }
    }

    static func summary(added: Int, total: Int) -> String {
        let plural = { (n: Int) in n == 1 ? "quicklink" : "quicklinks" }
        if added == total { return "Imported \(added) \(plural(added))" }
        if added == 0 { return total == 1 ? "Already in Lizard" : "All \(total) are already in Lizard" }
        return "Imported \(added) new \(plural(added)) (\(total - added) already in Lizard)"
    }

    private func step<Content: View>(_ number: Int, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold)).foregroundStyle(Brand.moss)
                .frame(width: 20, height: 20)
                .background(Brand.moss.opacity(0.15), in: Circle())
            content()
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFile(url, explicit: true)
    }

    private func openRaycast() {
        since = Date.now.addingTimeInterval(-5)
        if phase != .waiting { phase = .waiting }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.raycast.macos") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Polls the usual save folders for a new JSON file that parses as a Raycast quicklinks export.
    private func watchForExport() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders = [home.appending(path: "Downloads", directoryHint: .isDirectory)]
        var tried: Set<URL> = []
        while !Task.isCancelled {
            if case .imported = phase { return }
            let cutoff = since
            let candidates = await Task.detached(priority: .utility) { Self.recentJSON(in: folders, since: cutoff) }.value
            for url in candidates where !tried.contains(url) {
                tried.insert(url)
                if importFile(url, explicit: false) { return }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    nonisolated static func recentJSON(in folders: [URL], since cutoff: Date) -> [URL] {
        var result: [URL] = []
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for url in files where url.pathExtension.lowercased() == "json" {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if modified > cutoff { result.append(url) }
            }
        }
        return result
    }

    /// True when the file was a quicklinks export and got imported.
    @discardableResult
    private func importFile(_ url: URL, explicit: Bool) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        let links = Quicklink.fromRaycastExport(data)
        guard !links.isEmpty else {
            if explicit { phase = .failed("That file isn't a Raycast quicklinks export") }
            return false
        }
        Task {
            let added = await app.quicklinks.merge(links)
            app.quicklinksChanged()
            withAnimation(.smooth) { phase = .imported(added: added, total: links.count) }
        }
        return true
    }
}

struct RaycastExtensionPicker: View {
    let available: [(folder: URL, manifest: ExtensionManifest)]
    @Binding var selected: Set<URL>

    var body: some View {
        List(available, id: \.folder) { item in
            Toggle(isOn: Binding(
                get: { selected.contains(item.folder) },
                set: { on in if on { selected.insert(item.folder) } else { selected.remove(item.folder) } })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.manifest.title)
                    Text("\(item.manifest.commands.count) commands · \(item.manifest.name)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(minHeight: 160)
    }
}
