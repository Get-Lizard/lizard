import AppKit
import KeyboardShortcuts

/// Lizard's own menu-bar icon. Created after extension menu-bar items so those sit to its right
/// (macOS adds each new item to the left), and hidden automatically when an extension item
/// wouldn't fit — on notched Macs with a full menu bar, macOS hides whatever is leftmost.
@MainActor
final class LizardStatusItem: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private weak var app: AppModel?

    init(app: AppModel) {
        self.app = app
    }

    var isShown: Bool { item?.isVisible == true }

    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "lizard.main"
        item.behavior = [.removalAllowed]
        let image = NSImage(named: "MenuBarIcon")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Lizard"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.isVisible = Preferences.showMenuBarIcon
        self.item = item
    }

    func setShown(_ shown: Bool) {
        item?.isVisible = shown
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ shortcut: KeyboardShortcuts.Name? = nil, action: @escaping @MainActor () -> Void) {
            let entry = ClosureMenuItem(title: title, action: action)
            if let shortcut { entry.setShortcut(for: shortcut) }
            menu.addItem(entry)
        }
        add("Open Lizard", .toggleLauncher) { [weak app] in app?.toggleLauncher() }
        add("Ask AI", .askAI) { [weak app] in app?.open(.chat(nil)) }
        add("Clipboard History", .clipboard) { [weak app] in app?.open(.clipboard) }
        add("Work Log", .workLog) { [weak app] in app?.showWorkLog() }
        add("New Note", .newNote) { [weak app] in app?.open(.newNote) }
        add("Capture Screenshot", .screenshotArea) { [weak app] in app?.screenshots.capture(.area) }
        menu.addItem(.separator())
        add("Settings…") { [weak app] in app?.openSettings() }
        add("Setup…") { [weak app] in app?.showSetup() }
        menu.addItem(.separator())
        add("Quit Lizard") { NSApp.terminate(nil) }
    }
}

/// NSMenuItem that runs a closure.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, action handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() {
        handler()
    }
}
