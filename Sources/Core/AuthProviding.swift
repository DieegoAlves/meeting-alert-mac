// OWNER: Core (frozen contract — do NOT edit after scaffold).
// Sync depends on THIS protocol, never on Auth's concrete files.
import Foundation

public protocol AuthProviding: AnyObject, Sendable {
    /// Returns a fresh access token, refreshing silently if needed.
    func validAccessToken() async throws -> String
    var isAuthorized: Bool { get async }
    func signIn() async throws
    func signOut() async throws
    /// F-042: drop the in-memory access-token cache so the next `validAccessToken()`
    /// re-fetches via the refresh token. A Sync caller that sees an HTTP 401 calls this
    /// before retrying, otherwise the same rejected token is reused for up to ~59 min.
    func invalidateAccessToken() async
}
