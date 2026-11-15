import Foundation
import Testing

@testable import ExtensionHost

/// Password-typed preferences belong in the Keychain: they must never reach `preferences.json`,
/// and a value written by an older build must move out of it.
struct PreferenceSecretTests {
    /// Stands in for the Keychain so the rules are testable without prompts.
    final class MemorySecrets: PreferenceSecretStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        func value(for key: String) -> String? { lock.withLock { values[key] } }
        func set(_ value: String?, for key: String) { lock.withLock { values[key] = value } }
        func remove(keys: [String]) { lock.withLock { for key in keys { values[key] = nil } } }
        func keys() -> [String] { lock.withLock { values.keys.sorted() } }
    }

    private let preferences: [[String: Any]] = [
        ["name": "apiKey", "type": "password", "title": "API Key", "required": true],
        ["name": "host", "type": "textfield", "title": "Host"],
    ]

    private func makeStore() throws -> (ExtensionStore, MemorySecrets, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "secrets-\(UUID().uuidString)/Extensions")
        let directory = root.appending(path: "gh")
        let manifest: [String: Any] = [
            "name": "gh", "title": "GitHub", "author": "someone",
            "preferences": preferences,
            "commands": [["name": "main", "title": "Main", "mode": "view"]],
        ]
        let package = directory.appending(path: "package")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest).write(to: package.appending(path: "package.json"))
        let secrets = MemorySecrets()
        return (ExtensionStore(root: root, secrets: secrets), secrets, root)
    }

    private func savedFile(_ root: URL) -> [String: Any] {
        let url = root.appending(path: "gh/preferences.json")
        guard let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return object as? [String: Any] ?? [:]
    }

    @Test func passwordValuesGoToTheKeychainAndNeverToTheFile() async throws {
        let (store, secrets, root) = try makeStore()
        let item = try #require(await store.extensionNamed("gh"))
        try await store.setPreferences("gh", values: ["apiKey": .string("s3cret"), "host": .string("ghe.local")])

        #expect(secrets.value(for: "gh/apiKey") == "s3cret")
        let file = savedFile(root)
        #expect(file["apiKey"] == nil)  // never written to disk
        #expect(file["host"] as? String == "ghe.local")

        let values = await store.preferences(for: item, command: nil)
        #expect(values["apiKey"] == .string("s3cret"))
        #expect(values["host"] == .string("ghe.local"))
    }

    @Test func legacyPlaintextMovesIntoTheKeychainOnFirstRead() async throws {
        let (store, secrets, root) = try makeStore()
        let item = try #require(await store.extensionNamed("gh"))
        // What earlier builds (and the workaround for there being no preferences UI) left behind.
        try JSONSerialization.data(withJSONObject: ["apiKey": "old-secret", "host": "h"]).write(to: root.appending(path: "gh/preferences.json"))

        let values = await store.preferences(for: item, command: nil)
        #expect(values["apiKey"] == .string("old-secret"))
        #expect(secrets.value(for: "gh/apiKey") == "old-secret")
        #expect(savedFile(root)["apiKey"] == nil)  // removed from disk
        #expect(savedFile(root)["host"] as? String == "h")  // everything else untouched
    }

    @Test func clearingAPasswordRemovesItEverywhere() async throws {
        let (store, secrets, _) = try makeStore()
        try await store.setPreferences("gh", values: ["apiKey": .string("s3cret")])
        #expect(secrets.value(for: "gh/apiKey") == "s3cret")

        try await store.setPreferences("gh", values: ["apiKey": HostJSON?.none])
        #expect(secrets.value(for: "gh/apiKey") == nil)
        try await store.setPreferences("gh", values: ["apiKey": .string("")])
        #expect(secrets.value(for: "gh/apiKey") == nil)
    }

    @Test func aStoredSecretSatisfiesARequiredPreference() async throws {
        let (store, _, _) = try makeStore()
        let item = try #require(await store.extensionNamed("gh"))
        let command = try #require(item.commands.first)
        #expect(await store.missingRequiredPreferences(for: item, command: command).map(\.name) == ["apiKey"])

        try await store.setPreferences("gh", values: ["apiKey": .string("s3cret")])
        #expect(await store.missingRequiredPreferences(for: item, command: command).isEmpty)
    }

    @Test func uninstallingPurgesThatExtensionsSecretsOnly() async throws {
        let (store, secrets, _) = try makeStore()
        try await store.setPreferences("gh", values: ["apiKey": .string("s3cret")])
        secrets.set("keep", for: "other/apiKey")

        try await store.uninstall("gh")
        #expect(secrets.value(for: "gh/apiKey") == nil)
        #expect(secrets.value(for: "other/apiKey") == "keep")
    }
}
