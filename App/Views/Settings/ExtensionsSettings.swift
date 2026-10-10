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
            Text("Your Raycast extensions run in Lizard as they are. Their saved data and quicklinks are encrypted by Raycast, so bring quicklinks over with Raycast's own export (below).")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            RaycastExtensionPicker(available: available, selected: $selected)
            HStack {
                Button("Import Quicklinks JSON…") { importQuicklinks() }
                Text("In Raycast: Search Quicklinks › ⌘K › Export Quicklinks").font(.caption).foregroundStyle(.secondary)
            }
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

    private func importQuicklinks() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let links = Quicklink.fromRaycastExport(data)
        Task {
            let added = await app.quicklinks.merge(links)
            app.quicklinksChanged()
            result = links.isEmpty ? "That file doesn't look like a Raycast quicklinks export." : "Imported \(added) quicklinks."
        }
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
