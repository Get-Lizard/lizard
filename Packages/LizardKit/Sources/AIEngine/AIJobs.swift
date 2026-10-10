import Foundation

/// Short, one-shot AI jobs the launcher runs (ported from Cocoon's `HelperJob`): each has a
/// prompt, a token cap and a time limit; nil means "fall back" (show the raw text, no summary).
public enum AIJob: Sendable, Equatable {
    case summarize(text: String)
    case summarizeWorkLog(entries: String, period: String)
    case bragDoc(entries: String)
    case explain(text: String)
    case rewrite(text: String, style: String)
    case answer(question: String)

    public var title: String {
        switch self {
        case .summarize: "Summary"
        case .summarizeWorkLog(_, let period): "Work summary — \(period)"
        case .bragDoc: "Brag document"
        case .explain: "Explanation"
        case .rewrite(_, let style): "Rewritten (\(style))"
        case .answer: "Answer"
        }
    }

    /// Seconds before the caller gives up.
    public var timeout: Double {
        switch self {
        case .summarize, .rewrite, .answer: 45
        case .explain: 60
        case .summarizeWorkLog, .bragDoc: 120
        }
    }

    public var prompt: (system: String, user: String, maxTokens: Int) {
        switch self {
        case .summarize(let text):
            return ("""
                You summarize text copied on a Mac. Reply with 1–3 short bullet points ("- ") capturing what it is \
                and what matters. No preamble.
                """, String(text.prefix(12_000)), 300)
        case .summarizeWorkLog(let entries, let period):
            return ("""
                You turn a software engineer's raw work-log lines into a concise status update for \(period). \
                Group by theme with short markdown headings, merge duplicates, keep ticket numbers and names, \
                and end with a "Next" line if the log hints at follow-ups. Be factual; never invent work.
                """, String(entries.suffix(16_000)), 900)
        case .bragDoc(let entries):
            return ("""
                You write a brag document for a performance review from a software engineer's work log. \
                Sections: Impact, Projects, Collaboration & mentoring, Learning. Each bullet states the outcome \
                first, then how. Only use facts from the log.
                """, String(entries.suffix(24_000)), 1_400)
        case .explain(let text):
            return ("""
                You explain code, errors, commands or technical text to a software engineer. Be precise and brief: \
                what it is, what it does, anything surprising. Use markdown and code blocks where useful.
                """, String(text.prefix(12_000)), 900)
        case .rewrite(let text, let style):
            return ("Rewrite the user's text to be \(style). Keep meaning and facts. Reply with the rewritten text only.", String(text.prefix(8_000)), 900)
        case .answer(let question):
            return ("You are Lizard, a concise assistant inside a Mac launcher. Answer directly; use markdown.", question, 1_200)
        }
    }
}

public enum AIJobRunner {
    /// Runs `job` on the first provider that answers, racing its time limit. Status updates and
    /// partial text are reported through `onPartial` (full text so far).
    public static func run(
        _ job: AIJob, providers: [any AIProvider], onPartial: (@Sendable (String) -> Void)? = nil
    ) async -> (text: String, provider: String)? {
        let prompt = job.prompt
        let request = ChatRequest(system: prompt.system, messages: [.user(prompt.user)], maxTokens: prompt.maxTokens, thinking: false)
        for provider in providers {
            if Task.isCancelled { return nil }
            let text = await withTaskGroup(of: String?.self) { group -> String? in
                group.addTask { try? await collect(provider.stream(request), onPartial: onPartial) }
                group.addTask {
                    try? await Task.sleep(for: .seconds(job.timeout))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (cleaned(text), provider.displayName)
            }
        }
        return nil
    }

    /// Concatenates text deltas until the stream completes.
    public static func collect(
        _ stream: AsyncThrowingStream<ChatEvent, Error>, onPartial: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        var text = ""
        for try await event in stream {
            if case .textDelta(let delta) = event {
                text += delta
                onPartial?(cleaned(text))
            }
        }
        return text
    }

    /// Drops a leading `<think>…</think>` block reasoning models sometimes emit.
    public static func cleaned(_ text: String) -> String {
        var result = text
        if let open = result.range(of: "<think>") {
            if let close = result.range(of: "</think>", range: open.upperBound..<result.endIndex) {
                result.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                result.removeSubrange(open.lowerBound..<result.endIndex)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
