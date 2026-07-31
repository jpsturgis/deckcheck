import XCTest
@testable import DeckCheckCore

final class OAuthTests: XCTestCase {
    // A representative Google iOS client id.
    let clientId = "407408718192-abc123.apps.googleusercontent.com"

    // ── PKCE (RFC 7636) ──────────────────────────────────────────────────────

    func testPKCEChallengeMatchesRFC7636Vector() {
        // RFC 7636 Appendix B worked example — pins the S256 implementation.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(PKCE.challenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testPKCEGenerateIsWellFormedAndSelfConsistent() {
        let p = PKCE.generate()
        XCTAssertTrue((43...128).contains(p.verifier.count))
        XCTAssertEqual(p.challenge, PKCE.challenge(for: p.verifier))
        // base64url: no +, /, or = padding
        XCTAssertFalse(p.verifier.contains(where: { "+/=".contains($0) }))
        XCTAssertFalse(p.challenge.contains(where: { "+/=".contains($0) }))
        XCTAssertNotEqual(PKCE.generate().verifier, PKCE.generate().verifier) // random
    }

    // ── config / scopes (the §8.2 guardrail) ─────────────────────────────────

    func testRequiredScopesAreSpreadsheetsAndDriveFileOnly() {
        XCTAssertEqual(OAuthConfig.requiredScopes, [
            "https://www.googleapis.com/auth/spreadsheets",
            "https://www.googleapis.com/auth/drive.file",
        ])
        // Never the restricted `drive` scope — that would trigger a CASA audit (§8.2).
        XCTAssertFalse(OAuthConfig.requiredScopes.contains("https://www.googleapis.com/auth/drive"))
    }

    func testIOSConfigDerivesReversedClientRedirect() {
        let c = OAuthConfig.iOS(clientId: clientId)
        XCTAssertEqual(c.redirectURI, "com.googleusercontent.apps.407408718192-abc123:/oauth2redirect")
        XCTAssertEqual(c.redirectScheme, "com.googleusercontent.apps.407408718192-abc123")
        XCTAssertEqual(c.scopes, OAuthConfig.requiredScopes)
    }

    // ── authorization URL ────────────────────────────────────────────────────

    func testAuthorizationURLCarriesPKCEAndOfflineConsent() {
        let config = OAuthConfig.iOS(clientId: clientId)
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = GoogleOAuth.authorizationURL(config: config, pkce: pkce, state: "xyz")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
        func v(_ n: String) -> String? { items.first { $0.name == n }?.value }

        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(v("client_id"), clientId)
        XCTAssertEqual(v("redirect_uri"), config.redirectURI)
        XCTAssertEqual(v("response_type"), "code")
        XCTAssertEqual(v("scope"), "https://www.googleapis.com/auth/spreadsheets https://www.googleapis.com/auth/drive.file")
        XCTAssertEqual(v("code_challenge"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(v("code_challenge_method"), "S256")
        XCTAssertEqual(v("state"), "xyz")
        XCTAssertEqual(v("access_type"), "offline") // → refresh_token
        XCTAssertEqual(v("prompt"), "consent")
    }

    // ── token requests (public client → no secret) ───────────────────────────

    func testTokenExchangeRequestIsAPublicClientCodeExchange() {
        let config = OAuthConfig.iOS(clientId: clientId)
        let pkce = PKCE(verifier: "verifier-123")
        let req = GoogleOAuth.tokenExchangeRequest(config: config, code: "auth/code+with/reserved", pkce: pkce)

        XCTAssertEqual(req.method, .post)
        XCTAssertEqual(req.url.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(req.headers["Content-Type"], "application/x-www-form-urlencoded")
        let body = req.bodyString ?? ""
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("code_verifier=verifier-123"))
        XCTAssertTrue(body.contains("client_id=407408718192-abc123.apps.googleusercontent.com"))
        // reserved chars in the code are percent-encoded, not left raw
        XCTAssertTrue(body.contains("code=auth%2Fcode%2Bwith%2Freserved"))
        XCTAssertFalse(body.contains("client_secret")) // public client
    }

    func testRefreshRequestUsesRefreshGrant() {
        let req = GoogleOAuth.refreshRequest(config: OAuthConfig.iOS(clientId: clientId), refreshToken: "rt-9")
        let body = req.bodyString ?? ""
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertTrue(body.contains("refresh_token=rt-9"))
        XCTAssertFalse(body.contains("client_secret"))
    }

    // ── token response parsing / lifecycle ───────────────────────────────────

    func testParseTokenResponseStampsAbsoluteExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let json = Data(#"{"access_token":"at-1","expires_in":3600,"refresh_token":"rt-1","scope":"a b","token_type":"Bearer"}"#.utf8)
        let tok = try GoogleOAuth.parseTokenResponse(json, now: now)
        XCTAssertEqual(tok.accessToken, "at-1")
        XCTAssertEqual(tok.refreshToken, "rt-1")
        XCTAssertEqual(tok.scope, "a b")
        XCTAssertEqual(tok.expiresAt, now.addingTimeInterval(3600))
    }

    func testParseTokenResponseSurfacesServerError() {
        let json = Data(#"{"error":"invalid_grant","error_description":"Bad Request"}"#.utf8)
        XCTAssertThrowsError(try GoogleOAuth.parseTokenResponse(json)) { err in
            XCTAssertEqual(err as? OAuthError, .server(error: "invalid_grant", description: "Bad Request"))
        }
    }

    func testTokenValidityHonorsRefreshMargin() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let tok = OAuthToken(accessToken: "at", refreshToken: nil, expiresAt: now.addingTimeInterval(120), scope: nil)
        XCTAssertTrue(tok.isValid(now: now, refreshMargin: 60))    // 120s left, 60s margin
        XCTAssertFalse(tok.isValid(now: now, refreshMargin: 120))  // within margin → refresh
        XCTAssertFalse(tok.isValid(now: now.addingTimeInterval(200), refreshMargin: 0)) // expired
    }
}
