// OWNER: Core (shared contract). Single source of truth for WHICH Google OAuth client the app
// uses, resolving between the credentials EMBEDDED at build time (Secrets.swift, F-065) and a
// client the user supplies themselves (Preferences → "Usar meu próprio client OAuth").
//
// F-065 distribution model:
//  • Default (override OFF): use the embedded Client ID + Secret so anyone who downloads the DMG
//    can sign in immediately, with no Google Cloud project of their own.
//  • Override ON ("Usar meu próprio client OAuth"): use the Client ID (UserDefaults) + Client
//    Secret (credentials.json, F-059) the user pasted, ignoring the embedded pair.
//  • Neither embedded NOR user-provided → `effectiveClientID == nil`; callers surface a clear
//    setup instruction instead of failing (AuthError.missingClientID).
import Foundation

public enum OAuthClientConfig {
    /// UserDefaults bool: user opted to use their OWN OAuth client instead of the embedded one.
    public static let useOwnClientDefaultsKey = "MeetingAlertUseOwnOAuthClient"
    /// UserDefaults string: the user-supplied Desktop-app Client ID (public value). Mirrors
    /// `GoogleAuth.clientIDDefaultsKey`.
    public static let clientIDDefaultsKey = "MeetingAlertOAuthClientID"
    /// UserDefaults bool: a user Client Secret is stored (in credentials.json, never here).
    /// Mirrors `GoogleAuth.hasClientSecretDefaultsKey`.
    public static let hasClientSecretDefaultsKey = "MeetingAlertHasClientSecret"

    // MARK: Embedded (build-time) credentials

    public static var embeddedClientID: String? { Secrets.googleClientID?.trimmedNonEmpty }
    public static var embeddedClientSecret: String? { Secrets.googleClientSecret?.trimmedNonEmpty }
    /// True when this build shipped with an embedded Client ID (a distributed DMG normally has one).
    public static var hasEmbeddedCredentials: Bool { embeddedClientID != nil }

    // MARK: User-supplied credentials

    public static var useOwnClient: Bool {
        UserDefaults.standard.bool(forKey: useOwnClientDefaultsKey)
    }
    public static var userClientID: String? {
        UserDefaults.standard.string(forKey: clientIDDefaultsKey)?.trimmedNonEmpty
    }
    public static var hasUserClientSecret: Bool {
        UserDefaults.standard.bool(forKey: hasClientSecretDefaultsKey)
    }

    // MARK: Effective resolution (honors the override toggle)

    /// The Client ID the app should actually use, or nil if nothing is configured.
    public static var effectiveClientID: String? {
        if useOwnClient { return userClientID }
        return embeddedClientID ?? userClientID
    }

    /// True when SOME usable OAuth client is configured (embedded or user-provided). Used to
    /// force real mode (vs demo) and to gate the "configure OAuth" instruction.
    public static var isConfigured: Bool { effectiveClientID != nil }

    /// True when a Client Secret is available for the effective client, so an automatic sign-in
    /// won't immediately fail on Google's "client_secret is missing" (F-057).
    public static var hasUsableClientSecret: Bool {
        if useOwnClient { return hasUserClientSecret }
        if embeddedClientSecret != nil { return true }
        return hasUserClientSecret
    }

    /// Safe to auto-open the browser sign-in: a client AND its secret are both present.
    public static var canAttemptSignIn: Bool { isConfigured && hasUsableClientSecret }
}

extension String {
    /// Trimmed of surrounding whitespace/newlines; nil when the result is empty. A pasted value
    /// often carries a trailing "\n" that Google rejects (F-055).
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
