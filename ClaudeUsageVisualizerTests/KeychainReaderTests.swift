import Testing
import Foundation
import Security
@testable import ClaudeUsageVisualizer

/// Guards the "no password dialog" behaviour of the Claude Code token read.
///
/// The bug: the widget kept asking for the login password. Reads that went
/// through `SecItemCopyMatching` prompt, because Claude Code files the item via
/// `/usr/bin/security` and the item admits only Apple's tools. The "silent"
/// variant used an `LAContext` with `interactionNotAllowed`, which old-style
/// login-keychain items ignore, so it prompted too. The fix reads through
/// `/usr/bin/security` and never makes the direct call when silent.
@Suite("KeychainReader")
struct KeychainReaderTests {

    private func blob(access: String = "sk-ant-oat01-test", refresh: String? = "sk-ant-ort01-test",
                      expiresAtMs: Double? = 1_800_000_000_000) -> Data {
        var oauth: [String: Any] = ["accessToken": access]
        if let refresh { oauth["refreshToken"] = refresh }
        if let expiresAtMs { oauth["expiresAt"] = expiresAtMs }
        return try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
    }

    // MARK: decode

    @Test func decode_readsAllFields_andConvertsMillisecondsToDate() throws {
        let c = try KeychainReader.decode(blob())
        #expect(c.accessToken == "sk-ant-oat01-test")
        #expect(c.refreshToken == "sk-ant-ort01-test")
        #expect(c.expiresAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func decode_allowsMissingRefreshTokenAndExpiry() throws {
        let c = try KeychainReader.decode(blob(refresh: nil, expiresAtMs: nil))
        #expect(c.refreshToken == nil)
        #expect(c.expiresAt == nil)
    }

    @Test func decode_toleratesTrailingNewline() throws {
        // `security -w` ends its output with a newline.
        let c = try KeychainReader.decode(blob() + Data("\n".utf8))
        #expect(c.accessToken == "sk-ant-oat01-test")
    }

    @Test func decode_emptiedToken_isNotUsable() {
        // Claude Code rewrites the item with an empty token on sign-out. It must
        // not become `Bearer ` on the wire.
        #expect(throws: KeychainReader.ReadError.emptyCredential) {
            try KeychainReader.decode(blob(access: "", refresh: nil, expiresAtMs: 0))
        }
    }

    @Test func decode_garbage_throwsDecodeFailed() {
        #expect(throws: KeychainReader.ReadError.decodeFailed) {
            try KeychainReader.decode(Data("not json".utf8))
        }
        #expect(throws: KeychainReader.ReadError.decodeFailed) {
            try KeychainReader.decode(Data("{}".utf8))
        }
    }

    // MARK: the decision: when the direct keychain call is allowed

    @Test func read_usesTheToolAndNeverTheDirectCall_whenTheToolAnswers() throws {
        for interactive in [false, true] {
            var directCalls = 0
            let c = try KeychainReader.read(
                allowInteraction: interactive,
                viaTool: { blob() },
                viaSecItem: { directCalls += 1; return blob() }
            )
            #expect(c.accessToken == "sk-ant-oat01-test")
            #expect(directCalls == 0, "the direct keychain call can prompt; it must not run when the tool worked")
        }
    }

    /// The regression test for the repeated password dialog.
    @Test func read_silent_neverMakesTheDirectKeychainCall() {
        var directCalls = 0
        #expect(throws: KeychainReader.ReadError.osStatus(errSecInteractionNotAllowed)) {
            try KeychainReader.read(
                allowInteraction: false,
                viaTool: { nil },
                viaSecItem: { directCalls += 1; return Data() }
            )
        }
        #expect(directCalls == 0, "a silent read must not call SecItemCopyMatching: old-style items ignore LAContext and show the dialog")
    }

    @Test func read_interactive_fallsBackToTheDirectCall_whenTheToolReturnsNothing() throws {
        var directCalls = 0
        let c = try KeychainReader.read(
            allowInteraction: true,
            viaTool: { nil },
            viaSecItem: { directCalls += 1; return blob(access: "from-secitem") }
        )
        #expect(directCalls == 1)
        #expect(c.accessToken == "from-secitem")
    }

    @Test func read_interactive_propagatesTheDirectCallsError() {
        #expect(throws: KeychainReader.ReadError.notFound) {
            try KeychainReader.read(allowInteraction: true, viaTool: { nil },
                                    viaSecItem: { throw KeychainReader.ReadError.notFound })
        }
    }

    @Test func read_emptiedCredentialFromTheTool_doesNotFallBackToAPrompt() {
        // The item exists and was read fine; it is simply signed out. Asking the
        // keychain again would only raise a dialog for the same answer.
        var directCalls = 0
        #expect(throws: KeychainReader.ReadError.emptyCredential) {
            try KeychainReader.read(
                allowInteraction: true,
                viaTool: { blob(access: "", refresh: nil, expiresAtMs: 0) },
                viaSecItem: { directCalls += 1; return blob() }
            )
        }
        #expect(directCalls == 0)
    }

    // MARK: the real tool

    @Test func securityTool_returnsNilForAnItemThatDoesNotExist_withoutHanging() {
        let started = Date()
        let data = SecurityTool.readPassword(service: "cuv-test-missing-\(UUID().uuidString)",
                                             account: "cuv-test-nobody")
        #expect(data == nil)
        #expect(Date().timeIntervalSince(started) < SecurityTool.timeout,
                "a missing item answers immediately; waiting out the timeout means something is blocking")
    }
}
