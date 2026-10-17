import AppKit
import Carbon.HIToolbox
import Clipboard
import Search

/// Type a snippet's keyword in any app and it's replaced by the snippet, like Raycast.
/// Watches key-downs in other apps (needs Accessibility, which auto-paste already uses); never
/// in password fields (secure input) or Lizard's own windows. On a match it erases the keyword
/// with backspaces, pastes the expanded text, puts the clipboard back and moves the caret to
/// `{cursor}`. A snippet with `{argument}`s erases the keyword and asks for them in the launcher.
@MainActor
final class SnippetExpander {
    private var monitor: Any?
    private var mouseMonitor: Any?
    private var matcher = SnippetKeywordMatcher()
    private var snippets: [UUID: Snippet] = [:]
    private var expanding = false
    private weak var app: AppModel?

    static let enabledKey = "Lizard.SnippetExpansion"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    init(app: AppModel) {
        self.app = app
    }

    func update(_ list: [Snippet]) {
        snippets = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        matcher.update(list)
        refreshMonitoring()
    }

    /// Runs only while it's enabled, permitted, and some snippet has a keyword.
    func refreshMonitoring() {
        let wanted = Self.isEnabled && !matcher.isEmpty && AutoPaste.isTrusted
        if wanted, monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
            }
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.matcher.reset() }
            }
        } else if !wanted, let monitor {
            NSEvent.removeMonitor(monitor)
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            self.monitor = nil
            mouseMonitor = nil
            matcher.reset()
        }
    }

    private func handle(_ event: NSEvent) {
        guard !expanding, !IsSecureEventInputEnabled() else { return matcher.reset() }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        if !event.modifierFlags.intersection([.command, .control]).isEmpty { return matcher.reset() }
        switch Int(event.keyCode) {
        case kVK_Delete:
            matcher.deleteBackward()
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Return, kVK_Tab, kVK_Escape, kVK_ForwardDelete, kVK_Home, kVK_End:
            matcher.reset()
        default:
            guard let characters = event.characters, !characters.isEmpty,
                let hit = matcher.typed(characters), let snippet = snippets[hit.id]
            else { return }
            expand(snippet, erasing: hit.keyword.count)
        }
    }

    private func expand(_ snippet: Snippet, erasing count: Int) {
        guard snippet.arguments.isEmpty else { return askArguments(snippet, erasing: count) }
        expanding = true
        let saved = NSPasteboard.general.string(forType: .string)
        Task {
            guard let expansion = await app?.expandSnippet(snippet) else { expanding = false; return }
            // Let the keyword's last key reach the app before erasing it.
            try? await Task.sleep(for: .milliseconds(30))
            Self.press(kVK_Delete, times: count)
            AutoPaste.copy(text: expansion.text)
            app?.markOwnPasteboardWrite()
            Self.press(kVK_ANSI_V, flags: .maskCommand)
            try? await Task.sleep(for: .milliseconds(60))
            if let back = expansion.cursorFromEnd, back > 0 { Self.press(kVK_LeftArrow, times: back) }
            // Give the app time to read the pasteboard, then restore what was copied before.
            try? await Task.sleep(for: .milliseconds(350))
            if let saved {
                AutoPaste.copy(text: saved)
                app?.markOwnPasteboardWrite()
            }
            await app?.recordSnippetUse(snippet)
            matcher.reset()
            expanding = false
        }
    }

    /// A snippet with arguments: erase the keyword, then ask for the values in the launcher,
    /// which pastes back into this app.
    private func askArguments(_ snippet: Snippet, erasing count: Int) {
        expanding = true
        Task {
            try? await Task.sleep(for: .milliseconds(30))
            Self.press(kVK_Delete, times: count)
            try? await Task.sleep(for: .milliseconds(30))
            app?.askSnippetArguments(snippet)
            matcher.reset()
            expanding = false
        }
    }

    static func press(_ key: Int, times: Int = 1, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<times {
            let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: false)
            down?.flags = flags
            up?.flags = flags
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }
}
