import Foundation

/// A Raycast-format extension `package.json`.
public struct ExtensionManifest: Sendable, Hashable, Codable {
    public struct Preference: Sendable, Hashable, Codable {
        public struct Option: Sendable, Hashable, Codable {
            public let title: String?
            public let value: String?
        }

        public let name: String
        public let title: String?
        public let description: String?
        public let type: String
        public let required: Bool?
        public let placeholder: String?
        public let label: String?
        public let `default`: HostJSON?
        public let data: [Option]?
    }

    public struct Argument: Sendable, Hashable, Codable {
        public let name: String
        public let type: String?
        public let placeholder: String?
        public let required: Bool?
    }

    public struct Command: Sendable, Hashable, Codable {
        public enum Mode: String, Sendable, Codable {
            case view, noView = "no-view", menuBar = "menu-bar"
        }

        public let name: String
        public let title: String
        public let subtitle: String?
        public let description: String?
        public let icon: String?
        public let mode: Mode
        public let interval: String?
        public let disabledByDefault: Bool?
        public let keywords: [String]?
        public let preferences: [Preference]?
        public let arguments: [Argument]?

        /// "5m", "30s", "1h", "1d" → seconds (minimum 10 s).
        public var intervalSeconds: TimeInterval? {
            guard let interval, let unit = interval.last, let value = Double(interval.dropLast()) else { return nil }
            let multiplier: Double = switch unit {
            case "s": 1
            case "m": 60
            case "h": 3600
            case "d": 86_400
            default: 0
            }
            guard multiplier > 0 else { return nil }
            return max(10, value * multiplier)
        }
    }

    public let name: String
    public let title: String
    public let description: String?
    public let icon: String?
    public let author: String?
    public let commands: [Command]
    public let preferences: [Preference]?

    public static func load(from directory: URL) throws -> ExtensionManifest {
        let data = try Data(contentsOf: directory.appending(path: "package.json"))
        return try JSONDecoder().decode(ExtensionManifest.self, from: data)
    }

    /// Default values for extension + command preferences (checkbox → Bool, others → String).
    public func defaultPreferences(for command: Command?) -> [String: HostJSON] {
        var values: [String: HostJSON] = [:]
        for preference in (preferences ?? []) + (command?.preferences ?? []) {
            if let value = preference.default, !value.isNull {
                values[preference.name] = value
            } else if preference.type == "checkbox" {
                values[preference.name] = .bool(false)
            }
        }
        return values
    }

    /// Every preference that applies to `command` (extension-wide first).
    public func allPreferences(for command: Command?) -> [Preference] {
        (preferences ?? []) + (command?.preferences ?? [])
    }
}
