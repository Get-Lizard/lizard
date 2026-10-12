import AIEngine
import Foundation
import LizardCore
import Observation

/// One AI conversation. Like Cocoon's ProjectSession, it keeps two layers: `items` (what the
/// UI shows) and `messages` (the history sent to the model), saved together as JSON.
@Observable
@MainActor
final class ChatSession: Identifiable {
    struct Item: Identifiable, Codable, Equatable {
        enum Kind: String, Codable { case user, assistant, status, error }
        var id = UUID()
        var kind: Kind
        var text: String
        var provider: String?
    }

    struct Saved: Codable {
        var id: UUID
        var title: String
        var created: Date
        var items: [Item]
        var messages: [ChatMessage]
    }

    let id: UUID
    let created: Date
    var title: String
    private(set) var items: [Item] = []
    private(set) var messages: [ChatMessage] = []
    private(set) var isStreaming = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let ai: AIService

    static let system = """
        You are Lizard, a fast assistant inside a Mac launcher. Answer in plain, conversational text, \
        concisely and directly; short Markdown (bold, lists) is fine. Never reply with HTML, a web page or \
        code unless the user asks for code; when they do, put it in a fenced Markdown block with its \
        language (```swift, ```bash…). You can't browse the web or see live data such as today's weather, \
        news, prices or scores: say so in one sentence and suggest where to check, instead of guessing.
        """

    init(ai: AIService, saved: Saved? = nil) {
        self.ai = ai
        id = saved?.id ?? UUID()
        created = saved?.created ?? .now
        title = saved?.title ?? "New chat"
        items = saved?.items ?? []
        messages = saved?.messages ?? []
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }
        if messages.isEmpty { title = String(trimmed.prefix(60)) }
        items.append(Item(kind: .user, text: trimmed))
        messages.append(.user(trimmed))
        stream()
    }

    /// Starts the chat from a finished one-shot job, so the user can follow up.
    func seed(user: String, assistant: String) {
        title = String(user.prefix(60))
        items = [Item(kind: .user, text: user), Item(kind: .assistant, text: assistant)]
        messages = [.user(user), ChatMessage(role: .assistant, text: assistant)]
    }

    func cancel() {
        task?.cancel()
    }

    /// Streams the reply from the first provider that answers; a failure before any text moves
    /// on to the next provider (Cocoon's Agent fallback, minus tools).
    private func stream() {
        let providers = ai.providers()
        guard !providers.isEmpty else {
            items.append(Item(kind: .error, text: "No AI is set up yet. Open Settings › AI to turn on Apple Intelligence, download a local model, or connect a cloud provider."))
            return
        }
        isStreaming = true
        let question = messages.last?.text ?? ""
        let request = ChatRequest(system: Self.system, messages: Array(messages.suffix(20)), maxTokens: 2_000, thinking: false)
        task = Task {
            defer {
                isStreaming = false
                save()
            }
            var lastError: Error?
            for provider in providers {
                let index = items.count
                items.append(Item(kind: .assistant, text: "", provider: provider.displayName))
                var text = ""
                do {
                    for try await event in provider.stream(request) {
                        switch event {
                        case .textDelta(let delta):
                            text += delta
                            items[index].text = ReplyFormatting.tidy(AIJobRunner.cleaned(text), question: question)
                        case .status(let status):
                            if text.isEmpty { items[index].text = "_\(status)_" }
                        default:
                            break
                        }
                    }
                    let final = ReplyFormatting.tidy(AIJobRunner.cleaned(text), question: question)
                    items[index].text = final
                    messages.append(ChatMessage(role: .assistant, text: final))
                    return
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        let partial = AIJobRunner.cleaned(text)
                        if partial.isEmpty { items.remove(at: index) } else {
                            items[index].text = partial
                            messages.append(ChatMessage(role: .assistant, text: partial))
                        }
                        return
                    }
                    lastError = error
                    if text.isEmpty { items.remove(at: index) } else {
                        items[index].text = AIJobRunner.cleaned(text)
                        messages.append(ChatMessage(role: .assistant, text: items[index].text))
                        return
                    }
                }
            }
            items.append(Item(kind: .error, text: lastError?.localizedDescription ?? "The AI didn't answer."))
        }
    }

    var saved: Saved { Saved(id: id, title: title, created: created, items: items, messages: messages) }

    func save() {
        guard !messages.isEmpty, let data = try? JSONEncoder().encode(saved) else { return }
        try? ResilientFile.write(data, to: ChatStore.url(for: id))
    }
}

/// Saved chats under Application Support/Lizard/Chats.
enum ChatStore {
    static var directory: URL { AppPaths.ensure(AppPaths.applicationSupport.appending(path: "Chats", directoryHint: .isDirectory)) }

    static func url(for id: UUID) -> URL { directory.appending(path: "\(id.uuidString).json") }

    static func loadAll() -> [ChatSession.Saved] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { url in ResilientFile.read(url) { try JSONDecoder().decode(ChatSession.Saved.self, from: $0) } }
            .sorted { $0.created > $1.created }
    }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }
}
