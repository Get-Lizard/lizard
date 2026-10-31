import MarkdownUI
import SwiftUI

/// "Ask AI" inside the launcher panel, laid out like a modern assistant: answers as clean text
/// next to the gecko, your messages as compact bubbles, code in titled blocks with a copy button.
/// Scroll handling follows Cocoon's ChatPane: a plain (non-lazy) stack anchored to the bottom.
struct ChatView: View {
    @Environment(AppModel.self) private var app
    /// The open conversation; the sidebar switches it without leaving the screen.
    @State private var session: ChatSession
    var onBack: () -> Void

    @State private var draft = ""
    @State private var history: [ChatSession.Saved] = []
    @State private var showSidebar = true
    @FocusState private var focused: Bool

    init(session: ChatSession, onBack: @escaping () -> Void) {
        _session = State(initialValue: session)
        self.onBack = onBack
    }

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar {
                sidebar.frame(width: 220)
                Divider().opacity(0.5)
            }
            conversation
        }
        .task { reloadHistory() }
        .onChange(of: session.isStreaming) { _, streaming in if !streaming { reloadHistory() } }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: newChat) {
                Label("New chat", systemImage: "square.and.pencil")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Brand.moss.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
            .help("New chat (⌘N)")
            .padding(10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(groupedHistory, id: \.title) { group in
                        Text(group.title)
                            .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                            .textCase(.uppercase)
                            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 3)
                        ForEach(group.chats, id: \.id) { chat in
                            historyRow(chat)
                        }
                    }
                    if history.isEmpty {
                        Text("Your conversations appear here.")
                            .font(.caption).foregroundStyle(.tertiary).padding(10)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
            }
        }
        .background(Color.primary.opacity(0.025))
    }

    private func historyRow(_ chat: ChatSession.Saved) -> some View {
        let selected = chat.id == session.id
        return Button { open(chat) } label: {
            Text(chat.title)
                .font(.callout)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete", role: .destructive) { delete(chat) }
        }
    }

    private struct HistoryGroup {
        let title: String
        let chats: [ChatSession.Saved]
    }

    private var groupedHistory: [HistoryGroup] {
        let calendar = Calendar.current
        func title(_ date: Date) -> String {
            if calendar.isDateInToday(date) { return "Today" }
            if calendar.isDateInYesterday(date) { return "Yesterday" }
            if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: .now)).day, days < 7 { return "Previous 7 days" }
            return date.formatted(.dateTime.month(.wide).year())
        }
        var groups: [HistoryGroup] = []
        for chat in history {
            let name = title(chat.created)
            if let index = groups.firstIndex(where: { $0.title == name }) {
                groups[index] = HistoryGroup(title: name, chats: groups[index].chats + [chat])
            } else {
                groups.append(HistoryGroup(title: name, chats: [chat]))
            }
        }
        return groups
    }

    private func reloadHistory() {
        history = ChatStore.loadAll()
    }

    private func newChat() {
        session.cancel()
        session = ChatSession(ai: app.ai)
        draft = ""
        focused = true
    }

    private func open(_ chat: ChatSession.Saved) {
        guard chat.id != session.id else { return }
        session.cancel()
        session = ChatSession(ai: app.ai, saved: chat)
        focused = true
    }

    private func delete(_ chat: ChatSession.Saved) {
        ChatStore.delete(chat.id)
        if chat.id == session.id { newChat() }
        reloadHistory()
    }

    // MARK: Conversation

    private var conversation: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if session.items.isEmpty {
                        welcome
                    }
                    ForEach(session.items.suffix(150)) { item in
                        ChatMessageRow(item: item, streaming: session.isStreaming && item.id == session.items.last?.id)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            composer
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .help("Back (Esc)")
            Button { withAnimation(.snappy) { showSidebar.toggle() } } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(.borderless)
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .help("Show or hide conversations (⇧⌘S)")
            Text(session.items.isEmpty ? "New chat" : session.title)
                .font(.headline).lineLimit(1)
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(Brand.moss).frame(width: 6, height: 6)
                Text(app.ai.chatProviderName).lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .help("Answers come from \(app.ai.chatProviderName): a connected cloud AI if you have one, otherwise Apple Intelligence. Change it in Settings › AI.")
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    // MARK: Welcome

    private struct Suggestion: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        let prompt: String
        var id: String { title }
    }

    private let suggestions = [
        Suggestion(symbol: "doc.on.clipboard", title: "Explain my clipboard", detail: "Code, an error, a command", prompt: "Explain my clipboard"),
        Suggestion(symbol: "list.bullet.clipboard", title: "Summarize today", detail: "From your work log", prompt: "Summarize today's work log"),
        Suggestion(symbol: "envelope", title: "Draft a message", detail: "Clear and friendly", prompt: "Help me write a short, friendly message to "),
        Suggestion(symbol: "lightbulb", title: "Explain a concept", detail: "In plain words", prompt: "Explain in simple terms: "),
    ]

    private var welcome: some View {
        VStack(spacing: 18) {
            LizardMarkView(size: 54)
                .padding(.top, 30)
            Text("How can I help?")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
            Text("Answered by \(app.ai.chatProviderName).")
                .font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(suggestions) { suggestion in
                    Button { pick(suggestion) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: suggestion.symbol).foregroundStyle(Brand.moss).frame(width: 20).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.title).font(.callout.weight(.semibold))
                                Text(suggestion.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 560)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message Lizard…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit { send(draft) }
                    .onKeyPress(.escape) {
                        if session.isStreaming { session.cancel(); return .handled }
                        onBack()
                        return .handled
                    }
                    .padding(.vertical, 4)
                VoiceButton(compact: true).padding(.bottom, 1)
                if session.isStreaming {
                    Button { session.cancel() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 28, height: 28).background(Color.primary.opacity(0.75), in: Circle())
                    }
                    .buttonStyle(.plain).help("Stop (Esc)")
                } else {
                    let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button { send(draft) } label: {
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(empty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Brand.ink))
                            .frame(width: 28, height: 28)
                            .background(empty ? AnyShapeStyle(Color.primary.opacity(0.1)) : AnyShapeStyle(Brand.moss), in: Circle())
                    }
                    .buttonStyle(.plain).disabled(empty).help("Send (↩)")
                }
            }
            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(focused ? Brand.moss.opacity(0.6) : Color.primary.opacity(0.1)))
            Text(session.isStreaming ? "esc to stop" : "↩ to send · ⇧↩ for a new line · answers can be wrong, check what matters")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: 864)
        .frame(maxWidth: .infinity)
        .onAppear { focused = true }
    }

    private func pick(_ suggestion: Suggestion) {
        if suggestion.prompt.hasSuffix(" ") {
            draft = suggestion.prompt  // finish the sentence yourself
            focused = true
        } else {
            send(suggestion.prompt)
        }
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var prompt = trimmed
        if trimmed == "Explain my clipboard", let clip = NSPasteboard.general.string(forType: .string) {
            prompt = "Explain this:\n\n\(clip.prefix(8_000))"
        } else if trimmed == "Summarize today's work log" {
            prompt = "Summarize what I did today from my work log:\n\n" + app.todayWorkLogText()
        }
        session.send(prompt)
        draft = ""
    }
}

/// One turn. Assistant answers sit beside the gecko with no bubble (easier to read long text);
/// your messages are compact bubbles on the right.
private struct ChatMessageRow: View {
    let item: ChatSession.Item
    let streaming: Bool
    @State private var copied = false

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(item.text)
                    .font(.system(size: 14.5))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Brand.moss.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        case .assistant:
            HStack(alignment: .top, spacing: 12) {
                LizardMarkView(size: 22, thinking: streaming)
                    .frame(width: 26, height: 26)
                    .background(Brand.moss.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 8) {
                    if item.text.isEmpty && streaming {
                        TypingDots().padding(.top, 6)
                    } else {
                        Markdown(item.text)
                            .markdownTheme(.lizard)
                            .textSelection(.enabled)
                    }
                    if !streaming, !item.text.isEmpty {
                        HStack(spacing: 12) {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(item.text, forType: .string)
                                copied = true
                                Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
                            } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                                .buttonStyle(.borderless)
                            if let provider = item.provider { Text(provider) }
                        }
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .status:
            Text(item.text).font(.caption).foregroundStyle(.secondary).padding(.leading, 38)
        case .error:
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(item.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.leading, 38)
        }
    }
}

/// Three dots that pulse while the first words are on their way.
private struct TypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var onScreen = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !onScreen)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(Brand.moss)
                        .frame(width: 7, height: 7)
                        .opacity(reduceMotion ? 0.7 : 0.35 + 0.65 * max(0, sin(time * 5 - Double(index) * 0.7)))
                }
            }
        }
        .onWindowVisibility { onScreen = $0 }
        .accessibilityLabel("Thinking")
    }
}

/// A titled, copyable code block: the language on the left, Copy on the right.
private struct ChatCodeBlock: View {
    let configuration: CodeBlockConfiguration
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(configuration.language?.isEmpty == false ? configuration.language! : "code")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(configuration.content, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
                } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(.borderless).font(.caption)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.primary.opacity(0.06))
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .relativeLineSpacing(.em(0.25))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.86))
                    }
                    .padding(12)
            }
        }
        .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .markdownMargin(top: 6, bottom: 10)
    }
}

extension Theme {
    /// Readable answers: comfortable size and spacing, quiet headings, titled code blocks.
    @MainActor static let lizard = Theme()
        .text {
            FontSize(14.5)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.88))
            BackgroundColor(Color.primary.opacity(0.08))
        }
        .strong { FontWeight(.semibold) }
        .link { ForegroundColor(Brand.teal) }
        .heading1 { configuration in
            configuration.label.markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.3)) }.markdownMargin(top: 12, bottom: 6)
        }
        .heading2 { configuration in
            configuration.label.markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.15)) }.markdownMargin(top: 12, bottom: 6)
        }
        .heading3 { configuration in
            configuration.label.markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.05)) }.markdownMargin(top: 10, bottom: 4)
        }
        .paragraph { configuration in
            configuration.label.relativeLineSpacing(.em(0.22)).markdownMargin(top: 0, bottom: 10)
        }
        .listItem { configuration in
            configuration.label.markdownMargin(top: .em(0.2))
        }
        .blockquote { configuration in
            configuration.label
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Brand.moss.opacity(0.5)).frame(width: 3) }
                .markdownTextStyle { ForegroundColor(.secondary) }
        }
        .codeBlock { configuration in
            ChatCodeBlock(configuration: configuration)
        }
}
