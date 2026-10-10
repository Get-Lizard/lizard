import Knowledge
import MarkdownUI
import SwiftUI

/// Semantic search across notes, work log, clipboard and chats; ⇥ / "Ask" turns the query into
/// a cited answer from those same passages.
struct KnowledgeView: View {
    @Environment(AppModel.self) private var app
    @State var query: String
    @State var asking: Bool
    @State private var hits: [KnowledgeHit] = []
    @State private var selectedID: String?
    @State private var session: AskNotesSession?
    @State private var searching = false
    @FocusState private var focused: Bool

    init(query: String, ask: Bool) {
        _query = State(initialValue: query)
        _asking = State(initialValue: ask)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { app.launcher.pop() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Image(systemName: asking ? "sparkle.magnifyingglass" : "text.magnifyingglass").foregroundStyle(Brand.moss)
                TextField(asking ? "Ask your notes…" : "Search by meaning across notes, work log, clipboard, chats…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
                    .onSubmit { asking ? ask() : open(selected) }
                    .onKeyPress(.tab) { ask(); return .handled }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                if searching || session?.phase == .searching || session?.phase == .answering {
                    LizardThinkingIndicator(isThinking: true).frame(width: 22, height: 22)
                }
                Button(asking ? "Search" : "Ask") { asking ? (asking = false) : ask() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            Divider()
            if asking, let session {
                AnswerView(session: session) { hit in app.knowledge.open(hit) }
            } else {
                results
            }
            ActionBar(hints: asking ? [("Search", "esc")] : [("Open", "↩"), ("Ask your notes", "⇥")]) {
                indexStatus
            }
        }
        .task(id: query) {
            guard !asking else { return }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            searching = true
            hits = await app.knowledge.search(query, limit: 20)
            searching = false
            selectedID = hits.first?.id
        }
        .onAppear {
            focused = true
            if asking { ask() }
        }
        .onDisappear { session?.cancel() }
    }

    private var selected: KnowledgeHit? { hits.first { $0.id == selectedID } ?? hits.first }

    @ViewBuilder
    private var indexStatus: some View {
        switch app.knowledge.state {
        case .indexing(let done, let total):
            Text("Indexing \(done)/\(total)…").font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.orange).lineLimit(1)
        case .idle:
            Text("\(app.knowledge.stats.chunks) passages · \(app.knowledge.usesMultilingualModel ? "multilingual" : "English") model")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var results: some View {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "text.magnifyingglass").font(.system(size: 36)).foregroundStyle(.tertiary)
                Text("Search by meaning").font(.headline)
                Text("“that redis timeout thing” finds the note even if it never says “redis timeout”.\nPress ⇥ to ask a question and get an answer with sources.")
                    .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if hits.isEmpty, !searching {
            Text("Nothing found. Try other words, or check Settings › AI › Knowledge.").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(hits) { hit in
                                HitRow(hit: hit, selected: hit.id == selected?.id)
                                    .id(hit.id)
                                    .onTapGesture { selectedID = hit.id }
                                    .onTapGesture(count: 2) { open(hit) }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: selectedID) { _, id in if let id { proxy.scrollTo(id) } }
                }
                .frame(width: 320)
                Divider()
                if let hit = selected {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(hit.title, systemImage: hit.source.symbol).font(.headline)
                            if let heading = hit.heading { Text(heading).font(.caption).foregroundStyle(.secondary) }
                            Text(hit.modified.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.tertiary)
                            Divider()
                            Markdown(hit.text).textSelection(.enabled)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func ask() {
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        asking = true
        let session = AskNotesSession(question: question)
        self.session = session
        session.run(knowledge: app.knowledge, ai: app.ai)
    }

    private func open(_ hit: KnowledgeHit?) {
        if let hit { app.knowledge.open(hit) }
    }

    private func move(_ delta: Int) {
        guard !hits.isEmpty else { return }
        let index = hits.firstIndex { $0.id == selected?.id } ?? 0
        selectedID = hits[max(0, min(hits.count - 1, index + delta))].id
    }
}

private struct HitRow: View {
    let hit: KnowledgeHit
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: hit.source.symbol).foregroundStyle(Brand.moss).frame(width: 20).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.title).lineLimit(1)
                Text(hit.text.replacingOccurrences(of: "\n", with: " ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .contentShape(Rectangle())
        .selectableRow(selected)
    }
}

private struct AnswerView: View {
    let session: AskNotesSession
    let open: (KnowledgeHit) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(session.question).font(.title3.weight(.semibold))
                switch session.phase {
                case .searching:
                    Text("Looking through your notes…").foregroundStyle(.secondary)
                case .noSources:
                    Label("Nothing in your notes, work log, clipboard or chats matches that.", systemImage: "questionmark.folder")
                        .foregroundStyle(.secondary)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                default:
                    if session.answer.isEmpty {
                        Text("Thinking…").foregroundStyle(.secondary)
                    } else {
                        Markdown(session.answer).textSelection(.enabled)
                    }
                }
                if !session.sources.isEmpty, session.phase != .searching {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.phase == .done ? "Sources" : "Passages").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(session.phase == .done ? session.citedSources : session.sources.enumerated().map { ($0.offset + 1, $0.element) }, id: \.number) { item in
                            Button { open(item.hit) } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Text("[\(item.number)]").font(.caption.monospacedDigit()).foregroundStyle(Brand.moss)
                                    Image(systemName: item.hit.source.symbol).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.hit.title).lineLimit(1)
                                        Text(item.hit.text.replacingOccurrences(of: "\n", with: " ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(8)
                                .surface(cornerRadius: 8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let provider = session.provider {
                    Text("Answered by \(provider) from \(session.sources.count) \(session.sources.count == 1 ? "passage" : "passages") on this Mac.").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.top)
    }
}
