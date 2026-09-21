// OWNER: Auth module. AuthProviding implementation — Google OAuth 2.0 PKCE (S256) + loopback redirect.
// Client ID is read at runtime from UserDefaults key "MeetingAlertOAuthClientID".
// Never hardcoded. Missing ID → AuthError.missingClientID (surface in Preferences UI, do not crash).
import Foundation
import AppKit
import Core

// MARK: - Public error type (usable by App composition root and Prefs for targeted UI)

public enum AuthError: Error, LocalizedError, Sendable {
    case missingClientID
    case notAuthorized
    case tokenExchangeFailed(statusCode: Int, detail: String?)
    case tokenRefreshFailed(statusCode: Int, detail: String?)
    case loopbackFailed(String)
    case badServerResponse
    case secureRandomFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Nenhum cliente OAuth configurado. Este build não tem credenciais embutidas: abra Preferências → Google OAuth, ative \"Usar meu próprio client OAuth\" e cole o Client ID + Secret de um cliente \"App para computador\" (veja o README)."
        case .notAuthorized:
            return "Not signed in. Use Preferences → Sign In to authorize Google Calendar access."
        case .tokenExchangeFailed(let code, let detail):
            let base = "Authorization code exchange failed (HTTP \(code))."
            return detail.map { "\(base) \($0)" } ?? base
        case .tokenRefreshFailed(let code, let detail):
            let base = "Token refresh failed (HTTP \(code)). Please sign in again via Preferences."
            return detail.map { "\(base) \($0)" } ?? base
        case .loopbackFailed(let detail):
            return "OAuth redirect error: \(detail)"
        case .badServerResponse:
            return "Unexpected server response during authentication."
        case .secureRandomFailed(let status):
            return "Secure random generation failed (OSStatus \(status)); sign-in aborted to avoid a weak PKCE verifier."
        }
    }
}

// MARK: - Sign-in diagnostics surface (F-056)

/// Cross-module notifications + UserDefaults keys the Auth layer uses to surface the exact
/// OAuth failure (and the authorize URL we opened, with client_id truncated) to the Preferences
/// window. Prefs observes the raw notification names (no Auth import needed) and also reads the
/// last-known values from UserDefaults when the window opens after a failure.
public enum AuthDiagnostics {
    /// Posted when an interactive sign-in fails or the loopback callback carries an error.
    /// userInfo: [messageKey: String, urlKey: String].
    public static let signInFailedNotification    = Notification.Name("Auth.signInFailed")
    /// Posted when a sign-in completes successfully so any open UI can clear the error.
    public static let signInSucceededNotification = Notification.Name("Auth.signInSucceeded")

    public static let messageKey = "message"
    public static let urlKey     = "url"

    /// UserDefaults keys mirroring the last failure so the Preferences window can show it
    /// even if it was opened *after* the failure happened.
    public static let lastErrorDefaultsKey = "MeetingAlertLastAuthError"
    public static let lastURLDefaultsKey   = "MeetingAlertLastAuthURL"
}

// MARK: - Token endpoint error classification (F-041)

/// Raised by `postToTokenEndpoint` on any non-200. Distinguishes an *authoritative*
/// credential failure (the refresh token is truly dead → must re-auth) from a
/// *transient* failure (429/5xx → recoverable, keep the token and retry next poll).
private struct TokenEndpointError: Error {
    let statusCode: Int
    /// `invalid_grant` (HTTP 400) or HTTP 401 — the refresh token is no longer valid.
    let isAuthoritativeAuthFailure: Bool
    /// F-057: Google's exact error text ("invalid_request — client_secret is missing"), for UI.
    var detail: String? = nil
}

// MARK: - Private response model

private struct TokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int
    let refreshToken: String?
    let tokenType: String
    /// F-060: the scopes Google actually GRANTED for this token (space-separated). Google returns
    /// this on both the code-exchange AND the refresh response. We log it and compare it to what the
    /// app needs — a granted scope narrower than the request means a stale grant that must be redone.
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken  = "access_token"
        case expiresIn    = "expires_in"
        case refreshToken = "refresh_token"
        case tokenType    = "token_type"
        case scope        = "scope"
    }
}

// MARK: - GoogleAuth

public actor GoogleAuth: AuthProviding {
    /// UserDefaults key where the caller stores the Google OAuth Desktop-app client ID.
    public static let clientIDDefaultsKey = "MeetingAlertOAuthClientID"
    /// F-057: Google's token endpoint REQUIRES `client_secret` for a "Desktop app" client even with
    /// PKCE — omitting it makes the code→token exchange fail with HTTP 400, which is why login
    /// "worked" (consent + loopback code) but no token was ever stored → not authorized → zero
    /// events.
    ///
    /// F-058 (security): the secret is stored in the KEYCHAIN (next to the refresh token), NEVER in
    /// UserDefaults/JSON in plaintext. `clientSecretLegacyDefaultsKey` exists only so a value saved
    /// by the first F-057 build is migrated into the Keychain and then deleted.
    public static let clientSecretKeychainAccount   = "google.client_secret"
    public static let clientSecretLegacyDefaultsKey = "MeetingAlertOAuthClientSecret"
    /// Non-secret boolean flag so the Preferences UI (which has no Keychain access) can show that a
    /// secret is already stored without ever reading the secret itself. F-058.
    public static let hasClientSecretDefaultsKey    = "MeetingAlertHasClientSecret"

    /// Persist the Desktop-app client secret to the Keychain (called from the App layer when the
    /// user saves it in Preferences). Sets the non-secret "has secret" flag for the UI. F-058.
    public nonisolated static func saveClientSecret(_ secret: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // F-059: persisted to the file store (0600), not the Keychain — an ad-hoc-signed binary
        // loses Keychain access on every rebuild, which forced the repeated re-login.
        try? CredentialStore.saveString(trimmed, account: clientSecretKeychainAccount)
        UserDefaults.standard.set(true, forKey: hasClientSecretDefaultsKey)
        // Belt-and-suspenders: ensure no plaintext copy lingers.
        UserDefaults.standard.removeObject(forKey: clientSecretLegacyDefaultsKey)
    }

    private static let keychainAccount = "google.refresh_token"
    /// F-060: the scope MUST cover `calendarList.list` (the FIRST call every sync makes, added in
    /// F-053) AND `events.list`. `calendar.events.readonly` grants ONLY events — it does NOT grant
    /// calendarList, so calendarList.list returned HTTP 403 `insufficientPermissions` ("Request had
    /// insufficient authentication scopes"). `calendar.readonly` covers BOTH read paths (calendarList
    /// + events) with one grant. This was never widened when F-053 introduced the calendar-list fetch.
    private static let scope           = "https://www.googleapis.com/auth/calendar.readonly"
    /// F-060: scopes that actually grant `calendarList.list`. Used to detect a STALE token that was
    /// granted under the old narrow `events.readonly` scope and must be discarded + re-consented.
    private static let calendarListGrantingScopes: Set<String> = [
        "https://www.googleapis.com/auth/calendar.readonly",
        "https://www.googleapis.com/auth/calendar",
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
        "https://www.googleapis.com/auth/calendar.calendarlist",
    ]
    private static let authEndpoint    = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenEndpoint   = "https://oauth2.googleapis.com/token"
    private static let revokeEndpoint  = "https://oauth2.googleapis.com/revoke"

    private struct CachedToken: Sendable {
        let value: String
        let expiresAt: Date
        // Treat as expired 60 s early so callers always get a fresh token.
        var isValid: Bool { expiresAt > Date().addingTimeInterval(60) }
    }

    private var cachedToken: CachedToken?
    private var signingIn = false

    public init() {}

    // MARK: AuthProviding

    public var isAuthorized: Bool {
        get async { CredentialStore.loadString(account: Self.keychainAccount) != nil }
    }

    public func validAccessToken() async throws -> String {
        if let token = cachedToken, token.isValid { return token.value }

        if let refresh = CredentialStore.loadString(account: Self.keychainAccount) {
            return try await refreshAccessToken(using: refresh)
        }

        try await signIn()
        guard let token = cachedToken else { throw AuthError.notAuthorized }
        return token.value
    }

    public func signIn() async throws {
        // Guard against concurrent sign-in flows (actor serialises calls; a second call
        // while the first is awaiting waitForCode will see signingIn == true and bail).
        guard !signingIn else { return }
        signingIn = true
        defer { signingIn = false }

        let clientID  = try requireClientID()
        let verifier  = try PKCE.makeVerifier()
        let challenge = PKCE.challenge(for: verifier)
        let state     = UUID().uuidString

        let server = try await LoopbackRedirectServer.start()
        let redirectURI = "http://127.0.0.1:\(server.port)"

        var comps = URLComponents(string: Self.authEndpoint)!
        comps.queryItems = [
            .init(name: "client_id",            value: clientID),
            .init(name: "response_type",         value: "code"),
            .init(name: "redirect_uri",          value: redirectURI),
            .init(name: "scope",                 value: Self.scope),
            .init(name: "code_challenge",        value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state",                 value: state),
            .init(name: "access_type",           value: "offline"),
            // F-060: force a fresh consent so a token previously granted the narrow
            // `events.readonly` scope is re-granted with the widened `calendar.readonly`.
            .init(name: "prompt",                value: "consent"),
            .init(name: "include_granted_scopes", value: "true"),
        ]

        guard let authURL = comps.url else {
            server.cancel()
            throw AuthError.badServerResponse
        }

        // F-056: log the FULL authorize URL with client_id truncated, so a failed consent
        // (e.g. Google "Erro 400: invalid_request") can be diagnosed from the exact URL we opened.
        // Every other parameter is kept intact.
        let redactedURL = Self.redactClientID(in: authURL.absoluteString)
        NSLog("[MeetingAlert] OAuth authorize URL: \(redactedURL)")

        _ = await MainActor.run { NSWorkspace.shared.open(authURL) }

        do {
            let code = try await server.waitForCode(expectedState: state)
            try await exchangeCode(code, verifier: verifier, redirectURI: redirectURI, clientID: clientID)
            Self.clearSignInFailure()
        } catch {
            server.cancel()
            Self.recordSignInFailure(error, redactedURL: redactedURL)
            throw error
        }
    }

    // MARK: - F-056 diagnostics helpers

    /// Truncates the `client_id` value in an authorize URL for safe logging/display, keeping every
    /// other parameter byte-for-byte intact. Shows the project-number prefix + suffix so Diego can
    /// still tell WHICH client was used without leaking the whole id.
    static func redactClientID(in url: String) -> String {
        guard let range = url.range(of: "client_id=") else { return url }
        let after = url[range.upperBound...]
        let end   = after.firstIndex(of: "&") ?? after.endIndex
        let value = String(after[..<end])
        let redacted = value.count > 20 ? "\(value.prefix(13))…\(value.suffix(6))" : "…"
        return url.replacingOccurrences(of: "client_id=\(value)", with: "client_id=\(redacted)")
    }

    /// Persists + broadcasts the exact failure (message + the redacted authorize URL) so the
    /// Preferences window can show it instead of Diego having to guess.
    private static func recordSignInFailure(_ error: Error, redactedURL: String) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        NSLog("[MeetingAlert] OAuth falhou: \(message) — URL: \(redactedURL)")
        UserDefaults.standard.set(message, forKey: AuthDiagnostics.lastErrorDefaultsKey)
        UserDefaults.standard.set(redactedURL, forKey: AuthDiagnostics.lastURLDefaultsKey)
        NotificationCenter.default.post(
            name: AuthDiagnostics.signInFailedNotification,
            object: nil,
            userInfo: [AuthDiagnostics.messageKey: message, AuthDiagnostics.urlKey: redactedURL]
        )
    }

    /// Clears the last-failure surface after a successful sign-in.
    private static func clearSignInFailure() {
        UserDefaults.standard.removeObject(forKey: AuthDiagnostics.lastErrorDefaultsKey)
        UserDefaults.standard.removeObject(forKey: AuthDiagnostics.lastURLDefaultsKey)
        NotificationCenter.default.post(name: AuthDiagnostics.signInSucceededNotification, object: nil)
    }

    /// Drops the in-memory access-token cache so the next `validAccessToken()` re-fetches
    /// via the refresh token. F-042: a caller that sees an HTTP 401 from the Calendar API
    /// calls this before retrying, otherwise `validAccessToken()` keeps returning the same
    /// rejected token from cache for up to ~59 min.
    ///
    /// F-042 (integration): now part of the `AuthProviding` protocol, so `CalendarSyncService`
    /// (which only sees the protocol) can bust the cache after a 401. This actor-isolated
    /// synchronous method witnesses the protocol's `func invalidateAccessToken() async`
    /// requirement — cross-actor access is implicitly async.
    public func invalidateAccessToken() {
        cachedToken = nil
    }

    public func signOut() async throws {
        // Best-effort token revocation — don't throw if it fails.
        if let token = CredentialStore.loadString(account: Self.keychainAccount) {
            var req = URLRequest(url: URL(string: Self.revokeEndpoint)!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let encoded = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
            req.httpBody = "token=\(encoded)".data(using: .utf8)
            _ = try? await URLSession.shared.data(for: req)
        }
        cachedToken = nil
        try? CredentialStore.delete(account: Self.keychainAccount)
        await MainActor.run { AuthStatusCenter.shared.recordSignedOut() }
    }

    // MARK: - Private

    private func requireClientID() throws -> String {
        // F-065: resolve between the credentials embedded at build time and a client the user
        // supplied themselves (override toggle), via the shared Core resolver. F-055 trimming is
        // applied inside the resolver. Nothing configured → missingClientID (surfaced in the UI,
        // never a crash).
        guard let id = OAuthClientConfig.effectiveClientID else { throw AuthError.missingClientID }
        return id
    }

    /// The client SECRET for the CURRENTLY effective client (F-065): the embedded secret when the
    /// embedded client is in use, otherwise the user's secret from `credentials.json` (F-059).
    /// Resolving id and secret through the same override toggle keeps the pair consistent.
    ///
    /// Migrates a value left in UserDefaults by the first F-057 build into the file store, then
    /// wipes the plaintext copy — so an already-connected user keeps working with no residue.
    private func optionalClientSecret() -> String? {
        // Embedded client in use (override OFF) → its embedded secret is the matching one.
        if !OAuthClientConfig.useOwnClient, let embedded = OAuthClientConfig.embeddedClientSecret {
            return embedded
        }
        if let legacy = UserDefaults.standard.string(forKey: Self.clientSecretLegacyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !legacy.isEmpty {
            Self.saveClientSecret(legacy)   // → file store, sets flag, deletes the plaintext key
        }
        let s = CredentialStore.loadString(account: Self.clientSecretKeychainAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }

    private func exchangeCode(_ code: String, verifier: String, redirectURI: String, clientID: String) async throws {
        // F-057: Google's Desktop-app flow REQUIRES client_secret at the token endpoint (even with
        // PKCE). Include it whenever it's set; omitting it is what caused HTTP 400 here.
        var params = [
            "client_id":     clientID,
            "code":          code,
            "code_verifier": verifier,
            "grant_type":    "authorization_code",
            "redirect_uri":  redirectURI,
        ]
        if let secret = optionalClientSecret() { params["client_secret"] = secret }
        let body = formEncoded(params)
        let resp: TokenResponse
        do {
            resp = try await postToTokenEndpoint(body: body)
        } catch let e as TokenEndpointError {
            throw AuthError.tokenExchangeFailed(statusCode: e.statusCode, detail: e.detail)
        }
        // F-060: log the scope Google actually granted and verify it covers calendarList.list. A
        // fresh consent under the widened scope should always pass; a failure here means the consent
        // screen was answered with a narrower grant — surface it instead of storing a dead token.
        NSLog("[MeetingAlert] Token exchange granted scope: \(resp.scope ?? "<none>")")
        guard Self.scopeCoversCalendarList(resp.scope) else {
            NSLog("[MeetingAlert] Consent granted insufficient scope (\(resp.scope ?? "<none>")) — needs \(Self.scope). Não armazenando token.")
            throw AuthError.tokenExchangeFailed(
                statusCode: 200,
                detail: "Escopo concedido insuficiente (\(resp.scope ?? "vazio")). Reconecte e conceda acesso ao Google Calendar (calendar.readonly).")
        }
        if let refresh = resp.refreshToken {
            try CredentialStore.saveString(refresh, account: Self.keychainAccount)
        }
        let expiresAt = Date().addingTimeInterval(Double(resp.expiresIn))
        cachedToken = CachedToken(value: resp.accessToken, expiresAt: expiresAt)
        await Self.publishAuthStatus(validUntil: expiresAt, refreshOK: true)
    }

    /// F-060: does the granted `scope` string include a scope that grants `calendarList.list`?
    /// A `nil`/empty scope is treated as OK (some endpoints omit it) to avoid destroying a working
    /// credential on a missing field — the API-side 403 handler is the backstop for that case.
    private static func scopeCoversCalendarList(_ granted: String?) -> Bool {
        guard let granted, !granted.isEmpty else { return true }
        let scopes = Set(granted.split(separator: " ").map(String.init))
        return !scopes.isDisjoint(with: calendarListGrantingScopes)
    }

    private func refreshAccessToken(using refreshToken: String) async throws -> String {
        let clientID = try requireClientID()
        var params = [
            "client_id":     clientID,
            "grant_type":    "refresh_token",
            "refresh_token": refreshToken,
        ]
        if let secret = optionalClientSecret() { params["client_secret"] = secret }  // F-057
        let body = formEncoded(params)
        do {
            let resp = try await postToTokenEndpoint(body: body)
            // F-060: a refresh token minted under the OLD narrow `events.readonly` scope keeps
            // returning access tokens scoped to `events.readonly` even after the app widened the
            // requested scope — refresh tokens carry the scope from their ORIGINAL consent. That
            // stale token cannot call calendarList.list (403 insufficientPermissions on every sync).
            // Detect it from the granted scope, DISCARD the credential, and force a one-time
            // re-consent under the widened scope. This is the automatic remediation for Diego's
            // just-created (narrow) token.
            NSLog("[MeetingAlert] Token refresh granted scope: \(resp.scope ?? "<none>")")
            if !Self.scopeCoversCalendarList(resp.scope) {
                NSLog("[MeetingAlert] Refresh token has stale scope (\(resp.scope ?? "<none>")) — descartando credencial e exigindo reconexão.")
                cachedToken = nil
                try? CredentialStore.delete(account: Self.keychainAccount)
                await Self.publishAuthStatus(validUntil: nil, refreshOK: false)
                throw AuthError.tokenRefreshFailed(
                    statusCode: 403,
                    detail: "Escopo insuficiente (\(resp.scope ?? "vazio")). Reconecte em 'Conectar Google' para conceder calendar.readonly.")
            }
            if let newRefresh = resp.refreshToken {
                try CredentialStore.saveString(newRefresh, account: Self.keychainAccount)
            }
            let expiresAt = Date().addingTimeInterval(Double(resp.expiresIn))
            let token = CachedToken(value: resp.accessToken, expiresAt: expiresAt)
            cachedToken = token
            await Self.publishAuthStatus(validUntil: expiresAt, refreshOK: true)
            return token.value
        } catch let e as TokenEndpointError {
            // F-041: only an authoritative failure (invalid_grant / 401) means the refresh
            // token is truly dead — wipe it and force interactive re-auth. A transient
            // 429/5xx is recoverable: keep the refresh token, drop only the cached access
            // token, and rethrow so the next scheduled poll retries.
            cachedToken = nil
            if e.isAuthoritativeAuthFailure {
                try? CredentialStore.delete(account: Self.keychainAccount)
                // F-059: refresh token is dead → surface "refresh erro" + no valid token.
                await Self.publishAuthStatus(validUntil: nil, refreshOK: false)
            }
            throw AuthError.tokenRefreshFailed(statusCode: e.statusCode, detail: e.detail)
        } catch {
            // Network/other transient error — never destroy the credential; retry next poll.
            cachedToken = nil
            throw error
        }
    }

    /// F-059: publish token validity + refresh outcome to the shared `AuthStatusCenter` so the
    /// Preferences status line ("Conectado como … · token válido até HH:MM · refresh OK/erro")
    /// reflects reality. `nonisolated` + reads the file store off the actor; hops to the main actor
    /// for the @Published mutation.
    private nonisolated static func publishAuthStatus(validUntil: Date?, refreshOK: Bool?) async {
        let hasRefresh = CredentialStore.loadString(account: keychainAccount) != nil
        await MainActor.run {
            AuthStatusCenter.shared.recordToken(validUntil: validUntil,
                                                refreshOK: refreshOK,
                                                hasRefreshToken: hasRefresh)
        }
    }

    private func postToTokenEndpoint(body: String) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: Self.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuthError.badServerResponse }
        guard http.statusCode == 200 else {
            // F-041: classify the OAuth failure. Only `invalid_grant` (400) or 401 are
            // authoritative "credential is dead" signals; 429/5xx are transient/recoverable.
            let oauthError = Self.parseOAuthError(from: data)
            let authoritative = http.statusCode == 401
                || (http.statusCode == 400 && oauthError == "invalid_grant")
            // F-057: capture Google's EXACT token-endpoint error (e.g. "invalid_request —
            // client_secret is missing") so it reaches the Preferences window instead of a bare
            // "HTTP 400". Body shape: {"error":"…","error_description":"…"}.
            let detail = Self.parseOAuthErrorDetail(from: data)
            NSLog("[MeetingAlert] Token endpoint HTTP \(http.statusCode): \(detail ?? "<no body>")")
            throw TokenEndpointError(statusCode: http.statusCode,
                                     isAuthoritativeAuthFailure: authoritative,
                                     detail: detail)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    /// Extracts the OAuth 2.0 `error` code (e.g. "invalid_grant") from a token-endpoint
    /// error body, if present. Returns nil for empty/non-JSON bodies.
    private static func parseOAuthError(from data: Data) -> String? {
        struct OAuthErrorBody: Decodable { let error: String? }
        return (try? JSONDecoder().decode(OAuthErrorBody.self, from: data))?.error
    }

    /// F-057: builds a human "error — error_description" string from a token-endpoint error body,
    /// falling back to the raw body text. Used to surface the EXACT reason for an HTTP 400/401.
    private static func parseOAuthErrorDetail(from data: Data) -> String? {
        struct Body: Decodable { let error: String?; let error_description: String? }
        if let b = try? JSONDecoder().decode(Body.self, from: data), (b.error != nil || b.error_description != nil) {
            switch (b.error, b.error_description) {
            case let (e?, d?): return "\(e) — \(d)"
            case let (e?, nil): return e
            case let (nil, d?): return d
            default: break
            }
        }
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty == false) ? raw : nil
    }

    private func formEncoded(_ params: [String: String]) -> String {
        params.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v)"
        }.joined(separator: "&")
    }
}
