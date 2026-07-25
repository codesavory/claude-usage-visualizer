import Foundation
import Security
import LocalAuthentication

enum KeychainReader {
    struct ClaudeCredentials: Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
    }

    enum ReadError: Error {
        case notFound
        case decodeFailed
        case osStatus(OSStatus)
    }

    /// Reads the Claude Code OAuth credentials from the login keychain.
    /// Service = "Claude Code-credentials", account = current username.
    ///
    /// When `allowInteraction` is false the read never raises a prompt: if the
    /// item's ACL would require user presence the call fails with
    /// `errSecInteractionNotAllowed` instead. Callers use this for a cheap
    /// silent probe before falling back to the foregrounded password path.
    static func readClaudeCredentials(allowInteraction: Bool = true) throws -> ClaudeCredentials {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecAttrAccount as String: NSUserName(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !allowInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            throw ReadError.notFound
        default:
            throw ReadError.osStatus(status)
        }

        guard let data = item as? Data else { throw ReadError.decodeFailed }

        struct Envelope: Decodable {
            struct OAuth: Decodable {
                let accessToken: String
                let refreshToken: String?
                let expiresAt: Double?

                enum CodingKeys: String, CodingKey {
                    case accessToken
                    case refreshToken
                    case expiresAt
                }
            }
            let claudeAiOauth: OAuth
        }

        do {
            let env = try JSONDecoder().decode(Envelope.self, from: data)
            let expires = env.claudeAiOauth.expiresAt.map {
                Date(timeIntervalSince1970: $0 / 1000.0)
            }
            return ClaudeCredentials(
                accessToken: env.claudeAiOauth.accessToken,
                refreshToken: env.claudeAiOauth.refreshToken,
                expiresAt: expires
            )
        } catch {
            throw ReadError.decodeFailed
        }
    }
}
