#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// Drives the one-time interactive sign-in: opens the browser to Anthropic's
/// consent page, then exchanges the code the user pastes back for the widget's
/// own token. On success the token is handed to `CredentialsManager`, which owns
/// it from then on and refreshes it independently of Claude Code.
@MainActor
final class OAuthLoginService: ObservableObject {
    enum Phase: Equatable {
        case idle
        case awaitingCode
        case exchanging
        case done
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private var verifier: String?
    private var expectedState: String?
    private let credentials: CredentialsManager

    /// Called after a successful sign-in so the view model can immediately fetch
    /// live usage with the fresh token.
    var onSignedIn: (() -> Void)?

    init(credentials: CredentialsManager) {
        self.credentials = credentials
    }

    /// Opens the consent page in the default browser and moves to the
    /// paste-the-code step.
    func beginLogin() {
        let (verifier, challenge) = OAuthPKCE.generate()
        let state = UUID().uuidString
        self.verifier = verifier
        self.expectedState = state
        let url = OAuthEndpoint.authorizeURL(challenge: challenge, state: state)
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
        phase = .awaitingCode
    }

    /// Exchanges the pasted code for a token and persists it.
    func submitCode(_ pasted: String) async {
        guard let verifier else {
            phase = .failed("Start sign-in first.")
            return
        }
        phase = .exchanging
        do {
            let token = try await OAuthEndpoint.exchangeAuthCode(
                pasted: pasted,
                verifier: verifier,
                expectedState: expectedState
            )
            await credentials.storeOwnToken(
                accessToken: token.accessToken,
                refreshToken: token.refreshToken,
                expiresAt: token.expiresAt
            )
            self.verifier = nil
            self.expectedState = nil
            phase = .done
            onSignedIn?()
        } catch {
            let message = (error as? OAuthEndpoint.EndpointError)?.errorDescription
                ?? error.localizedDescription
            phase = .failed(message)
        }
    }

    func reset() {
        verifier = nil
        expectedState = nil
        phase = .idle
    }
}
