import Foundation
import CryptoKit

/// The OAuth authorization-code + PKCE flow used to obtain this app's OWN token,
/// completely independent of Claude Code's shared `Claude Code-credentials`
/// keychain item.
///
/// This is the crux of the re-architecture: instead of copying Claude Code's
/// token (whose keychain item Claude Code owns and rewrites on every rotation,
/// re-triggering the login-password prompt), the widget runs its own sign-in
/// once and receives its own grant. Refreshing that grant rotates only the
/// widget's refresh token, so Claude Code's session is never touched and no
/// keychain prompt can ever fire again.
///
/// It reuses Anthropic's public Claude Code OAuth client, so the resulting token
/// carries the same scopes and works against `/api/oauth/usage`.
enum OAuthEndpoint {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeBase = "https://claude.ai/oauth/authorize"
    static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    /// The out-of-band "show me a code to paste" redirect. Avoids running a
    /// loopback HTTP server inside a menu-bar app; the user copies the code
    /// Anthropic displays and pastes it back into the widget.
    static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    static let scope = "org:create_api_key user:profile user:inference"

    struct Token: Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
    }

    enum EndpointError: Error, LocalizedError {
        case badCode
        case stateMismatch
        case http(Int)
        case decode
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .badCode: return "That code didn't look right. Copy the whole code from the browser."
            case .stateMismatch: return "Security check failed (state mismatch). Start sign-in again."
            case .http(let c): return "Anthropic returned HTTP \(c). Start sign-in again."
            case .decode: return "Couldn't read Anthropic's response."
            case .transport(let m): return m
            }
        }
    }

    /// Builds the browser URL the user is sent to in order to approve access.
    static func authorizeURL(challenge: String, state: String) -> URL {
        var comps = URLComponents(string: authorizeBase)!
        comps.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        return comps.url!
    }

    /// Exchanges the pasted "code#state" string for a token. The out-of-band
    /// flow returns the authorization code with the state appended after a `#`.
    static func exchangeAuthCode(
        pasted rawCode: String,
        verifier: String,
        expectedState: String?,
        now: Date = .now
    ) async throws -> Token {
        let trimmed = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EndpointError.badCode }

        // The code may arrive as "CODE#STATE" or as a bare code. Split defensively.
        let parts = trimmed.split(separator: "#", maxSplits: 1).map(String.init)
        let code = parts[0]
        let returnedState = parts.count > 1 ? parts[1] : nil
        if let expectedState, let returnedState, returnedState != expectedState {
            throw EndpointError.stateMismatch
        }
        guard !code.isEmpty else { throw EndpointError.badCode }

        let body: [String: Any] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
            "state": expectedState ?? returnedState ?? "",
        ]
        return try await post(body, now: now)
    }

    /// Rotates the app's OWN refresh token. Safe: this grant is independent of
    /// Claude Code, so rotating it never invalidates the CLI's session.
    static func refresh(refreshToken: String, now: Date = .now) async throws -> Token {
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        return try await post(body, now: now)
    }

    // MARK: - Private

    private static func post(_ body: [String: Any], now: Date) async throws -> Token {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: config)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw EndpointError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw EndpointError.decode }
        guard (200..<300).contains(http.statusCode) else { throw EndpointError.http(http.statusCode) }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String else {
            throw EndpointError.decode
        }
        let refresh = obj["refresh_token"] as? String
        let expiresAt: Date? = {
            if let secs = obj["expires_in"] as? Double { return now.addingTimeInterval(secs) }
            if let secs = obj["expires_in"] as? Int { return now.addingTimeInterval(Double(secs)) }
            return nil
        }()
        return Token(accessToken: access, refreshToken: refresh, expiresAt: expiresAt)
    }
}

/// PKCE code verifier / challenge pair (RFC 7636, S256).
enum OAuthPKCE {
    static func generate() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = base64URL(Data(bytes))
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = base64URL(Data(digest))
        return (verifier, challenge)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
