import Foundation
import AuthenticationServices
import DeckCheckCore

// OAuth sign-in shell (spec §8.2). Presents the authorization URL that GoogleOAuth
// built in ASWebAuthenticationSession, captures the reversed-client-id redirect
// (no Info.plist URL-scheme registration needed — ASWebAuthenticationSession
// intercepts the callbackURLScheme itself), exchanges the code for tokens, and
// keeps a valid access token available (refreshing on demand). PKCE + all request
// construction live in DeckCheckCore; this is the device glue.

@MainActor
final class GoogleAuthService: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let config: OAuthConfig
    private let http: SheetsAPIHTTP
    private let store: KeychainTokenStore
    private var session: ASWebAuthenticationSession?

    init(config: OAuthConfig, http: SheetsAPIHTTP = SheetsAPIHTTP(), store: KeychainTokenStore = KeychainTokenStore()) {
        self.config = config; self.http = http; self.store = store
    }

    var isSignedIn: Bool { store.load() != nil }
    func signOut() { store.clear() }

    /// Full interactive sign-in: PKCE + state → present the consent screen → exchange
    /// the returned code for tokens → persist them.
    func signIn() async throws {
        let pkce = PKCE.generate()
        let state = UUID().uuidString
        let authURL = GoogleOAuth.authorizationURL(config: config, pkce: pkce, state: state)

        let callback = try await present(authURL)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ n: String) -> String? { items.first { $0.name == n }?.value }
        if let err = q("error") { throw AuthError.consentDenied(err) }
        guard q("state") == state else { throw AuthError.stateMismatch }
        guard let code = q("code") else { throw AuthError.noCode }

        let data = try await http.execute(GoogleOAuth.tokenExchangeRequest(config: config, code: code, pkce: pkce))
        try store.save(try GoogleOAuth.parseTokenResponse(data))
    }

    /// A currently-valid access token, refreshing if the stored one is near expiry.
    /// Throws `.notSignedIn` (do interactive sign-in) if there's no usable token.
    func validAccessToken() async throws -> String {
        guard let token = store.load() else { throw AuthError.notSignedIn }
        if token.isValid() { return token.accessToken }
        guard let refresh = token.refreshToken else { throw AuthError.notSignedIn }

        let data = try await http.execute(GoogleOAuth.refreshRequest(config: config, refreshToken: refresh))
        let refreshed = try GoogleOAuth.parseTokenResponse(data)
        // A refresh response omits refresh_token — keep the one we already have.
        let merged = OAuthToken(accessToken: refreshed.accessToken,
                                refreshToken: refreshed.refreshToken ?? refresh,
                                expiresAt: refreshed.expiresAt,
                                scope: refreshed.scope ?? token.scope)
        try store.save(merged)
        return merged.accessToken
    }

    // MARK: ASWebAuthenticationSession

    private func present(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: config.redirectScheme
            ) { callbackURL, error in
                if let callbackURL { continuation.resume(returning: callbackURL) }
                else if let error { continuation.resume(throwing: error) }
                else { continuation.resume(throwing: AuthError.noCode) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() { continuation.resume(throwing: AuthError.cannotPresent) }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.keyWindow ?? ASPresentationAnchor()
    }

    enum AuthError: LocalizedError {
        case notSignedIn, stateMismatch, noCode, cannotPresent
        case consentDenied(String)
        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "Not signed in. Tap Sign in with Google."
            case .stateMismatch: return "Sign-in state mismatch — please try again."
            case .noCode: return "No authorization code returned."
            case .cannotPresent: return "Couldn't present the sign-in screen."
            case let .consentDenied(e): return "Sign-in was cancelled or denied (\(e))."
            }
        }
    }
}
