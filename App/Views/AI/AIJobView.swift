import AIEngine
import MarkdownUI
import SwiftUI

/// Runs one AI job (summary, explanation, work-log report) and streams the result.
struct AIJobView: View {
    @Environment(AppModel.self) private var app
    let job: AIJob

    @State private var text = ""
    @State private var provider: String?
    @State private var running = true
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { app.launcher.pop() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                LizardThinkingIndicator(isThinking: running).frame(width: 22, height: 22)
                Text(job.title).font(.headline)
                Spacer()
                if let provider { Text(provider).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            Divider()
            ScrollView {
                Group {
                    if failed {
                        Label("No AI answered. Set one up in Settings › AI.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else if text.isEmpty {
                        Text("Thinking…").foregroundStyle(.secondary)
                    } else {
                        Markdown(text).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            ActionBar(hints: [("Copy", "⌘C"), ("Back", "esc")]) {
                Button("Copy") { copy() }.keyboardShortcut("c", modifiers: .command).disabled(text.isEmpty)
                Button("Continue in chat") { continueInChat() }.disabled(text.isEmpty)
            }
        }
        .task(id: job) { await run() }
    }

    private func run() async {
        running = true
        let result = await app.ai.run(job) { partial in
            Task { @MainActor in text = partial }
        }
        running = false
        if let result {
            text = result.text
            provider = result.provider
        } else if text.isEmpty {
            failed = true
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func continueInChat() {
        let session = ChatSession(ai: app.ai)
        session.seed(user: job.prompt.user, assistant: text)
        app.launcher.push(.chat(session))
    }
}

/// Past conversations.
struct ChatHistoryView: View {
    @Environment(AppModel.self) private var app
    @State private var chats: [ChatSession.Saved] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { app.launcher.pop() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Text("AI Chats").font(.headline)
                Spacer()
                Button("New chat") { app.launcher.push(.chat(ChatSession(ai: app.ai))) }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            Divider()
            List(chats, id: \.id) { chat in
                Button {
                    app.launcher.push(.chat(ChatSession(ai: app.ai, saved: chat)))
                } label: {
                    VStack(alignment: .leading) {
                        Text(chat.title).lineLimit(1)
                        Text(chat.created, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Delete", role: .destructive) {
                        ChatStore.delete(chat.id)
                        chats.removeAll { $0.id == chat.id }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .onAppear { chats = ChatStore.loadAll() }
    }
}
