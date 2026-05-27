import Foundation
import UserNotifications
import AppKit

class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission() async {
        try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func applyCurrentSettings() {
        let morningEnabled = UserDefaults.standard.bool(forKey: "hivemind.morningNudgeEnabled")
        let eveningEnabled = UserDefaults.standard.bool(forKey: "hivemind.eveningNudgeEnabled")
        let morningSeconds = UserDefaults.standard.double(forKey: "hivemind.morningNudgeSeconds")
        let eveningSeconds = UserDefaults.standard.double(forKey: "hivemind.eveningNudgeSeconds")

        if morningEnabled {
            schedule(
                id: "hivemind.morning",
                title: "Good morning",
                body: "What's your MIT for today?",
                secondsFromMidnight: morningSeconds > 0 ? morningSeconds : 8 * 3600 + 30 * 60
            )
        } else {
            cancel(id: "hivemind.morning")
        }

        if eveningEnabled {
            schedule(
                id: "hivemind.evening",
                title: "Time to reflect",
                body: "How did today go?",
                secondsFromMidnight: eveningSeconds > 0 ? eveningSeconds : 16 * 3600 + 30 * 60
            )
        } else {
            cancel(id: "hivemind.evening")
        }
    }

    private func schedule(id: String, title: String, body: String, secondsFromMidnight: Double) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let totalMinutes = Int(secondsFromMidnight / 60)
        var components = DateComponents()
        components.hour = totalMinutes / 60
        components.minute = totalMinutes % 60

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        center.add(request)
    }

    func send(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func cancel(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let pageId = UserDefaults.shared.string(forKey: "hivemind.todayPageId") ?? ""
        if !pageId.isEmpty {
            let cleanId = pageId.replacingOccurrences(of: "-", with: "")
            if let url = URL(string: "notion://www.notion.so/\(cleanId)") {
                NSWorkspace.shared.open(url)
            }
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
