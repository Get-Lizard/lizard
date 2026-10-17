import SwiftUI

/// Shared surfaces and metrics (Cocoon's MagicStyle, adapted to the launcher's glass look).
enum Metrics {
    static let launcherSize = CGSize(width: 760, height: 480)
    static let workspaceSize = CGSize(width: 980, height: 620)
    static let corner: CGFloat = 18
    static let rowHeight: CGFloat = 40
}

extension View {
    /// Rounded card on a quiet fill with a hairline border.
    func surface(cornerRadius: CGFloat = 12) -> some View {
        background(.fill.quinary, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }

    /// The launcher's glass container.
    func launcherGlass() -> some View {
        background(Color(nsColor: .windowBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
    }

    /// Selected-row highlight in the brand color.
    func selectableRow(_ selected: Bool) -> some View {
        background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? AnyShapeStyle(Brand.moss.opacity(0.22)) : AnyShapeStyle(.clear)))
    }
}

/// Small key-cap label ("⌘", "↩").
struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// Footer bar with the current action hints, like Raycast's action bar. Hints given an action
/// are buttons too, so they can be clicked as well as pressed.
struct ActionBar<Leading: View>: View {
    struct Hint {
        var title: String
        var key: String
        var action: (() -> Void)?
    }

    let hints: [Hint]
    let leading: Leading

    init(hints: [(String, String)], @ViewBuilder leading: () -> Leading) {
        self.hints = hints.map { Hint(title: $0.0, key: $0.1) }
        self.leading = leading()
    }

    init(actions: [Hint], @ViewBuilder leading: () -> Leading) {
        hints = actions
        self.leading = leading()
    }

    var body: some View {
        HStack(spacing: 12) {
            leading
            Spacer()
            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                if let action = hint.action {
                    Button(action: action) { label(hint) }.buttonStyle(ActionHintStyle())
                } else {
                    label(hint)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(.bar)
    }

    private func label(_ hint: Hint) -> some View {
        HStack(spacing: 4) {
            Text(hint.title).font(.caption).foregroundStyle(.secondary)
            KeyCap(text: hint.key)
        }
    }
}

/// A clickable hint: a soft highlight on hover and press.
private struct ActionHintStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 5).padding(.vertical, 3)
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
