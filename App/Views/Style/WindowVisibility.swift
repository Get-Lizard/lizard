import AppKit
import SwiftUI

extension View {
    /// Calls `action` with whether this view's window is on screen (ordered in and not fully
    /// covered). Looping animations use it to stop drawing: a hidden panel (the launcher after
    /// esc, the HUD, the voice pill) keeps its SwiftUI tree, and a `TimelineView` in it would
    /// otherwise render 30 frames a second for as long as Lizard runs.
    func onWindowVisibility(_ action: @escaping (Bool) -> Void) -> some View {
        background(WindowVisibilityProbe(onChange: action).allowsHitTesting(false))
    }
}

private struct WindowVisibilityProbe: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onChange = onChange
    }

    final class ProbeView: NSView {
        var onChange: ((Bool) -> Void)?
        private var reported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)
            }
            report()
        }

        @objc private func occlusionChanged(_ notification: Notification) {
            report()
        }

        private func report() {
            let visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
            guard visible != reported else { return }
            reported = visible
            // Not during the view update that moved us into a window.
            Task { @MainActor [weak self] in self?.onChange?(visible) }
        }
    }
}
