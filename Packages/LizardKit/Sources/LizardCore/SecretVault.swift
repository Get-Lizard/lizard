import Foundation
import Security
import Synchronization

/// One Keychain item holding named secrets as a JSON object, so macOS asks for access at most once
/// instead of once per secret. Same shape as `AIEngine.Keychain`, which keeps its own item for the
/// AI providers' API keys — separate items so one caller can never rewrite the other's secrets.
///
/// Reads go through an in-memory cache: a first read can block on an access prompt, so call
/// `prefetch()` off the main thread at launch and let the UI use `cachedValue`.
public final class SecretVault: @unchecked Sendable {
    public let account: String
    public let service: String

    private struct State {
        var secrets: [String: String]?
        /// The item exists but couldn't be read (access denied, prompt cancelled). Writing then
        /// would drop every other secret in it, so writes are refused until a read succeeds.
        var unreadable = false
    }

    private let state = Mutex(State())

    public init(account: String, service: String = "io.lizard.app") {
        self.account = account
        self.service = service
    }

    /// Reads through the cache, loading the item on first use.
    public func value(_ name: String) -> String? { load()[name] }

    /// The cached value without touching the Keychain: `nil` when the vault isn't loaded yet.
    public func cachedValue(_ name: String) -> String?? { state.withLock { $0.secrets.map { $0[name] } } }

    public func prefetch() { _ = load() }

    public func names() -> [String] { load().keys.sorted() }

    /// Stores `value` under `name`; `nil` or empty removes it.
    public func set(_ value: String?, for name: String) {
        var secrets = load()
        if let value, !value.isEmpty { secrets[name] = value } else { secrets[name] = nil }
        persist(secrets)
    }

    public func remove(names: [String]) {
        guard !names.isEmpty else { return }
        var secrets = load()
        for name in names { secrets[name] = nil }
        persist(secrets)
    }

    // MARK: Keychain

    private func persist(_ secrets: [String: String]) {
        guard !state.withLock({ $0.unreadable }) else {
            // Keep the in-memory view (this session works) but never overwrite what we couldn't read.
            state.withLock { $0.secrets = secrets }
            return
        }
        deleteItem()
        if !secrets.isEmpty, let data = try? JSONEncoder().encode(secrets) {
            var attributes = baseQuery()
            attributes[kSecValueData as String] = data
            attributes[kSecAttrLabel as String] = "Lizard extension passwords"
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            SecItemAdd(attributes as CFDictionary, nil)
        }
        state.withLock { $0.secrets = secrets }
    }

    private func load() -> [String: String] {
        if let secrets = state.withLock({ $0.secrets }) { return secrets }
        let secrets: [String: String]
        var unreadable = false
        switch read() {
        case .found(let data):
            secrets = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        case .notFound:
            secrets = [:]
        case .unavailable:
            secrets = [:]
            unreadable = true
        }
        state.withLock {
            $0.secrets = secrets
            $0.unreadable = unreadable
        }
        return secrets
    }

    private enum ReadResult { case found(Data), notFound, unavailable }

    private func read() -> ReadResult {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess: return (item as? Data).map(ReadResult.found) ?? .unavailable
        case errSecItemNotFound: return .notFound
        default: return .unavailable
        }
    }

    private func deleteItem() { SecItemDelete(baseQuery() as CFDictionary) }

    private func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
