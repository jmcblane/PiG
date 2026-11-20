import SwiftUI
import AppKit
@preconcurrency import UserNotifications

enum WindowLaunchDefaults {
    static let defaultSize = CGSize(width: 1000, height: 820)
    static let minimumSize = CGSize(width: 620, height: 700)
}

final class PiGAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var model: AppModel?
    private var approvedWindowClose = false

    @MainActor
    func confirmStoppingWork() -> Bool {
        let workingPi = model?.controllers.values.filter(\.hasLiveWork) ?? []
        let workingACP = model?.acpControllers.values.filter(\.hasLiveWork) ?? []
        let totalCount = workingPi.count + workingACP.count
        guard totalCount > 0 else {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        if totalCount == 1 {
            let name: String
            if let controller = workingPi.first {
                let title = controller.title.trimmingCharacters(in: .whitespacesAndNewlines)
                name = title.isEmpty || title == "Untitled" ? controller.projectName : title
            } else if let acp = workingACP.first {
                let title = acp.title.trimmingCharacters(in: .whitespacesAndNewlines)
                name = title.isEmpty || title == "Untitled" ? URL(fileURLWithPath: acp.projectPath).lastPathComponent : title
            } else {
                name = "Chat"
            }
            alert.messageText = "Quit PiG while “\(name)” is working?"
        } else {
            alert.messageText = "Quit PiG while \(totalCount) chats are working?"
        }
        alert.informativeText = "Running agent work and background jobs will be stopped."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    func confirmWindowClose() -> Bool {
        guard confirmStoppingWork() else { return false }
        // Closing the last window terminates the app. Do not ask again in applicationShouldTerminate.
        approvedWindowClose = true
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            if approvedWindowClose {
                approvedWindowClose = false
                return .terminateNow
            }
            return confirmStoppingWork() ? .terminateNow : .terminateCancel
        }
    }
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Terminal navigation needs held letters to repeat, not open the macOS accent picker.
        UserDefaults.standard.set(false, forKey: "ApplePressAndHoldEnabled")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A dying terminal pty (or any closed pipe) raises SIGPIPE on write,
        // which terminates the whole app by default. Handle EPIPE errors instead.
        signal(SIGPIPE, SIG_IGN)

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated {
            model?.markSelectedACPChatRead()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let acpChatID = info["acpChatID"] as? String
        let agentID = info["agentID"] as? String
        let hermesChatID = info["hermesChatID"] as? String
        let controllerID = info["controllerID"] as? String
        let sessionPath = info["sessionPath"] as? String
        Task { @MainActor [weak self] in
            guard let model = self?.model else { return }
            var userInfo: [AnyHashable: Any] = [:]
            userInfo["acpChatID"] = acpChatID
            userInfo["agentID"] = agentID
            userInfo["hermesChatID"] = hermesChatID
            userInfo["controllerID"] = controllerID
            userInfo["sessionPath"] = sessionPath
            await model.openNotification(userInfo)
            NSApp.activate(ignoringOtherApps: true)
        }
        completionHandler()
    }
}
