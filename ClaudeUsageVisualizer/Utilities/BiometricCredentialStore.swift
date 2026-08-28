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

        // NOTE: do NOT pass kSecUseAuthenticationContext here. Adding a
        // .biometryCurrentSet item with an un-evaluated LAContext makes
        // SecItemAdd fail with errSecAuthFailed, which was being swallowed by
        // the caller's `try?` — leaving the store empty and forcing a re-read
        // of the source keychain (the recurring login-password prompt). The
        // biometry gate is enforced on READ; the ADD needs no auth context.
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: access,
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

/// App-owned credential store backed by a plain `0600` file in Application
/// Support — deliberately NOT the Keychain.
///
/// A login-keychain item's ACL is bound to the creating app's code signature.
/// This widget is self-signed and rebuilt often, so every rebuild re-signs it,
/// drops it out of its own item's ACL, and macOS prompts for the login-keychain
/// password on the next read. That prompt is exactly what this store exists to
/// kill, and the Keychain fundamentally cannot avoid it here. A plain file read
/// never prompts, across any number of rebuilds.
///
/// Trade-off: the OAuth token now sits in plaintext in the user's home dir
/// (mode 0600, so not readable by other users) instead of the encrypted
/// Keychain. For a local personal menu-bar widget holding a usage-scoped token,
/// that is the accepted cost of never seeing the password prompt again. Same
/// trust model as Claude Code's own `~/.claude/.credentials.json` fallback.
enum PlainCredentialStore {
    private static var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ClaudeUsageVisualizer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("credentials.json")
    }

    static func read() throws -> BiometricCredentialStore.Envelope {
        let data = try Data(contentsOf: fileURL)   // throws when the file is absent
        return try JSONDecoder.cuv.decode(BiometricCredentialStore.Envelope.self, from: data)
    }

    static func write(_ envelope: BiometricCredentialStore.Envelope) throws {
        let data = try JSONEncoder.cuv.encode(envelope)
        let url = fileURL
        try data.write(to: url, options: [.atomic])
        // Owner read/write only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// One-time cleanup of the abandoned login-keychain items from the old
/// Keychain-backed design. `SecItemDelete` needs only the item's attributes,
/// not its data, so it does not trigger the login-password prompt.
enum LegacyKeychainCleanup {
    static func purge() {
        for service in ["dev.claudeusagevisualizer.credentials",
                        "dev.claudeusagevisualizer.credentials.plain"] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "oauth",
            ]
            SecItemDelete(query as CFDictionary)
        }
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
