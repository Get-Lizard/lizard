import Foundation
import LizardCore
import Vision

/// What a screenshot shows; the folder it's filed under.
public enum ScreenshotCategory: String, Sendable, Codable, CaseIterable, Identifiable {
    case code, terminal, error, design, document, chat, web, receipt, meeting, photo, other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .code: "Code"
        case .terminal: "Terminal"
        case .error: "Errors"
        case .design: "Design"
        case .document: "Documents"
        case .chat: "Chats"
        case .web: "Web"
        case .receipt: "Receipts"
        case .meeting: "Meetings"
        case .photo: "Photos"
        case .other: "Other"
        }
    }

    public var symbol: String {
        switch self {
        case .code: "chevron.left.forwardslash.chevron.right"
        case .terminal: "terminal"
        case .error: "exclamationmark.triangle"
        case .design: "paintbrush.pointed"
        case .document: "doc.richtext"
        case .chat: "bubble.left.and.bubble.right"
        case .web: "safari"
        case .receipt: "receipt"
        case .meeting: "video"
        case .photo: "photo"
        case .other: "square.dashed"
        }
    }
}

/// One captured screenshot and what Lizard learned about it.
public struct Screenshot: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var path: String
    public var date: Date
    public var app: String?
    public var appBundleID: String?
    public var category: ScreenshotCategory
    public var title: String
    public var tags: [String]
    /// Recognized text (OCR), for search.
    public var text: String
    public var width: Int
    public var height: Int

    public var url: URL { URL(filePath: path) }
}

/// The screenshot folder and its index (JSON next to Lizard's other data).
public actor ScreenshotLibrary {
    public let root: URL
    private let indexURL: URL
    public private(set) var items: [Screenshot]

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Pictures/Lizard Screenshots", directoryHint: .isDirectory)
    }

    public init(root: URL = ScreenshotLibrary.defaultRoot, indexURL: URL = AppPaths.applicationSupport.appending(path: "screenshots.json")) {
        self.root = root
        self.indexURL = indexURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = ResilientFile.read(indexURL) { try decoder.decode([Screenshot].self, from: $0) } ?? []
        // Forget entries whose files were deleted in Finder.
        items.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
    }

    /// `<root>/<Category>/<YYYY-MM>/<yyyy-MM-dd HH.mm.ss> <Title>.png`
    public func destination(for category: ScreenshotCategory, title: String, date: Date) -> URL {
        let month = DateFormatter()
        month.dateFormat = "yyyy-MM"
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let safeTitle = title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces).prefix(60)
        let folder = root.appending(path: category.title).appending(path: month.string(from: date), directoryHint: .isDirectory)
        return folder.appending(path: "\(stamp.string(from: date))\(safeTitle.isEmpty ? "" : " \(safeTitle)").png")
    }

    /// Files a captured image: moves it into place and records it.
    @discardableResult
    public func add(captured file: URL, date: Date, app: String?, bundleID: String?, label: ScreenshotLabel, text: String, size: CGSize) throws -> Screenshot {
        let target = Self.unique(destination(for: label.category, title: label.title, date: date))
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: target)
        let item = Screenshot(
            id: UUID(), path: target.path, date: date, app: app, appBundleID: bundleID, category: label.category, title: label.title,
            tags: label.tags, text: text, width: Int(size.width), height: Int(size.height))
        items.insert(item, at: 0)
        save()
        return item
    }

    /// `url`, or `<name> 2.png`, `<name> 3.png`… when a file is already there. Two captures in the
    /// same second with the same title used to overwrite each other (and orphan the first entry).
    static func unique(_ url: URL) -> URL {
        var candidate = url
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appending(path: "\(url.deletingPathExtension().lastPathComponent) \(counter).\(url.pathExtension)")
            counter += 1
        }
        return candidate
    }

    /// Re-files a screenshot under another category (moves the file).
    @discardableResult
    public func recategorize(_ id: UUID, to category: ScreenshotCategory) throws -> Screenshot? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        var item = items[index]
        guard item.category != category else { return item }
        let target = Self.unique(destination(for: category, title: item.title, date: item.date))
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: item.url, to: target)
        item.category = category
        item.path = target.path
        items[index] = item
        save()
        return item
    }

    public func delete(_ id: UUID) throws {
        guard let item = items.first(where: { $0.id == id }) else { return }
        try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        items.removeAll { $0.id == id }
        save()
    }

    /// Matches title, tags, app and the text inside the image (all words must match).
    public func search(_ query: String, category: ScreenshotCategory? = nil) -> [Screenshot] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return items.filter { item in
            if let category, item.category != category { return false }
            guard !words.isEmpty else { return true }
            let haystack = ([item.title, item.app ?? "", item.text, item.category.title] + item.tags).joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(items) { try? ResilientFile.write(data, to: indexURL) }
    }
}

/// How a screenshot is filed: from the on-device AI, or from rules when it's unavailable.
public struct ScreenshotLabel: Sendable, Equatable {
    public var category: ScreenshotCategory
    public var title: String
    public var tags: [String]

    public init(category: ScreenshotCategory, title: String, tags: [String]) {
        self.category = category
        self.title = title
        self.tags = tags
    }

    /// Rules: the app in front plus words in the image.
    public static func heuristic(text: String, app: String?, bundleID: String?) -> ScreenshotLabel {
        let lower = text.lowercased()
        let bundle = (bundleID ?? "").lowercased()
        let category: ScreenshotCategory
        if ["error", "exception", "failed", "traceback", "fatal", "undefined is not", "cannot find"].contains(where: lower.contains) {
            category = .error
        } else if ["terminal", "iterm", "warp", "ghostty", "alacritty", "kitty"].contains(where: bundle.contains) {
            category = .terminal
        } else if ["xcode", "vscode", "visualstudio", "jetbrains", "zed", "cursor", "sublime", "nova"].contains(where: bundle.contains) {
            category = .code
        } else if ["figma", "sketch", "pixelmator", "affinity", "photoshop", "illustrator"].contains(where: bundle.contains) {
            category = .design
        } else if ["slack", "messages", "whatsapp", "telegram", "discord", "teams", "mail"].contains(where: bundle.contains) {
            category = .chat
        } else if ["zoom", "facetime", "webex", "meet"].contains(where: bundle.contains) {
            category = .meeting
        } else if ["total", "subtotal", "invoice", "receipt", "amount due", "vat"].contains(where: lower.contains) {
            category = .receipt
        } else if ["safari", "chrome", "firefox", "arc", "brave", "edge", "orion"].contains(where: bundle.contains) {
            category = .web
        } else if ["pages", "word", "preview", "acrobat", "notes", "docs"].contains(where: bundle.contains) || text.count > 600 {
            category = .document
        } else if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 15 {
            category = .photo
        } else {
            category = .other
        }
        let firstLine = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.count >= 4 } ?? ""
        let title = String((firstLine.isEmpty ? (app ?? "Screenshot") : firstLine).prefix(48))
        return ScreenshotLabel(category: category, title: title, tags: app.map { [$0.lowercased()] } ?? [])
    }
}

/// On-device text recognition (Vision).
public enum ScreenshotOCR {
    public static func text(in image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let lines = (request.results as? [VNRecognizedTextObservation] ?? []).compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
            } catch {
                continuation.resume(returning: "")
            }
        }
    }
}
