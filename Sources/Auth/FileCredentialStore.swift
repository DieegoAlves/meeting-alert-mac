// OWNER: Auth module. Signature-independent secret store for the OAuth refresh token + client secret.
//
// WHY THIS EXISTS (F-059 — the "asks me to log in again and again" loop):
// The app is distributed AD-HOC signed (`codesign --sign -`). Every rebuild produces a brand-new
// code-signing identity (new cdhash, no stable Developer-ID "designated requirement"). A macOS
// Keychain generic-password item's ACL is bound to the identity that CREATED it, so after each
// rebuild the freshly-signed binary can no longer read the previous build's Keychain item —
// `SecItemCopyMatching` returns errSecItemNotFound / errSecInteractionNotAllowed, `try?` swallows
// it, `isAuthorized` reads FALSE, and the app reopens the browser. That is the repeated-login loop.
//
// FIX: store credentials in a plain file in Application Support, keyed by BUNDLE ID (not by code
// signature), so it survives rebuilds exactly like events.json / preferences.json already do. The
// file is written 0600 (owner read/write only) — the task's "file with 600 perms" requirement.
import Foundation
import Core

/// File-backed replacement for the Keychain: `credentials.json` (a `{account: secret}` map) written
/// atomically with POSIX 0600 permissions, next to the app's other Application Support state.
enum FileCredentialStore {
    private static var fileURL: URL {
        AppPaths.appSupportDirectory.appendingPathComponent("credentials.json")
    }

    /// Serialize every read/write: the `GoogleAuth` actor and the `nonisolated` `saveClientSecret`
    /// (invoked from the main thread) would otherwise race on the shared file.
    private static let queue = DispatchQueue(label: "com.meetingalert.auth.credentials")

    static func saveString(_ string: String, account: String) throws {
        try queue.sync {
            var dict = readDict()
            dict[account] = string
            try writeDict(dict)
        }
    }

    static func loadString(account: String) throws -> String? {
        queue.sync { readDict()[account] }
    }

    static func delete(account: String) throws {
        try queue.sync {
            var dict = readDict()
            guard dict[account] != nil else { return }
            dict.removeValue(forKey: account)
            try writeDict(dict)
        }
    }

    // MARK: Private (callers already hold `queue`)

    private static func readDict() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    private static func writeDict(_ dict: [String: String]) throws {
        try AppPaths.ensureAppSupportDirectory()
        let data = try JSONEncoder().encode(dict)
        try data.write(to: fileURL, options: .atomic)
        // Enforce owner-only 0600 on the final file (atomic write may land 0644 first).
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: fileURL.path)
    }
}

/// Facade the Auth layer uses for the refresh token and Desktop-app client secret. Reads/writes the
/// file store, and TRANSPARENTLY MIGRATES a value still held in the legacy Keychain (written by a
/// build before F-059) into the file the first time it is read — so an install that was working
/// keeps working without a re-paste, and the plaintext-free Keychain copy is then removed.
enum CredentialStore {
    static func loadString(account: String) -> String? {
        if let v = (try? FileCredentialStore.loadString(account: account)) ?? nil, !v.isEmpty {
            return v
        }
        // Legacy Keychain fallback + one-time migration. Best-effort: on an ad-hoc rebuild the
        // Keychain read itself may fail (that's the very bug this class fixes) — then there is simply
        // nothing to migrate and the caller re-authenticates ONCE, after which the token lives in the
        // file and every later relaunch/rebuild finds it.
        guard let legacy = (try? KeychainStore.loadString(account: account)) ?? nil, !legacy.isEmpty
        else { return nil }
        try? FileCredentialStore.saveString(legacy, account: account)
        try? KeychainStore.delete(account: account)
        return legacy
    }

    static func saveString(_ string: String, account: String) throws {
        try FileCredentialStore.saveString(string, account: account)
    }

    static func delete(account: String) throws {
        try FileCredentialStore.delete(account: account)
        try? KeychainStore.delete(account: account)   // also purge any legacy Keychain copy
    }
}
