import AIEngine
import AppKit
import ApplicationServices
import Clipboard
import ExtensionHost
import Foundation
import Synchronization

/// Native services extensions call and wait for: paste, confirm dialogs, AI, app lists,
/// the selected text, launching other commands.
struct AppHostServices: HostServices {
    weak var app: AppModel?

    init(app: AppModel) {
        self.app = app
    }

    func handle(method: String, params: HostJSON, context: ExtensionContext) async throws -> HostJSON {
        switch method {
        case "clipboard.paste":
            await MainActor.run {
                app?.hideLauncher()
                AutoPaste.paste(into: app?.previousApp)
            }
            return .null
        case "confirmAlert":
            return .bool(await confirm(params))
        case "ai.ask":
            guard let app else { return .string("") }
            let prompt = params["prompt"]?.string ?? ""
            // Stream: the runner reports the full text so far; the extension gets only what's new.
            let progress = HostProgress.send
            let sent = Mutex(0)
            let result = await app.ai.ask(prompt, model: params["model"]?.string) { full in
                let delta: Substring? = sent.withLock { count in
                    guard full.count > count else { return nil }
                    defer { count = full.count }
                    return full.dropFirst(count)
                }
                if let delta { progress?(.string(String(delta))) }
            }
            guard let result else { throw AIProviderError.unavailable("No AI is set up. Open Lizard Settings › AI.") }
            return .string(result.text)
        case "applications":
            let apps = await MainActor.run { app?.indexedApps ?? [] }
            return .array(apps.map { entry in
                .object(["name": .string(entry.name), "path": .string(entry.path.path), "bundleId": entry.bundleIdentifier.map(HostJSON.string) ?? .null])
            })
        case "frontmostApplication":
            let front = await MainActor.run { app?.previousApp }
            return .object([
                "name": .string(front?.localizedName ?? ""), "path": .string(front?.bundleURL?.path ?? ""),
                "bundleId": .string(front?.bundleIdentifier ?? ""),
            ])
        case "selectedText":
            return await MainActor.run { app?.selectedTextInPreviousApp() }.map(HostJSON.string) ?? .null
        case "launchCommand":
            guard let name = params["name"]?.string else { return .null }
            let extensionName = params["extensionName"]?.string ?? context.extensionName
            await MainActor.run { app?.launchExtensionCommand(extension: extensionName, command: name, background: params["type"]?.string == "background") }
            return .null
        default:
            return .null
        }
    }

    @MainActor
    private func confirm(_ params: HostJSON) -> Bool {
        let alert = NSAlert()
        alert.messageText = params["title"]?.string ?? "Are you sure?"
        alert.informativeText = params["message"]?.string ?? ""
        let primary = alert.addButton(withTitle: params["primary"]?.string ?? "OK")
        if params["destructive"]?.bool == true { primary.hasDestructiveAction = true }
        alert.addButton(withTitle: params["dismiss"]?.string ?? "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}
