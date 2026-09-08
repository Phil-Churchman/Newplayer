import Foundation

/// Keeps a usable access token to hand: reuses a stored one while it lasts, refreshes it
/// silently when it doesn't, and only opens the browser when there is nothing to work with.
///
/// Shared by the library import and by playback so both agree on one token and one refresh —
/// two independent refreshes would race and invalidate each other.
@MainActor
final class SpotifySession {
    /// One session for the whole app. The library import and the playback poll both need tokens,
    /// and with an instance each their refreshes race: Spotify rotates the refresh token, so the
    /// second refresh presents one the first has already invalidated, which fails, which falls
    /// through to an interactive sign-in from a background poll. Sharing one session is what
    /// makes the coalescing below actually coalesce.
    static let shared = SpotifySession(auth: SpotifyAuth(), tokens: SpotifyKeychainTokenStore())

    private let auth: SpotifyAuthorizing
    private let tokens: SpotifyTokenStoring
    private let refreshDeadline: TimeInterval
    private var refreshInFlight: Task<String, Error>?
    /// Whether the in-flight attempt is allowed to open a sign-in page. A background attempt's
    /// refusal must not be handed to a caller who *could* have signed in — with the playback
    /// poll running every couple of seconds, a sync would otherwise keep inheriting the poll's
    /// "not signed in" and could never get to the sign-in page it needed.
    private var inFlightIsInteractive = false

    init(
        auth: SpotifyAuthorizing,
        tokens: SpotifyTokenStoring,
        refreshDeadline: TimeInterval = SpotifySession.refreshDeadlineSeconds
    ) {
        self.auth = auth
        self.tokens = tokens
        self.refreshDeadline = refreshDeadline
    }

    var hasStoredTokens: Bool { tokens.load() != nil }

    /// - Parameter interactive: whether this caller may put Spotify's sign-in page on screen.
    ///   False for anything the user didn't just ask for — above all the playback poll, which
    ///   runs every couple of seconds. A poll that can sign in will try to present a web sheet
    ///   from the background, repeatedly, and a presentation that never completes leaves the
    ///   continuation below suspended forever, taking every later token request down with it.
    func accessToken(clientID: String, interactive: Bool = true) async throws -> String {
        // Coalesce: several callers hitting an expired token at once should produce one refresh.
        // An interactive caller may only join an attempt that is itself interactive; otherwise
        // it waits for that one to finish and then tries properly on its own.
        if let refreshInFlight, inFlightIsInteractive || !interactive {
            return try await refreshInFlight.value
        }
        if let refreshInFlight {
            _ = try? await refreshInFlight.value
            if let stored = tokens.load(), !stored.isExpired, stored.hasAllRequiredScopes {
                return stored.accessToken
            }
        }

        let stored = tokens.load()

        // A token issued before a scope was added never gains it — not by reuse, and not by
        // refresh. Only a fresh authorization will do, so re-sign-in rather than handing out a
        // token that will be refused.
        let needsWiderPermissions = stored.map { !$0.hasAllRequiredScopes } ?? false

        if let stored, !stored.isExpired, !needsWiderPermissions {
            return stored.accessToken
        }

        let deadline = refreshDeadline
        let task = Task<String, Error> { [auth, tokens] in
            if !needsWiderPermissions,
               let stored = tokens.load(), stored.isExpired, let refreshToken = stored.refreshToken,
               let refreshed = try? await Self.withDeadline(
                   seconds: deadline,
                   operation: { try await auth.refresh(clientID: clientID, refreshToken: refreshToken) }
               ),
               refreshed.hasAllRequiredScopes {
                tokens.save(refreshed)
                return refreshed.accessToken
            }
            // Only a person's own action gets to open a browser.
            guard interactive else { throw SpotifyError.notSignedIn }
            let fresh = try await auth.signIn(clientID: clientID)
            tokens.save(fresh)
            return fresh.accessToken
        }
        refreshInFlight = task
        inFlightIsInteractive = interactive
        defer {
            refreshInFlight = nil
            inFlightIsInteractive = false
        }
        return try await task.value
    }

    /// A refresh happens without anyone watching, so it must not be able to run long. Interactive
    /// sign-in is deliberately *not* bounded this way: a person may take minutes over it.
    static let refreshDeadlineSeconds: TimeInterval = 20

    /// Races an operation against a deadline. Whichever finishes first wins; the loser is
    /// cancelled inside the group, since a task group cannot return until its children are done.
    private static func withDeadline<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SpotifyError.requestFailed("timed out")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw SpotifyError.requestFailed("no result")
            }
            return first
        }
    }

    func signOut() {
        tokens.clear()
    }

    /// Drops the stored token so the next request signs in again. Used when Spotify rejects a
    /// token it previously issued — most often because the app now asks for more than the token
    /// was granted.
    func discardStoredTokens() {
        tokens.clear()
    }
}
