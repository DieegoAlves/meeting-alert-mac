// OWNER: Core. Shared infrastructure (like SyncStatusCenter / CalendarCatalog): the single source
// of truth for "are we connected, until when is the access token valid, did the last silent refresh
// work" (F-059). Auth WRITES token validity + refresh outcome; Sync WRITES the connected e-mail
// (the primary calendar id IS the account address); Prefs READS it for the status line.
//
// Additive shared surface — not part of the frozen EventStore contract.
import Foundation
import Combine

/// Snapshot of the current authentication state. Persisted to UserDefaults so the Preferences
/// window shows it immediately on open, even before the first sync/refresh of the session.
public struct AuthStatusSnapshot: Codable, Sendable, Equatable {
    /// The signed-in account's e-mail (Google's primary calendar id), when known.
    public var connectedEmail: String?
    /// When the currently-cached access token expires (drives "token válido até HH:MM").
    public var tokenValidUntil: Date?
    /// Outcome of the last token exchange/refresh: true OK, false failed, nil unknown yet.
    public var lastRefreshOK: Bool?
    /// Whether a refresh token is stored (i.e. silent refresh is possible without a browser).
    public var hasRefreshToken: Bool

    public init(
        connectedEmail: String? = nil,
        tokenValidUntil: Date? = nil,
        lastRefreshOK: Bool? = nil,
        hasRefreshToken: Bool = false
    ) {
        self.connectedEmail = connectedEmail
        self.tokenValidUntil = tokenValidUntil
        self.lastRefreshOK = lastRefreshOK
        self.hasRefreshToken = hasRefreshToken
    }
}

@MainActor
public final class AuthStatusCenter: ObservableObject {
    public static let shared = AuthStatusCenter()

    private static let defaultsKey = "MeetingAlertAuthStatus"

    @Published public private(set) var snapshot: AuthStatusSnapshot

    public init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(AuthStatusSnapshot.self, from: data) {
            snapshot = decoded
        } else {
            snapshot = AuthStatusSnapshot()
        }
    }

    /// Auth layer: a token exchange/refresh just happened. `validUntil == nil` + `refreshOK == false`
    /// means the refresh token was rejected (re-auth needed).
    public func recordToken(validUntil: Date?, refreshOK: Bool?, hasRefreshToken: Bool) {
        var s = snapshot
        s.tokenValidUntil = validUntil
        s.lastRefreshOK = refreshOK
        s.hasRefreshToken = hasRefreshToken
        commit(s)
    }

    /// Sync layer: the account's primary-calendar id (== the e-mail address).
    public func recordConnectedEmail(_ email: String?) {
        guard let email, !email.isEmpty else { return }
        var s = snapshot
        s.connectedEmail = email
        commit(s)
    }

    /// Cleared on explicit sign-out.
    public func recordSignedOut() {
        commit(AuthStatusSnapshot())
    }

    private func commit(_ s: AuthStatusSnapshot) {
        guard s != snapshot else { return }
        snapshot = s
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
