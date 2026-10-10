import AIEngineMLX
import Knowledge
import SwiftUI

/// What semantic search and "Ask your notes" may read, the embedding model, index status.
struct KnowledgeSettingsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let knowledge = app.knowledge!
        VStack(alignment: .leading, spacing: 10) {
            Text("Search by meaning & Ask your notes").font(.headline)
            Text("Lizard indexes what you choose below, on this Mac only, so you can search by meaning and ask questions answered from your own notes, with sources.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(KnowledgeSource.allCases) { source in
                Toggle(isOn: Binding(
                    get: { knowledge.enabledSources.contains(source) },
                    set: { on in
                        if on { knowledge.enabledSources.insert(source) } else { knowledge.enabledSources.remove(source) }
                    })) {
                    Label("\(source.title) — \(knowledge.stats.documents[source] ?? 0) indexed", systemImage: source.symbol)
                }
            }
            Divider()
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(knowledge.usesMultilingualModel ? "Multilingual model on this Mac" : "Using Apple's English model").font(.callout.weight(.medium))
                    Text(knowledge.usesMultilingualModel ? MLXEmbedder.downloadDescription : "Download the multilingual model for better results in every language (\(MLXEmbedder.downloadDescription)).")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = knowledge.embeddingError { Text(error).font(.caption).foregroundStyle(.red) }
                }
                Spacer()
                if let progress = knowledge.embeddingDownload {
                    ProgressView(value: progress).frame(width: 120).tint(Brand.moss)
                } else if !knowledge.usesMultilingualModel {
                    Button("Download") { knowledge.downloadEmbeddingModel() }.buttonStyle(.borderedProminent).tint(Brand.moss)
                }
            }
            HStack {
                switch knowledge.state {
                case .indexing(let done, let total): ProgressView(value: Double(done), total: Double(max(total, 1))).frame(width: 140); Text("Indexing \(done) of \(total)").font(.caption)
                case .failed(let message): Text(message).font(.caption).foregroundStyle(.orange)
                case .idle: Text("\(knowledge.stats.chunks) passages indexed").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Rebuild Index") { knowledge.rebuild() }
            }
        }
        .padding(12)
        .surface()
    }
}
