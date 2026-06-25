import Foundation
import Security

/// Minimal Keychain wrapper for small secrets (API key, auth session).
enum Keychain {
    enum Item: String {
        case anthropicKey = "mango.secret.anthropicKey"
        /// Legacy single-token slot. Kept so existing reads don't break; the
        /// current id token now lives inside the JSON-encoded `.authSession`.
        case authToken = "mango.secret.authToken"
        /// JSON-encoded `AuthSession` (id/access/refresh tokens + expiry).
        case authSession = "mango.secret.authSession"
    }

    @discardableResult
    static func save(_ item: Item, value: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: item.rawValue,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func read(_ item: Item) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: item.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    @discardableResult
    static func delete(_ item: Item) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: item.rawValue,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    // MARK: - Typed AuthSession convenience

    /// Persist the auth session as JSON. Mirrors the current id token into the
    /// legacy `.authToken` slot so any code still reading that keeps working.
    @discardableResult
    static func saveSession(_ session: AuthSession) -> Bool {
        guard let data = try? JSONEncoder().encode(session),
              let json = String(data: data, encoding: .utf8)
        else { return false }
        save(.authToken, value: session.idToken)
        return save(.authSession, value: json)
    }

    /// Read and decode the stored auth session, if any.
    static func readSession() -> AuthSession? {
        guard let json = read(.authSession),
              let data = json.data(using: .utf8),
              let session = try? JSONDecoder().decode(AuthSession.self, from: data)
        else { return nil }
        return session
    }

    /// Clear all auth material (session JSON + legacy token slot).
    static func clearSession() {
        delete(.authSession)
        delete(.authToken)
    }
}
