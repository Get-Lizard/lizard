import AIEngine
import AppKit
import Carbon.HIToolbox
import Clipboard
import Observation
import SwiftUI

/// Voice typing. Hold the shortcut (⌃⌥V by default) and talk, release to type; or tap it to keep
/// listening hands-free and tap again (or pause) to finish. Esc cancels. The text goes where you
/// are: Lizard's own field (search, chat, notes…) when Lizard is in front, otherwise the app you're in.
@Observable
@MainActor
final class VoiceTypist {
    enum Phase: Equatable { case idle, preparing(Double), listening, finishing, failed(String) }
    enum Target: Equatable { case launcher, app }

    private(set) var phase: Phase = .idle
    private(set) var transcript = DictationText()
    /// Recent input levels for the waveform, newest last.
    private(set) var levels: [Float] = Array(repeating: 0, count: 28)
    private(set) var target: Target = .app
    /// Tapped rather than held: keeps listening until tapped again or a pause.
    private(set) var handsFree = false

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var engine: SpeechEngine?
    @ObservationIgnored private var pressedAt = Date.distantPast
    @ObservationIgnored private var targetApp: NSRunningApplication?
    @ObservationIgnored private var lastVoice = Date.now
    @ObservationIgnored private var silenceWatch: Task<Void, Never>?
    @ObservationIgnored private var escMonitors: [Any] = []
    @ObservationIgnored private var pill: NSPanel?

    static let polishKey = "Lizard.VoicePolish"
    /// Tidy longer dictation with Apple Intelligence before typing it into other apps.
    static var polish: Bool {
        get { UserDefaults.standard.object(forKey: polishKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: polishKey) }
    }

    init(app: AppModel) {
        self.app = app
    }

    var isActive: Bool {
        switch phase {
        case .preparing, .listening, .finishing: true
        default: false
        }
    }

    // MARK: Shortcut (hold to talk, tap for hands-free)

    func shortcutDown() {
        if isActive {
            if handsFree { Task { await finish() } }
            return
        }
        pressedAt = .now
        handsFree = false
        start()
    }

    func shortcutUp() {
        guard isActive, !handsFree else { return }
        if Date.now.timeIntervalSince(pressedAt) < 0.35 {
            handsFree = true  // a tap: keep listening
            watchForSilence()
        } else {
            Task { await finish() }
        }
    }

    /// Mic buttons in Lizard: toggle hands-free dictation into Lizard's field.
    func toggleFromButton() {
        if isActive {
            Task { await finish() }
        } else {
            handsFree = true
            start()
            watchForSilence()
        }
    }

    // MARK: Session

    private func start() {
        guard let app else { return }
        UserDefaults.standard.set(true, forKey: "Lizard.VoiceCoachDone")  // found it: no more coaching
        target = app.isLauncherVisible && app.isLauncherKey ? .launcher : .app
        targetApp = target == .app ? NSWorkspace.shared.frontmostApplication : nil
        transcript = DictationText()
        levels = Array(repeating: 0, count: levels.count)
        lastVoice = .now
        phase = .listening
        showPill()
        installEscape()

        let engine = SpeechEngine()
        self.engine = engine
        engine.onText = { [weak self] text, isFinal in
            self?.transcript.update(text, isFinal: isFinal)
            self?.lastVoice = .now
        }
        engine.onLevel = { [weak self] level in
            guard let self else { return }
            levels.removeFirst()
            levels.append(level)
            if level > 0.35 { lastVoice = .now }
        }
        engine.onPreparing = { [weak self] fraction in self?.phase = .preparing(fraction) }
        Task {
            do {
                try await engine.start()
                if case .preparing = phase { phase = .listening }
            } catch {
                await fail(error.localizedDescription)
            }
        }
    }

    /// In hands-free mode, a pause after speaking finishes on its own.
    private func watchForSilence() {
        silenceWatch?.cancel()
        silenceWatch = Task {
            while !Task.isCancelled, isActive {
                try? await Task.sleep(for: .milliseconds(250))
                if phase == .listening, !transcript.current.isEmpty, Date.now.timeIntervalSince(lastVoice) > 2.2 {
                    await finish()
                    return
                }
            }
        }
    }

    func finish() async {
        guard phase == .listening || isPreparing else { return }
        phase = .finishing
        silenceWatch?.cancel()
        await engine?.finish()
        engine = nil
        removeEscape()
        let said = transcript.current
        guard !said.trimmingCharacters(in: .whitespaces).isEmpty else { return close() }
        switch target {
        case .launcher:
            close()
            app?.insertIntoLauncher { before, isSearch in
                let text = isSearch ? DictationText.forSearch(said) : DictationText.clean(said)
                return DictationText.insertion(text, after: before)
            }
        case .app:
            var text = DictationText.clean(said)
            if Self.polish, text.split(separator: " ").count >= 6 {
                text = await polished(text)
            }
            close()
            type(text)
        }
    }

    func cancel() {
        silenceWatch?.cancel()
        removeEscape()
        let engine = engine
        self.engine = nil
        Task { await engine?.cancel() }
        close()
    }

    private var isPreparing: Bool { if case .preparing = phase { true } else { false } }

    private func polished(_ text: String) async -> String {
        // Never keep someone waiting long for a nicety.
        await withTaskGroup(of: String?.self) { group in
            group.addTask { await AppleIntelligence.polishDictation(text) }
            group.addTask {
                try? await Task.sleep(for: .seconds(2.5))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? text
        }
    }

    private func fail(_ message: String) async {
        await engine?.cancel()
        engine = nil
        removeEscape()
        phase = .failed(message)
        try? await Task.sleep(for: .seconds(3.5))
        if case .failed = phase { close() }
    }

    private func close() {
        phase = .idle
        handsFree = false
        pill?.orderOut(nil)
    }

    /// Pastes into the app that was in front, then puts the clipboard back.
    private func type(_ text: String) {
        let saved = NSPasteboard.general.string(forType: .string)
        AutoPaste.copy(text: text)
        app?.markOwnPasteboardWrite()
        guard AutoPaste.paste(into: targetApp) else {
            app?.showHUD("Copied. Allow Lizard under Accessibility to type it for you.")
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            if let saved {
                AutoPaste.copy(text: saved)
                app?.markOwnPasteboardWrite()
            }
        }
    }

    // MARK: Esc

    private func installEscape() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard Int(event.keyCode) == kVK_Escape else { return }
            MainActor.assumeIsolated { self?.cancel() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) { escMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            if Int(event.keyCode) == kVK_Escape {
                handler(event)
                return nil
            }
            return event
        }) { escMonitors.append(local) }
    }

    private func removeEscape() {
        escMonitors.forEach(NSEvent.removeMonitor)
        escMonitors = []
    }

    // MARK: Pill

    private func showPill() {
        if pill == nil {
            let panel = PillPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 64), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .statusBar
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.contentView = NSHostingView(rootView: VoicePill(voice: self))
            pill = panel
        }
        guard let pill else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            pill.setFrameOrigin(NSPoint(x: frame.midX - pill.frame.width / 2, y: frame.minY + 90))
        }
        pill.orderFrontRegardless()
    }
}

/// Floats above everything without taking focus from the app you're typing into.
private final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The listening pill: gecko, live waveform, your words as they form, and how to finish.
struct VoicePill: View {
    let voice: VoiceTypist

    var body: some View {
        HStack(spacing: 12) {
            LizardMarkView(size: 26, thinking: voice.phase == .finishing)
            content
            Spacer(minLength: 0)
            Text(hint).font(.caption2.weight(.medium)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 16)
        .frame(width: 460, height: 56)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Brand.ink.opacity(0.55), in: Capsule())
        .overlay(Capsule().strokeBorder(Brand.moss.opacity(0.55), lineWidth: 1))
        .shadow(color: Brand.moss.opacity(0.25), radius: 18)
        .padding(4)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        switch voice.phase {
        case .preparing(let fraction):
            VStack(alignment: .leading, spacing: 4) {
                Text("Getting voice typing ready (one time)").font(.callout.weight(.medium))
                ProgressView(value: fraction).tint(Brand.moss).frame(width: 220)
            }
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.orange).lineLimit(2)
        default:
            let text = voice.transcript.current
            if text.isEmpty {
                Waveform(levels: voice.levels)
            } else {
                HStack(spacing: 10) {
                    Waveform(levels: Array(voice.levels.suffix(10)))
                    Text(text)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .contentTransition(.opacity)
                }
            }
        }
    }

    private var hint: String {
        switch voice.phase {
        case .finishing: voice.target == .app ? "Typing…" : "Done"
        case .listening: voice.handsFree ? "pause or \(voiceShortcutText) to finish · esc" : "release to type · esc"
        default: ""
        }
    }
}

private struct Waveform: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Brand.gradient)
                    .frame(width: 3, height: 4 + CGFloat(level) * 26)
            }
        }
        .frame(height: 30)
        .animation(.easeOut(duration: 0.08), value: levels)
    }
}
