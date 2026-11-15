import Foundation
import LizardCore

/// Where `password`-typed preference values live. They never enter `preferences.json`, so a backup,
/// a share export or an iCloud sync copy can't carry them — which is what `docs/EXTENSIONS.md`
/// promises, and what the rest of the app already does with API keys.
public protocol PreferenceSecretStoring: Sendable {
    func value(for key: String) -> String?
    func set(_ value: String?, for key: String)
    func remove(keys: [String])
    func keys() -> [String]
}

/// One Keychain item for every extension's passwords, so macOS prompts at most once.
public struct KeychainPreferenceSecrets: PreferenceSecretStoring {
    public static let vault = SecretVault(account: "extension-preferences")

    /// `"<extension>/<preference>"` — the same flat namespace as the preferences file, so a name
    /// declared by both the extension and a command still resolves to one value.
    public static func key(_ extensionName: String, _ preference: String) -> String { "\(extensionName)/\(preference)" }

    public init() {}

    public func value(for key: String) -> String? { Self.vault.value(key) }
    public func set(_ value: String?, for key: String) { Self.vault.set(value, for: key) }
    public func remove(keys: [String]) { Self.vault.remove(names: keys) }
    public func keys() -> [String] { Self.vault.names() }
}
