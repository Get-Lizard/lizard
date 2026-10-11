import AIEngine
import NaturalLanguage
import SwiftUI
import Translation

/// Translation in the launcher, on device. Apple Translation when the language pair is installed;
/// until then Apple Intelligence translates right away, and the pair can download in the
/// background (only when asked, so typing never opens the download sheet). Google is an explicit
/// online fallback.
struct TranslateView: View {
    @Environment(AppModel.self) private var app
    @State var text: String
    @AppStorage("Lizard.TranslateTarget") private var target = Locale.current.language.languageCode?.identifier == "en" ? "pt" : "en"
    @State private var result = ""
    @State private var detected: String?
    @State private var error: String?
    @State private var configuration: TranslationSession.Configuration?
    /// The pair isn't installed: offer the download (it continues in the background).
    @State private var missingPair: (source: Locale.Language, target: Locale.Language)?
    @State private var preparing = false
    @State private var engine = "Apple Translation"
    @State private var languages: [Locale.Language] = []
    @FocusState private var focused: Bool

    init(text: String) {
        _text = State(initialValue: text)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { app.launcher.pop() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Image(systemName: "character.bubble").foregroundStyle(Brand.moss)
                Text("Translate").font(.headline)
                Spacer()
                if let detected { Text(name(detected)).font(.caption).foregroundStyle(.secondary) }
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                Picker("", selection: $target) {
                    ForEach(languages, id: \.minimalIdentifier) { language in
                        Text(name(language.minimalIdentifier)).tag(language.minimalIdentifier)
                    }
                }
                .labelsHidden()
                .frame(width: 170)
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            Divider()
            HStack(spacing: 0) {
                TextEditor(text: $text)
                    .font(.system(size: 16))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(12)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let pair = missingPair, error == nil {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.down.circle").foregroundStyle(Brand.moss)
                                Text("Translated by Apple Intelligence. Download \(name(pair.target.minimalIdentifier)) for faster, offline translation; it keeps downloading in the background.")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                Button(preparing ? "Downloading…" : "Download") { download(pair) }.controlSize(.small).disabled(preparing)
                            }
                            .padding(10)
                            .background(Brand.moss.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                            Button("Translate online with Google") { Task { await translateOnline() } }.buttonStyle(.link)
                        } else {
                            Text(result.isEmpty ? " " : result).font(.system(size: 16)).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
                .background(Brand.moss.opacity(0.05))
            }
            ActionBar(hints: [("Copy", "⌘↩"), ("Paste", "⌥↩"), ("Swap", "⌘S")]) {
                Text("On-device · \(engine)").font(.caption).foregroundStyle(.secondary)
                Button("") { app.copyText(result) }.keyboardShortcut(.return, modifiers: .command).opacity(0).disabled(result.isEmpty)
                Button("") { app.pasteText(result) }.keyboardShortcut(.return, modifiers: .option).opacity(0).disabled(result.isEmpty)
                Button("") { swap() }.keyboardShortcut("s", modifiers: .command).opacity(0)
            }
        }
        .translationTask(configuration) { session in
            let source = text
            // The session is only used here, within this task; Translation isn't annotated for Swift 6 yet.
            nonisolated(unsafe) let session = session
            if preparing {
                // Shows the system download sheet; "Done" lets it carry on in the background.
                try? await session.prepareTranslation()
                preparing = false
                return
            }
            do {
                let response = try await session.translate(source)
                if source == text { result = response.targetText }
                error = nil
            } catch {
                self.error = "This language pair isn't available on this Mac yet. macOS can download it (System Settings › General › Language & Region › Translation Languages)."
            }
        }
        .task(id: "\(text)|\(target)") {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await translate()
        }
        .task {
            let supported = await Task.detached { await LanguageAvailability().supportedLanguages }.value
            languages = supported.sorted { name($0.minimalIdentifier) < name($1.minimalIdentifier) }
            if text.isEmpty, let selection = app.selectedTextInPreviousApp() { text = selection }
            focused = true
        }
    }

    private func translate() async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            result = ""
            return
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        let source = recognizer.dominantLanguage?.rawValue
        detected = source
        error = nil
        let sourceLanguage = source.map { Locale.Language(identifier: $0) }
        let targetLanguage = Locale.Language(identifier: target)
        // Installed pair: Apple Translation. Otherwise Apple Intelligence now, download optional.
        let installed = await Task.detached {
            guard let sourceLanguage else { return false }
            return await LanguageAvailability().status(from: sourceLanguage, to: targetLanguage) == .installed
        }.value
        guard !Task.isCancelled else { return }
        if installed {
            engine = "Apple Translation"
            missingPair = nil
            if configuration?.source == sourceLanguage, configuration?.target == targetLanguage {
                configuration?.invalidate()
            } else {
                configuration = TranslationSession.Configuration(source: sourceLanguage, target: targetLanguage)
            }
            return
        }
        if let sourceLanguage { missingPair = (sourceLanguage, targetLanguage) }
        if let translated = await AppleIntelligence.translate(trimmed, to: Locale(identifier: "en").localizedString(forIdentifier: target) ?? target) {
            guard !Task.isCancelled, trimmed == text.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            engine = "Apple Intelligence"
            result = translated
        } else {
            // No Apple Intelligence either: the download is the way (or Google, on request).
            missingPair = nil
            error = "\(name(target)) isn't downloaded on this Mac yet, and Apple Intelligence isn't available."
            if let sourceLanguage { download((sourceLanguage, targetLanguage)) }
        }
    }

    /// Asks macOS to download the pair; its sheet's "Done" leaves it downloading in the background.
    private func download(_ pair: (source: Locale.Language, target: Locale.Language)) {
        preparing = true
        if configuration?.source == pair.source, configuration?.target == pair.target {
            configuration?.invalidate()  // same pair: run the task again
        } else {
            configuration = TranslationSession.Configuration(source: pair.source, target: pair.target)
        }
    }

    private func swap() {
        guard !result.isEmpty else { return }
        let previous = detected ?? "en"
        text = result
        target = Locale.Language(identifier: previous).minimalIdentifier
    }

    /// Google's free web endpoint — only when the user asks (the text leaves the Mac).
    private func translateOnline() async {
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        components.queryItems = [.init(name: "client", value: "gtx"), .init(name: "sl", value: "auto"), .init(name: "tl", value: target), .init(name: "dt", value: "t"), .init(name: "q", value: text)]
        guard let url = components.url, let (data, _) = try? await URLSession.shared.data(from: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [Any], let chunks = json.first as? [[Any]]
        else { return }
        result = chunks.compactMap { $0.first as? String }.joined()
        error = nil
    }

    private func name(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier)?.capitalized ?? identifier
    }
}
