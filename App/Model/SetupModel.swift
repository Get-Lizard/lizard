import AppKit
import ApplicationServices
import ExtensionHost
import Foundation
import Observation

/// First-run setup: hotkeys → permissions → folders → AI → live test. Mirrors Cocoon's paged
/// SetupModel; progress survives quitting (`Lizard.SetupStep`).
@Observable
@MainActor
final class SetupModel {
    enum Page: Int, CaseIterable {
        case welcome, hotkeys, permissions, folders, ai, github, raycast, done

        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .hotkeys: "Shortcuts"
            case .permissions: "Permissions"
            case .folders: "Folders"
            case .ai: "AI"
            case .github: "GitHub"
            case .raycast: "Raycast"
            case .done: "Try it"
            }
        }
    }

    static let completedKey = "Lizard.SetupCompleted"
    static let stepKey = "Lizard.SetupStep"

    static var hasCompletedSetup: Bool {
        get { UserDefaults.standard.bool(forKey: completedKey) }
        set { UserDefaults.standard.set(newValue, forKey: completedKey) }
    }

    var page: Page {
        didSet { UserDefaults.standard.set(page.rawValue, forKey: Self.stepKey) }
    }
    var forward = true
    private(set) var accessibilityGranted = AXIsProcessTrusted()
    /// Set by the hotkey handler while the "Try it" page is showing.
    var hotkeyTestPassed = false

    @ObservationIgnored private var trustPoll: Task<Void, Never>?

    init() {
        page = Page(rawValue: UserDefaults.standard.integer(forKey: Self.stepKey)) ?? .welcome
    }

    /// Pages that apply to this Mac (the Raycast step only when Raycast has extensions installed).
    static var pages: [Page] {
        Page.allCases.filter { $0 != .raycast || !ExtensionStore.raycastExtensions().isEmpty }
    }

    func next() {
        forward = true
        // ⌘Space is the default offer: applied when leaving the shortcuts page without another pick.
        if page == .hotkeys, !LauncherShortcut.hasChosen {
            Task { await LauncherShortcut.use(LauncherShortcut.commandSpace) }
        }
        if let index = Self.pages.firstIndex(of: page), index + 1 < Self.pages.count { page = Self.pages[index + 1] }
    }

    func back() {
        forward = false
        if let index = Self.pages.firstIndex(of: page), index > 0 { page = Self.pages[index - 1] }
    }

    func finish() {
        Self.hasCompletedSetup = true
        UserDefaults.standard.removeObject(forKey: Self.stepKey)
        trustPoll?.cancel()
    }

    // MARK: Accessibility (needed to paste into the previous app)

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        pollTrust()
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        pollTrust()
    }

    /// The grant arrives asynchronously from System Settings; poll until it does.
    private func pollTrust() {
        trustPoll?.cancel()
        trustPoll = Task {
            while !Task.isCancelled, !AXIsProcessTrusted() {
                try? await Task.sleep(for: .seconds(1))
            }
            accessibilityGranted = AXIsProcessTrusted()
        }
    }

    // MARK: Folders

    func choose(folder current: URL, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = current
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }
}
