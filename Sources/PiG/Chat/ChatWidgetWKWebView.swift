import AppKit
import WebKit

// WebKit's internal view consumes scroll events even when the HTML fits its
// viewport. Forward native events before that view receives them, preserving
// trackpad phases/momentum and the transcript's normal user-scroll handling.
final class ChatWidgetWKWebView: WKWebView {
    var contentHeight: CGFloat = 0
    private var scrollMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoringScroll()
        guard window != nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.forwardScrollToChat(event) else { return event }
            return nil
        }
    }

    func stopMonitoringScroll() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }

    deinit {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    }

    private func forwardScrollToChat(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, !isHiddenOrHasHiddenAncestor,
              visibleRect.contains(convert(event.locationInWindow, from: nil)),
              abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX),
              contentHeight <= bounds.height + 1,
              let scrollView = superview?.enclosingScrollView,
              let contentView = window.contentView else { return false }

        // Ignore events over a different view layered above this widget, such
        // as the split terminal, a popover, or a native overlay control.
        let point = contentView.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        guard let hit = contentView.hitTest(point), hit === self || hit.isDescendant(of: self) else { return false }
        scrollView.scrollWheel(with: event)
        return true
    }
}
