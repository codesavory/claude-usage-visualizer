import Foundation

/// Cross-device OAuth token sync via the user's private iCloud key-value store
/// (`NSUbiquitousKeyValueStore`). The macOS widget and the iOS app declare the
/// same `com.apple.developer.ubiquity-kvstore-identifier`, so a token validated
/// on one device propagates to the other with no extra sign-in. Validate once
/// on either the Mac or the iPhone and both show the exact numbers.
///
/// Best-effort by design: without the iCloud entitlement/provisioning, or when
/// the user is signed out of iCloud, reads return nil and writes are dropped.
/// Every call then degrades gracefully to local-only behaviour, so the apps
/// still work exactly as before with no iCloud.
enum ICloudUsageSync {
    private static let key = "usage_snapshot_v1"
    private static var store: NSUbiquitousKeyValueStore { .default }

    /// Mac side: publishes a reading for the phone. Numbers only, no credentials.
    static func push(_ snapshot: OAuthUsageSnapshot) {
        guard let data = try? JSONEncoder.cuv.encode(snapshot),
              let json = String(data: data, encoding: .utf8) else { return }
        store.set(json, forKey: key)
        store.synchronize()
    }

    /// Phone side: the Mac's latest reading, or nil.
    static func pull() -> OAuthUsageSnapshot? {
        store.synchronize()
        guard let json = store.string(forKey: key),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder.cuv.decode(OAuthUsageSnapshot.self, from: data)
    }
}

enum ICloudTokenSync {
    private static let key = "oauth_envelope_v1"
    private static var store: NSUbiquitousKeyValueStore { .default }

    /// Publishes the envelope to iCloud so the other device can pick it up.
    static func push(_ envelope: BiometricCredentialStore.Envelope) {
        guard let data = try? JSONEncoder.cuv.encode(envelope),
              let json = String(data: data, encoding: .utf8) else { return }
        store.set(json, forKey: key)
        store.synchronize()
    }

    /// Reads the envelope the other device last published, or nil.
    static func pull() -> BiometricCredentialStore.Envelope? {
        store.synchronize()
        guard let json = store.string(forKey: key),
              let data = json.data(using: .utf8),
              let env = try? JSONDecoder.cuv.decode(BiometricCredentialStore.Envelope.self, from: data)
        else { return nil }
        return env
    }

    /// Fires `onChange` on the main queue whenever the other device pushes a new
    /// token. Returns the observer token; retain it for the app's lifetime.
    static func observe(_ onChange: @escaping () -> Void) -> NSObjectProtocol {
        // Prime the store so the first didChangeExternally can arrive.
        store.synchronize()
        return NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { _ in onChange() }
    }
}
