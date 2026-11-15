import AppKit
import ExtensionHost
import SwiftUI
import UniformTypeIdentifiers

/// Raycast calls this pane "Configure Extension". The manifest declares the preferences,
/// `ExtensionStore` already persists them to `Extensions/<name>/preferences.json`, and the
/// extensions themselves read them through `getPreferenceValues()` — but nothing filled them in,
/// so `required` ones could never be satisfied. One sheet covers both scopes the shim exposes:
/// extension-wide preferences, and the preferences of one command.
struct ExtensionPreferencesSheet: View {
    @Environment(AppModel.self) private var app
    let installed: InstalledExtension
    /// nil = extension-wide preferences only.
    let command: ExtensionManifest.Command?

    @State private var draft: PreferenceDraft?
    @State private var error: String?

    private var extensionPreferences: [ExtensionManifest.Preference] { installed.manifest.preferences ?? [] }
    private var commandPreferences: [ExtensionManifest.Preference] { command?.preferences ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(20)
            Divider()
            if extensionPreferences.isEmpty && commandPreferences.isEmpty {
                Text("This extension declares no preferences.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let draft {
                Form {
                    if !extensionPreferences.isEmpty {
                        Section {
                            ForEach(extensionPreferences, id: \.name) { row($0, draft: draft) }
                        } header: {
                            Text(installed.title)
                        }
                    }
                    if let command, !commandPreferences.isEmpty {
                        Section("\(command.title)") {
                            ForEach(commandPreferences, id: \.name) { row($0, draft: draft) }
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 520)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let icon = installed.iconURL, let image = NSImage(contentsOf: icon) {
                Image(nsImage: image).resizable().frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: "puzzlepiece.extension").frame(width: 40, height: 40).font(.title)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Preferences").font(.title3.weight(.semibold))
                Text(command.map { "\(installed.title) · \($0.title)" } ?? installed.title).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).lineLimit(2)
            } else if let draft, !draft.canSave {
                Label("Fill in \(draft.missingRequired.map(\.displayTitle).joined(separator: ", ")) to save.", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Show Files") {
                    NSWorkspace.shared.activateFileViewerSelecting([installed.directory.appending(path: "preferences.json")])
                }
                .buttonStyle(.link).font(.caption)
            }
            Spacer()
            Button("Cancel") { app.extensions.dismissPreferences() }.keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!(draft?.canSave ?? false))
                .tint(Brand.moss)
        }
        .padding(20)
    }

    // MARK: Fields

    @ViewBuilder
    private func row(_ preference: ExtensionManifest.Preference, draft: PreferenceDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if preference.kind == .checkbox {
                Toggle(preference.displayTitle, isOn: flag(preference))
            } else {
                HStack(spacing: 6) {
                    Text(preference.displayTitle)
                    if isMissing(preference, in: draft) { Badge(text: "Required", color: .orange) }
                }
                control(preference)
            }
            if let description = preference.description {
                Text(description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func control(_ preference: ExtensionManifest.Preference) -> some View {
        switch preference.kind {
        case .password:
            SecureField(preference.placeholder ?? "", text: text(preference)).textFieldStyle(.roundedBorder)
        case .dropdown:
            Picker("", selection: text(preference)) {
                ForEach(preference.data ?? [], id: \.self) { option in
                    Text(option.title ?? option.value ?? "").tag(option.value ?? "")
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        case .appPicker:
            HStack(spacing: 8) {
                TextField("Bundle identifier", text: text(preference)).textFieldStyle(.roundedBorder).font(.callout.monospaced())
                Button("Choose…") { choose(.application, for: preference) }
            }
        case .file:
            HStack(spacing: 8) {
                TextField("Path", text: text(preference)).textFieldStyle(.roundedBorder)
                Button("Choose…") { choose(.file, for: preference) }
            }
        case .directory:
            HStack(spacing: 8) {
                TextField("Path", text: text(preference)).textFieldStyle(.roundedBorder)
                Button("Choose…") { choose(.directory, for: preference) }
            }
        default:
            TextField(preference.placeholder ?? "", text: text(preference)).textFieldStyle(.roundedBorder)
        }
    }

    private func isMissing(_ preference: ExtensionManifest.Preference, in draft: PreferenceDraft) -> Bool {
        draft.missingRequired.contains { $0.name == preference.name }
    }

    // MARK: Bindings

    private func text(_ preference: ExtensionManifest.Preference) -> Binding<String> {
        Binding(
            get: { draft?.value(preference.name)?.string ?? "" },
            set: { draft?.set(preference.name, .string($0)) })
    }

    private func flag(_ preference: ExtensionManifest.Preference) -> Binding<Bool> {
        Binding(
            get: { draft?.value(preference.name)?.bool ?? false },
            set: { draft?.set(preference.name, .bool($0)) })
    }

    private enum Chooser { case application, file, directory }

    private func choose(_ kind: Chooser, for preference: ExtensionManifest.Preference) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = kind != .directory
        panel.canChooseDirectories = kind == .directory
        panel.allowsMultipleSelection = false
        switch kind {
        case .application: panel.allowedContentTypes = [.application]
        case .file: panel.allowedContentTypes = [.item]
        case .directory: panel.allowedContentTypes = []
        }
        if kind == .application { panel.directoryURL = URL(filePath: "/Applications") }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let value = kind == .application ? Bundle(url: url)?.bundleIdentifier ?? url.path : url.path
        draft?.set(preference.name, .string(value))
    }

    // MARK: Load and save

    private func load() async {
        guard draft == nil else { return }
        let saved = await app.extensions.store.savedPreferences(installed.name)
        draft = PreferenceDraft(manifest: installed.manifest, command: command, saved: saved)
    }

    private func save() {
        guard let draft else { return }
        let changes = draft.changes()
        guard !changes.isEmpty else {
            app.extensions.dismissPreferences()
            return
        }
        Task {
            do {
                try await app.extensions.store.setPreferences(installed.name, values: changes)
                app.extensions.dismissPreferences()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
