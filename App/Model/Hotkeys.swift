import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import LizardCore

/// Every global shortcut Lizard registers. ⌃Space is the fallback launcher shortcut; Setup offers
/// ⌘Space (see `LauncherShortcut`). ⌥⇧ + letter opens a feature directly. Users re-record them in Setup or Settings.
extension KeyboardShortcuts.Name {
    static let toggleLauncher = Self("toggleLauncher", default: .init(.space, modifiers: [.control]))
    static let workLog = Self("workLog", default: .init(.w, modifiers: [.option, .shift]))
    static let clipboard = Self("clipboardHistory", default: .init(.v, modifiers: [.option, .shift]))
    static let askAI = Self("askAI", default: .init(.a, modifiers: [.option, .shift]))
    static let newNote = Self("newNote", default: .init(.n, modifiers: [.option, .shift]))
    /// ⌃⌥Space: ⌥Space belongs to ChatGPT, Claude and Alfred; this one is free in common apps.
    static let voiceTyping = Self("voiceTyping", default: .init(.space, modifiers: [.control, .option]))
    static let screenshotArea = Self("screenshotArea", default: .init(.s, modifiers: [.control, .shift]))
}

struct HotkeyAction: Identifiable {
    let name: KeyboardShortcuts.Name
    let title: String
    let detail: String
    let symbol: String
    var id: String { name.rawValue }

    static let all: [HotkeyAction] = [
        HotkeyAction(name: .toggleLauncher, title: "Open Lizard", detail: "Show or hide the launcher from anywhere.", symbol: "magnifyingglass"),
        HotkeyAction(name: .workLog, title: "Work Log", detail: "Jot what you just did, with a timestamp.", symbol: "list.bullet.clipboard"),
        HotkeyAction(name: .clipboard, title: "Clipboard History", detail: "Search and paste anything you copied.", symbol: "doc.on.clipboard"),
        HotkeyAction(name: .askAI, title: "Ask AI", detail: "Chat with the on-device AI.", symbol: "sparkles"),
        HotkeyAction(name: .newNote, title: "New Note", detail: "Start a markdown note.", symbol: "square.and.pencil"),
        HotkeyAction(name: .voiceTyping, title: "Voice Typing", detail: "Hold and talk, release to type. Tap to keep listening.", symbol: "waveform"),
        HotkeyAction(name: .screenshotArea, title: "Capture Screenshot", detail: "Capture an area; Lizard names and files it.", symbol: "camera.viewfinder"),
    ]

    static let windows: [HotkeyAction] = [
        HotkeyAction(name: .windowLeft, title: "Window Left Half", detail: "Snap the front window left.", symbol: "rectangle.lefthalf.filled"),
        HotkeyAction(name: .windowRight, title: "Window Right Half", detail: "Snap the front window right.", symbol: "rectangle.righthalf.filled"),
        HotkeyAction(name: .windowTop, title: "Window Top Half", detail: "Snap the front window up.", symbol: "rectangle.tophalf.filled"),
        HotkeyAction(name: .windowBottom, title: "Window Bottom Half", detail: "Snap the front window down.", symbol: "rectangle.bottomhalf.filled"),
        HotkeyAction(name: .windowMaximize, title: "Maximize Window", detail: "Fill the screen.", symbol: "macwindow"),
        HotkeyAction(name: .windowCenter, title: "Center Window", detail: "Center the front window.", symbol: "rectangle.center.inset.filled"),
    ]
}

/// Conflicts worth warning about while recording.
enum HotkeyConflicts {
    /// ⌃Space is macOS's "Select the previous input source" — only a problem with 2+ input sources.
    static func warning(for shortcut: KeyboardShortcuts.Shortcut?) -> String? {
        guard let shortcut else { return nil }
        if shortcut.key == .space, shortcut.modifiers == [.control], enabledKeyboardInputSources() > 1 {
            return "⌃Space also switches keyboard input sources on this Mac. Turn that off in System Settings › Keyboard › Keyboard Shortcuts › Input Sources, or pick another shortcut."
        }
        return nil
    }

    /// Number of selectable keyboard layouts / input methods.
    static func enabledKeyboardInputSources() -> Int {
        let filter = [kTISPropertyInputSourceIsSelectCapable as String: true, kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return 1 }
        return list.count
    }

    static let keyboardShortcutsSettings = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts")!
}

/// The launcher shortcut choice offered in Setup and Settings. ⌘Space is the default offer; it
/// belongs to Spotlight until Spotlight's shortcut is switched off, which Lizard does (and undoes)
/// for you.
enum LauncherShortcut {
    static let commandSpace = KeyboardShortcuts.Shortcut(.space, modifiers: [.command])
    static let controlSpace = KeyboardShortcuts.Shortcut(.space, modifiers: [.control])
    private static let chosenKey = "Lizard.LauncherShortcutChosen"

    /// Whether the person has picked a launcher shortcut (Setup applies ⌘Space when they haven't).
    static var hasChosen: Bool {
        get { UserDefaults.standard.bool(forKey: chosenKey) }
        set { UserDefaults.standard.set(newValue, forKey: chosenKey) }
    }

    static var current: KeyboardShortcuts.Shortcut? { KeyboardShortcuts.getShortcut(for: .toggleLauncher) }

    /// Same keys, compared by Carbon codes (the stored value can differ in device-dependent flags).
    static func same(_ a: KeyboardShortcuts.Shortcut?, _ b: KeyboardShortcuts.Shortcut?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.carbonKeyCode == b.carbonKeyCode && a.carbonModifiers == b.carbonModifiers
    }

    /// For messages: "⌘Space", or a fallback when none is set.
    static var display: String { current.map { "\($0)" } ?? "your launcher shortcut" }

    @MainActor
    static func use(_ shortcut: KeyboardShortcuts.Shortcut?) async {
        KeyboardShortcuts.setShortcut(shortcut, for: .toggleLauncher)
        hasChosen = true
        await SpotlightShortcut.sync(launcher: shortcut)
    }
}

/// Spotlight's "Show Spotlight search" (symbolic hotkey 64). Turned off only when the launcher
/// takes ⌘Space, and turned back on if Lizard was the one that turned it off.
enum SpotlightShortcut {
    private static let domain = "com.apple.symbolichotkeys"
    private static let disabledByLizardKey = "Lizard.SpotlightShortcutDisabled"

    static var isEnabled: Bool {
        CFPreferencesAppSynchronize(domain as CFString)
        guard let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain as CFString) as? [String: Any],
            let entry = all["64"] as? [String: Any]
        else { return true }  // never customised: on
        return (entry["enabled"] as? NSNumber)?.boolValue ?? true
    }

    static func sync(launcher: KeyboardShortcuts.Shortcut?) async {
        let wantsCommandSpace = LauncherShortcut.same(launcher, LauncherShortcut.commandSpace)
        if wantsCommandSpace, isEnabled {
            if await setEnabled(false) { UserDefaults.standard.set(true, forKey: disabledByLizardKey) }
        } else if !wantsCommandSpace, UserDefaults.standard.bool(forKey: disabledByLizardKey) {
            if await setEnabled(true) { UserDefaults.standard.removeObject(forKey: disabledByLizardKey) }
        }
    }

    /// Writes the setting, then asks the system to reload shortcuts (takes effect without logging out).
    private static func setEnabled(_ enabled: Bool) async -> Bool {
        let entry = """
            <dict><key>enabled</key><\(enabled ? "true" : "false")/><key>value</key><dict><key>parameters</key>\
            <array><integer>32</integer><integer>49</integer><integer>1048576</integer></array>\
            <key>type</key><string>standard</string></dict></dict>
            """
        guard let write = try? await ProcessRunner.run("/usr/bin/defaults", ["write", "com.apple.symbolichotkeys", "AppleSymbolicHotKeys", "-dict-add", "64", entry], timeout: .seconds(10)),
            write.succeeded
        else { return false }
        _ = try? await ProcessRunner.run("/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings", ["-u"], timeout: .seconds(10))
        return true
    }
}
