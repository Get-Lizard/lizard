import KeyboardShortcuts
import SwiftUI

@main
struct LizardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Lizard's menu-bar icon is an NSStatusItem the app manages (LizardStatusItem), so extension
        // icons can be placed beside it and it can step aside when the menu bar is full.
        Settings { EmptyView() }
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
        guard !exiting, model.updates?.isRelaunching != true else { return .terminateNow }
        exiting = true
        Task { @MainActor in
            await model.prepareForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Dock icon (shown while Setup/Settings is open) brings that window back; otherwise
        // reopening the app from Finder opens the launcher.
        if !model.reopenWindows() { model.toggleLauncher() }
        return false
    }
}
