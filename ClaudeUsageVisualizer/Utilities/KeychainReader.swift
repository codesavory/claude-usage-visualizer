import Foundation
import Security

enum KeychainReader {
    struct ClaudeCredentials: Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
    }

    enum ReadError: Error, Equatable {
        case notFound
        case decodeFailed
        /// The item exists but holds no usable token. Claude Code rewrites it
        /// this way (`accessToken: ""`) on sign-out.
        case emptyCredential
        case osStatus(OSStatus)
    }

    /// Service Claude Code files its OAuth token under.
    static let service = "Claude Code-credentials"

    /// Reads the Claude Code OAuth credentials from the login keychain.
    ///
    /// Reads through `/usr/bin/security` first. Claude Code writes this item with
    /// that tool, so the item's access list (and its partition list, which no GUI
    /// can edit) admits Apple's tools and nothing else. `SecItemCopyMatching` from
    /// this app therefore raises the login-password dialog, and "Always Allow"
    /// does not stick: Claude Code files a fresh item on every token rotation, and
    /// a rebuilt app has a new signature. `/usr/bin/security` is already trusted by
    /// the item, so it reads it with no dialog, ever.
    ///
    /// When `allowInteraction` is false this never touches `SecItemCopyMatching`.
    /// An `LAContext` with `interactionNotAllowed` does NOT stop that call from
    /// prompting for old-style login-keychain items, so the only way a "silent"
    /// read stays silent is to not make the call. It throws
    /// `errSecInteractionNotAllowed` instead when the tool returns nothing.
    ///
    /// When `allowInteraction` is true and the tool returns nothing, it falls back
    /// to `SecItemCopyMatching`, which may show the dialog. Only a person's
    /// explicit action should ask for that.
    static func readClaudeCredentials(allowInteraction: Bool = true) throws -> ClaudeCredentials {
        try read(
            allowInteraction: allowInteraction,
            viaTool: { SecurityTool.readPassword(service: service, account: NSUserName()) },
            viaSecItem: { try readViaSecItem() }
        )
    }

    /// The decision, separated from the two readers so a test can pin it
    /// without a real keychain.
    static func read(
        allowInteraction: Bool,
        viaTool: () -> Data?,
        viaSecItem: () throws -> Data
    ) throws -> ClaudeCredentials {
        if let data = viaTool() {
            return try decode(data)
        }
        guard allowInteraction else {
            throw ReadError.osStatus(errSecInteractionNotAllowed)
        }
        return try decode(try viaSecItem())
    }

    /// Turns the stored JSON into credentials. Throws `emptyCredential` for a
    /// present-but-emptied token, which would otherwise go out as `Bearer ` and
    /// come back as a puzzling 401.
    static func decode(_ data: Data) throws -> ClaudeCredentials {
        struct Envelope: Decodable {
            struct OAuth: Decodable {
                let accessToken: String
                let refreshToken: String?
                let expiresAt: Double?
            }
            let claudeAiOauth: OAuth
        }

        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw ReadError.decodeFailed
        }
        guard !env.claudeAiOauth.accessToken.isEmpty else {
            throw ReadError.emptyCredential
        }
        return ClaudeCredentials(
            accessToken: env.claudeAiOauth.accessToken,
            refreshToken: env.claudeAiOauth.refreshToken,
            expiresAt: env.claudeAiOauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000.0) }
        )
    }

    /// The direct keychain read. May raise the password dialog.
    private static func readViaSecItem() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
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
        return data
    }
}

/// Reads a generic password through `/usr/bin/security`.
///
/// The secret comes straight back into this process. It is never logged, never
/// put on a command line, and nothing is written. The tool is Apple-signed and is
/// how Claude Code filed the item, so it is already on that item's access list.
enum SecurityTool {
    /// Seconds before the tool is given up on. It should answer in milliseconds; a
    /// hang means it is waiting on a dialog, and a poll must not wait forever.
    static let timeout: TimeInterval = 10

    static func readPassword(service: String, account: String) -> Data? {
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        tool.arguments = ["find-generic-password", "-a", account, "-s", service, "-w"]
        let out = Pipe()
        tool.standardOutput = out
        tool.standardError = FileHandle.nullDevice
        tool.standardInput = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        tool.terminationHandler = { _ in finished.signal() }

        do {
            try tool.run()
        } catch {
            return nil
        }

        // The credential is well under a pipe buffer, so the tool can write all of
        // it and exit without anyone reading, which lets us wait on exit with a
        // timeout and read afterwards.
        guard finished.wait(timeout: .now() + timeout) == .success else {
            tool.terminate()
            return nil
        }
        guard tool.terminationStatus == 0 else { return nil }

        var data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        while data.last == 0x0A || data.last == 0x0D { data.removeLast() }
        return data.isEmpty ? nil : data
    }
}
