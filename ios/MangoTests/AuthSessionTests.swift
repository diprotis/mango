import XCTest
@testable import Mango

final class AuthSessionTests: XCTestCase {

    // MARK: - Session validity / expiry

    func testValidWhenExpiryInFuture() {
        let session = makeSession(expiresIn: 3600)
        XCTAssertTrue(session.isValid)
        XCTAssertFalse(session.isExpiringSoon)
    }

    func testInvalidWhenExpired() {
        let session = makeSession(expiresIn: -10)
        XCTAssertFalse(session.isValid)
        XCTAssertTrue(session.isExpiringSoon)
    }

    func testExpiringSoonWithinWindow() {
        let session = makeSession(expiresIn: 120) // 2 min out
        XCTAssertTrue(session.isValid)
        XCTAssertTrue(session.isExpiringSoon) // default window is 5 min
        XCTAssertFalse(session.isExpiringSoon(within: 60)) // but not within 1 min
    }

    func testCodableRoundTrip() throws {
        let original = makeSession(expiresIn: 1800)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AuthSession.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - PKCE (RFC 7636)

    func testPKCEChallengeMatchesKnownVector() {
        // RFC 7636 Appendix B test vector.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = PKCE.codeChallenge(for: verifier)
        XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testPKCEVerifierIsURLSafeAndLongEnough() {
        let verifier = PKCE.makeCodeVerifier()
        XCTAssertGreaterThanOrEqual(verifier.count, 43)
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertTrue(verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    func testPKCEChallengeHasNoPaddingOrUnsafeChars() {
        let challenge = PKCE.codeChallenge(for: PKCE.makeCodeVerifier())
        XCTAssertFalse(challenge.contains("="))
        XCTAssertFalse(challenge.contains("+"))
        XCTAssertFalse(challenge.contains("/"))
    }

    func testStateIsNonEmptyAndRandom() {
        let a = PKCE.makeState()
        let b = PKCE.makeState()
        XCTAssertFalse(a.isEmpty)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - JWT claim decoding (display only)

    func testEmailDecodedFromIdToken() {
        let token = makeJWT(payloadJSON: #"{"email":"reader@example.com","sub":"abc"}"#)
        let session = AuthSession(idToken: token, accessToken: "a", refreshToken: "r", expiresAt: .now)
        XCTAssertEqual(session.email, "reader@example.com")
    }

    func testEmailNilForMalformedToken() {
        let session = AuthSession(idToken: "not-a-jwt", accessToken: "a", refreshToken: "r", expiresAt: .now)
        XCTAssertNil(session.email)
    }

    func testJWTClaimMissingReturnsNil() {
        let token = makeJWT(payloadJSON: #"{"sub":"abc"}"#)
        XCTAssertNil(JWT.claim("email", in: token))
    }

    // MARK: - Helpers

    private func makeSession(expiresIn seconds: TimeInterval) -> AuthSession {
        AuthSession(
            idToken: "id",
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(seconds)
        )
    }

    /// Build a compact JWT (header.payload.signature) with a base64url payload.
    private func makeJWT(payloadJSON: String) -> String {
        let header = base64URL(Data(#"{"alg":"none"}"#.utf8))
        let payload = base64URL(Data(payloadJSON.utf8))
        return "\(header).\(payload).sig"
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
