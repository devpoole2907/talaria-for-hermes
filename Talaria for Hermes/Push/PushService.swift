import Foundation
import Observation
import UIKit
import UserNotifications

/// Owns the device-side half of push notifications: requesting authorization,
/// registering with APNs, uploading the device token to the Talaria push Worker,
/// and routing a tapped notification to the right session.
///
/// A single shared instance because `UIApplicationDelegate` (which receives the
/// APNs token and notification taps) has no access to the SwiftUI environment.
@MainActor
@Observable
final class PushService {
    static let shared = PushService()

    /// Base URL of the Talaria push Cloudflare Worker, e.g.
    /// `https://talaria-push.<you>.workers.dev`. Empty disables push entirely.
    ///
    /// Fill this in after deploying the Worker (see the talaria-push repo:
    /// https://github.com/devpoole2907/talaria-push). Left
    /// as a constant deliberately — it's one fixed deployment per user and not
    /// worth a Settings field yet.
    static let workerBaseURL = ""   // TODO: set to your deployed Worker URL

    private(set) var deviceTokenHex: String?
    private(set) var lastError: String?

    /// Stable per-user id (`X-Hermes-Session-Key`); set via `configure`.
    private var sessionKey: String?

    /// The session currently on screen — used to suppress its own foreground push.
    var activeSessionID: String?

    /// A session id from a tapped notification, awaiting in-app navigation.
    var pendingDeepLinkSessionID: String?

    private init() {}

    /// Whether push is wired up (a Worker URL has been set). When false every
    /// entry point below no-ops, so the app runs identically with push disabled.
    var isEnabled: Bool { Self.workerBaseURL.hasPrefix("https://") }

    func configure(sessionKey: String) {
        self.sessionKey = sessionKey
        // A token may have arrived before we knew the session key — flush it now.
        if deviceTokenHex != nil { Task { await uploadRegistration() } }
    }

    /// Asks for notification permission (first launch shows the prompt) and, if
    /// granted, registers with APNs. Safe to call every launch — Apple recommends
    /// re-registering so the token stays fresh.
    func requestAuthorizationAndRegister() async {
        guard isEnabled else { return }
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else { return }
            UIApplication.shared.registerForRemoteNotifications()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setDeviceToken(_ data: Data) {
        deviceTokenHex = data.map { String(format: "%02x", $0) }.joined()
        Task { await uploadRegistration() }
    }

    func recordRegistrationFailure(_ message: String) {
        lastError = message
    }

    func handleDeepLink(sessionID: String) {
        pendingDeepLinkSessionID = sessionID
    }

    /// Whether a foreground push for `sessionID` should be shown as a banner.
    /// Suppresses it when the user is already looking at that session, so an
    /// active conversation doesn't buzz on its own completion.
    func shouldPresentForeground(sessionID: String?) -> Bool {
        guard let sessionID else { return true }
        return sessionID != activeSessionID
    }

    private func uploadRegistration() async {
        guard isEnabled,
              let token = deviceTokenHex,
              let sessionKey, !sessionKey.isEmpty,
              let url = URL(string: Self.workerBaseURL + "/register") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "deviceToken": token,
            "sessionKey": sessionKey,
            "bundleId": Bundle.main.bundleIdentifier ?? "",
            "platform": "apns",
        ])

        do {
            _ = try await URLSession.shared.data(for: request)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
