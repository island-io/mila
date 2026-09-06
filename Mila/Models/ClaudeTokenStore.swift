import Foundation

/// Where the managed Claude OAuth token lives.
///
/// A protocol for two reasons. The obvious one is that a unit test can supply
/// an in-memory double instead of touching the login keychain. The other is
/// that it forces the *verified* shape on every operation: `save` and `delete`
/// return whether the store actually ends up in the state that was asked for.
/// A delete that silently failed is the bug this shape exists to prevent — the
/// UI would flip to "signed out" over a credential that is still sitting in the
/// keychain.
protocol ClaudeTokenStoring {
    func load() -> String?
    /// Returns true only if the token can be read back afterwards.
    @discardableResult func save(_ token: String) -> Bool
    /// Returns true only if nothing can be read back afterwards.
    @discardableResult func delete() -> Bool
}

/// Keychain-backed store, on top of the app's existing `KeychainHelper` (the
/// same generic-password service the OpenAI API key uses — see
/// `LLMSettings.openAIAPIKey`).
///
/// **UserDefaults is not an option here and never becomes one.** This is a
/// long-lived credential for the user's Claude account: `defaults read` would
/// print it, it would ride along in a preferences backup, and it would sit in a
/// plist that any process running as the user can read without prompting.
///
/// `key` is injectable so tests can use their own item and never read or
/// clobber the real one — the same treatment `LLMSettings` gives
/// `apiKeyKeychainKey`.
struct KeychainClaudeTokenStore: ClaudeTokenStoring {

    /// Keychain account name. Namespaced like every other `claudeSetup.*` key,
    /// though this one is a keychain item and not a defaults key.
    static let defaultKey = "claudeSetup.oauthToken"

    let key: String

    init(key: String = KeychainClaudeTokenStore.defaultKey) {
        self.key = key
    }

    func load() -> String? {
        guard let value = KeychainHelper.load(key: key),
              !value.isEmpty else { return nil }
        return value
    }

    @discardableResult
    func save(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        KeychainHelper.save(key: key, value: trimmed)
        // Read back rather than trust the write. `KeychainHelper.save` swallows
        // its `OSStatus`, and a keychain write can fail for reasons that have
        // nothing to do with this app (a locked keychain, a duplicate item left
        // by an older build).
        return load() == trimmed
    }

    @discardableResult
    func delete() -> Bool {
        KeychainHelper.delete(key: key)
        return load() == nil
    }
}
