import AppKit
import ExtensionHost
import SwiftUI

/// Shows an extension's menu-bar command as a native status item (e.g. the GitHub icon with a
/// count). Re-runs the command on its manifest `interval` in the background; the previous run
/// stays alive until the new one renders, so menu clicks always reach a live process.
@MainActor
final class MenuBarCommandController: NSObject, NSMenuDelegate {
    let installed: InstalledExtension
    let command: ExtensionManifest.Command
    private weak var model: ExtensionsModel?
    private var statusItem: NSStatusItem?
    private var runtime: ExtensionRuntime?
    private var pending: ExtensionRuntime?
    private var timer: Timer?
    private var latest: ViewNode?

    init(installed: InstalledExtension, command: ExtensionManifest.Command, model: ExtensionsModel) {
        self.installed = installed
        self.command = command
        self.model = model
    }

    func start() {
        refresh(launchType: "userInitiated")
        let interval = command.intervalSeconds ?? 300
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(launchType: "background") }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        runtime?.stop()
        pending?.stop()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    func refresh(launchType: String = "userInitiated") {
        guard let model, pending == nil else { return }
        Task {
            do {
                let runtime = try await model.makeRuntime(installed, command, launchType: launchType)
                pending = runtime
                listen(runtime)
            } catch {
                show(error: error.localizedDescription)
            }
        }
    }

    private func listen(_ runtime: ExtensionRuntime) {
        Task {
            for await event in runtime.events {
                switch event {
                case .render(let tree, _):
                    guard let root = tree.first(where: { $0.type == "MenuBarExtra" }) ?? tree.first?.first("MenuBarExtra") else {
                        // Rendering nothing hides the item.
                        if !tree.isEmpty || runtime === pending { hide() }
                        continue
                    }
                    if runtime === pending {
                        self.runtime?.stop()
                        self.runtime = runtime
                        pending = nil
                    }
                    if runtime === self.runtime { update(root) }
                case .notify(let method, let params):
                    model?.handleNotify(method, params, extensionName: installed.name, command: command.name)
                case .error(let message, _):
                    if runtime === pending, latest == nil { show(error: message) }
                case .exited:
                    if runtime === pending { pending = nil }
                default:
                    break
                }
            }
        }
    }

    private func ensureItem() -> NSStatusItem {
        if let statusItem { return statusItem }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "lizard.\(installed.name).\(command.name)"
        item.behavior = [.removalAllowed]
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        return item
    }

    private func hide() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    private func update(_ root: ViewNode) {
        latest = root
        let item = ensureItem()
        let title = root.string("title") ?? ""
        if let count = Int(title.trimmingCharacters(in: .whitespaces)), count > 0 {
            // A pending count (e.g. PRs waiting on you) gets an attention colour.
            item.button?.attributedTitle = NSAttributedString(string: " \(title)", attributes: [
                .foregroundColor: NSColor.systemOrange, .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
                .baselineOffset: 0.5,
            ])
        } else {
            item.button?.title = title.isEmpty ? "" : " \(title)"
        }
        item.button?.image = MenuImages.image(root["icon"], assets: installed.assetsDirectory, template: true, size: 16)
            ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: installed.title)
        item.button?.imagePosition = .imageLeading
        item.button?.toolTip = root.string("tooltip")
        rebuildMenu(item.menu!, from: root)
    }

    private func show(error: String) {
        let item = ensureItem()
        item.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        item.button?.title = ""
        let menu = item.menu!
        menu.removeAllItems()
        menu.addItem(withTitle: "\(installed.title): \(error.prefix(120))", action: nil, keyEquivalent: "")
        let retry = NSMenuItem(title: "Retry", action: #selector(retry), keyEquivalent: "")
        retry.target = self
        menu.addItem(retry)
    }

    @objc private func retry() { refresh() }

    func menuWillOpen(_ menu: NSMenu) {
        // Raycast re-runs menu-bar commands when opened; refresh in the background.
        refresh(launchType: "userInitiated")
    }

    private func rebuildMenu(_ menu: NSMenu, from root: ViewNode) {
        menu.removeAllItems()
        append(root.content, to: menu)
        if menu.items.isEmpty {
            menu.addItem(withTitle: installed.title, action: nil, keyEquivalent: "")
        }
    }

    private func append(_ nodes: [ViewNode], to menu: NSMenu) {
        for node in nodes {
            switch node.type {
            case "MenuBarExtra.Section":
                if !menu.items.isEmpty, menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
                if let title = node.string("title") {
                    menu.addItem(NSMenuItem.sectionHeader(title: title))
                }
                append(node.content, to: menu)
            case "MenuBarExtra.Separator":
                menu.addItem(.separator())
            case "MenuBarExtra.Submenu":
                let item = NSMenuItem(title: node.string("title") ?? "", action: nil, keyEquivalent: "")
                item.image = MenuImages.image(node["icon"], assets: installed.assetsDirectory, template: false, size: 16)
                let submenu = NSMenu()
                append(node.content, to: submenu)
                item.submenu = submenu
                menu.addItem(item)
            case "MenuBarExtra.Item":
                menu.addItem(menuItem(node))
            default:
                append(node.content, to: menu)
            }
        }
    }

    private func menuItem(_ node: ViewNode) -> NSMenuItem {
        var title = node.string("title") ?? ""
        if let subtitle = node.string("subtitle") { title += "  \(subtitle)" }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let subtitle = node.string("subtitle") {
            let attributed = NSMutableAttributedString(string: node.string("title") ?? "", attributes: [.font: NSFont.menuFont(ofSize: 0)])
            attributed.append(NSAttributedString(string: "  \(subtitle)", attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.menuFont(ofSize: 0)]))
            item.attributedTitle = attributed
        }
        item.image = MenuImages.image(node["icon"], assets: installed.assetsDirectory, template: false, size: 16)
        item.toolTip = node.string("tooltip")
        if let callback = node.callback("onAction") {
            item.target = self
            item.action = #selector(menuItemClicked(_:))
            item.representedObject = callback
        }
        if let alternate = node.slot("alternate") ?? node.children.first(where: { $0.type == "MenuBarExtra.Item" }), alternate.callback("onAction") != nil, node.props["alternate"] != nil {
            let alt = menuItem(alternate)
            alt.isAlternate = true
            alt.keyEquivalentModifierMask = .option
            return alt
        }
        return item
    }

    @objc private func menuItemClicked(_ sender: NSMenuItem) {
        guard let callback = sender.representedObject as? String else { return }
        // The event object Raycast passes: { type: "left-click" | "right-click" }.
        runtime?.invoke(callback, args: [.object(["type": .string("left-click")])])
    }
}

/// Converts extension image values to NSImages for menus (SF Symbols, files, URLs cached).
@MainActor
enum MenuImages {
    private static var remote: [URL: NSImage] = [:]
    private static var loading: Set<URL> = []

    static func image(_ value: HostJSON?, assets: URL, template: Bool, size: CGFloat) -> NSImage? {
        guard let value else { return nil }
        var source: String?
        var tint: NSColor?
        switch value {
        case .string(let text): source = text
        case .object(let object):
            source = object["source"].flatMap { $0["light"] ?? $0["dark"] ?? $0 }?.string
            tint = object["tintColor"].flatMap(ExtensionColor.color).map { NSColor($0) }
        default: return nil
        }
        guard let source else { return nil }
        var image: NSImage?
        if source.hasPrefix("icon:") {
            let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.8, weight: .regular)
            image = NSImage(systemSymbolName: ExtensionIcons.symbol(for: String(source.dropFirst(5))), accessibilityDescription: nil)?
                .withSymbolConfiguration(tint.map { configuration.applying(.init(paletteColors: [$0])) } ?? configuration)
            if tint == nil { image?.isTemplate = true }
            return image
        }
        if source.hasPrefix("http"), let url = URL(string: source) {
            if let cached = remote[url] { return cached }
            if !loading.contains(url) {
                loading.insert(url)
                Task {
                    if let (data, _) = try? await URLSession.shared.data(from: url), let fetched = NSImage(data: data) {
                        fetched.size = NSSize(width: size, height: size)
                        remote[url] = rounded(fetched, size: size)
                    }
                }
            }
            return nil
        }
        let url = source.hasPrefix("/") ? URL(filePath: source) : assets.appending(path: source)
        if let loaded = NSImage(contentsOf: url) {
            loaded.size = NSSize(width: size, height: size)
            loaded.isTemplate = template
            image = loaded
        }
        return image
    }

    private static func rounded(_ image: NSImage, size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            image.draw(in: rect)
            return true
        }
    }
}
