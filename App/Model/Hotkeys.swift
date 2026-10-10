import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts

/// Every global shortcut Lizard registers. Defaults follow the plan: ⌃Space toggles the
/// launcher, ⌥⇧ + letter opens a feature directly. Users re-record them in Setup or Settings.
extension KeyboardShortcuts.Name {
    static let toggleLauncher = Self("toggleLauncher", default: .init(.space, modifiers: [.control]))
    static let workLog = Self("workLog", default: .init(.w, modifiers: [.option, .shift]))
    static let clipboard = Self("clipboardHistory", default: .init(.v, modifiers: [.option, .shift]))
    static let askAI = Self("askAI", default: .init(.a, modifiers: [.option, .shift]))
    static let newNote = Self("newNote", default: .init(.n, modifiers: [.option, .shift]))
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
        if shortcut.key == .space, shortcut.modifiers == [.command] {
            return "⌘Space opens Spotlight. Turn Spotlight's shortcut off in System Settings › Keyboard › Keyboard Shortcuts › Spotlight first."
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
