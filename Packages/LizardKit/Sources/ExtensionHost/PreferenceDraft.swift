import Foundation

/// Editable state for a manifest's preferences, shared by the preferences pane and its tests.
///
/// Seeds from the saved values over the manifest defaults, tracks edits, and reports exactly what
/// has to be persisted. The save rules are subtle enough to deserve tests: a cleared optional field
/// must delete the stored value (so the manifest default applies again) rather than persisting an
/// empty string, and a `required` preference that is still empty has to block the save.
public struct PreferenceDraft: Sendable {
    public let preferences: [ExtensionManifest.Preference]
    /// What the pane opened with: manifest defaults overlaid with saved values. `changes()` diffs
    /// against this, so opening a pane and pressing Save writes nothing.
    private let initial: [String: HostJSON]
    public private(set) var values: [String: HostJSON]

    public init(
        preferences: [ExtensionManifest.Preference], saved: [String: HostJSON], defaults: [String: HostJSON]
    ) {
        self.preferences = preferences
        var seeded = defaults
        for (key, value) in saved where preferences.contains(where: { $0.name == key }) { seeded[key] = value }
        self.initial = seeded
        self.values = seeded
    }

    /// Both the extension-wide and that command's preferences, the way the host merges them.
    public init(manifest: ExtensionManifest, command: ExtensionManifest.Command?, saved: [String: HostJSON]) {
        self.init(
            preferences: manifest.allPreferences(for: command), saved: saved,
            defaults: manifest.defaultPreferences(for: command))
    }

    public func value(_ name: String) -> HostJSON? { values[name] }

    public mutating func set(_ name: String, _ value: HostJSON) { values[name] = value }

    /// Required preferences still without a value — the command can't run until they're filled.
    public var missingRequired: [ExtensionManifest.Preference] {
        preferences.filter { $0.required == true && Self.isEmpty(values[$0.name]) }
    }

    public var canSave: Bool { missingRequired.isEmpty }

    /// Only the keys the person changed. `nil` deletes the stored value so the manifest default
    /// applies again — a cleared text field must not persist as `""`.
    public func changes() -> [String: HostJSON?] {
        var changes: [String: HostJSON?] = [:]
        for preference in preferences {
            let new = values[preference.name] ?? .null
            let old = initial[preference.name] ?? .null
            if new == old { continue }
            changes[preference.name] = Self.isEmpty(new) && preference.type != "checkbox" ? HostJSON?.none : new
        }
        return changes
    }

    /// A checkbox's `false` is a choice, not a gap.
    static func isEmpty(_ value: HostJSON?) -> Bool {
        switch value {
        case nil, .null?: true
        case .string(let text)?: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: false
        }
    }
}

public extension ExtensionManifest.Preference {
    /// The field to render; Raycast's documented set, plus anything a manifest invents.
    enum Kind: Sendable, Equatable {
        case text, password, checkbox, dropdown, appPicker, file, directory, other(String)
    }

    var kind: Kind {
        switch type {
        case "textfield": .text
        case "password": .password
        case "checkbox": .checkbox
        case "dropdown": .dropdown
        case "appPicker": .appPicker
        case "file": .file
        case "directory": .directory
        default: .other(type)
        }
    }

    /// Title, falling back to the label and then the name so a field is never unlabelled.
    var displayTitle: String { title ?? label ?? name }
}
