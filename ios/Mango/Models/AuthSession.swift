import Foundation

/// The tokens returned by Cognito's OAuth2 token endpoint, plus a computed
/// expiry. Persisted (JSON-encoded) in the Keychain by `AuthService`.
///
/// `idToken` is the JWT sent as `Authorization: Bearer …` on `/v1/*` calls;
/// `accessToken` is kept for completeness; `refreshToken` is used for silent
/// renewal. `expiresAt` is derived from the token endpoint's `expires_in`.
struct AuthSession: Codable, Equatable, Sendable {
    var idToken: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    /// True while the id token is still comfortably within its lifetime.
    var isValid: Bool { expiresAt > Date() }

    /// True when the token is valid but close enough to expiry that we should
    /// refresh it proactively (default: within 5 minutes).
    func isExpiringSoon(within interval: TimeInterval = 300) -> Bool {
        expiresAt.timeIntervalSinceNow < interval
    }

    /// Convenience for `isExpiringSoon(within:)` with the default window.
    var isExpiringSoon: Bool { isExpiringSoon() }

    /// The `email` claim from the id token, for display only.
    ///
    /// This does **not** verify the JWT signature — it only base64url-decodes the
    /// payload to show who's signed in. Never trust this for authorization.
    var email: String? {
        JWT.claim("email", in: idToken)
    }
}

/// Tiny, display-only JWT reader (payload claims). No signature verification.
enum JWT {
    /// Decode a single string claim from a compact JWT's payload segment.
    static func claim(_ name: String, in token: String) -> String? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        guard let payload = base64URLDecode(String(segments[1])),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }
        return object[name] as? String
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Re-pad to a multiple of 4.
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }
}
