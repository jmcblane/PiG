import SwiftUI
import AppKit

struct ReliableBottomScrollView<Content: View>: NSViewRepresentable {
    @Binding var isAtBottom: Bool
    let forceScrollToken: Int
    let streamingFrameToken: Int
    var textSizeStep: Int = TextSizePreference.step
    var topAnchorToken: Int = 0
    var messageScrollRequest: MessageScrollRequest? = nil
    let content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator(isAtBottom: $isAtBottom)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = BottomLockingNSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.onUserScroll = { [weak coordinator = context.coordinator] in
            coordinator?.userDidScroll()
        }

        let hosting = TranscriptHostingView(rootView: content())
        hosting.isFlipped = true
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width]
        hosting.onContentSizeInvalidated = { [weak coordinator = context.coordinator] in
            coordinator?.hostedContentSizeInvalidated()
        }
        scrollView.documentView = hosting

        context.coordinator.scrollView = scrollView
        context.coordinator.hostingView = hosting
        context.coordinator.lastForceToken = forceScrollToken
        context.coordinator.lastTextSizeStep = textSizeStep
        context.coordinator.lastStreamingFrameToken = streamingFrameToken
        context.coordinator.lastTopAnchorToken = topAnchorToken
        context.coordinator.lastMessageScrollRequestID = messageScrollRequest?.id
        context.coordinator.lastClipSize = scrollView.contentView.bounds.size

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        context.coordinator.relayout(follow: true, force: true)
        if let request = messageScrollRequest {
            context.coordinator.scrollToMessage(request.messageID)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let hosting = context.coordinator.hostingView else { return }
        hosting.rootView = content()

        let sizeChanged = context.coordinator.lastTextSizeStep != textSizeStep
        if sizeChanged { context.coordinator.lastTextSizeStep = textSizeStep }
        let forced = context.coordinator.lastForceToken != forceScrollToken
        if forced { context.coordinator.lastForceToken = forceScrollToken }
        let streamingFrame = context.coordinator.lastStreamingFrameToken != streamingFrameToken
        if streamingFrame { context.coordinator.lastStreamingFrameToken = streamingFrameToken }
        let topInsert = context.coordinator.lastTopAnchorToken != topAnchorToken
        if topInsert { context.coordinator.lastTopAnchorToken = topAnchorToken }
        let messageTargetChanged = context.coordinator.lastMessageScrollRequestID != messageScrollRequest?.id
        if messageTargetChanged { context.coordinator.lastMessageScrollRequestID = messageScrollRequest?.id }

        if messageTargetChanged, let request = messageScrollRequest {
            context.coordinator.scrollToMessage(request.messageID)
        } else if topInsert && !forced {
            context.coordinator.relayoutPreservingTopInsertion()
        } else if streamingFrame && !forced && !sizeChanged {
            context.coordinator.relayoutStreamingFrame(follow: context.coordinator.shouldFollowBottom)
        } else {
            context.coordinator.relayout(follow: forced || context.coordinator.shouldFollowBottom, force: forced || sizeChanged)
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject {
        weak var scrollView: NSScrollView?
        weak var hostingView: TranscriptHostingView<Content>?
        var isAtBottomBinding: Binding<Bool>
        var lastForceToken = 0
        var lastTextSizeStep = TextSizePreference.step
        var lastStreamingFrameToken = 0
        var lastTopAnchorToken = 0
        var lastMessageScrollRequestID: UUID?
        var lockToBottom = true
        var lastClipSize: CGSize = .zero
        var shouldFollowBottom: Bool { !isTargetingMessage && lockToBottom }

        private var userScrollPending = false
        private var isTargetingMessage = false
        private var isProgrammaticScroll = false
        private var lastDocumentHeight: CGFloat = 0
        private var clipResizeGeneration = 0
        private var targetScrollGeneration = 0
        private var atBottomUpdateGeneration = 0
        private var isMeasuring = false
        private var contentSizePassScheduled = false
        private let threshold: CGFloat = 36

        init(isAtBottom: Binding<Bool>) {
            self.isAtBottomBinding = isAtBottom
        }

        @objc func boundsDidChange(_ notification: Notification) {
            guard !userScrollPending, !isProgrammaticScroll else { return }
            let clipSize = scrollView?.contentView.bounds.size ?? .zero
            if abs(clipSize.width - lastClipSize.width) > 0.5 || abs(clipSize.height - lastClipSize.height) > 0.5 {
                // Live resize: keep the bottom pinned using the stale document
                // height and defer the full-document measurement until the
                // size stops changing.
                lastClipSize = clipSize
                if shouldFollowBottom { scrollToBottom() }
                scheduleClipResizeRelayout()
                return
            }
            if shouldFollowBottom {
                _ = measureAndApplyDocumentSize()
                scrollToBottom()
            } else {
                updateAtBottom()
            }
        }

        func userDidScroll() {
            cancelMessageTargeting()
            userScrollPending = true
            lockToBottom = false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.userScrollPending = false
                let atBottom = self.computeAtBottom(margin: 8)
                self.lockToBottom = atBottom && !self.isTargetingMessage
                self.setAtBottom(atBottom)
            }
        }

        func relayoutStreamingFrame(follow: Bool) {
            _ = measureAndApplyDocumentSize()
            if follow && !isTargetingMessage && !userScrollPending {
                lockToBottom = true
                scrollToBottom()
            } else {
                updateAtBottom()
            }
        }

        // AppKit invalidates the hosting view's intrinsic content size every
        // time SwiftUI republishes a different layout: the final streaming
        // frame that lands after this runloop turn, a tool preview that
        // finishes preparing asynchronously, a table that reflows. Re-measure
        // on that signal instead of guessing when content has settled, so the
        // document frame can never stay shorter than what is rendered (which
        // squeezes rows into each other and hides content under the composer).
        func hostedContentSizeInvalidated() {
            guard !isMeasuring, !contentSizePassScheduled else { return }
            contentSizePassScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.contentSizePassScheduled = false
                self.applyHostedContentSize()
            }
        }

        private func applyHostedContentSize() {
            guard let scrollView else { return }
            let previousHeight = lastDocumentHeight
            let previousOrigin = scrollView.contentView.bounds.origin
            let newHeight = measureAndApplyDocumentSize()
            guard abs(newHeight - previousHeight) > 0.5 else {
                updateAtBottom()
                return
            }
            if shouldFollowBottom && !userScrollPending {
                scrollToBottom()
                return
            }
            // Reading from further up: keep the current viewport pinned, only
            // clamp it into the document that just changed size.
            let maxY = max(0, newHeight - scrollView.contentView.bounds.height)
            let target = NSPoint(x: previousOrigin.x, y: min(max(previousOrigin.y, 0), maxY))
            if abs(target.y - previousOrigin.y) > 0.5 {
                isProgrammaticScroll = true
                scrollView.contentView.scroll(to: target)
                scrollView.reflectScrolledClipView(scrollView.contentView)
                isProgrammaticScroll = false
            } else {
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            updateAtBottom()
        }

        // Content was prepended above the viewport (e.g. "Load earlier
        // messages"): grow the document and shift the scroll origin by the
        // height delta so the previously visible content stays put.
        func relayoutPreservingTopInsertion() {
            guard let scrollView else { return }
            let previousHeight = lastDocumentHeight
            let previousOrigin = scrollView.contentView.bounds.origin
            let newHeight = measureAndApplyDocumentSize()
            let delta = newHeight - previousHeight
            guard delta > 0.5 else {
                updateAtBottom()
                return
            }
            lockToBottom = false
            let maxY = max(0, newHeight - scrollView.contentView.bounds.height)
            let target = NSPoint(x: previousOrigin.x, y: min(max(previousOrigin.y + delta, 0), maxY))
            isProgrammaticScroll = true
            scrollView.contentView.scroll(to: target)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isProgrammaticScroll = false
            setAtBottom(computeAtBottom(margin: threshold))
        }

        func relayout(follow: Bool, force: Bool) {
            let previousHeight = lastDocumentHeight
            let previousOrigin = scrollView?.contentView.bounds.origin ?? .zero
            let newHeight = measureAndApplyDocumentSize()
            let grew = abs(newHeight - previousHeight) > 0.5

            if force {
                cancelMessageTargeting()
                lockToBottom = true
                scrollToBottom()
                return
            }

            if follow && !isTargetingMessage && !userScrollPending {
                lockToBottom = true
                scrollToBottom()
                return
            }

            if grew, let scrollView {
                let maxY = max(0, newHeight - scrollView.contentView.bounds.height)
                let preserved = NSPoint(x: previousOrigin.x, y: min(max(previousOrigin.y, 0), maxY))
                isProgrammaticScroll = true
                scrollView.contentView.scroll(to: preserved)
                scrollView.reflectScrolledClipView(scrollView.contentView)
                isProgrammaticScroll = false
            }
            updateAtBottom()
        }

        @discardableResult
        private func measureAndApplyDocumentSize() -> CGFloat {
            guard let scrollView, let hostingView else { return 0 }
            isMeasuring = true
            defer { isMeasuring = false }
            let width = max(scrollView.contentView.bounds.width, 100)
            hostingView.frame.size.width = width
            hostingView.needsLayout = true
            hostingView.layoutSubtreeIfNeeded()
            let fitting = hostingView.fittingSize
            let intrinsic = hostingView.intrinsicContentSize
            // Never pad the document out to the viewport height: the extra
            // slack is handed to whatever child is vertically flexible (a
            // markdown table cell, say), which then stretches into a giant
            // blank row. A short transcript just sits at the top of the
            // flipped document view.
            // Round up to whole points: a fractional document height puts the
            // text views at fractional origins, where Core Animation resamples
            // their glyphs and the text renders soft until some later pass
            // happens to land on a pixel boundary.
            let height = max(fitting.height, intrinsic.height, 1).rounded(.up)
            hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
            lastDocumentHeight = height
            return height
        }

        private func scheduleClipResizeRelayout() {
            clipResizeGeneration += 1
            let generation = clipResizeGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self, self.clipResizeGeneration == generation else { return }
                let shouldFollow = !self.isTargetingMessage
                    && (self.lockToBottom || self.computeAtBottom(margin: self.threshold))
                self.relayout(follow: shouldFollow, force: false)
            }
        }

        func scrollToMessage(_ messageID: String) {
            targetScrollGeneration += 1
            let generation = targetScrollGeneration
            isTargetingMessage = true
            lockToBottom = false
            setAtBottom(false)
            let retryDelays: [TimeInterval] = [0, 0.06, 0.22]
            for delay in retryDelays {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.performMessageScroll(messageID, generation: generation)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (retryDelays.last ?? 0) + 0.02) { [weak self] in
                self?.finishMessageScroll(generation: generation)
            }
        }

        private func performMessageScroll(_ messageID: String, generation: Int) {
            guard generation == targetScrollGeneration,
                  let scrollView,
                  let hostingView else { return }
            _ = measureAndApplyDocumentSize()
            hostingView.layoutSubtreeIfNeeded()
            let identifier = NSUserInterfaceItemIdentifier("PiG.chatMessage.\(messageID)")
            guard let anchor = descendant(with: identifier, in: hostingView) else { return }
            let rect = anchor.convert(anchor.bounds, to: hostingView)
            let clipHeight = scrollView.contentView.bounds.height
            let maxY = max(0, hostingView.frame.height - clipHeight)
            let targetY = min(max(rect.midY - clipHeight / 2, 0), maxY)
            lockToBottom = false
            isProgrammaticScroll = true
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isProgrammaticScroll = false
            setAtBottom(computeAtBottom(margin: threshold))
        }

        private func finishMessageScroll(generation: Int) {
            guard generation == targetScrollGeneration else { return }
            isTargetingMessage = false
            let atBottom = computeAtBottom(margin: threshold)
            lockToBottom = atBottom
            setAtBottom(atBottom)
        }

        private func cancelMessageTargeting() {
            targetScrollGeneration += 1
            isTargetingMessage = false
        }

        private func descendant(with identifier: NSUserInterfaceItemIdentifier, in view: NSView) -> NSView? {
            if view.identifier == identifier { return view }
            for subview in view.subviews {
                if let match = descendant(with: identifier, in: subview) { return match }
            }
            return nil
        }

        private func scrollToBottom() {
            guard let scrollView, let documentView = scrollView.documentView else { return }
            let clipHeight = scrollView.contentView.bounds.height
            let docHeight = documentView.frame.height
            let y = max(0, docHeight - clipHeight)
            isProgrammaticScroll = true
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isProgrammaticScroll = false
            setAtBottom(computeAtBottom(margin: 2))
        }

        private func updateAtBottom() {
            let atBottom = computeAtBottom(margin: threshold)
            if isTargetingMessage {
                lockToBottom = false
            } else if atBottom {
                lockToBottom = true
            }
            setAtBottom(atBottom)
        }

        private func computeAtBottom(margin: CGFloat) -> Bool {
            guard let scrollView, let documentView = scrollView.documentView else { return true }
            let visible = scrollView.contentView.bounds
            return visible.maxY >= documentView.frame.height - margin
        }

        private func setAtBottom(_ value: Bool) {
            atBottomUpdateGeneration += 1
            let generation = atBottomUpdateGeneration
            guard isAtBottomBinding.wrappedValue != value else { return }
            DispatchQueue.main.async { [weak self, binding = isAtBottomBinding] in
                guard let self, self.atBottomUpdateGeneration == generation else { return }
                binding.wrappedValue = value
            }
        }
    }
}

// NSHostingView invalidates its intrinsic content size whenever SwiftUI
// republishes a layout with a different size, including the passes that land
// after the update that triggered them. That is the only reliable "the
// transcript is taller now" signal; without it the document frame is measured
// one runloop turn too early and stays stale.
final class TranscriptHostingView<Content: View>: NSHostingView<Content> {
    var onContentSizeInvalidated: (() -> Void)?

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onContentSizeInvalidated?()
    }
}

struct ChatMessageScrollAnchor: NSViewRepresentable {
    let messageID: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.identifier = identifier
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.identifier = identifier
    }

    private var identifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("PiG.chatMessage.\(messageID)")
    }
}

final class BottomLockingNSScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onUserScroll?()
        super.scrollWheel(with: event)
    }
}
