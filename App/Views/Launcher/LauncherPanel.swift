import AppKit
import SwiftUI

/// The floating launcher window. Non-activating so summoning it never steals focus from the
/// app you're in (VS Code, Xcode…), yet it can become key so typing goes into the search field.
final class LauncherPanel: NSPanel {
    var onResignKey: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .borderless],
            backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    // Required: a non-activating panel otherwise refuses key status and swallows typing.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func cancelOperation(_ sender: Any?) {
        // Esc is handled by SwiftUI (pop a level first); only reached when nothing handled it.
    }
}

/// Owns a panel hosting SwiftUI content; shows it centered in the upper third of the active screen.
@MainActor
final class FloatingPanelController<Content: View> {
    let panel: LauncherPanel
    private let size: NSSize

    init(size: NSSize, hidesOnResign: Bool = true, @ViewBuilder content: () -> Content) {
        self.size = size
        panel = LauncherPanel(contentRect: NSRect(origin: .zero, size: size))
        let host = NSHostingView(rootView: content())
        host.sizingOptions = []
        panel.contentView = host
        if hidesOnResign {
            panel.onResignKey = { [weak panel] in panel?.orderOut(nil) }
        }
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.68 - size.height / 2)
            panel.setFrame(NSRect(origin: origin, size: size), display: false)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() { panel.orderOut(nil) }
}
