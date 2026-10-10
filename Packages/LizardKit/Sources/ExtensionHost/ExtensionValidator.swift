import Foundation

/// Checks an extension folder against docs/EXTENSIONS.md before it's shared or installed.
public enum ExtensionValidator {
    public struct Issue: Sendable, Hashable, CustomStringConvertible {
        public enum Level: String, Sendable { case error, warning }
        public let level: Level
        public let message: String
        public var description: String { "\(level == .error ? "✗" : "!") \(message)" }
    }

    public static let validModes: Set<String> = ["view", "no-view", "menu-bar"]
    public static let validPreferenceTypes: Set<String> = ["textfield", "password", "checkbox", "dropdown", "appPicker", "file", "directory"]

    public static func validate(_ folder: URL) -> [Issue] {
        var issues: [Issue] = []
        func error(_ text: String) { issues.append(Issue(level: .error, message: text)) }
        func warn(_ text: String) { issues.append(Issue(level: .warning, message: text)) }

        let packageURL = folder.appending(path: "package.json")
        guard let data = try? Data(contentsOf: packageURL), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [Issue(level: .error, message: "package.json is missing or isn't valid JSON")]
        }
        let kebab = #"^[a-z0-9]+(-[a-z0-9]+)*$"#
        let name = json["name"] as? String ?? ""
        if name.range(of: kebab, options: .regularExpression) == nil { error("\"name\" must be kebab-case (e.g. \"my-extension\")") }
        for field in ["title", "description", "author", "license"] where (json[field] as? String)?.isEmpty ?? true {
            error("\"\(field)\" is required")
        }
        if let icon = json["icon"] as? String {
            if !FileManager.default.fileExists(atPath: folder.appending(path: "assets/\(icon)").path) { error("icon \"\(icon)\" not found in assets/") }
        } else {
            error("\"icon\" is required (a 512×512 PNG in assets/)")
        }
        if json["repository"] == nil, (json["lizard"] as? [String: Any])?["repository"] == nil {
            warn("add \"repository\" (e.g. \"github.com/you/your-repo/path\") so Lizard can offer updates")
        }
        if let scripts = json["scripts"] as? [String: Any], scripts.keys.contains(where: { ["preinstall", "install", "postinstall"].contains($0) }) {
            warn("install scripts are never run by Lizard; don't rely on them")
        }

        let commands = json["commands"] as? [[String: Any]] ?? []
        if commands.isEmpty { error("at least one command is required") }
        var seen = Set<String>()
        for command in commands {
            let commandName = command["name"] as? String ?? ""
            if commandName.range(of: kebab, options: .regularExpression) == nil { error("command name \"\(commandName)\" must be kebab-case") }
            if !seen.insert(commandName).inserted { error("duplicate command \"\(commandName)\"") }
            if (command["title"] as? String)?.isEmpty ?? true { error("command \"\(commandName)\" needs a title") }
            let mode = command["mode"] as? String ?? ""
            if !validModes.contains(mode) { error("command \"\(commandName)\": mode must be view, no-view or menu-bar") }
            let entry = ["tsx", "ts", "jsx", "js"].contains { FileManager.default.fileExists(atPath: folder.appending(path: "src/\(commandName).\($0)").path) }
            if !entry { error("command \"\(commandName)\": missing src/\(commandName).tsx (or .ts/.jsx/.js)") }
            if let interval = command["interval"] as? String {
                if mode == "view" { error("command \"\(commandName)\": only menu-bar and no-view commands can have an interval") }
                if interval.range(of: #"^\d+[smhd]$"#, options: .regularExpression) == nil { error("command \"\(commandName)\": interval like \"10m\", \"1h\"") }
                else if let seconds = ExtensionManifest.Command(name: commandName, title: "", subtitle: nil, description: nil, icon: nil, mode: .noView, interval: interval, disabledByDefault: nil, keywords: nil, preferences: nil, arguments: nil).intervalSeconds, seconds < 60 {
                    warn("command \"\(commandName)\": intervals under 1 minute drain battery")
                }
            }
            for preference in command["preferences"] as? [[String: Any]] ?? [] { checkPreference(preference, error: error) }
        }
        for preference in json["preferences"] as? [[String: Any]] ?? [] { checkPreference(preference, error: error) }

        if !FileManager.default.fileExists(atPath: folder.appending(path: "README.md").path) { warn("add a README.md: what it does, what it accesses, how to set it up") }
        let size = folderSize(folder)
        if size > 50_000_000 { warn("the extension is \(size / 1_000_000) MB without node_modules; keep it small") }
        return issues
    }

    private static func checkPreference(_ preference: [String: Any], error: (String) -> Void) {
        let name = preference["name"] as? String ?? "?"
        if !validPreferenceTypes.contains(preference["type"] as? String ?? "") { error("preference \"\(name)\": unknown type") }
        if preference["type"] as? String == "dropdown", (preference["data"] as? [Any])?.isEmpty ?? true { error("preference \"\(name)\": dropdowns need data") }
        if (preference["title"] as? String)?.isEmpty ?? true, preference["type"] as? String != "checkbox" { error("preference \"\(name)\": title is required") }
    }

    private static func folderSize(_ folder: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let url as URL in enumerator {
            if url.lastPathComponent == "node_modules" { enumerator.skipDescendants(); continue }
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    /// Creates a new extension project that passes validation.
    public static func scaffold(name: String, title: String, author: String, in parent: URL) throws -> URL {
        let folder = parent.appending(path: name, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw ExtensionHostError.buildFailed("\(folder.path) already exists") }
        try FileManager.default.createDirectory(at: folder.appending(path: "src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appending(path: "assets"), withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "$schema": "https://www.raycast.com/schemas/extension.json",
            "name": name, "title": title, "description": "Describe what \(title) does in one sentence.",
            "icon": "icon.png", "author": author, "license": "MIT",
            "repository": "github.com/\(author)/\(name)",
            "categories": ["Productivity"],
            "commands": [["name": "index", "title": title, "description": "Main command", "mode": "view"]],
            "dependencies": ["@raycast/api": "^1.100.0", "@raycast/utils": "^2.0.0"],
            "devDependencies": ["typescript": "^5.6.0", "@types/node": "^22.0.0", "@types/react": "^18.3.0"],
            "scripts": ["typecheck": "tsc --noEmit", "validate": "lizardcli ext validate ."],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: folder.appending(path: "package.json"))
        try """
            import { Action, ActionPanel, Icon, List, showToast } from "@raycast/api";

            export default function Command() {
              return (
                <List searchBarPlaceholder="Search…">
                  <List.Item
                    icon={Icon.Star}
                    title="Hello from \(title)"
                    actions={
                      <ActionPanel>
                        <Action title="Say Hello" onAction={() => showToast({ title: "Hello!" })} />
                      </ActionPanel>
                    }
                  />
                </List>
              );
            }

            """.write(to: folder.appending(path: "src/index.tsx"), atomically: true, encoding: .utf8)
        try """
            {
              "compilerOptions": {
                "target": "ES2022", "module": "commonjs", "lib": ["ES2022"], "jsx": "react-jsx",
                "strict": true, "esModuleInterop": true, "skipLibCheck": true, "noEmit": true
              },
              "include": ["src"]
            }

            """.write(to: folder.appending(path: "tsconfig.json"), atomically: true, encoding: .utf8)
        try "node_modules/\nbuild/\n.DS_Store\n".write(to: folder.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        try """
            # \(title)

            Describe what the extension does.

            ## Setup

            What it needs (accounts, CLIs, permissions) and how to set it up.

            ## What it accesses

            Files, network hosts, other apps or CLIs it uses — be explicit.

            ## Install in Lizard

            Settings › Extensions › Install → `github.com/\(author)/\(name)`

            """.write(to: folder.appending(path: "README.md"), atomically: true, encoding: .utf8)
        return folder
    }
}
