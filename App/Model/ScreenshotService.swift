import AIEngine
import AppKit
import Foundation
import LizardCore
import Observation
import Screenshots

/// Capture → read the text (Vision) → file it (Apple Intelligence, else rules) → copy to clipboard.
/// Uses macOS's own `screencapture` UI, so it feels native (crosshair, space for window, Esc to cancel).
@Observable
@MainActor
final class ScreenshotService {
    enum Mode { case area, window, screen }

    private(set) var items: [Screenshot] = []
    private(set) var processing = false
    @ObservationIgnored let library = ScreenshotLibrary()
    @ObservationIgnored private weak var app: AppModel?

    static let copyKey = "Lizard.ScreenshotCopy"
    static let aiKey = "Lizard.ScreenshotAI"

    var copyToClipboard: Bool {
        get { UserDefaults.standard.object(forKey: Self.copyKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.copyKey) }
    }

    var organizeWithAI: Bool {
        get { UserDefaults.standard.object(forKey: Self.aiKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.aiKey) }
    }

    init(app: AppModel) {
        self.app = app
        Task { items = await library.items }
    }

    func capture(_ mode: Mode) {
        guard let app else { return }
        app.hideLauncher()
        let front = NSWorkspace.shared.frontmostApplication.flatMap { $0.bundleIdentifier == Bundle.main.bundleIdentifier ? app.previousApp : $0 }
        Task {
            // Let the launcher fade out before the screen is captured.
            try? await Task.sleep(for: .milliseconds(180))
            let temporary = FileManager.default.temporaryDirectory.appending(path: "lizard-shot-\(UUID().uuidString).png")
            let arguments: [String] = switch mode {
            case .area: ["-i", "-x", temporary.path]
            case .window: ["-i", "-W", "-x", temporary.path]
            case .screen: ["-x", temporary.path]
            }
            _ = try? await ProcessRunner.run("/usr/sbin/screencapture", arguments, timeout: .seconds(300))
            guard FileManager.default.fileExists(atPath: temporary.path) else { return }  // cancelled with Esc
            await file(temporary, app: front?.localizedName, bundleID: front?.bundleIdentifier)
        }
    }

    private func file(_ temporary: URL, app frontApp: String?, bundleID: String?) async {
        processing = true
        defer { processing = false }
        guard let image = NSImage(contentsOf: temporary), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        if copyToClipboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            app?.markOwnPasteboardWrite()
        }
        let text = await ScreenshotOCR.text(in: cgImage)
        var label = ScreenshotLabel.heuristic(text: text, app: frontApp, bundleID: bundleID)
        if organizeWithAI, let ai = await AppleIntelligence.labelScreenshot(text: text, app: frontApp) {
            label = ScreenshotLabel(
                category: ScreenshotCategory(rawValue: ai.kind.rawValue) ?? label.category,
                title: ai.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? label.title : ai.title,
                tags: Array(Set(ai.tags.map { $0.lowercased() } + label.tags)).sorted())
        }
        do {
            let item = try await library.add(
                captured: temporary, date: .now, app: frontApp, bundleID: bundleID, label: label, text: text,
                size: CGSize(width: cgImage.width, height: cgImage.height))
            items = await library.items
            app?.showHUD("\(copyToClipboard ? "Copied · " : "")Saved to \(item.category.title) — \(item.title)")
            app?.knowledge.scheduleSync()
        } catch {
            app?.showHUD("Couldn't save the screenshot: \(error.localizedDescription)")
        }
    }

    func search(_ query: String, category: ScreenshotCategory?) async -> [Screenshot] {
        await library.search(query, category: category)
    }

    func recategorize(_ item: Screenshot, to category: ScreenshotCategory) {
        Task {
            _ = try? await library.recategorize(item.id, to: category)
            items = await library.items
        }
    }

    func delete(_ item: Screenshot) {
        Task {
            try? await library.delete(item.id)
            items = await library.items
        }
    }

    func copy(_ item: Screenshot) {
        guard let image = NSImage(contentsOf: item.url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        app?.markOwnPasteboardWrite()
        app?.showHUD("Screenshot copied")
    }

    /// Opens Preview with Markup ready for annotating.
    func annotate(_ item: Screenshot) {
        NSWorkspace.shared.open([item.url], withApplicationAt: URL(filePath: "/System/Applications/Preview.app"), configuration: NSWorkspace.OpenConfiguration())
        app?.hideLauncher()
    }
}
