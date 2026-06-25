import Foundation
import UserNotifications

/// One gentle daily reminder, tied to the user's chosen anchor time. Capped at a
/// single repeating notification — no fake urgency, easy to turn off.
final class NotificationService {
    private let center = UNUserNotificationCenter.current()
    private let reminderID = "mango.dailyReminder"

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func scheduleDailyReminder(hour: Int, minute: Int, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Mango"
        content.body = body
        content.sound = .default

        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: reminderID, content: content, trigger: trigger)

        center.removePendingNotificationRequests(withIdentifiers: [reminderID])
        try? await center.add(request)
    }

    func cancelDailyReminder() {
        center.removePendingNotificationRequests(withIdentifiers: [reminderID])
    }
}
