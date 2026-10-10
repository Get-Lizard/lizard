import AIEngine
import AIEngineMLX
import AppKit
import Clipboard
import Foundation
import Knowledge
import Notes
import Observation

/// Semantic search and "Ask your notes": keeps a local index of notes, work log, clipboard and
/// chats fresh in the background, and answers questions from it with citations.
@Observable
@MainActor
final class KnowledgeService {
    enum State: Equatable {
        case idle
        case indexing(done: Int, total: Int)
        case failed(String)
    }

    private static let sourcesKey = "Lizard.KnowledgeSources"

    private(set) var state = State.idle
    private(set) var stats = KnowledgeIndex.Stats()
    private(set) var embeddingDownload: Double?
    private(set) var embeddingError: String?
    var enabledSources: Set<KnowledgeSource> {
        didSet {
            UserDefaults.standard.set(enabledSources.map(\.rawValue), forKey: Self.sourcesKey)
            scheduleSync(after: 0.5)
        }
    }

    @ObservationIgnored private let index: KnowledgeIndex?
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSync: Task<Void, Never>?
    @ObservationIgnored private let apple = AppleSentenceEmbedder()
    @ObservationIgnored private let mlx = MLXEmbedder()

    init(app: AppModel) {
        self.app = app
        index = try? KnowledgeIndex()
        let saved = UserDefaults.standard.stringArray(forKey: Self.sourcesKey)?.compactMap(KnowledgeSource.init(rawValue:))
        enabledSources = Set(saved ?? KnowledgeSource.allCases)
    }

    /// The multilingual MLX model once downloaded; Apple's English embedding until then.
    var embedder: any Embedder { MLXEmbedder.isDownloaded ? mlx : apple }
    var usesMultilingualModel: Bool { MLXEmbedder.isDownloaded }

    func start() {
        scheduleSync(after: 8)
        // Clipboard and chats change all the time; pick them up every few minutes.
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                sync()
            }
        }
        guard let app else { return }
        Task {
            for await _ in await app.notes.changes() { scheduleSync(after: 3) }
        }
    }

    /// Something changed (note saved, work logged, chat saved…): re-sync shortly, coalescing bursts.
    func scheduleSync(after seconds: Double = 4) {
        pendingSync?.cancel()
        pendingSync = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            sync()
        }
    }

    func sync() {
        guard syncTask == nil, let index, let app else { return }
        let sources = enabledSources
        let embedder = embedder
        syncTask = Task {
            defer { syncTask = nil }
            let documents = await gather(app: app, sources: sources)
            do {
                try await index.sync(documents, sources: Set(KnowledgeSource.allCases), embedder: embedder) { progress in
                    Task { @MainActor in
                        self.state = progress.total == 0 || progress.done >= progress.total ? .idle : .indexing(done: progress.done, total: progress.total)
                    }
                }
                state = .idle
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
            stats = (try? await index.stats()) ?? stats
        }
    }

    func rebuild() {
        Task {
            try? await index?.reset()
            sync()
        }
    }

    func search(_ query: String, limit: Int = 8) async -> [KnowledgeHit] {
        guard let index, !enabledSources.isEmpty else { return [] }
        return (try? await index.search(query, embedder: embedder, sources: enabledSources, limit: limit)) ?? []
    }

    // MARK: Embedding model

    func downloadEmbeddingModel() {
        guard embeddingDownload == nil else { return }
        embeddingDownload = 0
        embeddingError = nil
        Task {
            do {
                try await MLXEmbedder.prepare { fraction in
                    Task { @MainActor in self.embeddingDownload = fraction }
                }
                embeddingDownload = nil
                // New vector space: the next sync re-embeds everything with the better model.
                sync()
            } catch {
                embeddingDownload = nil
                embeddingError = error.localizedDescription
            }
        }
    }

    // MARK: Documents

    private func gather(app: AppModel, sources: Set<KnowledgeSource>) async -> [KnowledgeDocument] {
        var documents: [KnowledgeDocument] = []
        if sources.contains(.note) {
            for note in await app.notes.list() {
                let text = await app.notes.read(note.url)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                documents.append(KnowledgeDocument(id: note.url.path, source: .note, title: note.title, text: text, modified: note.modified, location: note.url.path))
            }
        }
        if sources.contains(.workLog) {
            // One document per day of the last year.
            let entries = app.workLog.entries(from: .now.addingTimeInterval(-365 * 86_400), to: .now)
            let calendar = Calendar.current
            let days = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
            let titleFormat = Date.FormatStyle(date: .complete, time: .omitted)
            for (day, dayEntries) in days {
                let text = WorkLogStore.text(of: dayEntries.sorted { $0.date < $1.date })
                documents.append(KnowledgeDocument(
                    id: day.formatted(.iso8601.year().month().day()), source: .workLog, title: "Work log — \(day.formatted(titleFormat))",
                    text: text, modified: dayEntries.map(\.date).max() ?? day, location: app.workLog.file(for: day).path))
            }
        }
        if sources.contains(.clipboard) {
            for item in await app.clipboardItems(matching: "").prefix(500) where item.kind == .text || item.kind == .url {
                let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.count >= 12, text.count <= 20_000 else { continue }
                let title = String(text.split(separator: "\n").first?.prefix(70) ?? "Clipboard")
                documents.append(KnowledgeDocument(id: String(item.id), source: .clipboard, title: title, text: text, modified: item.created, location: "clip:\(item.id)"))
            }
        }
        if sources.contains(.chat) {
            for chat in ChatStore.loadAll() {
                let text = chat.items.filter { $0.kind == .user || $0.kind == .assistant }
                    .map { ($0.kind == .user ? "Q: " : "A: ") + $0.text }.joined(separator: "\n\n")
                guard !text.isEmpty else { continue }
                documents.append(KnowledgeDocument(id: chat.id.uuidString, source: .chat, title: chat.title, text: text, modified: chat.created, location: "chat:\(chat.id.uuidString)"))
            }
        }
        if sources.contains(.screenshot) {
            for shot in app.screenshots.items where shot.text.count >= 12 {
                documents.append(KnowledgeDocument(
                    id: shot.id.uuidString, source: .screenshot, title: "\(shot.title) (\(shot.category.title))",
                    text: ([shot.text] + shot.tags.map { "#\($0)" }).joined(separator: "\n"), modified: shot.date, location: shot.path))
            }
        }
        return documents
    }

    // MARK: Opening results

    func open(_ hit: KnowledgeHit) {
        guard let app else { return }
        switch hit.source {
        case .note:
            if let path = hit.location { app.launcher.push(.notes(URL(filePath: path))) }
        case .workLog:
            if let path = hit.location { NSWorkspace.shared.open(URL(filePath: path)); app.hideLauncher() }
        case .clipboard:
            app.copyText(hit.text)
        case .screenshot:
            app.launcher.push(.screenshots)
        case .chat:
            if let id = hit.location?.replacingOccurrences(of: "chat:", with: ""), let saved = ChatStore.loadAll().first(where: { $0.id.uuidString == id }) {
                app.launcher.push(.chat(ChatSession(ai: app.ai, saved: saved)))
            }
        }
    }
}

/// One "Ask your notes" answer: retrieves passages, streams an answer that cites them.
@Observable
@MainActor
final class AskNotesSession {
    let question: String
    private(set) var sources: [KnowledgeHit] = []
    private(set) var answer = ""
    private(set) var provider: String?
    private(set) var phase = Phase.searching
    @ObservationIgnored private var task: Task<Void, Never>?

    enum Phase: Equatable { case searching, answering, done, noSources, failed(String) }

    init(question: String) {
        self.question = question
    }

    func run(knowledge: KnowledgeService, ai: AIService) {
        task?.cancel()
        task = Task {
            let hits = await knowledge.search(question, limit: 12)
            let providers = ai.providers()
            let budget = AskNotes.contextBudget(promptTokens: providers.first?.contextTokens ?? 3_000)
            sources = AskNotes.select(AskNotes.relevant(hits), budget: budget)
            guard !sources.isEmpty else {
                phase = .noSources
                return
            }
            guard !providers.isEmpty else {
                phase = .failed("No AI is set up yet — the matching passages are listed below. Turn on an AI in Settings › AI to get answers.")
                return
            }
            phase = .answering
            let prompt = AskNotes.prompt(question: question, sources: sources)
            let request = ChatRequest(system: AskNotes.system, messages: [.user(prompt)], maxTokens: 1_200, thinking: false)
            // If a small model replies with bare citations, ask once more without the citation rule.
            let retry = ChatRequest(
                system: "Answer the question in full sentences using only the sources. Keep code and numbers exact. Answer in the language of the question.",
                messages: [.user(prompt)], maxTokens: 1_200, thinking: false)
            for candidate in providers {
                var text = ""
                do {
                    for attempt in [request, retry] {
                        text = ""
                        for try await event in candidate.stream(attempt) {
                            if case .textDelta(let delta) = event {
                                text += delta
                                answer = AIJobRunner.cleaned(text)
                            }
                        }
                        if !AskNotes.isOnlyCitations(answer) { break }
                    }
                    provider = candidate.displayName
                    phase = .done
                    return
                } catch {
                    if Task.isCancelled { return }
                    if !text.isEmpty {
                        phase = .done
                        return
                    }
                }
            }
            phase = .failed("The AI didn't answer. The passages it would have used are below.")
        }
    }

    func cancel() { task?.cancel() }

    /// Sources the answer actually cited (falls back to all retrieved).
    var citedSources: [(number: Int, hit: KnowledgeHit)] {
        let cited = AskNotes.citations(in: answer).filter { $0 <= sources.count }
        let numbers = cited.isEmpty ? Array(1...max(1, sources.count)).filter { $0 <= sources.count } : cited
        return numbers.map { ($0, sources[$0 - 1]) }
    }
}
