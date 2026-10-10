import AppKit
import SwiftUI

/// One row in the launcher. Every source (apps, commands, quicklinks, extensions, AI) maps
/// into this so the list view stays simple.
struct LauncherItem: Identifiable {
    enum Icon {
        case app(URL)
        case symbol(String, Color)
        case file(URL)
        case image(NSImage)
    }

    enum Kind: String {
        case app = "Application"
        case command = "Command"
        case quicklink = "Quicklink"
        case extensionCommand = "Extension"
        case ai = "AI"
        case note = "Note"
        case clipboard = "Clipboard"
    }

    let id: String
    var title: String
    var subtitle: String?
    var icon: Icon
    var kind: Kind
    /// Indices in `title` to bold (fuzzy match highlights).
    var highlights: [Int] = []
    var accessory: String?
    /// Primary action (↩). Returning true keeps the panel open (e.g. pushed a view).
    var perform: @MainActor () -> Bool
    /// Secondary actions for the ⌘K menu.
    var actions: [LauncherAction] = []

    init(
        id: String, title: String, subtitle: String? = nil, icon: Icon, kind: Kind, accessory: String? = nil,
        actions: [LauncherAction] = [], perform: @escaping @MainActor () -> Bool
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.kind = kind
        self.accessory = accessory
        self.actions = actions
        self.perform = perform
    }
}

struct LauncherAction: Identifiable {
    let id = UUID()
    var title: String
    var symbol: String
    var shortcut: KeyboardShortcut?
    var perform: @MainActor () -> Bool
}

/// Lazily loaded, cached app/file icons (NSWorkspace icons are expensive to fetch repeatedly).
@MainActor
enum IconCache {
    private static var cache: [URL: NSImage] = [:]

    static func icon(for url: URL) -> NSImage {
        if let image = cache[url] { return image }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 64, height: 64)
        cache[url] = image
        return image
    }
}

struct LauncherIconView: View {
    let icon: LauncherItem.Icon
    var size: CGFloat = 26

    var body: some View {
        switch icon {
        case .app(let url), .file(let url):
            Image(nsImage: IconCache.icon(for: url)).resizable().frame(width: size, height: size)
        case .image(let image):
            Image(nsImage: image).resizable().scaledToFit().frame(width: size, height: size)
        case .symbol(let name, let color):
            Image(systemName: name)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
        }
    }
}
