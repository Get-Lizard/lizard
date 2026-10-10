import AppKit
import ApplicationServices
import KeyboardShortcuts

/// Moves and resizes the front window of the app you were in, through Accessibility.
@MainActor
enum WindowManager {
    enum Layout: String, CaseIterable, Identifiable {
        case leftHalf, rightHalf, topHalf, bottomHalf
        case topLeft, topRight, bottomLeft, bottomRight
        case leftThird, centerThird, rightThird, leftTwoThirds, rightTwoThirds
        case maximize, almostMaximize, center, nextDisplay, restore

        var id: String { rawValue }

        var title: String {
            switch self {
            case .leftHalf: "Left Half"
            case .rightHalf: "Right Half"
            case .topHalf: "Top Half"
            case .bottomHalf: "Bottom Half"
            case .topLeft: "Top Left Quarter"
            case .topRight: "Top Right Quarter"
            case .bottomLeft: "Bottom Left Quarter"
            case .bottomRight: "Bottom Right Quarter"
            case .leftThird: "First Third"
            case .centerThird: "Center Third"
            case .rightThird: "Last Third"
            case .leftTwoThirds: "First Two Thirds"
            case .rightTwoThirds: "Last Two Thirds"
            case .maximize: "Maximize"
            case .almostMaximize: "Almost Maximize"
            case .center: "Center"
            case .nextDisplay: "Move to Next Display"
            case .restore: "Restore Size"
            }
        }

        var symbol: String {
            switch self {
            case .leftHalf: "rectangle.lefthalf.filled"
            case .rightHalf: "rectangle.righthalf.filled"
            case .topHalf: "rectangle.tophalf.filled"
            case .bottomHalf: "rectangle.bottomhalf.filled"
            case .topLeft: "rectangle.inset.topleft.filled"
            case .topRight: "rectangle.inset.topright.filled"
            case .bottomLeft: "rectangle.inset.bottomleft.filled"
            case .bottomRight: "rectangle.inset.bottomright.filled"
            case .leftThird, .leftTwoThirds: "rectangle.leadingthird.inset.filled"
            case .centerThird: "rectangle.center.inset.filled"
            case .rightThird, .rightTwoThirds: "rectangle.trailingthird.inset.filled"
            case .maximize: "macwindow"
            case .almostMaximize: "macwindow.badge.plus"
            case .center: "rectangle.center.inset.filled"
            case .nextDisplay: "display.2"
            case .restore: "arrow.uturn.backward.square"
            }
        }

        /// Default global shortcuts (⌃⌥ + arrows, like most window managers).
        var shortcutName: KeyboardShortcuts.Name? {
            switch self {
            case .leftHalf: .windowLeft
            case .rightHalf: .windowRight
            case .topHalf: .windowTop
            case .bottomHalf: .windowBottom
            case .maximize: .windowMaximize
            case .center: .windowCenter
            default: nil
            }
        }
    }

    /// Frames before Lizard moved them, for "Restore".
    private static var previous: [pid_t: CGRect] = [:]

    /// Applies a layout to the focused window of `app`. Returns an error message for the HUD, or nil.
    @discardableResult
    static func apply(_ layout: Layout, to app: NSRunningApplication?) -> String? {
        guard AXIsProcessTrusted() else { return "Allow Accessibility for Lizard (Setup › Permissions) to move windows." }
        guard let app, let window = focusedWindow(of: app) else { return "No window to move." }
        guard let frame = frame(of: window), let screen = screen(containing: frame) else { return "Couldn't read the window." }
        let visible = axFrame(screen.visibleFrame, primaryHeight: NSScreen.screens.first?.frame.height ?? screen.frame.height)
        let target: CGRect
        let pid = app.processIdentifier
        switch layout {
        case .restore:
            guard let saved = previous[pid] else { return "Nothing to restore." }
            target = saved
        case .nextDisplay:
            let screens = NSScreen.screens
            guard screens.count > 1, let index = screens.firstIndex(of: screen) else { return "Only one display." }
            let next = screens[(index + 1) % screens.count]
            let nextVisible = axFrame(next.visibleFrame, primaryHeight: screens.first?.frame.height ?? next.frame.height)
            let relativeX = (frame.minX - visible.minX) / visible.width
            let relativeY = (frame.minY - visible.minY) / visible.height
            let width = min(frame.width, nextVisible.width)
            let height = min(frame.height, nextVisible.height)
            target = CGRect(x: nextVisible.minX + relativeX * nextVisible.width, y: nextVisible.minY + relativeY * nextVisible.height, width: width, height: height)
        default:
            target = rect(for: layout, in: visible, current: frame)
        }
        if layout != .restore { previous[pid] = frame }
        set(window, frame: target)
        return nil
    }

    static func rect(for layout: Layout, in area: CGRect, current: CGRect) -> CGRect {
        let x = area.minX, y = area.minY, w = area.width, h = area.height
        switch layout {
        case .leftHalf: return CGRect(x: x, y: y, width: w / 2, height: h)
        case .rightHalf: return CGRect(x: x + w / 2, y: y, width: w / 2, height: h)
        case .topHalf: return CGRect(x: x, y: y, width: w, height: h / 2)
        case .bottomHalf: return CGRect(x: x, y: y + h / 2, width: w, height: h / 2)
        case .topLeft: return CGRect(x: x, y: y, width: w / 2, height: h / 2)
        case .topRight: return CGRect(x: x + w / 2, y: y, width: w / 2, height: h / 2)
        case .bottomLeft: return CGRect(x: x, y: y + h / 2, width: w / 2, height: h / 2)
        case .bottomRight: return CGRect(x: x + w / 2, y: y + h / 2, width: w / 2, height: h / 2)
        case .leftThird: return CGRect(x: x, y: y, width: w / 3, height: h)
        case .centerThird: return CGRect(x: x + w / 3, y: y, width: w / 3, height: h)
        case .rightThird: return CGRect(x: x + 2 * w / 3, y: y, width: w / 3, height: h)
        case .leftTwoThirds: return CGRect(x: x, y: y, width: 2 * w / 3, height: h)
        case .rightTwoThirds: return CGRect(x: x + w / 3, y: y, width: 2 * w / 3, height: h)
        case .maximize: return area
        case .almostMaximize: return area.insetBy(dx: w * 0.05, dy: h * 0.05)
        case .center:
            let width = min(current.width, w), height = min(current.height, h)
            return CGRect(x: x + (w - width) / 2, y: y + (h - height) / 2, width: width, height: height)
        case .nextDisplay, .restore: return current
        }
    }

    // MARK: Accessibility plumbing (AX uses top-left origin; AppKit bottom-left)

    private static func focusedWindow(of app: NSRunningApplication) -> AXUIElement? {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success, let window {
            return (window as! AXUIElement)
        }
        if AXUIElementCopyAttributeValue(element, kAXMainWindowAttribute as CFString, &window) == .success, let window {
            return (window as! AXUIElement)
        }
        return nil
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    private static func set(_ window: AXUIElement, frame: CGRect) {
        var position = frame.origin
        var size = frame.size
        // Size, position, size: some apps clamp the size against the old position.
        if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) }
        if let value = AXValueCreate(.cgPoint, &position) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) }
        if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) }
    }

    private static func axFrame(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func screen(containing axRect: CGRect) -> NSScreen? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let center = CGPoint(x: axRect.midX, y: primaryHeight - axRect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
    }
}

extension KeyboardShortcuts.Name {
    static let windowLeft = Self("windowLeft", default: .init(.leftArrow, modifiers: [.control, .option]))
    static let windowRight = Self("windowRight", default: .init(.rightArrow, modifiers: [.control, .option]))
    static let windowTop = Self("windowTop", default: .init(.upArrow, modifiers: [.control, .option]))
    static let windowBottom = Self("windowBottom", default: .init(.downArrow, modifiers: [.control, .option]))
    static let windowMaximize = Self("windowMaximize", default: .init(.return, modifiers: [.control, .option]))
    static let windowCenter = Self("windowCenter", default: .init(.c, modifiers: [.control, .option]))
}
