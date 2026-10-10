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
                    Section {
                        ForEach(HotkeyAction.all) { HotkeyRecorderRow(action: $0) }
                    } footer: {
                        Text("Shortcuts work from any app. ⌃Space can clash with input-source switching if you use several keyboard layouts.")
                    }
                }
                .formStyle(.grouped)
            }
            Tab("AI", systemImage: "sparkles") {
                ScrollView { AISetupSection().padding(20) }
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
        }
        .frame(width: 640, height: 560)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var clipboard = Preferences.clipboardEnabled
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

private struct ExtensionsSettings: View {
    @Environment(AppModel.self) private var app
    @State private var installName = ""

    var body: some View {
        let extensions = app.extensions
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Install from Raycast store (e.g. google-translate) or a folder path", text: $installName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(install)
                Button("Install", action: install).disabled(installName.isEmpty || extensions.isBusy)
            }
            if let message = extensions.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            List {
                Section("Installed") {
                    ForEach(extensions.installed) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.title).font(.headline)
                                Text("\(item.commands.count) commands · \(item.source)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove") { extensions.uninstall(item.name) }
                        }
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
        }
        .padding(20)
    }

    private func install() {
        app.extensions.install(installName)
        installName = ""
    }
}
