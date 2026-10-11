import AIEngine
import NaturalLanguage
import Search
import SwiftUI
import Translation

/// "good morning in spanish" right in the search: the text and its detected language, then the
/// translation, made on device by Apple Translation as you type. ↩ copies, ⌘K › Paste.
struct TranslationCard: View {
    let request: TranslationQuery
    let selected: Bool
    let onResult: (String?) -> Void

    @AppStorage("Lizard.TranslateTarget") private var preferredTarget = Locale.current.language.languageCode?.identifier == "en" ? "pt" : "en"
    @State private var result: String?
    @State private var detected: String?
    @State private var failed = false
    @State private var engine = "Apple Translation"
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        HStack(spacing: 0) {
            side(request.text, caption: detected.map(name) ?? "Detecting…")
            VStack(spacing: 10) {
                Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1)
                Image(systemName: "arrow.right").font(.system(size: 20, weight: .semibold)).foregroundStyle(Brand.moss)
                Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1)
            }
            .frame(width: 44)
            Group {
                if let result {
                    side(result, caption: name(target), emphasized: true)
                } else if failed {
                    VStack(spacing: 8) {
                        Text("\(name(target)) isn't downloaded yet").font(.callout.weight(.medium))
                        Text("Press ↩ to open Translate and download it (free, on device).")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 16).frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: 10) {
                        LizardThinkingIndicator(isThinking: true).frame(width: 26, height: 26)
                        Text(name(target)).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.bottom, 14)  // room for the engine label
        .frame(minHeight: 140)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(selected ? Brand.moss.opacity(0.10) : Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected ? Brand.moss.opacity(0.55) : Color.primary.opacity(0.08)))
        .overlay(alignment: .bottomTrailing) {
            Text("On device · \(engine)").font(.caption2).foregroundStyle(.tertiary).padding(8)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .translationTask(configuration) { session in
            let source = request.text
            // Used only inside this task; Translation isn't annotated for Swift 6 yet.
            nonisolated(unsafe) let session = session
            do {
                let response = try await session.translate(source)
                withAnimation(.smooth) { result = response.targetText }
                failed = false
                onResult(response.targetText)
            } catch {
                failed = true
                onResult(nil)
            }
        }
        .task(id: request) {
            result = nil
            failed = false
            onResult(nil)
            try? await Task.sleep(for: .milliseconds(220))  // typing still going
            guard !Task.isCancelled else { return }
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(request.text)
            detected = recognizer.dominantLanguage?.rawValue
            let source = detected.map { Locale.Language(identifier: $0) }
            let destination = Locale.Language(identifier: target)
            // Only use Apple Translation when the pair is already installed: otherwise macOS would
            // open its download sheet while you're typing. Apple Intelligence covers that case.
            let installed = await Task.detached {
                guard let source else { return false }
                return await LanguageAvailability().status(from: source, to: destination) == .installed
            }.value
            guard !Task.isCancelled else { return }
            if installed {
                engine = "Apple Translation"
                configuration = TranslationSession.Configuration(source: source, target: destination)
            } else if let translated = await AppleIntelligence.translate(request.text, to: Locale(identifier: "en").localizedString(forIdentifier: target) ?? target) {
                guard !Task.isCancelled else { return }
                engine = "Apple Intelligence"
                withAnimation(.smooth) { result = translated }
                onResult(translated)
            } else {
                failed = true
            }
        }
    }

    /// The named language, else your usual one; never the language you typed in.
    private var target: String {
        if let wanted = request.target { return wanted }
        if let detected, Locale.Language(identifier: detected).languageCode == Locale.Language(identifier: preferredTarget).languageCode {
            return detected.hasPrefix("en") ? (Locale.preferredLanguages.lazy.compactMap { Locale.Language(identifier: $0).languageCode?.identifier }.first { $0 != "en" } ?? "es") : "en"
        }
        return preferredTarget
    }

    private func side(_ text: String, caption: String, emphasized: Bool = false) -> some View {
        VStack(spacing: 12) {
            Text(text)
                .font(.system(size: text.count > 40 ? 18 : 26, weight: .semibold, design: .rounded))
                .foregroundStyle(emphasized ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(.primary))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.6)
                .textSelection(.enabled)
            Text(caption)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(16)
        .frame(maxWidth: .infinity)
    }

    private func name(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier)?.capitalized ?? identifier
    }
}
