import AIEngine
import LizardCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Shortcuts", systemImage: "keyboard") {
                Form {
                    Section("Open Lizard with") {
                        LauncherShortcutPicker()
                    }
                    Section("Window management") {
                        ForEach(HotkeyAction.windows) { HotkeyRecorderRow(action: $0) }
                    }
                    Section {
                        ForEach(HotkeyAction.all.filter { $0.name != .toggleLauncher }) { HotkeyRecorderRow(action: $0) }
                    } footer: {
                        Text("Shortcuts work from any app.")
                    }
                }
                .formStyle(.grouped)
            }
            Tab("AI", systemImage: "sparkles") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        AISetupSection()
                        KnowledgeSettingsSection()
                    }
                    .padding(20)
                }
            }
            Tab("Accounts", systemImage: "person.crop.circle") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        GitHubConnectSection()
                        CloudSignInSection()
                    }
                    .padding(20)
                }
            }
            Tab("Extensions", systemImage: "puzzlepiece.extension") { ExtensionsSettings() }
            Tab("Sync & Backup", systemImage: "icloud") { SyncSettings() }
        }
        .frame(width: 640, height: 560)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var clipboard = Preferences.clipboardEnabled
    @State private var resume = Preferences.resumeLauncher
    @State private var expandSnippets = SnippetExpander.isEnabled
    @State private var menuBarIcon = Preferences.showMenuBarIcon
    @State private var mode = PerformanceMode.current

    var body: some View {
        Form {
            UpdatesSection()
            Section {
                Toggle("Open Lizard at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle("Show Lizard in the menu bar", isOn: $menuBarIcon)
                    .onChange(of: menuBarIcon) { _, on in
                        Preferences.showMenuBarIcon = on
                        app.statusItem.setShown(on)
                    }
                Text("The gecko sits next to the clock. If the menu bar is full, turn this off to make room for extension icons; \(LauncherShortcut.display) always opens Lizard.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Reopen where I left off", isOn: $resume)
                    .onChange(of: resume) { _, on in Preferences.resumeLauncher = on }
                Toggle("Expand snippet keywords as I type", isOn: $expandSnippets)
                    .onChange(of: expandSnippets) { _, on in
                        SnippetExpander.isEnabled = on
                        app.snippetExpander.refreshMonitoring()
                    }
                Text("Type a snippet's keyword (like ;sig) in any app and it turns into the snippet. Never in password fields. Needs the Accessibility permission.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Keep clipboard history", isOn: $clipboard)
                    .onChange(of: clipboard) { _, on in
                        Preferences.clipboardEnabled = on
                        app.clipboardEnabledChanged()
                    }
            }
            Section("Folders") {
                LabeledContent("Notes", value: Preferences.notesFolder.path(percentEncoded: false))
                LabeledContent("Work Log", value: Preferences.workLogFolder.path(percentEncoded: false))
            }
            Section("Performance") {
                Picker("Mode", selection: $mode) {
                    ForEach(PerformanceMode.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: mode) { _, value in app.ai.resources.mode = value }
                Text(mode.explanation).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Run setup again…") { app.showSetup() }
                Button("Show splash") { app.showSplash(firstLaunch: true) }
            }
        }
        .formStyle(.grouped)
    }
}


/// Current version, the latest release, and one-click install.
private struct UpdatesSection: View {
    @Environment(AppModel.self) private var app
    @State private var autoCheck = UpdateService.autoCheck

    var body: some View {
        let updates = app.updates!
        Section("Updates") {
            HStack(spacing: 12) {
                Image(systemName: icon(updates.state)).font(.title2).foregroundStyle(Brand.moss).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(updates)).font(.headline)
                    Text(detail(updates)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                switch updates.state {
                case .available:
                    Button("Install Update") { updates.install() }.buttonStyle(.borderedProminent).tint(Brand.moss)
                case .installing, .checking:
                    ProgressView().controlSize(.small)
                default:
                    Button("Check Now") { Task { await updates.check() } }
                }
            }
            if case .available(let release) = updates.state, !release.notes.isEmpty {
                DisclosureGroup("What's new") {
                    Text(release.notes.prefix(2_000)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Toggle("Check for updates automatically", isOn: $autoCheck)
                .onChange(of: autoCheck) { _, on in UpdateService.autoCheck = on }
        }
    }

    private func icon(_ state: UpdateService.State) -> String {
        switch state {
        case .available: "arrow.down.circle.fill"
        case .failed: "exclamationmark.triangle"
        default: "checkmark.seal"
        }
    }

    private func title(_ updates: UpdateService) -> String {
        switch updates.state {
        case .available(let release): "Lizard \(release.version) is available"
        case .installing(let step): step
        default: "Lizard \(updates.currentVersion)"
        }
    }

    private func detail(_ updates: UpdateService) -> String {
        switch updates.state {
        case .idle: "Checks GitHub once a day."
        case .checking: "Checking…"
        case .upToDate: "You're on the latest version."
        case .available: "You have \(updates.currentVersion). Installing keeps your settings and data, then restarts Lizard."
        case .installing: "Lizard restarts when it's done."
        case .failed(let message): message
        }
    }
}
