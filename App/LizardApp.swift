import KeyboardShortcuts
import SwiftUI

@main
struct LizardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu()
                .environment(appDelegate.model)
        } label: {
            Image("MenuBarIcon")
        }
    }
}

/// Lizard's own menu-bar menu (extensions' menu-bar commands get their own status items).
private struct MenuBarMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Button("Open Lizard") { app.toggleLauncher() }
            .globalKeyboardShortcut(.toggleLauncher)
        Button("Ask AI") { app.open(.chat(nil)) }
            .globalKeyboardShortcut(.askAI)
        Button("Clipboard History") { app.open(.clipboard) }
            .globalKeyboardShortcut(.clipboard)
        Button("Work Log") { app.showWorkLog() }
            .globalKeyboardShortcut(.workLog)
        Button("New Note") { app.open(.newNote) }
            .globalKeyboardShortcut(.newNote)
        Divider()
        Button("Settings…") { app.openSettings() }
        .keyboardShortcut(",")
        Button("Setup…") { app.showSetup() }
        Divider()
        Button("Quit Lizard") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Graceful quit: let a running MLX generation finish before teardown (Cocoon's lesson: MLX
/// must not be torn down mid-inference).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var exiting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !exiting else { return .terminateNow }
        exiting = true
        Task { @MainActor in
            await model.prepareForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.toggleLauncher()
        return false
    }
}
