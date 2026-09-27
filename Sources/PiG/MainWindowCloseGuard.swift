import AppKit
import SwiftUI

/// Keeps SwiftUI's window delegate in the chain while intercepting close before the window disappears.
struct MainWindowCloseGuard: NSViewRepresentable {
    let appDelegate: PiGAppDelegate
    let model: AppModel

    func makeNSView(context: Context) -> GuardView {
        appDelegate.model = model
        return GuardView(appDelegate: appDelegate)
    }

    func updateNSView(_ view: GuardView, context: Context) {
        appDelegate.model = model
        view.install()
    }

    static func dismantleNSView(_ view: GuardView, coordinator: ()) {
        if let window = view.window, window.delegate === view.closeDelegate {
            window.delegate = view.closeDelegate.previousDelegate
        }
    }

    final class GuardView: NSView {
        let closeDelegate: CloseDelegate

        init(appDelegate: PiGAppDelegate) {
            closeDelegate = CloseDelegate(appDelegate: appDelegate)
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            install()
        }

        func install() {
            guard let window, window.delegate !== closeDelegate else { return }
            closeDelegate.previousDelegate = window.delegate
            window.delegate = closeDelegate
        }
    }

    final class CloseDelegate: NSObject, NSWindowDelegate {
        weak var previousDelegate: NSWindowDelegate?
        let appDelegate: PiGAppDelegate

        init(appDelegate: PiGAppDelegate) {
            self.appDelegate = appDelegate
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard previousDelegate?.windowShouldClose?(sender) ?? true else { return false }
            return MainActor.assumeIsolated { appDelegate.confirmWindowClose() }
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (previousDelegate?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            previousDelegate?.responds(to: selector) == true ? previousDelegate : super.forwardingTarget(for: selector)
        }
    }
}
