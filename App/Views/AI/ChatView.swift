import MarkdownUI
import SwiftUI

/// "Ask AI" inside the launcher panel. Scroll handling follows Cocoon's ChatPane: a plain
/// (non-lazy) stack anchored to the bottom, following new text until the user scrolls up.
struct ChatView: View {
    @Environment(AppModel.self) private var app
    let session: ChatSession
    var onBack: () -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if session.items.isEmpty {
                        emptyState
                    }
                    ForEach(session.items.suffix(150)) { item in
                        ChatBubble(item: item, streaming: session.isStreaming && item.id == session.items.last?.id)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            Divider()
            composer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .help("Back (Esc)")
            LizardThinkingIndicator(isThinking: session.isStreaming)
                .frame(width: 22, height: 22)
            Text(session.title).font(.headline).lineLimit(1)
            Spacer()
            Text(app.ai.activeProviderName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask anything").font(.title3.weight(.semibold))
            Text("Explain an error, draft a message, convert some code. Answers come from \(app.ai.activeProviderName).")
                .foregroundStyle(.secondary)
            HStack {
                ForEach(["Explain my clipboard", "Summarize today's work log", "Write a regex for emails"], id: \.self) { prompt in
                    Button(prompt) { send(prompt) }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding(.top, 20)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message Lizard…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit { send(draft) }
                .onKeyPress(.escape) {
                    if session.isStreaming { session.cancel(); return .handled }
                    onBack()
                    return .handled
                }
            if session.isStreaming {
                Button { session.cancel() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
                    .help("Stop")
            } else {
                Button { send(draft) } label: { Image(systemName: "arrow.up.circle.fill").font(.title2).foregroundStyle(Brand.moss) }
                    .buttonStyle(.borderless)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .onAppear { focused = true }
    }

    private func send(_ text: String) {
        var prompt = text
        if text == "Explain my clipboard", let clip = NSPasteboard.general.string(forType: .string) {
            prompt = "Explain this:\n\n\(clip.prefix(8_000))"
        } else if text == "Summarize today's work log" {
            prompt = "Summarize what I did today from my work log:\n\n" + app.todayWorkLogText()
        }
        session.send(prompt)
        draft = ""
    }
}

private struct ChatBubble: View {
    let item: ChatSession.Item
    let streaming: Bool

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(item.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Brand.moss.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                if item.text.isEmpty && streaming {
                    LizardThinkingIndicator(isThinking: true).frame(width: 26, height: 26)
                } else {
                    Markdown(item.text)
                        .markdownTheme(.gitHub.text { BackgroundColor(nil) })
                        .textSelection(.enabled)
                }
                if let provider = item.provider, !streaming {
                    HStack(spacing: 8) {
                        Text(provider).font(.caption2).foregroundStyle(.tertiary)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item.text, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).font(.caption2).help("Copy")
                    }
                }
            }
        case .status:
            Text(item.text).font(.caption).foregroundStyle(.secondary)
        case .error:
            Label(item.text, systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.orange)
        }
    }
}
