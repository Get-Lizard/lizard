import Foundation
import Knowledge
import Testing

/// Deterministic toy embedder: hashed bag of words (enough to test plumbing, not meaning).
struct HashEmbedder: Embedder {
    let identifier = "test.hash"
    let displayName = "hash"
    func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] {
        texts.map { text in
            var vector = [Float](repeating: 0, count: 64)
            for word in text.lowercased().split(whereSeparator: { !$0.isLetter }) { vector[abs(word.hashValue) % 64] += 1 }
            return VectorMath.normalized(vector, dimension: 64)
        }
    }
}

@Suite struct KnowledgeTests {
    func tempIndex() throws -> KnowledgeIndex {
        try KnowledgeIndex(url: FileManager.default.temporaryDirectory.appending(path: "knowledge-\(UUID()).sqlite"))
    }

    @Test func chunkerKeepsHeadingsAndSize() {
        let text = "# Deploy\n\n" + String(repeating: "Step one of the deploy goes here. ", count: 40) + "\n\n## Rollback\n\nRun the rollback script."
        let chunks = TextChunker.chunks(for: text, targetCharacters: 400, overlap: 50)
        #expect(chunks.count > 2)
        #expect(chunks.allSatisfy { $0.text.count <= 520 })
        #expect(chunks.last?.heading == "Rollback")
    }

    @Test func citationsParse() {
        #expect(AskNotes.citations(in: "Use the pool [2]. Also see [1, 3][2] and [x].") == [2, 1, 3])
    }

    @Test func syncIsIncrementalAndRemovesDeleted() async throws {
        let index = try tempIndex()
        let embedder = HashEmbedder()
        let a = KnowledgeDocument(id: "a", source: .note, title: "Redis", text: "Redis timeout fixed by raising pool size", modified: .now)
        let b = KnowledgeDocument(id: "b", source: .note, title: "Groceries", text: "eggs milk coffee", modified: .now)
        #expect(try await index.sync([a, b], sources: [.note], embedder: embedder) == 2)
        #expect(try await index.sync([a, b], sources: [.note], embedder: embedder) == 0)
        try await index.sync([a], sources: [.note], embedder: embedder)
        let stats = try await index.stats()
        #expect(stats.documents[.note] == 1)
    }

    @Test func keywordsFindExactTerms() async throws {
        let index = try tempIndex()
        let embedder = HashEmbedder()
        try await index.sync([
            KnowledgeDocument(id: "1", source: .workLog, title: "Oct 10", text: "Investigated ECONNRESET in the payments worker", modified: .now),
            KnowledgeDocument(id: "2", source: .note, title: "Ideas", text: "Build a launcher", modified: .now),
        ], sources: [.workLog, .note], embedder: embedder)
        let hits = try await index.search("ECONNRESET", embedder: embedder)
        #expect(hits.first?.documentKey == "workLog:1")
    }

    @Test func appleEmbedderFindsParaphrases() async throws {
        let embedder = AppleSentenceEmbedder()
        guard embedder.isAvailable else { return }
        let index = try tempIndex()
        try await index.sync([
            KnowledgeDocument(id: "pool", source: .note, title: "Incident", text: "Fixed connection pool exhaustion: the cache client kept sockets open and requests hung after 30 seconds", modified: .now),
            KnowledgeDocument(id: "food", source: .note, title: "Shopping", text: "Grocery list: eggs, milk, coffee beans", modified: .now),
            KnowledgeDocument(id: "design", source: .note, title: "Meeting", text: "Meeting with design about the onboarding screens", modified: .now),
        ], sources: [.note], embedder: embedder)
        let hits = try await index.search("that cache timeout problem", embedder: embedder)
        #expect(hits.first?.documentKey == "note:pool")
    }

    @Test func promptNumbersSources() {
        let hit = KnowledgeHit(documentKey: "note:a", source: .note, title: "Redis", location: nil, modified: .now, ordinal: 0, text: "raise the pool", heading: nil, score: 1, similarity: 0.8)
        let prompt = AskNotes.prompt(question: "how did I fix redis?", sources: [hit])
        #expect(prompt.contains("[1] Notes › Redis"))
        #expect(prompt.hasSuffix("Question: how did I fix redis?"))
    }
}

@Suite struct AskNotesTests {
    @Test func detectsBareCitations() {
        #expect(AskNotes.isOnlyCitations("[1] [2]"))
        #expect(AskNotes.isOnlyCitations(" [1, 2]. "))
        #expect(!AskNotes.isOnlyCitations("You raised the pool to 50 [1]."))
    }

    @Test func dropsWeakPassages() {
        func hit(_ id: String, _ score: Double) -> KnowledgeHit {
            KnowledgeHit(documentKey: id, source: .note, title: id, location: nil, modified: .now, ordinal: 0, text: "", heading: nil, score: score, similarity: score)
        }
        let kept = AskNotes.relevant([hit("a", 0.9), hit("b", 0.3), hit("c", 0.7)])
        #expect(kept.map(\.documentKey) == ["a", "c"])
    }
}

@Suite struct RetrievalRegressionTests {
    /// The Ask Your Notes demo: the incident note must win for a paraphrased "how did I fix" question.
    @Test func incidentNoteWinsForFixQuestion() async throws {
        let embedder = AppleSentenceEmbedder()
        guard embedder.isAvailable else { return }
        let index = try KnowledgeIndex(url: FileManager.default.temporaryDirectory.appending(path: "rr-\(UUID()).sqlite"))
        let incident = """
            # Checkout requests hanging

            After the Tuesday deploy the cache client kept sockets open, the connection pool ran dry and checkout requests hung for 30 seconds.

            ## Fix

            ```ts
            const cache = createClient({ maxRetriesPerRequest: 2, poolSize: 50, idleTimeoutMs: 60_000 })
            ```

            - [x] Raise the pool from 10 to 50
            - [x] Close idle sockets after 60s
            """
        try await index.sync([
            KnowledgeDocument(id: "incident", source: .note, title: "Checkout requests hanging", text: incident, modified: .now),
            KnowledgeDocument(id: "pods", source: .note, title: "Watch pods", text: "# Watch pods\n```sh\nkubectl get pods -n checkout -w\n```", modified: .now),
            KnowledgeDocument(id: "release", source: .note, title: "Release checklist", text: "# Release checklist\n1. Bump the version and tag v0.2.0\n2. Wait for notarization\n3. Check the Homebrew cask updated", modified: .now),
        ], sources: [.note], embedder: embedder)
        let hits = try await index.search("how did I fix the hanging checkout requests?", embedder: embedder)
        for hit in hits { print(hit.documentKey, hit.score, hit.similarity) }
        #expect(hits.first?.documentKey == "note:incident")
        #expect(AskNotes.relevant(hits).contains { $0.documentKey == "note:incident" })

        // A pure paraphrase (no shared keywords) must still find it by meaning.
        try await index.sync([
            KnowledgeDocument(id: "ideas", source: .note, title: "Onboarding ideas", text: "# Onboarding ideas\nShow the gecko first, then ask for one shortcut. Keep setup under a minute.", modified: .now),
        ] + [
            KnowledgeDocument(id: "incident", source: .note, title: "Checkout requests hanging", text: incident, modified: .now),
            KnowledgeDocument(id: "pods", source: .note, title: "Watch pods", text: "# Watch pods\n```sh\nkubectl get pods -n checkout -w\n```", modified: .now),
        ], sources: [.note], embedder: embedder)
        let paraphrase = try await index.search("that redis timeout problem", embedder: embedder)
        for hit in paraphrase { print("paraphrase", hit.documentKey, hit.score, hit.similarity) }
        // Apple's English sentence model is modest; the multilingual MLX model does better. Top 2 here.
        #expect(paraphrase.prefix(2).contains { $0.documentKey == "note:incident" })
        for query in ["payments were slow", "why was checkout stuck after the deploy", "that time the pool ran out"] {
            #expect(try await index.search(query, embedder: embedder).first?.documentKey == "note:incident")
        }
    }
}
