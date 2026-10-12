import Foundation
import FoundationModels
import Synchronization

/// Apple's on-device model (Foundation Models, macOS 26): nothing to download, instant, and
/// **guided generation** (`@Generable`) so answers always match a Swift type.
///
/// ~3B parameters and a ~4k-token context: use it for short structured jobs (intent triage,
/// work-log tags, one-line summaries) and fall back to MLX when it's unavailable (`isAvailable`).
public enum AppleIntelligence {
    /// On when this Mac has Apple Intelligence enabled and the model is ready.
    public static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Why it's off, in plain words (nil when available).
    public static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "This Mac doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): "Apple Intelligence is turned off in System Settings."
        case .unavailable(.modelNotReady): "Apple Intelligence is still downloading its model."
        case .unavailable: "Apple Intelligence isn't available right now."
        }
    }

    /// What setup should offer when Apple Intelligence can't be used.
    public enum Status: Sendable, Equatable {
        case ready
        /// Supported but switched off: a click in System Settings fixes it.
        case turnedOff
        /// Switched on; macOS is still downloading the model (Lizard switches over when it's done).
        case downloading
        /// This Mac (or its region/language) can't run it: use the local model or cloud instead.
        case unsupported
    }

    public static var status: Status {
        switch SystemLanguageModel.default.availability {
        case .available: .ready
        case .unavailable(.appleIntelligenceNotEnabled): .turnedOff
        case .unavailable(.modelNotReady): .downloading
        case .unavailable: .unsupported
        }
    }

    // MARK: Translation

    /// Translates with Apple's on-device model (used when Apple Translation's language pack isn't
    /// downloaded). nil when unavailable or the model can't do that language.
    public static func translate(_ text: String, to language: String) async -> String? {
        guard isAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
            You are a translator. Translate the user's text into \(language). Keep the meaning, tone and \
            formatting. Reply with the translation only: no quotes, notes or explanations.
            """)
        do {
            let answer = try await session.respond(to: text, options: GenerationOptions(temperature: 0.2)).content
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            lastError = "\(error)"
            return nil
        }
    }

    // MARK: Dictation polish

    /// Tidies dictated text: punctuation, capitals, obvious recognition slips. Never rewrites the
    /// meaning or adds anything. nil when unavailable (callers keep the raw text).
    public static func polishDictation(_ text: String) async -> String? {
        guard isAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
            You clean up dictated text. Fix punctuation, capitalization and obvious speech-recognition \
            mistakes, and remove repeated words and false starts. Keep the person's words, meaning, tone and \
            language; never add, answer or explain anything. Reply with the cleaned text only.
            """)
        do {
            let answer = try await session.respond(to: text, options: GenerationOptions(temperature: 0)).content
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            // A reply much longer than what was said means the model answered instead of cleaning.
            guard !trimmed.isEmpty, trimmed.count < text.count * 2 + 20 else { return nil }
            return trimmed
        } catch {
            return nil
        }
    }

    // MARK: Launcher intent triage

    @Generable
    public enum LauncherIntent: String, Sendable {
        case openApp, quicklink, note, workLog, clipboard, ask, devTool
    }

    @Generable(description: "What the person typed into a Mac launcher wants to do")
    public struct Triage: Sendable {
        @Guide(description: "The most likely intent")
        public var intent: LauncherIntent
        @Guide(description: "true only when the text reads like a question or instruction for an AI, not a name to search")
        public var looksLikeQuestion: Bool
    }

    /// Classifies free text typed into the launcher (nil when unavailable or on failure).
    public static func triage(_ text: String) async -> Triage? {
        guard isAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
            You classify short text typed into a Mac launcher. Names of apps or files are openApp. \
            "search github for x" style requests are quicklink. Jotting a thought is note; logging finished work is workLog. \
            Questions, explanations, rewrites and summaries are ask. JSON, JWT, base64, ports are devTool.
            """)
        do {
            return try await session.respond(to: text, generating: Triage.self, options: GenerationOptions(temperature: 0)).content
        } catch {
            lastError = "\(error)"
            return nil
        }
    }

    // MARK: Work log tags

    @Generable
    public struct WorkTags: Sendable {
        @Guide(description: "1 to 3 short lowercase tags such as bugfix, review, meeting, feature, docs, infra", .maximumCount(3))
        public var tags: [String]
    }

    public static func workTags(for entry: String) async -> [String] {
        guard isAvailable else { return [] }
        let session = LanguageModelSession(instructions: "You tag a software engineer's work-log entries.")
        let result = try? await session.respond(to: entry, generating: WorkTags.self, options: GenerationOptions(temperature: 0)).content
        return result?.tags.map { $0.lowercased().replacingOccurrences(of: " ", with: "-") } ?? []
    }

    // MARK: Screenshot labels

    @Generable
    public enum ScreenshotKind: String, Sendable {
        case code, terminal, error, design, document, chat, web, receipt, meeting, photo, other
    }

    @Generable(description: "How to file a screenshot")
    public struct ScreenshotLabel: Sendable {
        @Guide(description: "What the screenshot mainly shows")
        public var kind: ScreenshotKind
        @Guide(description: "A short descriptive title, 2 to 6 words, no date, no file extension")
        public var title: String
        @Guide(description: "Up to 3 short lowercase tags (project, topic, tool)", .maximumCount(3))
        public var tags: [String]
    }

    /// Files a screenshot from its recognized text and the app it came from.
    public static func labelScreenshot(text: String, app: String?) async -> ScreenshotLabel? {
        guard isAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
            You file screenshots for a software engineer. Pick what the screenshot mainly shows: code (source code in an editor), \
            terminal (command line), error (an error message or stack trace), design (UI mockups, design tools), document, chat \
            (messaging), web (a web page), receipt (invoices, purchases), meeting (video calls, slides), photo (little or no text), other.
            """)
        let prompt = "App: \(app ?? "unknown")\nText in the screenshot:\n\(text.prefix(2_500))"
        return try? await session.respond(to: prompt, generating: ScreenshotLabel.self, options: GenerationOptions(temperature: 0)).content
    }

    // MARK: Note organization

    @Generable(description: "Where a note belongs")
    public struct NoteOrganization: Sendable {
        @Guide(description: "The best folder for the note: one of the existing folders when one fits, otherwise a short new folder name (1-2 words, Title Case)")
        public var folder: String
        @Guide(description: "1 to 4 short lowercase tags (topic, project, tool, kind)", .maximumCount(4))
        public var tags: [String]
    }

    /// Suggests a folder (preferring existing ones) and tags for a note.
    public static func organizeNote(title: String, text: String, existingFolders: [String], existingTags: [String]) async -> NoteOrganization? {
        guard isAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
            You organize a software engineer's Markdown notes. Prefer an existing folder and existing tags when they fit; \
            invent new ones only when nothing fits. Keep names short.
            """)
        let prompt = """
            Existing folders: \(existingFolders.isEmpty ? "(none)" : existingFolders.joined(separator: ", "))
            Existing tags: \(existingTags.isEmpty ? "(none)" : existingTags.prefix(60).joined(separator: ", "))
            Note title: \(title)
            Note:
            \(text.prefix(2_500))
            """
        return try? await session.respond(to: prompt, generating: NoteOrganization.self, options: GenerationOptions(temperature: 0)).content
    }

    /// The last failure, for diagnostics (`lizardcli apple-ai`). Lock-protected: generation
    /// runs on arbitrary executors, so a plain static var would be a data race.
    public static var lastError: String? {
        get { lastErrorStorage.withLock { $0 } }
        set { lastErrorStorage.withLock { $0 = newValue } }
    }

    private static let lastErrorStorage = Mutex<String?>(nil)

    /// Loads the model ahead of time so the first answer is instant (call when the panel opens).
    public static func prewarm() {
        guard isAvailable else { return }
        LanguageModelSession().prewarm()
    }
}

/// Apple's on-device model as a plain streaming chat provider, so chat and jobs can treat it
/// like any other `AIProvider`. Tools are not supported; history is folded into the prompt.
public struct AppleFMProvider: AIProvider {
    public init() {}

    public var id: String { "apple" }
    public var displayName: String { "Apple Intelligence" }
    public var contextTokens: Int { 3_000 }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard AppleIntelligence.isAvailable else {
                    continuation.finish(throwing: AIProviderError.unavailable(AppleIntelligence.unavailableReason ?? "Apple Intelligence is unavailable."))
                    return
                }
                let session = LanguageModelSession(instructions: request.system)
                let prompt = Self.prompt(from: request.messages)
                do {
                    var sent = ""
                    for try await snapshot in session.streamResponse(to: prompt, options: GenerationOptions(maximumResponseTokens: min(request.maxTokens, 2_000))) {
                        let text = snapshot.content
                        if text.hasPrefix(sent) {
                            let delta = String(text.dropFirst(sent.count))
                            if !delta.isEmpty { continuation.yield(.textDelta(delta)) }
                        } else {
                            continuation.yield(.textDelta(text))
                        }
                        sent = text
                    }
                    continuation.yield(.completed(.endTurn, providerContent: nil))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.plain(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Apple's errors in words people understand (chat falls through to the next AI on any error).
    static func plain(_ error: Error) -> Error {
        guard let generation = error as? LanguageModelSession.GenerationError else { return error }
        switch generation {
        case .guardrailViolation:
            return AIProviderError.unavailable("Apple Intelligence's safety filter blocked this; it sometimes misfires on short or unusual text. Try rephrasing, or add another AI in Settings › AI.")
        case .exceededContextWindowSize:
            return AIProviderError.unavailable("That's too long for Apple Intelligence. Start a new chat, or use a local model or cloud AI.")
        case .unsupportedLanguageOrLocale:
            return AIProviderError.unavailable("Apple Intelligence doesn't support this language yet.")
        default:
            return error
        }
    }

    /// Earlier turns as a compact transcript, newest last; keeps within the small context.
    static func prompt(from messages: [ChatMessage]) -> String {
        guard let last = messages.last else { return "" }
        let history = messages.dropLast().suffix(6).map { message in
            "\(message.role == .user ? "User" : "Assistant"): \(message.text.prefix(1_200))"
        }
        if history.isEmpty { return last.text }
        return "Conversation so far:\n" + history.joined(separator: "\n") + "\n\nUser: " + last.text
    }
}
