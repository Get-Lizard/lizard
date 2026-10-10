import SwiftUI

/// iCloud sync (your Apple ID, through iCloud Drive) and backup files.
struct SyncSettings: View {
    @Environment(AppModel.self) private var app
    @State private var includeNotes = true
    @State private var includeChats = false
    @State private var working: String?
    @State private var movingNotes = false

    var body: some View {
        let sync = app.sync!
        Form {
            Section {
                if SyncService.isICloudDriveAvailable {
                    Toggle("Sync with iCloud", isOn: Binding(get: { sync.isEnabled }, set: { sync.isEnabled = $0 }))
                    Text("Quicklinks, settings, shortcuts and your extension list follow your Apple ID to every Mac with Lizard. Passwords and API keys stay in each Mac's Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Keep notes and work log in iCloud Drive", isOn: Binding(
                        get: { sync.notesInICloud },
                        set: { on in
                            movingNotes = true
                            Task {
                                try? await sync.moveNotes(toICloud: on)
                                movingNotes = false
                            }
                        }))
                    .disabled(movingNotes)
                    Text("Stored in iCloud Drive › Lizard. Your files are copied, never deleted.").font(.caption).foregroundStyle(.secondary)
                    if let last = sync.lastSync { LabeledContent("Last sync", value: last.formatted(date: .omitted, time: .shortened)) }
                    if let status = sync.status { Text(status).font(.caption).foregroundStyle(.orange) }
                } else {
                    Text("Turn on iCloud Drive in System Settings › Apple Account › iCloud to sync Lizard between your Macs.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("iCloud")
            }
            if !sync.offeredExtensions.isEmpty {
                Section("From your other Macs") {
                    ForEach(sync.offeredExtensions, id: \.name) { entry in
                        HStack {
                            Text(entry.name)
                            if entry.source.isExternal { Badge(text: "External", color: .orange) }
                            Spacer()
                            Button("Install") {
                                if !entry.source.isExternal || ExtensionsModel.confirmExternalInstall(entry.name) { sync.installOffered(entry) }
                            }
                        }
                    }
                }
            }
            Section("Backup") {
                Toggle("Include notes and work log", isOn: $includeNotes)
                Toggle("Include AI chats", isOn: $includeChats)
                HStack {
                    Button("Export Backup…", action: exportBackup)
                    Button("Restore Backup…", action: restoreBackup)
                    if let working { ProgressView().controlSize(.small); Text(working).font(.caption).foregroundStyle(.secondary) }
                }
                Text("A .lizardbackup file holds your settings, shortcuts, quicklinks, extensions with their preferences and data, and optionally notes and chats. To share an extension with a friend without your data, use Share Extension in the Extensions tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Lizard \(Date.now.formatted(.iso8601.year().month().day())).lizardbackup"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = "Exporting…"
        Task {
            do {
                try await BackupService.export(app: app, options: .init(notes: includeNotes, chats: includeChats), to: url)
                working = nil
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                working = error.localizedDescription
            }
        }
    }

    private func restoreBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "lizardbackup") ?? .zip, .zip]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = "Restoring…"
        Task {
            do {
                try await BackupService.restore(app: app, from: url) { line in working = line }
            } catch {
                working = error.localizedDescription
            }
        }
    }
}
