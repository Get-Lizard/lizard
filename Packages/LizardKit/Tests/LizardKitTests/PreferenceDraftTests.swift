import Foundation
import Testing

@testable import ExtensionHost

/// The preferences pane's save rules: what a cleared field must do, and which gaps block the save.
struct PreferenceDraftTests {
    private func manifest(extension preferences: [[String: Any]] = [], command: [[String: Any]] = []) throws -> ExtensionManifest {
        let json: [String: Any] = [
            "name": "gh", "title": "GitHub", "author": "someone",
            "preferences": preferences,
            "commands": [["name": "main", "title": "Main", "mode": "view", "preferences": command]],
        ]
        return try JSONDecoder().decode(ExtensionManifest.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private let text: [String: Any] = ["name": "host", "type": "textfield", "title": "Host", "default": "github.com"]
    private let token: [String: Any] = ["name": "token", "type": "password", "title": "Token", "required": true]
    private let verbose: [String: Any] = ["name": "verbose", "type": "checkbox", "label": "Verbose"]
    private let requiredFlag: [String: Any] = ["name": "fetchFavicons", "type": "checkbox", "title": "Favicons", "required": true]

    @Test func seedsFromManifestDefaultsThenSavedValues() throws {
        let draft = PreferenceDraft(
            manifest: try manifest(extension: [text, token]), command: nil, saved: ["token": .string("abc")])
        #expect(draft.value("host") == .string("github.com"))
        #expect(draft.value("token") == .string("abc"))
        #expect(draft.canSave)
    }

    @Test func savedValuesTheManifestNoLongerDeclaresAreIgnored() throws {
        let draft = PreferenceDraft(
            manifest: try manifest(extension: [text]), command: nil, saved: ["stray": .string("x")])
        #expect(draft.value("stray") == nil)
        #expect(draft.changes().isEmpty)
    }

    @Test func onlyChangedKeysAreWritten() throws {
        var draft = PreferenceDraft(
            manifest: try manifest(extension: [text, token]), command: nil, saved: ["token": .string("abc")])
        draft.set("host", .string("ghe.local"))
        let changes = draft.changes()
        #expect(Array(changes.keys) == ["host"])
        #expect(changes["host"] == .string("ghe.local"))
    }

    @Test func clearingAnOptionalFieldDeletesItSoTheDefaultAppliesAgain() throws {
        var draft = PreferenceDraft(
            manifest: try manifest(extension: [text, token]), command: nil, saved: ["host": .string("ghe.local")])
        draft.set("host", .string(""))
        let changes = draft.changes()
        #expect(changes["host"] != nil)  // the key IS in the payload…
        #expect(changes["host"]! == nil)  // …mapped to "delete", not to ""
        #expect(draft.value("host") == .string(""))
    }

    @Test func clearingARequiredFieldBlocksTheSave() throws {
        var draft = PreferenceDraft(
            manifest: try manifest(extension: [text, token]), command: nil, saved: ["token": .string("abc")])
        #expect(draft.canSave)
        draft.set("token", .string("   "))
        #expect(draft.missingRequired.map(\.name) == ["token"])
        #expect(!draft.canSave)
    }

    @Test func aRequiredCheckboxIsSatisfiedByFalse() throws {
        let draft = PreferenceDraft(
            manifest: try manifest(extension: [requiredFlag, verbose]), command: nil, saved: [:])
        #expect(draft.value("fetchFavicons") == .bool(false))
        #expect(draft.missingRequired.isEmpty)
        #expect(draft.canSave)
    }

    @Test func commandPreferencesShareTheDraftAndTheFile() throws {
        let manifest = try manifest(extension: [text], command: [token])
        var draft = PreferenceDraft(manifest: manifest, command: manifest.commands[0], saved: [:])
        #expect(draft.preferences.map { $0.name } == ["host", "token"])
        #expect(!draft.canSave)  // the command's required token is still empty
        draft.set("token", .string("abc"))
        draft.set("host", .string("ghe.local"))
        #expect(Set(draft.changes().keys) == ["host", "token"])
        #expect(draft.canSave)
    }

    @Test func kindsMapToTheFieldsThePaneRenders() throws {
        let prefs = [
            ["name": "a", "type": "textfield"], ["name": "b", "type": "password"],
            ["name": "c", "type": "checkbox"], ["name": "d", "type": "dropdown"],
            ["name": "e", "type": "appPicker"], ["name": "f", "type": "file"],
            ["name": "g", "type": "directory"], ["name": "h", "type": "radio"],
        ].map { $0.merging(["title": "T"]) { $1 } }
        let preferences = try manifest(extension: prefs).preferences ?? []
        #expect(preferences.map { $0.kind } == [
            .text, .password, .checkbox, .dropdown, .appPicker, .file, .directory, .other("radio"),
        ])
    }
}
