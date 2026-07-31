import Foundation
import CryptoKit

// ─────────────────────────────────────────────────────────────────────────────
// Google OAuth onboarding core. The pure, testable half of "Sign in
// with Google, we set up your Sheet": PKCE, the authorization URL, the token-
// exchange / refresh request specs, and token-lifecycle parsing. The device shell
// (ASWebAuthenticationSession to present the auth URL, URLSession to POST the token
// requests, Keychain to store the tokens) is a thin later layer that just executes
// the values built here — so the security-critical string/crypto logic is unit-
// tested off-device.
//
// v2 uses a PER-USER OAuth client: each user makes their own Google Cloud
// project + iOS OAuth client in "testing" mode with themselves as the sole test
// user, so an unverified client needs NO Google verification. An iOS client is a
// PUBLIC client — no client secret — so auth rests on PKCE. Scopes are exactly
// `spreadsheets` + `drive.file`; NEVER the restricted `drive` scope (that's
// what would trigger a CASA audit).
// ─────────────────────────────────────────────────────────────────────────────

/// A ready-to-execute HTTP request as pure data. The URLSession shell runs it; the
/// Sheets client (2c) reuses the same type. Keeps request-building unit-testable.
public struct HTTPRequestSpec: Equatable {
    public enum Method: String { case get = "GET", post = "POST", put = "PUT", delete = "DELETE" }
    public let method: Method
    public let url: URL
    public let headers: [String: String]
    public let body: Data?

    public init(method: Method, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method; self.url = url; self.headers = headers; self.body = body
    }

    /// The body decoded as a form string, for assertions/debugging.
    public var bodyString: String? { body.flatMap { String(data: $0, encoding: .utf8) } }
}

/// The per-user OAuth client configuration. No secret — an iOS client is a
/// public, PKCE-based client.
public struct OAuthConfig: Equatable {
    public let clientId: String
    public let redirectURI: String
    public let scopes: [String]

    /// The only scopes v2 requests at onboarding. `drive.file` = just the files
    /// this app creates/opens; `spreadsheets` = read/write those sheets. No broad `drive`.
    public static let requiredScopes = [
        "https://www.googleapis.com/auth/spreadsheets",
        "https://www.googleapis.com/auth/drive.file",
    ]

    /// Extra scope requested ONLY when the user opts into in-browser/app-closed
    /// gap-check. It lets the app create + push a container-bound
    /// Apps Script into the user's own sheet via the Apps Script API. Off by default;
    /// granted incrementally (a fresh consent showing the added permission) when the
    /// feature is turned on, never at first onboarding.
    public static let scriptProjectsScope = "https://www.googleapis.com/auth/script.projects"

    /// The onboarding scopes plus `script.projects` — the scope set to re-auth with
    /// when enabling in-browser gap-check.
    public static let scopesWithScript = requiredScopes + [scriptProjectsScope]

    public init(clientId: String, redirectURI: String, scopes: [String] = OAuthConfig.requiredScopes) {
        self.clientId = clientId; self.redirectURI = redirectURI; self.scopes = scopes
    }

    /// Build an iOS-client config from just the client id. Google iOS clients use a
    /// redirect of the reversed client id, e.g. client id
    /// `12345-abc.apps.googleusercontent.com` → redirect
    /// `com.googleusercontent.apps.12345-abc:/oauth2redirect`. That reversed scheme
    /// is what the app registers as a URL scheme and ASWebAuthenticationSession
    /// listens for.
    public static func iOS(clientId: String, scopes: [String] = OAuthConfig.requiredScopes) -> OAuthConfig {
        OAuthConfig(clientId: clientId, redirectURI: reversedClientRedirect(clientId), scopes: scopes)
    }

    /// The reversed-client-id redirect URI for an iOS OAuth client.
    public static func reversedClientRedirect(_ clientId: String) -> String {
        let base = clientId.hasSuffix(".apps.googleusercontent.com")
            ? String(clientId.dropLast(".apps.googleusercontent.com".count))
            : clientId
        return "com.googleusercontent.apps.\(base):/oauth2redirect"
    }

    /// The custom URL scheme the app must register (everything before the ":/").
    public var redirectScheme: String {
        String(redirectURI.prefix(while: { $0 != ":" }))
    }
}

/// A PKCE verifier/challenge pair (RFC 7636). The verifier is a high-entropy secret
/// kept in memory during the flow; the challenge (S256) travels in the auth URL.
public struct PKCE: Equatable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = PKCE.challenge(for: verifier)
    }

    /// code_challenge = BASE64URL(SHA256(code_verifier)) — RFC 7636 §4.2.
    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// A fresh pair with a 43-char base64url verifier (32 bytes of entropy).
    public static func generate() -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return PKCE(verifier: base64URL(Data(bytes)))
    }
}

/// An OAuth token set with a computed absolute expiry.
public struct OAuthToken: Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date
    public let scope: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, scope: String?) {
        self.accessToken = accessToken; self.refreshToken = refreshToken
        self.expiresAt = expiresAt; self.scope = scope
    }

    /// Usable now, with a refresh-ahead margin (default 60s) so a request never goes
    /// out on a token about to expire mid-flight.
    public func isValid(now: Date = Date(), refreshMargin: TimeInterval = 60) -> Bool {
        now.addingTimeInterval(refreshMargin) < expiresAt
    }
}

public enum GoogleOAuth {
    static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    /// The authorization URL to present in ASWebAuthenticationSession. `access_type
    ///=offline` + `prompt=consent` ensure a refresh_token comes back so the app can
    /// keep working without re-prompting.
    public static func authorizationURL(config: OAuthConfig, pkce: PKCE, state: String) -> URL {
        var comps = URLComponents(url: authEndpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "client_id", value: config.clientId),
            .init(name: "redirect_uri", value: config.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: config.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        return comps.url!
    }

    /// Exchange an authorization code for tokens. Public client → no client_secret.
    public static func tokenExchangeRequest(config: OAuthConfig, code: String, pkce: PKCE) -> HTTPRequestSpec {
        formPost([
            ("client_id", config.clientId),
            ("code", code),
            ("code_verifier", pkce.verifier),
            ("grant_type", "authorization_code"),
            ("redirect_uri", config.redirectURI),
        ])
    }

    /// Refresh an access token with a stored refresh_token.
    public static func refreshRequest(config: OAuthConfig, refreshToken: String) -> HTTPRequestSpec {
        formPost([
            ("client_id", config.clientId),
            ("refresh_token", refreshToken),
            ("grant_type", "refresh_token"),
        ])
    }

    /// Parse a token endpoint response. `expires_in` is relative → stamp an absolute
    /// `expiresAt` off `now`. A refresh response omits `refresh_token`; callers keep
    /// the previously-stored one.
    public static func parseTokenResponse(_ data: Data, now: Date = Date()) throws -> OAuthToken {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthError.malformedTokenResponse
        }
        if let err = obj["error"] as? String {
            throw OAuthError.server(error: err, description: obj["error_description"] as? String)
        }
        guard let access = obj["access_token"] as? String else { throw OAuthError.malformedTokenResponse }
        let expiresIn = (obj["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return OAuthToken(
            accessToken: access,
            refreshToken: obj["refresh_token"] as? String,
            expiresAt: now.addingTimeInterval(expiresIn),
            scope: obj["scope"] as? String
        )
    }

    private static func formPost(_ fields: [(String, String)]) -> HTTPRequestSpec {
        HTTPRequestSpec(
            method: .post,
            url: tokenEndpoint,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(formURLEncode(fields).utf8)
        )
    }
}

public enum OAuthError: Error, Equatable {
    case malformedTokenResponse
    case server(error: String, description: String?)
}

// ── encoding helpers ──────────────────────────────────────────────────────────

/// base64url without padding (RFC 4648 §5) — for PKCE verifier/challenge.
func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// application/x-www-form-urlencoded body. Percent-encode with a strict unreserved
/// set so `+`, `/`, `=` in codes/ids survive intact.
func formURLEncode(_ fields: [(String, String)]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
    return fields.map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "&")
}
