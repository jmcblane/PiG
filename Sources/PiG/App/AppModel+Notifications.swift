import Foundation
import SwiftUI
@preconcurrency import UserNotifications

extension AppModel {
    func scheduleTestNotification(delay: TimeInterval = 10) {
        guard notificationsEnabled else {
            statusLine = "Notifications are disabled."
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "PiG notification test"
        content.body = "Notifications are working."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "PiG.testNotification.\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false)
        )
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Task { @MainActor in self.statusLine = "Notification error: \(error.localizedDescription)" }
                return
            }
            guard granted else {
                Task { @MainActor in self.statusLine = "Notifications are not allowed in System Settings." }
                return
            }
            UNUserNotificationCenter.current().add(request) { error in
                Task { @MainActor in
                    self.statusLine = error.map { "Notification error: \($0.localizedDescription)" } ?? "Test notification scheduled."
                }
            }
        }
    }

    func notifyAgentFinished(controllerID: String) {
        guard notificationsEnabled, let controller = controllers[controllerID] else { return }
        let content = UNMutableNotificationContent()
        let owner = agent(for: controller)
        content.title = owner.map { "\($0.name) finished" } ?? "Agent finished"
        content.subtitle = owner?.name ?? controller.projectName
        content.body = controller.title.isEmpty || controller.title == "Untitled" ? "A background chat completed." : "\(controller.title) completed."
        content.sound = .default
        var userInfo: [AnyHashable: Any] = ["controllerID": controllerID]
        if let sessionPath = controller.sessionPath { userInfo["sessionPath"] = sessionPath }
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: "PiG.agentFinished.\(controllerID).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

}
