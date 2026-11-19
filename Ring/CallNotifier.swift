import Foundation
import UserNotifications

/// Native macOS notification for incoming calls, with Answer / Decline buttons.
@MainActor
final class CallNotifier: NSObject, UNUserNotificationCenterDelegate {
    private static let category = "INCOMING_CALL"
    private static let answerAction = "ANSWER"
    private static let declineAction = "DECLINE"
    private static let notificationID = "incoming-call"

    var onAnswer: () -> Void = {}
    var onDecline: () -> Void = {}

    private var center: UNUserNotificationCenter { .current() }

    override init() {
        super.init()
        center.delegate = self
        let answer = UNNotificationAction(identifier: Self.answerAction, title: "Answer", options: [])
        let decline = UNNotificationAction(identifier: Self.declineAction, title: "Decline", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [answer, decline],
                                   intentIdentifiers: [], options: [])
        ])
        // Asks once; afterwards the choice is in System Settings › Notifications › Ring.
        center.requestAuthorization(options: [.alert]) { _, _ in }
    }

    func showIncoming(from caller: String) {
        let content = UNMutableNotificationContent()
        content.title = "Incoming call"
        content.body = caller
        content.categoryIdentifier = Self.category
        content.sound = nil // liblinphone already plays the ring tone
        content.interruptionLevel = .active
        center.add(UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil))
    }

    /// Remove it once the call is answered, declined or over.
    func clear() {
        center.removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show the banner even though Ring counts as the active app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        Task { @MainActor in
            switch action {
            // Clicking the notification itself also answers.
            case Self.answerAction, UNNotificationDefaultActionIdentifier: self.onAnswer()
            case Self.declineAction: self.onDecline()
            default: break // e.g. dismissed
            }
            completionHandler()
        }
    }
}
