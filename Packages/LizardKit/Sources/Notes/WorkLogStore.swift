import Foundation

/// One line of the work log.
public struct WorkLogEntry: Sendable, Hashable {
    public let date: Date
    public let app: String?
    public let text: String
}

/// Monthly Markdown logs (`YYYY-MM.md`) of timestamped entries:
/// `- 2026-10-10T14:03:05+02:00 [Xcode] Fixed the flaky login test`
public struct WorkLogStore: Sendable {
    public let root: URL
    private let calendar: Calendar

    public init(root: URL, calendar: Calendar = .current) {
        self.root = root
        self.calendar = calendar
    }

    static func timestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }

    public func file(for date: Date) -> URL {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return root.appending(path: String(format: "%04d-%02d.md", parts.year ?? 0, parts.month ?? 0))
    }

    static func line(for entry: WorkLogEntry) -> String {
        let flat = entry.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let app = entry.app.map { " [\($0)]" } ?? ""
        return "- \(timestampFormatter().string(from: entry.date))\(app) \(flat)"
    }

    public func append(text: String, app: String?, date: Date = .now) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = file(for: date)
        let line = Self.line(for: WorkLogEntry(date: date, app: app, text: text)) + "\n"
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } else {
            let header = DateFormatter()
            header.calendar = calendar
            header.dateFormat = "LLLL yyyy"
            try Data("# Work Log: \(header.string(from: date))\n\n\(line)".utf8).write(to: url, options: .atomic)
        }
    }

    /// Parses one log line (nil for headings and other text).
    public static func parse(line: String) -> WorkLogEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ") else { return nil }
        let rest = trimmed.dropFirst(2)
        guard let space = rest.firstIndex(of: " ") else { return nil }
        guard let date = timestampFormatter().date(from: String(rest[..<space])) else { return nil }
        var body = rest[rest.index(after: space)...]
        var app: String?
        if body.hasPrefix("["), let close = body.firstIndex(of: "]") {
            app = String(body[body.index(after: body.startIndex)..<close])
            body = body[body.index(after: close)...]
        }
        return WorkLogEntry(date: date, app: app, text: body.trimmingCharacters(in: .whitespaces))
    }

    public func entries(inMonthOf date: Date) -> [WorkLogEntry] {
        guard let text = try? String(contentsOf: file(for: date), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { Self.parse(line: String($0)) }
    }

    public func entries(from start: Date, to end: Date) -> [WorkLogEntry] {
        var result: [WorkLogEntry] = []
        var month = calendar.date(from: calendar.dateComponents([.year, .month], from: start)) ?? start
        while month <= end {
            result += entries(inMonthOf: month).filter { $0.date >= start && $0.date <= end }
            guard let next = calendar.date(byAdding: .month, value: 1, to: month) else { break }
            month = next
        }
        return result
    }

    public func entries(onDayOf date: Date) -> [WorkLogEntry] {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-1)
        return entries(from: start, to: end)
    }

    /// Entries as plain lines for an AI summary.
    public static func text(of entries: [WorkLogEntry]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM HH:mm"
        return entries.map { "\(formatter.string(from: $0.date))\($0.app.map { " [\($0)]" } ?? "") \($0.text)" }.joined(separator: "\n")
    }
}
