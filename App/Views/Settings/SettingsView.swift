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
                    Section("Window management") {
                        ForEach(HotkeyAction.windows) { HotkeyRecorderRow(action: $0) }
                    }
                    Section {
                        ForEach(HotkeyAction.all) { HotkeyRecorderRow(action: $0) }
                    } footer: {
                        Text("Shortcuts work from any app. ⌃Space can clash with input-source switching if you use several keyboard layouts.")
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
    @State private var menuBarIcon = Preferences.showMenuBarIcon
    @State private var mode = PerformanceMode.current

    var body: some View {
        Form {
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
                Text("Lizard hides its own icon automatically when extension icons (like GitHub) need the room. ⌃Space always opens Lizard.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Reopen where I left off", isOn: $resume)
                    .onChange(of: resume) { _, on in Preferences.resumeLauncher = on }
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

