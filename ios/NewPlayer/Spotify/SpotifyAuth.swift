import AuthenticationServices
import CryptoKit
import Foundation

/// Spotify sign-in, as Authorization Code with PKCE.
///
/// Deliberately never sees an account password: Spotify's terms forbid a third-party app
/// collecting them, and there is no API that would accept one. The user signs in on Spotify's
/// own page in a system browser sheet, and this only ever holds the tokens that come back.
@MainActor
protocol SpotifyAuthorizing {
    /// Runs the browser sign-in and returns an access token.
    func signIn(clientID: String) async throws -> SpotifyTokens
    /// Exchanges a refresh token for a fresh access token.
    func refresh(clientID: String, refreshToken: String) async throws -> SpotifyTokens
}

struct SpotifyTokens: Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    /// The scopes Spotify actually granted. Kept because a token carries the permissions it was
    /// issued with for life: adding a scope to the app does not widen an existing token, and
    /// refreshing preserves the original set. Without checking this, a token from before the
    /// playback scopes existed keeps being reused and every player call comes back 401.
    var scopes: Set<String> = SpotifyAuth.requiredScopes

    var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-60) }

    /// Whether this token can do everything the app now needs.
    var hasAllRequiredScopes: Bool { SpotifyAuth.requiredScopes.isSubset(of: scopes) }
}

@MainActor
final class SpotifyAuth: NSObject, SpotifyAuthorizing {
    /// Must match a redirect URI registered against the client ID in Spotify's dashboard, and
    /// the URL scheme declared in Info.plist.
    static let redirectURI = "newplayer://spotify-callback"
    private static let callbackScheme = "newplayer"

    /// user-library-read covers saved tracks and albums; user-read-private carries the
    /// `product` field the Premium check reads; the two playback scopes are what Connect needs
    /// to read and drive whichever Spotify client is currently active.
    static let requiredScopes: Set<String> = [
        "user-library-read",
        "user-read-private",
        "user-read-playback-state",
        "user-modify-playback-state",
    ]

    private static var scopes: String { requiredScopes.sorted().joined(separator: " ") }

    private let session: URLSession
    /// Held so the session isn't deallocated mid-flow, which cancels it.
    private var presentedSession: ASWebAuthenticationSession?

    init(session: URLSession? = nil) {
        // Explicit timeouts. A token request on the shared session inherits a seven-day resource
        // timeout, and because one SpotifySession serialises every token request in the app, a
        // stalled refresh takes playback, the device list and the sync down with it.
        self.session = session ?? {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            // Never serve a token exchange from a cache.
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            return URLSession(configuration: configuration)
        }()
    }

    func signIn(clientID: String) async throws -> SpotifyTokens {
        guard !clientID.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw SpotifyError.missingClientID
        }

        let verifier = Self.makeCodeVerifier()
        let challenge = Self.codeChallenge(for: verifier)

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "scope", value: Self.scopes),
        ]

        let callbackURL = try await authorize(url: components.url!)
        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw SpotifyError.authorizationFailed("no authorization code in the response")
        }

        return try await requestTokens(form: [
            "client_id": clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "code_verifier": verifier,
        ])
    }

    func refresh(clientID: String, refreshToken: String) async throws -> SpotifyTokens {
        var tokens = try await requestTokens(form: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])
        // Spotify may not return a new refresh token; keep the one we have.
        if tokens.refreshToken == nil { tokens.refreshToken = refreshToken }
        return tokens
    }

    private func authorize(url: URL) async throws -> URL {
        // Deliberately no "already presenting" guard here. One was added while chasing a freeze
        // that turned out to be elsewhere — a background poll reaching sign-in, now impossible
        // since polling is non-interactive — and a flag like that only has to get stuck once to
        // refuse every future sign-in, with nothing the user can do about it.
        guard presentationWindow() != nil else {
            throw SpotifyError.authorizationFailed("the app isn't on screen to sign in")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: Self.callbackScheme
            ) { callbackURL, error in
                if let error {
                    let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    continuation.resume(throwing: cancelled
                        ? SpotifyError.authorizationCancelled
                        : SpotifyError.authorizationFailed(error.localizedDescription))
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: SpotifyError.authorizationFailed("no callback"))
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                continuation.resume(throwing: SpotifyError.authorizationFailed("couldn't open the sign-in page"))
            }
            self.presentedSession = session
        }
    }

    private func requestTokens(form: [String: String]) async throws -> SpotifyTokens {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SpotifyError.authorizationFailed("token request rejected — \(body)")
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int
            let scope: String?
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        return SpotifyTokens(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token,
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in)),
            scopes: Set((decoded.scope ?? "").split(separator: " ").map(String.init))
        )
    }

    // MARK: - PKCE

    static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

extension SpotifyAuth {
    /// The window to present the sign-in sheet over.
    ///
    /// Falls back through progressively weaker matches rather than insisting on a foreground-
    /// active scene with a key window: that stricter test can fail during a UI transition, and
    /// refusing to sign in because a scene was momentarily inactive is worse than presenting
    /// over a window that turns out to be a slightly odd choice.
    func presentationWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }

        if let active = scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow {
            return active
        }
        if let anyKeyWindow = scenes.compactMap(\.keyWindow).first {
            return anyKeyWindow
        }
        return scenes.flatMap(\.windows).first
    }
}

extension SpotifyAuth: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        presentationWindow() ?? ASPresentationAnchor()
    }
}

extension Data {
    /// Base64url, as PKCE requires: no padding, URL-safe alphabet.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
