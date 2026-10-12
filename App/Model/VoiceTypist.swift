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
    /// One engine for the app's lifetime: it keeps the next session prepared, so starting is instant.
    @ObservationIgnored private let engine = SpeechEngine()
    /// What this session has typed so far (spacing/capitals for the next phrase).
    @ObservationIgnored private var committed = ""
    /// Live typing: phrases go in as they're recognized. Off when tidying with Apple Intelligence,
    /// which needs the whole text at the end.
    @ObservationIgnored private var live = true
    @ObservationIgnored private var pressedAt = Date.distantPast
    @ObservationIgnored private var targetApp: NSRunningApplication?
    @ObservationIgnored private var lastVoice = Date.now
    @ObservationIgnored private var silenceWatch: Task<Void, Never>?
    @ObservationIgnored private var escMonitors: [Any] = []
    @ObservationIgnored private var pill: NSPanel?

    static let polishKey = "Lizard.VoicePolish2"
    /// Tidy dictation with Apple Intelligence (types when you finish instead of as you speak).
    static var polish: Bool {
        get { UserDefaults.standard.object(forKey: polishKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: polishKey) }
    }

    init(app: AppModel) {
        self.app = app
        engine.onText = { [weak self] text, isFinal in self?.heard(text, isFinal: isFinal) }
        engine.onLevel = { [weak self] level in self?.level(level) }
        engine.onPreparing = { [weak self] fraction in self?.phase = .preparing(fraction) }
        Task {
            try? await Task.sleep(for: .seconds(4))
            engine.prewarm()
        }
    }

    private func heard(_ text: String, isFinal: Bool) {
        transcript.update(text, isFinal: isFinal)
        lastVoice = .now
        guard isFinal, live else { return }
        emit(text)
    }

    private func level(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
        if level > 0.35 { lastVoice = .now }
    }

    /// Types one recognized phrase right away.
    private func emit(_ phrase: String) {
        switch target {
        case .launcher:
            app?.insertIntoLauncher { before, isSearch in
                let text = isSearch ? DictationText.forSearch(phrase) : DictationText.clean(phrase)
                return DictationText.insertion(text, after: before)
            }
        case .app:
            let text = DictationText.insertion(DictationText.clean(phrase), after: committed)
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            committed += text
            KeyTyper.type(text)
        }
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
        committed = ""
        live = !Self.polish || target == .launcher
        levels = Array(repeating: 0, count: levels.count)
        lastVoice = .now
        phase = .listening
        showPill()
        installEscape()

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
        await engine.finish()  // the last phrases arrive (and are typed) before this returns
        removeEscape()
        let said = transcript.current
        guard !live, !said.trimmingCharacters(in: .whitespaces).isEmpty else { return close() }
        switch target {
        case .launcher:
            close()
            app?.insertIntoLauncher { before, isSearch in
                let text = isSearch ? DictationText.forSearch(said) : DictationText.clean(said)
                return DictationText.insertion(text, after: before)
            }
        case .app:
            var text = DictationText.clean(said)
            if text.split(separator: " ").count >= 4 { text = await polished(text) }
            close()
            KeyTyper.type(text)
        }
    }

    func cancel() {
        silenceWatch?.cancel()
        removeEscape()
        Task { await engine.cancel() }
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
        await engine.cancel()
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
        case .finishing: "Finishing…"
        case .listening: voice.handsFree ? "typing as you talk · pause to stop" : "typing as you talk · release to stop"
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

/// Types text into whatever app has focus, as keystrokes (no clipboard involved), so phrases
/// can go in live while you're still talking. Needs Accessibility, like auto-paste.
enum KeyTyper {
    static func type(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            // Events carry at most 20 UTF-16 units; don't split a surrogate pair.
            var end = min(index + 20, units.count)
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            var chunk = Array(units[index..<end])
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
                event?.flags = []
                event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                event?.post(tap: .cghidEventTap)
            }
            index = end
        }
    }
}
