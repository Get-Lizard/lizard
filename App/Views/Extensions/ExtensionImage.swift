import AppKit
import ExtensionHost
import SwiftUI

/// Renders a Raycast-style image value: `icon:Name`, a URL, a file in the extension's assets,
/// `{source, tintColor, mask, fallback}` objects, `color:` tints and `initials:` avatars.
struct ExtensionImage: View {
    let value: HostJSON?
    let assets: URL?
    var size: CGFloat = 18

    var body: some View {
        if let value {
            content(value)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }

    @ViewBuilder
    private func content(_ value: HostJSON) -> some View {
        switch value {
        case .string(let text):
            image(source: text, tint: nil, mask: nil)
        case .object(let object):
            let source = object["source"].flatMap { $0["light"] ?? $0["dark"] ?? $0 }?.string
                ?? object["value"]?.string ?? ""
            image(source: source, tint: object["tintColor"].flatMap(ExtensionColor.color), mask: object["mask"]?.string)
        default:
            Color.clear.frame(width: size, height: size)
        }
    }

    @ViewBuilder
    private func image(source: String, tint: Color?, mask: String?) -> some View {
        if source.hasPrefix("icon:") {
            Image(systemName: ExtensionIcons.symbol(for: String(source.dropFirst(5))))
                .font(.system(size: size * 0.78, weight: .medium))
                .foregroundStyle(tint ?? .secondary)
                .frame(width: size, height: size)
        } else if source.hasPrefix("initials:") {
            Text(source.dropFirst(9))
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Brand.teal.gradient, in: Circle())
        } else if source.hasPrefix("http://") || source.hasPrefix("https://") {
            AsyncImage(url: URL(string: source)) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Color.secondary.opacity(0.15)
            }
            .frame(width: size, height: size)
            .clipShape(mask == "circle" ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)))
        } else if let url = fileURL(source), let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .renderingMode(tint == nil ? .original : .template)
                .scaledToFit()
                .foregroundStyle(tint ?? .primary)
                .frame(width: size, height: size)
                .clipShape(mask == "circle" ? AnyShape(Circle()) : AnyShape(Rectangle()))
        } else if source.count <= 2, !source.isEmpty {
            Text(source).font(.system(size: size * 0.8)).frame(width: size, height: size)
        } else {
            Image(systemName: "square.dashed").foregroundStyle(.tertiary).frame(width: size, height: size)
        }
    }

    private func fileURL(_ source: String) -> URL? {
        if source.hasPrefix("/") { return URL(filePath: source) }
        if source.hasPrefix("file://") { return URL(string: source) }
        guard let assets else { return nil }
        let url = assets.appending(path: source)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

enum ExtensionColor {
    static func color(_ value: HostJSON) -> Color? {
        if case .object(let object) = value { return (object["light"] ?? object["dark"]).flatMap(color) }
        guard let text = value.string else { return nil }
        switch text {
        case "color:blue": return .blue
        case "color:green": return .green
        case "color:magenta": return .pink
        case "color:orange": return .orange
        case "color:purple": return .purple
        case "color:red": return .red
        case "color:yellow": return .yellow
        case "color:primaryText": return .primary
        case "color:secondaryText": return .secondary
        default:
            let hex = text.hasPrefix("#") ? String(text.dropFirst()) : text
            guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
            return Color(hex: value)
        }
    }
}

/// Raycast icon names → SF Symbols (the common ones; unknown names get a neutral glyph).
enum ExtensionIcons {
    static func symbol(for name: String) -> String {
        if let symbol = table[name] { return symbol }
        let lower = name.lowercased()
        for (key, symbol) in fuzzy where lower.contains(key) { return symbol }
        return "circle.dashed"
    }

    static let table: [String: String] = [
        "AppWindow": "macwindow", "AppWindowGrid": "square.grid.2x2", "AppWindowList": "list.bullet.rectangle", "ArrowClockwise": "arrow.clockwise",
        "ArrowCounterClockwise": "arrow.counterclockwise", "ArrowDown": "arrow.down", "ArrowLeft": "arrow.left", "ArrowRight": "arrow.right",
        "ArrowUp": "arrow.up", "ArrowNe": "arrow.up.right", "Bell": "bell", "BellDisabled": "bell.slash", "Binoculars": "binoculars", "Bolt": "bolt",
        "Book": "book", "Bookmark": "bookmark", "Box": "shippingbox", "Brush": "paintbrush", "Bug": "ladybug", "Building": "building.2",
        "BullsEye": "scope", "Calendar": "calendar", "Camera": "camera", "Check": "checkmark", "CheckCircle": "checkmark.circle",
        "CheckList": "checklist", "Checkmark": "checkmark", "ChevronDown": "chevron.down", "ChevronRight": "chevron.right", "ChevronUp": "chevron.up",
        "Circle": "circle", "CircleFilled": "circle.fill", "CircleProgress": "circle.dotted", "Clipboard": "doc.on.clipboard", "Clock": "clock",
        "Cloud": "cloud", "Code": "chevron.left.forwardslash.chevron.right", "CodeBlock": "curlybraces", "Cog": "gearshape", "Coin": "dollarsign.circle",
        "Command": "command", "Compass": "safari", "ComputerChip": "cpu", "Copy": "doc.on.doc", "CopyClipboard": "doc.on.clipboard",
        "CreditCard": "creditcard", "Desktop": "desktopcomputer", "Document": "doc", "Dot": "circle.fill", "Download": "arrow.down.circle",
        "Ellipsis": "ellipsis", "Envelope": "envelope", "Exclamationmark": "exclamationmark", "Eye": "eye", "EyeDisabled": "eye.slash",
        "EyeDropper": "eyedropper", "Filter": "line.3.horizontal.decrease", "Finder": "folder", "Fingerprint": "touchid", "Flag": "flag",
        "Folder": "folder", "Gear": "gearshape", "Gift": "gift", "Globe": "globe", "Hammer": "hammer", "HardDrive": "internaldrive",
        "Hashtag": "number", "Heart": "heart", "House": "house", "Hourglass": "hourglass", "Image": "photo", "Info": "info.circle", "Key": "key",
        "Keyboard": "keyboard", "Layers": "square.3.layers.3d", "LightBulb": "lightbulb", "Link": "link", "List": "list.bullet", "Lock": "lock",
        "LockUnlocked": "lock.open", "MagnifyingGlass": "magnifyingglass", "Map": "map", "Megaphone": "megaphone", "Message": "message",
        "Microphone": "mic", "MinusCircle": "minus.circle", "Mobile": "iphone", "Moon": "moon", "Music": "music.note", "Network": "network",
        "NewDocument": "doc.badge.plus", "NewFolder": "folder.badge.plus", "Paperclip": "paperclip", "Pause": "pause", "Pencil": "pencil",
        "Person": "person", "PersonCircle": "person.circle", "Phone": "phone", "Pin": "pin", "PinDisabled": "pin.slash", "Play": "play",
        "Plus": "plus", "PlusCircle": "plus.circle", "Power": "power", "Print": "printer", "QuestionMark": "questionmark", "QuestionMarkCircle": "questionmark.circle",
        "Repeat": "repeat", "Reply": "arrowshape.turn.up.left", "Rocket": "paperplane", "RotateClockwise": "arrow.clockwise", "Shield": "shield",
        "Sidebar": "sidebar.left", "Signal1": "cellularbars", "SpeakerHigh": "speaker.wave.3", "SpeakerOff": "speaker.slash", "SpeechBubble": "bubble.left",
        "SpeechBubbleActive": "bubble.left.fill", "Star": "star", "StarCircle": "star.circle", "StarDisabled": "star.slash", "Stop": "stop",
        "Sun": "sun.max", "Switch": "switch.2", "Tag": "tag", "Terminal": "terminal", "Text": "textformat", "TextCursor": "character.cursor.ibeam",
        "Trash": "trash", "Tray": "tray", "TwoPeople": "person.2", "Upload": "arrow.up.circle", "Video": "video", "Wallet": "wallet.pass",
        "Wand": "wand.and.stars", "Warning": "exclamationmark.triangle", "Wifi": "wifi", "Window": "macwindow", "XMarkCircle": "xmark.circle",
        "XMarkCircleFilled": "xmark.circle.fill", "XMark": "xmark", "ExclamationMark": "exclamationmark", "Livestream": "dot.radiowaves.left.and.right",
        "Leaf": "leaf", "Logout": "rectangle.portrait.and.arrow.right", "Monitor": "display", "Patch": "bandage", "Receipt": "receipt",
    ]

    static let fuzzy: [(String, String)] = [
        ("arrow", "arrow.right"), ("circle", "circle"), ("person", "person"), ("folder", "folder"), ("doc", "doc"), ("calendar", "calendar"),
        ("chart", "chart.bar"), ("battery", "battery.75"), ("cloud", "cloud"), ("lock", "lock"), ("star", "star"), ("bell", "bell"),
    ]
}
