// OWNER: Auth module.
import Foundation
import CryptoKit
import Security

enum PKCE {
    /// Generates a code_verifier: 32 random bytes → Base64URL, no padding (43 chars).
    /// F-044: aborts (throws) if the secure RNG fails, rather than proceeding with a
    /// predictable all-zero verifier that would nullify PKCE's protection.
    static func makeVerifier() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw AuthError.secureRandomFailed(status)
        }
        return Data(bytes).base64URLEncoded()
    }

    /// Derives the S256 code_challenge: Base64URL(SHA-256(verifier)).
    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
