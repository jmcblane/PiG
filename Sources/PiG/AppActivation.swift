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
        guard let working = model?.controllers.values.filter(\.showsActivityIndicator), !working.isEmpty else {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        if working.count == 1, let controller = working.first {
            let title = controller.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = title.isEmpty || title == "Untitled" ? controller.projectName : title
            alert.messageText = "Quit PiG while “\(name)” is working?"
        } else {
            alert.messageText = "Quit PiG while \(working.count) sessions are working?"
        }
        alert.informativeText = "Running agent work will be stopped."
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A dying terminal pty (or any closed pipe) raises SIGPIPE on write,
        // which terminates the whole app by default. Handle EPIPE errors instead.
        signal(SIGPIPE, SIG_IGN)

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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
}
