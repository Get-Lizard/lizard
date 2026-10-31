import KeyboardShortcuts
import SwiftUI

/// The voice-typing shortcut as text ("⌃⌥V"), following what the person recorded.
@MainActor
var voiceShortcutText: String { KeyboardShortcuts.getShortcut(for: .voiceTyping)?.description ?? "⌃⌥V" }

/// A glowing mic capsule in Lizard's fields: shows the shortcut, starts dictation on click, and
/// turns into a live waveform while listening.
struct VoiceButton: View {
    @Environment(AppModel.self) private var app
    var compact = false
    @State private var hovering = false
    @State private var onScreen = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let voice = app.voice!
        let active = voice.isActive && voice.target == .launcher
        Button { voice.toggleFromButton() } label: {
            HStack(spacing: 6) {
                if active {
                    HStack(spacing: 2) {
                        ForEach(Array(voice.levels.suffix(6).enumerated()), id: \.offset) { _, level in
                            Capsule().fill(Brand.ink).frame(width: 2.5, height: 4 + CGFloat(level) * 12)
                        }
                    }
                    .frame(height: 16)
                    .animation(.easeOut(duration: 0.08), value: voice.levels)
                } else {
                    Image(systemName: "mic.fill").font(.system(size: 12, weight: .semibold))
                }
                if !compact || active {
                    Text(active ? "Listening" : voiceShortcutText)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                }
            }
            .foregroundStyle(active ? AnyShapeStyle(Brand.ink) : AnyShapeStyle(Brand.moss))
            .padding(.horizontal, compact && !active ? 8 : 10)
            .frame(height: 26)
            .background(active ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Brand.moss.opacity(hovering ? 0.22 : 0.12)), in: Capsule())
            .overlay {
                // The rim breathes (a 3.2 s cycle) only while the field is on screen: a
                // forever-repeating animation would keep redrawing in the hidden launcher.
                TimelineView(.animation(minimumInterval: 1 / 20, paused: active || reduceMotion || !onScreen)) { context in
                    let glow = active || reduceMotion ? 1 : 0.5 - 0.5 * cos(context.date.timeIntervalSinceReferenceDate * .pi / 1.6)
                    Capsule().strokeBorder(Brand.moss.opacity(0.25 + 0.45 * glow), lineWidth: 1)
                        .shadow(color: Brand.moss.opacity(active ? 0.5 : 0.3 * glow), radius: active ? 10 : 6)
                }
                .allowsHitTesting(false)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Voice typing: hold \(voiceShortcutText) and talk anywhere, release to type. Click to talk here.")
        .onWindowVisibility { onScreen = $0 }
    }
}

/// One-time "New" badge at the bottom of the launcher, until voice typing has been used once.
struct VoiceCoachBadge: View {
    @AppStorage("Lizard.VoiceCoachDone") private var done = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var onScreen = true

    var body: some View {
        if !done {
            HStack(spacing: 12) {
                Text("NEW").font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundStyle(Brand.ink)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Brand.gradient, in: Capsule())
                TimelineView(.animation(minimumInterval: 1 / 24, paused: reduceMotion || !onScreen)) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    HStack(spacing: 2) {
                        ForEach(0..<9) { index in
                            Capsule().fill(Brand.gradient)
                                .frame(width: 2.5, height: 4 + 12 * CGFloat(abs(sin(time * 3.2 + Double(index) * 0.7))))
                        }
                    }
                }
                .frame(width: 40, height: 18)
                .onWindowVisibility { onScreen = $0 }
                HStack(spacing: 4) {
                    Text("Hold")
                    KeyCap(text: voiceShortcutText)
                    Text("and talk, in any app. Release to type.")
                }
                .font(.callout)
                Spacer()
                Button { withAnimation(.snappy) { done = true } } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Got it")
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Brand.moss.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Brand.moss.opacity(0.35)))
            .padding(.horizontal, 10).padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
