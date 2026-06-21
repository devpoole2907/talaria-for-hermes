import UIKit
import UserNotifications

/// Bridges the UIKit push lifecycle (APNs token + notification taps) into
/// `PushService`. Installed via `@UIApplicationDelegateAdaptor` in `TalariaApp`.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushService.shared.setDeviceToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushService.shared.recordRegistrationFailure(error.localizedDescription)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// App is foreground when this fires — show a banner unless the user is already
    /// looking at the session the push is about.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let sessionID = notification.request.content.userInfo["sessionId"] as? String
        return PushService.shared.shouldPresentForeground(sessionID: sessionID)
            ? [.banner, .sound]
            : []
    }

    /// User tapped the notification — deep link to the session.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        if let sessionID = response.notification.request.content.userInfo["sessionId"] as? String {
            PushService.shared.handleDeepLink(sessionID: sessionID)
        }
    }
}
