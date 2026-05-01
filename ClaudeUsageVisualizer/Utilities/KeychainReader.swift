import Foundation
import Security

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
    static func readClaudeCredentials() throws -> ClaudeCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecAttrAccount as String: NSUserName(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

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
