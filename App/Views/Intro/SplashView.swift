import SwiftUI

/// Launch splash: the gecko draws itself, fills in, flicks its tail twice, blinks, and the
/// wordmark rises. A scripted async sequence like Cocoon's SplashView. Any key or click skips;
/// Reduce Motion shows the final frame.
struct SplashView: View {
    var firstLaunch: Bool
    var preview = false
    var onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: CGFloat = 0
    @State private var fill: Double = 0
    @State private var markScale: CGFloat = 0.86
    @State private var tailCurl: CGFloat = 0.2
    @State private var sway: CGFloat = 0
    @State private var eyes: CGFloat = 1
    @State private var tongue: CGFloat = 0
    @State private var wordmark = false
    @State private var tagline = false
    @State private var finished = false
    @FocusState private var focused: Bool

    init(firstLaunch: Bool, preview: Bool = false, onFinish: @escaping () -> Void) {
        self.firstLaunch = firstLaunch
        self.preview = preview
        self.onFinish = onFinish
        if preview {
            _drawn = State(initialValue: 1)
            _fill = State(initialValue: 1)
            _markScale = State(initialValue: 1)
            _tailCurl = State(initialValue: 1)
            _wordmark = State(initialValue: true)
            _tagline = State(initialValue: true)
        }
    }

    var body: some View {
        ZStack {
            Brand.ink
            RadialGradient(colors: [Brand.moss.opacity(0.28), .clear], center: .init(x: 0.5, y: 0.38), startRadius: 0, endRadius: 300)
            LizardPattern().opacity(0.9)
            VStack(spacing: 14) {
                LizardMark(style: Brand.gradient, tailCurl: tailCurl, sway: sway, eyesOpen: eyes, tongue: tongue, drawn: drawn, fill: fill)
                    .frame(width: 150, height: 150)
                    .scaleEffect(markScale)
                    .shadow(color: Brand.moss.opacity(fill * 0.5), radius: 18)
                LizardWordmark(size: 44)
                    .foregroundStyle(Brand.sand)
                    .opacity(wordmark ? 1 : 0)
                    .offset(y: wordmark ? 0 : 14)
                Text("Everything on your Mac, one keystroke away.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Brand.sand.opacity(0.6))
                    .opacity(tagline ? 1 : 0)
                    .offset(y: tagline ? 0 : 10)
            }
        }
        .frame(width: 520, height: 360)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .contentShape(Rectangle())
        .onTapGesture(perform: finish)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress { _ in finish(); return .handled }
        .task {
            focused = true
            if preview || reduceMotion { showFinalFrame() } else { await play() }
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 500 : (firstLaunch ? 700 : 250)))
            finish()
        }
    }

    private func showFinalFrame() {
        drawn = 1
        fill = 1
        markScale = 1
        tailCurl = 1
        wordmark = true
        tagline = true
    }

    private func pause(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(firstLaunch ? ms : ms / 2)) }

    private func play() async {
        withAnimation(.easeInOut(duration: firstLaunch ? 0.7 : 0.35)) { drawn = 1 }
        await pause(600)
        withAnimation(.easeOut(duration: 0.3)) { fill = 1 }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) {
            markScale = 1
            tailCurl = 1
        }
        await pause(380)
        for direction in [1.0, -1.0] {
            withAnimation(.easeInOut(duration: 0.14)) { sway = direction; tailCurl = 0.7 }
            await pause(140)
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { sway = 0; tailCurl = 1 }
        await pause(200)
        withAnimation(.easeIn(duration: 0.07)) { eyes = 0.05 }
        try? await Task.sleep(for: .milliseconds(100))
        withAnimation(.easeOut(duration: 0.1)) { eyes = 1 }
        withAnimation(.spring(response: 0.18, dampingFraction: 0.6)) { tongue = 1 }
        try? await Task.sleep(for: .milliseconds(200))
        withAnimation(.easeIn(duration: 0.12)) { tongue = 0 }
        withAnimation(.smooth(duration: 0.5)) { wordmark = true }
        await pause(160)
        withAnimation(.smooth(duration: 0.5)) { tagline = true }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinish()
    }
}

#Preview("Splash") {
    SplashView(firstLaunch: true) {}
}

#Preview("Splash final frame") {
    SplashView(firstLaunch: true, preview: true) {}
}
