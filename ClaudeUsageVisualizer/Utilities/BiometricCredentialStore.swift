import Foundation
import LocalAuthentication
import Security

/// Stores Claude OAuth credentials in our own keychain item gated by Touch ID
/// (kSecAttrAccessControl = .biometryCurrentSet). After a one-time bootstrap
/// from the source `Claude Code-credentials` item, daily reads happen via
/// Touch ID against this store — bypassing Claude Code's daily token rotation
/// that wipes the ACL on the source item and re-prompts for the login password.
enum BiometricCredentialStore {
    static let service = "dev.claudeusagevisualizer.credentials"
    static let account = "oauth"

    struct Envelope: Codable, Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
    }

    enum StoreError: Error {
        case notFound
        case userCancelled
        case biometryUnavailable
        case decodeFailed
        case osStatus(OSStatus)
    }

    /// True when this Mac has Touch ID configured and an enrolled fingerprint.
    static func isBiometryAvailable() -> Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    static func read(context: LAContext) throws -> Envelope {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            throw StoreError.notFound
        case errSecUserCanceled, errSecAuthFailed:
            throw StoreError.userCancelled
        default:
            throw StoreError.osStatus(status)
        }

        guard let data = item as? Data else { throw StoreError.decodeFailed }
        do {
            return try JSONDecoder.cuv.decode(Envelope.self, from: data)
        } catch {
            throw StoreError.decodeFailed
        }
    }

    /// Writes (or replaces) the envelope. Pass the same LAContext used for read
    /// to avoid a second Touch ID prompt within the reuse window.
    static func write(_ envelope: Envelope, context: LAContext) throws {
        let data = try JSONEncoder.cuv.encode(envelope)

        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: context,
        ]
        let updateAttrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw StoreError.osStatus(updateStatus)
        }

        var sacError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            &sacError
        ) else {
            throw StoreError.biometryUnavailable
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: access,
            kSecUseAuthenticationContext as String: context,
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecUserCanceled, errSecAuthFailed:
            throw StoreError.userCancelled
        default:
            throw StoreError.osStatus(addStatus)
        }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Builds an LAContext suitable for chained read+update within one Touch ID
    /// prompt. The 60s reuse window covers the OAuth refresh network round-trip
    /// (15s timeout) so a refresh-then-write doesn't re-prompt the user.
    static func makeContext(reason: String) -> LAContext {
        let ctx = LAContext()
        ctx.localizedReason = reason
        ctx.touchIDAuthenticationAllowableReuseDuration = 60
        return ctx
    }
}

extension JSONDecoder {
    static let cuv: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

extension JSONEncoder {
    static let cuv: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
}
