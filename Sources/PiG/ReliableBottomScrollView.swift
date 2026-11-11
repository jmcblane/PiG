import SwiftUI
import AppKit

struct ReliableBottomScrollView<Content: View>: NSViewRepresentable {
    @Binding var isAtBottom: Bool
    let forceScrollToken: Int
    let streamingFrameToken: Int
    var textStyle: TextStyle = .current
    var topAnchorToken: Int = 0
    var messageScrollRequest: MessageScrollRequest? = nil
    var findMatch: ChatFindMatch? = nil
    let content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator(isAtBottom: $isAtBottom)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.postsBoundsChangedNotifications = true

        let hosting = TranscriptHostingView(rootView: TopPinnedDocument(content: content()))
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
        context.coordinator.lastTextStyle = textStyle
        context.coordinator.lastStreamingFrameToken = streamingFrameToken
        context.coordinator.lastTopAnchorToken = topAnchorToken
        context.coordinator.lastMessageScrollRequestID = messageScrollRequest?.id
        context.coordinator.findMatch = findMatch
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
        hosting.rootView = TopPinnedDocument(content: content())

        let styleChanged = context.coordinator.lastTextStyle != textStyle
        if styleChanged { context.coordinator.lastTextStyle = textStyle }
        let forced = context.coordinator.lastForceToken != forceScrollToken
        if forced { context.coordinator.lastForceToken = forceScrollToken }
        let streamingFrame = context.coordinator.lastStreamingFrameToken != streamingFrameToken
        if streamingFrame { context.coordinator.lastStreamingFrameToken = streamingFrameToken }
        let topInsert = context.coordinator.lastTopAnchorToken != topAnchorToken
        if topInsert { context.coordinator.lastTopAnchorToken = topAnchorToken }
        let messageTargetChanged = context.coordinator.lastMessageScrollRequestID != messageScrollRequest?.id
        if messageTargetChanged { context.coordinator.lastMessageScrollRequestID = messageScrollRequest?.id }
        let findTargetChanged = context.coordinator.findMatch != findMatch
        context.coordinator.findMatch = findMatch

        if messageTargetChanged, let request = messageScrollRequest {
            context.coordinator.scrollToMessage(request.messageID)
        } else if findTargetChanged, let findMatch {
            context.coordinator.scrollToMessage(findMatch.messageID)
        } else if topInsert && !forced {
            context.coordinator.relayoutPreservingTopInsertion()
        } else if streamingFrame && !forced && !styleChanged {
            context.coordinator.relayoutStreamingFrame(follow: context.coordinator.shouldFollowBottom)
        } else {
            context.coordinator.relayout(follow: forced || context.coordinator.shouldFollowBottom, force: forced || styleChanged)
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject {
        weak var scrollView: NSScrollView?
        weak var hostingView: TranscriptHostingView<TopPinnedDocument<Content>>?
        var isAtBottomBinding: Binding<Bool>
        var lastForceToken = 0
        var lastTextStyle = TextStyle.current
        var lastStreamingFrameToken = 0
        var lastTopAnchorToken = 0
        var lastMessageScrollRequestID: UUID?
        var findMatch: ChatFindMatch?
        var lockToBottom = true
        var lastClipSize: CGSize = .zero
        var shouldFollowBottom: Bool { !isTargetingMessage && lockToBottom }

        private var isTargetingMessage = false
        private var lastOriginY: CGFloat = 0
        // The message at the top of the viewport and how far the viewport has
        // scrolled past its top. While reading scrolled up, relayouts restore
        // this instead of the raw scroll offset, so content that changes
        // height above the viewport (a tool group folding when its turn ends,
        // the oldest message leaving the window) cannot move the text on screen.
        private var readingAnchor: (id: NSUserInterfaceItemIdentifier, offset: CGFloat)?
        private var isProgrammaticScroll = false
        private var lastDocumentHeight: CGFloat = 0
        private var clipResizeGeneration = 0
        private var targetScrollGeneration = 0
        private var atBottomUpdateGeneration = 0
        private var isMeasuring = false
        private var contentSizePassScheduled = false
        private var invalidatedWhileMeasuring = false
        private var remeasureBudget = 3
        private let threshold: CGFloat = 36

        init(isAtBottom: Binding<Bool>) {
            self.isAtBottomBinding = isAtBottom
        }

        @objc func boundsDidChange(_ notification: Notification) {
            guard let clipView = scrollView?.contentView else { return }
            let originY = clipView.bounds.origin.y
            let movedUp = originY < lastOriginY - 0.5
            lastOriginY = originY
            guard !isProgrammaticScroll, !isMeasuring else { return }
            let clipSize = clipView.bounds.size
            if abs(clipSize.width - lastClipSize.width) > 0.5 || abs(clipSize.height - lastClipSize.height) > 0.5 {
                // Live resize: keep the bottom pinned using the stale document
                // height and defer the full-document measurement until the
                // size stops changing.
                lastClipSize = clipSize
                if shouldFollowBottom { scrollToBottom() }
                scheduleClipResizeRelayout()
                return
            }
            // Any other bounds change is the user scrolling: wheel, scroller
            // drag, keyboard, or autoscroll while selecting. Scrolling up lets
            // go of the bottom at once; only reaching the bottom takes it back.
            // The elastic bounce at the bottom also moves up, but ends there.
            cancelMessageTargeting()
            if movedUp && !computeAtBottom(margin: 1) {
                lockToBottom = false
            } else if computeAtBottom(margin: 8) {
                lockToBottom = true
            }
            if !lockToBottom { captureReadingAnchor() }
            setAtBottom(computeAtBottom(margin: threshold))
        }

        func relayoutStreamingFrame(follow: Bool) {
            let previousOrigin = scrollView?.contentView.bounds.origin ?? .zero
            _ = measureAndApplyDocumentSize()
            if follow && !isTargetingMessage {
                lockToBottom = true
                scrollToBottom()
            } else {
                holdReadingPosition(fallback: previousOrigin)
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
            // A layout that lands while measuring can leave that measurement
            // stale, so it earns another pass. The budget stops a layout that
            // invalidates on every measurement from looping.
            if isMeasuring {
                invalidatedWhileMeasuring = true
                return
            }
            remeasureBudget = 3
            scheduleContentSizePass()
        }

        private func scheduleContentSizePass() {
            guard !contentSizePassScheduled else { return }
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
            if shouldFollowBottom {
                scrollToBottom()
                return
            }
            holdReadingPosition(fallback: previousOrigin)
            updateAtBottom()
        }

        // Reading from further up: keep the anchored message where it is on
        // screen. Without an anchor, keep the scroll offset. Either way the
        // viewport is clamped into the document, which may have changed size.
        private func holdReadingPosition(fallback: NSPoint) {
            guard let scrollView, let hostingView else { return }
            hostingView.layoutSubtreeIfNeeded()
            let clipView = scrollView.contentView
            var y = fallback.y
            var anchored = false
            if let anchor = readingAnchor, let view = descendant(with: anchor.id, in: hostingView) {
                y = view.convert(view.bounds, to: hostingView).minY + anchor.offset
                anchored = true
            }
            let maxY = max(0, hostingView.frame.height - clipView.bounds.height)
            y = min(max(y, 0), maxY)
            if abs(y - clipView.bounds.origin.y) > 0.5 {
                isProgrammaticScroll = true
                clipView.scroll(to: NSPoint(x: fallback.x, y: y))
                isProgrammaticScroll = false
            }
            scrollView.reflectScrolledClipView(clipView)
            if !anchored { captureReadingAnchor() }
        }

        // Prefers the message the viewport's top edge cuts through, then the
        // first message starting inside the viewport, then the nearest above.
        private func captureReadingAnchor() {
            guard let scrollView, let hostingView else { return }
            let visible = scrollView.contentView.bounds
            var anchors: [(id: NSUserInterfaceItemIdentifier, rect: NSRect)] = []
            func visit(_ view: NSView) {
                if let id = view.identifier, id.rawValue.hasPrefix(ChatMessageScrollAnchor.identifierPrefix) {
                    anchors.append((id, view.convert(view.bounds, to: hostingView)))
                } else {
                    view.subviews.forEach(visit)
                }
            }
            visit(hostingView)
            let best = anchors.first { $0.rect.minY <= visible.minY && $0.rect.maxY > visible.minY }
                ?? anchors.filter { $0.rect.minY > visible.minY && $0.rect.minY < visible.maxY }
                    .min { $0.rect.minY < $1.rect.minY }
                ?? anchors.filter { $0.rect.minY <= visible.minY }.max { $0.rect.minY < $1.rect.minY }
            readingAnchor = best.map { ($0.id, visible.minY - $0.rect.minY) }
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
            hostingView?.layoutSubtreeIfNeeded()
            captureReadingAnchor()
            setAtBottom(computeAtBottom(margin: threshold))
        }

        func relayout(follow: Bool, force: Bool) {
            let previousOrigin = scrollView?.contentView.bounds.origin ?? .zero
            measureAndApplyDocumentSize()

            if force {
                cancelMessageTargeting()
                lockToBottom = true
                scrollToBottom()
                // A newly swapped-in transcript (switching chats) can still report
                // the previous document's size here, and the invalidation that
                // corrects it lands during this measurement, where it is ignored.
                // Measure again once layout settles instead of waiting for an
                // unrelated invalidation such as a hover.
                hostedContentSizeInvalidated()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.hostedContentSizeInvalidated()
                }
                return
            }

            if follow && !isTargetingMessage {
                lockToBottom = true
                scrollToBottom()
                return
            }

            holdReadingPosition(fallback: previousOrigin)
            updateAtBottom()
        }

        @discardableResult
        private func measureAndApplyDocumentSize() -> CGFloat {
            guard let scrollView, let hostingView else { return 0 }
            isMeasuring = true
            invalidatedWhileMeasuring = false
            defer {
                isMeasuring = false
                if invalidatedWhileMeasuring, remeasureBudget > 0 {
                    remeasureBudget -= 1
                    scheduleContentSizePass()
                }
            }
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
            readingAnchor = nil
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
            let rect: NSRect
            if findMatch?.messageID == messageID, let matchRect = currentFindRect(in: hostingView, relativeTo: hostingView) {
                rect = matchRect
            } else {
                rect = anchor.convert(anchor.bounds, to: hostingView)
            }
            let clipHeight = scrollView.contentView.bounds.height
            let maxY = max(0, hostingView.frame.height - clipHeight)
            let targetY = min(max(rect.midY - clipHeight / 2, 0), maxY)
            lockToBottom = false
            isProgrammaticScroll = true
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isProgrammaticScroll = false
            captureReadingAnchor()
            setAtBottom(computeAtBottom(margin: threshold))
        }

        private func currentFindRect(in view: NSView, relativeTo document: NSView) -> NSRect? {
            if let text = view as? MarkdownTextView, let rect = text.currentFindRect {
                return text.convert(rect, to: document)
            }
            for child in view.subviews {
                if let rect = currentFindRect(in: child, relativeTo: document) { return rect }
            }
            return nil
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
            // Being near the bottom is not following it: a reader a few lines
            // up stays put. A document that shrank onto the viewport's bottom
            // edge does resume following.
            if isTargetingMessage {
                lockToBottom = false
            } else if computeAtBottom(margin: 1) {
                lockToBottom = true
            }
            setAtBottom(computeAtBottom(margin: threshold))
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

    static let identifierPrefix = "PiG.chatMessage."

    private var identifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(Self.identifierPrefix + messageID)
    }
}

// NSHostingView pins content taller than its frame to the bottom edge, so a
// row that grows before the document frame catches up pushes everything above
// it past the top of the document, out of scrolling reach. Accepting the
// proposed height and placing the content at the top makes it overflow
// downward instead, where the next measurement picks it up.
struct TopPinnedDocument<Content: View>: View {
    let content: Content

    var body: some View {
        TopPinnedLayout { content }
    }
}

private struct TopPinnedLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let size = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        guard let height = proposal.height else { return size }
        return CGSize(width: size.width, height: min(size.height, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}
