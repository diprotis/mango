import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Things that can go wrong during sign-in. User-facing copy is intentionally
/// non-technical and never includes token material.
enum AuthError: LocalizedError {
    case notConfigured
    case cancelled
    case invalidCallback
    case tokenExchangeFailed(String)
    case noRefreshToken

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Sign-in isn't configured in this build yet. You can keep using Mango offline."
        case .cancelled:
            return "Sign-in was cancelled."
        case .invalidCallback:
            return "Sign-in didn't complete. Please try again."
        case .tokenExchangeFailed:
            return "We couldn't finish signing you in. Please try again."
        case .noRefreshToken:
            return "Your session expired. Please sign in again."
        }
    }
}

/// Owns the user's Cognito session: starts the Hosted-UI OAuth2 + PKCE flow via
/// `ASWebAuthenticationSession`, exchanges the authorization code for tokens,
/// persists them in the Keychain, and refreshes silently.
///
/// Not `@MainActor` at the type level (matching the app's other services); only
/// the UI-touching `ASWebAuthenticationSession` work is hopped to the main actor.
/// Token strings are never logged.
@Observable
final class AuthService {
    /// The current session, or nil when signed out.
    private(set) var session: AuthSession?

    var isSignedIn: Bool { session?.isValid == true }

    /// Cognito config, read once from `AppConfig.plist`.
    @ObservationIgnored private let config: CognitoConfig?

    init() {
        self.config = CognitoConfig.fromAppConfig()
    }

    /// True when the build has enough Cognito config to attempt sign-in.
    var isConfigured: Bool { config != nil }

    // MARK: - Restore

    /// Load any persisted session from the Keychain. Cheap; safe to call on init.
    func restore() {
        session = Keychain.readSession()
    }

    // MARK: - Sign in

    /// An identity provider to jump straight to in the Hosted UI, skipping the
    /// provider-chooser. `identity_provider` is a Cognito Hosted-UI parameter;
    /// `Google` / `SignInWithApple` are the conventional names for the federated
    /// IdPs. Email/phone use the Cognito user pool directly (no hint).
    enum IdPHint: String {
        case google = "Google"
        case apple = "SignInWithApple"
    }

    /// Run the full Hosted-UI sign-in: PKCE challenge → authorize → code → token
    /// exchange → persist. Throws `AuthError` on failure/cancel.
    ///
    /// Pass `idpHint` to deep-link to a specific federated provider; omit it to
    /// show Cognito's full provider list (Google, Apple, phone, email).
    @MainActor
    func signIn(idpHint: IdPHint? = nil) async throws {
        guard let config else { throw AuthError.notConfigured }

        let verifier = PKCE.makeCodeVerifier()
        let challenge = PKCE.codeChallenge(for: verifier)
        let state = PKCE.makeState()

        let authorizeURL = config.authorizeURL(
            codeChallenge: challenge,
            state: state,
            idpHint: idpHint?.rawValue
        )
        let code = try await runWebAuth(url: authorizeURL, callbackScheme: config.redirectScheme, expectedState: state)
        let tokens = try await exchangeCodeForTokens(code: code, verifier: verifier, config: config)

        Keychain.saveSession(tokens)
        session = tokens
    }

    /// Present the system auth sheet and return the `code` from the redirect.
    ///
    /// A *started* `ASWebAuthenticationSession` is retained by the system while it
    /// presents, but `presentationContextProvider` is held **weakly**, so we keep
    /// `presenter` alive by capturing it in the completion closure.
    @MainActor
    private func runWebAuth(url: URL, callbackScheme: String, expectedState: String) async throws -> String {
        let presenter = WebAuthPresenter()

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                // Keep the (weakly-held) presenter alive until the callback fires.
                withExtendedLifetime(presenter) {}

                if let error {
                    let nsError = error as NSError
                    if nsError.domain == ASWebAuthenticationSessionError.errorDomain,
                       nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: AuthError.cancelled)
                    } else {
                        continuation.resume(throwing: AuthError.invalidCallback)
                    }
                    return
                }
                guard let callbackURL,
                      let code = Self.code(from: callbackURL, expectedState: expectedState) else {
                    continuation.resume(throwing: AuthError.invalidCallback)
                    return
                }
                continuation.resume(returning: code)
            }
            session.presentationContextProvider = presenter
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                continuation.resume(throwing: AuthError.invalidCallback)
            }
        }
    }

    /// Parse `?code=…&state=…` from the redirect, validating the state.
    private static func code(from url: URL, expectedState: String) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        let returnedState = items.first { $0.name == "state" }?.value
        guard returnedState == expectedState else { return nil }
        return items.first { $0.name == "code" }?.value
    }

    // MARK: - Token exchange / refresh

    private func exchangeCodeForTokens(
        code: String,
        verifier: String,
        config: CognitoConfig
    ) async throws -> AuthSession {
        let form: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": config.clientId,
            "code": code,
            "redirect_uri": config.redirectURI,
            "code_verifier": verifier,
        ]
        return try await postToken(form: form, config: config, existingRefreshToken: nil)
    }

    /// Refresh the id/access tokens if the current session is missing, expired,
    /// or close to expiry. Never throws — best-effort silent refresh.
    func refreshIfNeeded() async {
        guard let config else { return }
        guard let current = session else { return }
        guard current.isExpiringSoon else { return }
        guard !current.refreshToken.isEmpty else { return }

        let form: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": config.clientId,
            "refresh_token": current.refreshToken,
        ]
        do {
            // Cognito's refresh response omits the refresh_token; carry the old one forward.
            let refreshed = try await postToken(
                form: form,
                config: config,
                existingRefreshToken: current.refreshToken
            )
            Keychain.saveSession(refreshed)
            session = refreshed
        } catch {
            // Leave the (stale) session in place; a 401 on the next call will
            // surface re-auth. We deliberately don't log token material here.
        }
    }

    /// POST an x-www-form-urlencoded body to the Cognito token endpoint and
    /// decode the result into an `AuthSession`.
    private func postToken(
        form: [String: String],
        config: CognitoConfig,
        existingRefreshToken: String?
    ) async throws -> AuthSession {
        var request = URLRequest(url: config.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(form)
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AuthError.tokenExchangeFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            // Status only — never echo the body, which can contain tokens.
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AuthError.tokenExchangeFailed("status \(code)")
        }

        let token: TokenResponse
        do {
            token = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw AuthError.tokenExchangeFailed("decode")
        }

        let refresh = token.refreshToken ?? existingRefreshToken ?? ""
        let expires = Date().addingTimeInterval(TimeInterval(token.expiresIn))
        return AuthSession(
            idToken: token.idToken,
            accessToken: token.accessToken,
            refreshToken: refresh,
            expiresAt: expires
        )
    }

    private static func formBody(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~") // RFC 3986 unreserved
        let pairs = form.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    // MARK: - Sign out

    /// Clear the session locally. Best-effort hits the Hosted-UI `/logout` to
    /// end the Cognito web session too (so the next sign-in re-prompts).
    func signOut() {
        let logoutURL = config?.logoutURL
        session = nil
        Keychain.clearSession()
        guard let logoutURL else { return }
        // Fire-and-forget; failure here doesn't matter for local sign-out.
        Task { _ = try? await URLSession.shared.data(from: logoutURL) }
    }
}

// MARK: - Cognito config

/// Resolved, validated Cognito OAuth configuration. `nil` when any required key
/// is empty so the rest of the app can treat "unconfigured" as "offline only".
private struct CognitoConfig {
    let domain: String
    let clientId: String
    let region: String
    let redirectScheme: String

    static func fromAppConfig() -> CognitoConfig? {
        let domain = AppConfig.cognitoDomain
        let clientId = AppConfig.cognitoClientId
        let region = AppConfig.cognitoRegion
        let scheme = AppConfig.cognitoRedirectScheme
        guard !domain.isEmpty, !clientId.isEmpty, !region.isEmpty, !scheme.isEmpty else { return nil }
        return CognitoConfig(domain: domain, clientId: clientId, region: region, redirectScheme: scheme)
    }

    /// `https://<domain>` — the domain is stored host-only.
    private var base: URL? { URL(string: "https://\(domain)") }

    var redirectURI: String { "\(redirectScheme)://callback" }

    var tokenURL: URL { base?.appendingPathComponent("oauth2/token") ?? fallbackTokenURL }

    var logoutURL: URL? {
        guard var components = base.flatMap({ URLComponents(url: $0.appendingPathComponent("logout"), resolvingAgainstBaseURL: false) }) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "logout_uri", value: redirectURI),
        ]
        return components.url
    }

    func authorizeURL(codeChallenge: String, state: String, idpHint: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = domain
        components.path = "/oauth2/authorize"
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "openid email"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
        ]
        if let idpHint, !idpHint.isEmpty {
            items.append(URLQueryItem(name: "identity_provider", value: idpHint))
        }
        components.queryItems = items
        return components.url ?? fallbackAuthorizeURL
    }

    // These fallbacks are unreachable in practice (host/scheme are validated
    // non-empty), but keep the API non-optional for call sites.
    private var fallbackTokenURL: URL { URL(string: "https://\(domain)/oauth2/token")! }
    private var fallbackAuthorizeURL: URL { URL(string: "https://\(domain)/oauth2/authorize")! }
}

// MARK: - Token endpoint response

private struct TokenResponse: Decodable {
    let idToken: String
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

// MARK: - PKCE

/// RFC 7636 PKCE helpers (S256) plus an OAuth `state` nonce, using CryptoKit.
enum PKCE {
    /// A high-entropy code verifier (43–128 chars from the unreserved set).
    static func makeCodeVerifier() -> String {
        base64URL(randomBytes(32))
    }

    /// BASE64URL( SHA256( verifier ) ).
    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    /// Opaque CSRF/state nonce for the authorize request.
    static func makeState() -> String {
        base64URL(randomBytes(16))
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            // Fallback to a non-crypto source only if SecRandom fails (very rare).
            for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        }
        return Data(bytes)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Presentation anchor

/// Provides the window that `ASWebAuthenticationSession` presents over. UIKit, so
/// it's pinned to the main actor.
@MainActor
private final class WebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes
        let window = scenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        return window ?? ASPresentationAnchor()
    }
}
