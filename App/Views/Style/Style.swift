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

/// Footer bar with the current action hints, like Raycast's action bar.
struct ActionBar<Leading: View>: View {
    let hints: [(String, String)]
    @ViewBuilder var leading: Leading

    var body: some View {
        HStack(spacing: 12) {
            leading
            Spacer()
            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                HStack(spacing: 4) {
                    Text(hint.0).font(.caption).foregroundStyle(.secondary)
                    KeyCap(text: hint.1)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(.bar)
    }
}
