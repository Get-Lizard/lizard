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
        // Appear instantly: the system fade adds ~150 ms before the field is fully there.
        animationBehavior = .none
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
    private var size: NSSize

    init(size: NSSize, hidesOnResign: Bool = true, @ViewBuilder content: () -> Content) {
        self.size = size
        panel = LauncherPanel(contentRect: NSRect(origin: .zero, size: size))
        let host = NSHostingView(rootView: content())
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        if hidesOnResign {
            panel.onResignKey = { [weak panel] in panel?.orderOut(nil) }
        }
    }

    var isVisible: Bool { panel.isVisible }

    func show(size requested: NSSize? = nil) {
        if let requested { size = requested }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            // The top edge sits at the same place whatever the size, so the search field never jumps.
            let top = frame.minY + frame.height * 0.68 + Metrics.launcherSize.height / 2
            let origin = NSPoint(x: frame.midX - size.width / 2, y: max(frame.minY, top - size.height))
            panel.setFrame(NSRect(origin: origin, size: size), display: false)
        }
        panel.makeKeyAndOrderFront(nil)
        focusTypingField()
    }

    /// Lays out and draws the content once off screen, so the first real show is warm.
    func prerender(size requested: NSSize) {
        size = requested
        panel.setContentSize(requested)
        panel.alphaValue = 0
        panel.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    func hide() {
        lastResponder = panel.firstResponder
        panel.orderOut(nil)
    }

    private weak var lastResponder: NSResponder?

    /// Always land ready to type: restore the text field that had focus, else the topmost editable
    /// field on screen. Retried once after layout, since SwiftUI may still be building the view.
    /// - Parameter newScreen: after navigating (Esc back to search, opening a view) always pick the
    ///   new screen's topmost field instead of keeping the old responder.
    func focusTypingField(newScreen: Bool = false) {
        if newScreen { lastResponder = nil }
        for delay in newScreen ? [0.03, 0.12, 0.3] : [0.0, 0.08] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.panel.isVisible else { return }
                    // Keep a field that's focused and still on screen.
                    if let current = self.panel.firstResponder as? NSView, current.window === self.panel, !current.isHiddenOrHasHiddenAncestor,
                        (current as? NSText)?.isEditable == true {
                        if !newScreen || delay > 0.03 { return }
                    }
                    if let previous = self.lastResponder as? NSView, previous.window === self.panel,
                        (previous as? NSText)?.isEditable == true || (previous as? NSTextField)?.isEditable == true {
                        self.panel.makeFirstResponder(previous)
                        return
                    }
                    if let field = Self.topmostEditable(in: self.panel.contentView) { self.panel.makeFirstResponder(field) }
                }
            }
        }
    }

    private static func topmostEditable(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        var candidates: [NSView] = []
        func walk(_ node: NSView) {
            if node.isHiddenOrHasHiddenAncestor { return }
            if let field = node as? NSTextField, field.isEditable { candidates.append(field) }
            else if let text = node as? NSTextView, text.isEditable { candidates.append(text) }
            node.subviews.forEach(walk)
        }
        walk(view)
        // Topmost = highest on screen (largest y in window coordinates), then leftmost.
        return candidates.max { a, b in
            let fa = a.convert(a.bounds, to: nil), fb = b.convert(b.bounds, to: nil)
            return fa.maxY == fb.maxY ? fa.minX > fb.minX : fa.maxY < fb.maxY
        }
    }

    /// Grows/shrinks around the top edge so the search field stays put.
    func resize(to newSize: NSSize, animated: Bool = true) {
        var frame = panel.frame
        guard frame.size != newSize else { return }
        size = newSize
        let top = frame.maxY
        frame.origin.x = frame.midX - newSize.width / 2
        frame.size = newSize
        frame.origin.y = top - newSize.height
        if let visible = panel.screen?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - newSize.width)
            frame.origin.y = max(frame.origin.y, visible.minY)
        }
        panel.setFrame(frame, display: true, animate: animated)
    }
}
