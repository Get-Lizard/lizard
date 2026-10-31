import SwiftUI

/// Lizard's signature edge: a thin moss→teal glow that slowly travels around the panel (like light
/// moving across scales) and flares briefly each time the launcher is summoned.
struct BioluminescentRim: View {
    var pulse: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @State private var flare: Double = 0
    @State private var onScreen = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || activeState == .inactive || !onScreen)) { context in
            let angle = reduceMotion ? 30 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 14) / 14 * 360
            RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                .strokeBorder(
                    AngularGradient(
                        colors: [Brand.moss, Brand.teal.opacity(0.55), .clear, .clear, Brand.teal.opacity(0.4), Brand.moss],
                        center: .center, angle: .degrees(angle)),
                    lineWidth: 1.2 + flare * 1.3)
                .opacity(0.55 + flare * 0.45)
                .shadow(color: Brand.moss.opacity(0.25 + flare * 0.4), radius: 6 + flare * 10)
        }
        .allowsHitTesting(false)
        .onWindowVisibility { onScreen = $0 }
        .onChange(of: pulse) {
            guard !reduceMotion else { return }
            flare = 1
            withAnimation(.easeOut(duration: 0.9)) { flare = 0 }
        }
    }
}

/// A greeting for the launcher's home ("Good afternoon, Vitor").
enum Greeting {
    static var text: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let part = hour < 5 ? "Up late" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? part : "\(part), \(first)"
    }
}

/// One quick tile on the home screen.
struct DenTile: View {
    let title: String
    let symbol: String
    let colors: [Color]
    let shortcut: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: colors.first?.opacity(hovering ? 0.6 : 0.3) ?? .clear, radius: hovering ? 8 : 4)
                HStack {
                    Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(shortcut).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hovering ? Brand.moss.opacity(0.5) : Color.secondary.opacity(0.15), lineWidth: 0.6))
            .scaleEffect(hovering ? 1.03 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
