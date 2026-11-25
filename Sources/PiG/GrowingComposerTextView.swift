import SwiftUI
import AppKit

private let supportedComposerImageMIMETypes: [String: String] = [
    "png": "image/png",
    "jpg": "image/jpeg",
    "jpeg": "image/jpeg",
    "gif": "image/gif",
    "webp": "image/webp"
]

private func composerImageAttachment(from url: URL) throws -> ImageAttachment? {
    let ext = url.pathExtension.lowercased()
    guard let mimeType = supportedComposerImageMIMETypes[ext] else { return nil }
    let data = try Data(contentsOf: url)
    return ImageAttachment(name: url.lastPathComponent, mimeType: mimeType, data: data.base64EncodedString())
}

private let composerImagePasteboardTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]

private func pngAttachment(from data: Data) -> ImageAttachment? {
    guard !data.isEmpty else { return nil }
    return ImageAttachment(name: "Pasted Image", mimeType: "image/png", data: data.base64EncodedString())
}

private func pastedImageAttachment(from pasteboard: NSPasteboard) -> ImageAttachment? {
    if let data = pasteboard.data(forType: .png), let attachment = pngAttachment(from: data) {
        return attachment
    }
    if let data = pasteboard.data(forType: .tiff),
       let bitmap = NSBitmapImageRep(data: data),
       let png = bitmap.representation(using: .png, properties: [:]),
       let attachment = pngAttachment(from: png) {
        return attachment
    }
    return nil
}

private func pasteboardHasComposerImage(_ pasteboard: NSPasteboard) -> Bool {
    pasteboard.availableType(from: composerImagePasteboardTypes) != nil
}

private extension NSAttributedString.Key {
    static let pigComposerToken = NSAttributedString.Key("PiGComposerToken")
}

private final class ComposerTokenAttachmentCell: NSTextAttachmentCell {
    let token: ComposerToken
    let palette: AppThemePalette
    private let cachedSize: NSSize
    private let cachedBaselineOffset: NSPoint
    private let fillColor: NSColor
    private let borderColor: NSColor
    private let dollarAttributes: [NSAttributedString.Key: Any]
    private let labelAttributes: [NSAttributedString.Key: Any]
    private let fileIcon: NSImage?
    private let labelInsetX: CGFloat
    private let labelInsetY: CGFloat
    private let labelTrailingInset: CGFloat
    private let labelHeight: CGFloat

    init(token: ComposerToken, palette: AppThemePalette) {
        self.token = token
        self.palette = palette
        let labelFont = AppFonts.nsUI(13.5, weight: .semibold)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: palette.text.nsColor
        ]
        self.labelAttributes = labelAttrs
        self.dollarAttributes = [
            .font: AppFonts.nsUI(14, weight: .bold),
            .foregroundColor: palette.accent.nsColor
        ]
        self.fillColor = palette.codeBackground.nsColor.withAlphaComponent(0.78)
        self.borderColor = palette.line.nsColor.withAlphaComponent(0.9)
        if token.kind == .file {
            self.fileIcon = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [palette.accent.nsColor]))
        } else {
            self.fileIcon = nil
        }
        let labelWidth = (token.label as NSString).size(withAttributes: [.font: labelFont]).width
        self.cachedSize = NSSize(width: min(AppFonts.scaled(280), ceil(labelWidth + AppFonts.scaled(36))), height: AppFonts.scaled(24))
        self.cachedBaselineOffset = NSPoint(x: 0, y: -AppFonts.scaled(5))
        self.labelInsetX = AppFonts.scaled(27)
        self.labelInsetY = AppFonts.scaled(4)
        self.labelTrailingInset = AppFonts.scaled(33)
        self.labelHeight = AppFonts.scaled(17)
        super.init(textCell: token.label)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func cellSize() -> NSSize { cachedSize }

    override func cellBaselineOffset() -> NSPoint { cachedBaselineOffset }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let rect = cellFrame.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        fillColor.setFill()
        path.fill()
        borderColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        if token.kind == .skill {
            ("$" as NSString).draw(
                in: NSRect(x: rect.minX + 8, y: rect.minY + 3, width: 12, height: 18),
                withAttributes: dollarAttributes
            )
        } else if let image = fileIcon {
            image.draw(in: NSRect(x: rect.minX + 8, y: rect.minY + 5, width: 13, height: 13))
        }
        (token.label as NSString).draw(
            in: NSRect(x: rect.minX + labelInsetX, y: rect.minY + labelInsetY, width: rect.width - labelTrailingInset, height: labelHeight),
            withAttributes: labelAttributes
        )
    }
}

struct GrowingComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let theme: AppThemeChoice
    let focusRequest: Int
    let cursorEndRequest: Int
    var tabCompletion: (String, NSRange) -> ComposerTabCompletionResult = { _, _ in .passThrough }
    var onKeyCommand: (ComposerKeyCommand) -> Bool = { _ in false }
    var onCyclePinnedModel: () -> Bool = { false }
    var onFocusChange: (Bool) -> Void = { _ in }
    var onDequeue: () -> Void = { }
    var onImagesInserted: ([ImageAttachment]) -> Void = { _ in }
    var onAttachmentError: (String) -> Void = { _ in }
    let onSubmit: () -> Void
    var onFollowUpSubmit: () -> Void = { }

    private var minHeight: CGFloat { max(36, AppFonts.scaled(15.5) + 20) }
    private var maxHeight: CGFloat { max(140, AppFonts.scaled(140)) }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, height: $height, minHeight: minHeight, maxHeight: maxHeight, tabCompletion: tabCompletion, theme: theme)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ComposerScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.scheduleRecalculateHeight()
        }

        let textView = SubmitTextView()
        textView.onSubmit = onSubmit
        textView.onFollowUpSubmit = onFollowUpSubmit
        textView.onDequeue = onDequeue
        textView.onTab = { [weak coordinator = context.coordinator] textView in
            coordinator?.completeTab(in: textView) ?? false
        }
        textView.onKeyCommand = onKeyCommand
        textView.onCyclePinnedModel = onCyclePinnedModel
        textView.onFocusChange = onFocusChange
        textView.onFilesInserted = { [weak coordinator = context.coordinator] urls, textView in
            var images: [ImageAttachment] = []
            var files: [URL] = []
            for url in urls {
                do {
                    if let image = try composerImageAttachment(from: url) { images.append(image) }
                    else { files.append(url) }
                } catch {
                    onAttachmentError("Could not attach \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if !images.isEmpty { onImagesInserted(images) }
            coordinator?.insertFiles(files, in: textView)
        }
        textView.onImagePasted = onImagesInserted
        textView.delegate = context.coordinator
        context.coordinator.applyCanonicalText(text, to: textView)
        textView.font = AppFonts.nsUI(15.5)
        textView.placeholder = "Message..."
        applyTheme(to: textView)
        textView.drawsBackground = false
        textView.isRichText = true
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        if #available(macOS 15.0, *) {
            textView.writingToolsBehavior = .none
        }
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.registerForDraggedTypes([.fileURL])
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.minSize = NSSize(width: 0, height: minHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.scheduleRecalculateHeight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SubmitTextView else { return }
        textView.onSubmit = onSubmit
        textView.onFollowUpSubmit = onFollowUpSubmit
        textView.onDequeue = onDequeue
        textView.onTab = { [weak coordinator = context.coordinator] textView in
            coordinator?.completeTab(in: textView) ?? false
        }
        textView.onKeyCommand = onKeyCommand
        textView.onCyclePinnedModel = onCyclePinnedModel
        textView.onFocusChange = onFocusChange
        textView.onFilesInserted = { [weak coordinator = context.coordinator] urls, textView in
            var images: [ImageAttachment] = []
            var files: [URL] = []
            for url in urls {
                do {
                    if let image = try composerImageAttachment(from: url) { images.append(image) }
                    else { files.append(url) }
                } catch {
                    onAttachmentError("Could not attach \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if !images.isEmpty { onImagesInserted(images) }
            coordinator?.insertFiles(files, in: textView)
        }
        textView.onImagePasted = onImagesInserted
        // The draft binding is derived per session; rebind so typing writes
        // to the currently selected session's draft, not the one captured
        // when the coordinator was created.
        context.coordinator.text = $text
        context.coordinator.height = $height
        context.coordinator.tabCompletion = tabCompletion
        context.coordinator.minHeight = minHeight
        context.coordinator.maxHeight = maxHeight
        let themeChanged = context.coordinator.theme != theme
        let styleChanged = context.coordinator.textStyle != TextStyle.current
        if themeChanged || styleChanged {
            context.coordinator.textStyle = TextStyle.current
            context.coordinator.theme = theme
            context.coordinator.refreshBaseAttributes()
        }
        if themeChanged {
            applyTheme(to: textView)
        }
        if styleChanged {
            textView.font = AppFonts.nsUI(15.5)
            textView.minSize.height = minHeight
        }
        let didApplyText: Bool
        if context.coordinator.canonicalText(in: textView) != text || themeChanged || styleChanged {
            context.coordinator.applyCanonicalText(text, to: textView)
            didApplyText = true
        } else {
            didApplyText = false
        }
        if focusRequest > 0, focusRequest != context.coordinator.handledFocusRequest {
            context.coordinator.handledFocusRequest = focusRequest
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
                textView.scrollRangeToVisible(textView.selectedRange())
            }
        }
        if cursorEndRequest > 0, cursorEndRequest != context.coordinator.handledCursorEndRequest {
            context.coordinator.handledCursorEndRequest = cursorEndRequest
            DispatchQueue.main.async {
                let end = (textView.string as NSString).length
                textView.setSelectedRange(NSRange(location: end, length: 0))
                textView.scrollRangeToVisible(textView.selectedRange())
            }
        }
        if didApplyText || styleChanged {
            context.coordinator.scheduleRecalculateHeight()
        }
    }

    private func applyTheme(to textView: SubmitTextView) {
        let palette = theme.palette
        textView.textColor = palette.text.nsColor
        textView.insertionPointColor = palette.accent.nsColor
        textView.placeholderColor = palette.muted.nsColor
        textView.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        // Stored as plain bindings (not @Binding) and refreshed from
        // updateNSView: the composer's draft binding changes identity when
        // the selected session changes.
        var text: Binding<String>
        var height: Binding<CGFloat>
        var minHeight: CGFloat
        var maxHeight: CGFloat
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        var tabCompletion: (String, NSRange) -> ComposerTabCompletionResult
        var theme: AppThemeChoice
        var textStyle = TextStyle.current
        var handledFocusRequest = 0
        var handledCursorEndRequest = 0

        private var lastMeasuredWidth: CGFloat = 0
        private var lastDocumentHeight: CGFloat = 0
        private var recalculationScheduled = false
        private var isNormalizingAttributes = false
        private var wasEmpty = true
        private var cachedBaseFont: NSFont
        private var cachedBaseColor: NSColor
        private var cachedBaseAttributes: [NSAttributedString.Key: Any]

        init(
            text: Binding<String>,
            height: Binding<CGFloat>,
            minHeight: CGFloat,
            maxHeight: CGFloat,
            tabCompletion: @escaping (String, NSRange) -> ComposerTabCompletionResult,
            theme: AppThemeChoice
        ) {
            self.text = text
            self.height = height
            self.minHeight = minHeight
            self.maxHeight = maxHeight
            self.tabCompletion = tabCompletion
            self.theme = theme
            let font = AppFonts.nsUI(15.5)
            let color = theme.palette.text.nsColor
            self.cachedBaseFont = font
            self.cachedBaseColor = color
            self.cachedBaseAttributes = [.font: font, .foregroundColor: color]
        }

        func refreshBaseAttributes() {
            let font = AppFonts.nsUI(15.5)
            let color = theme.palette.text.nsColor
            cachedBaseFont = font
            cachedBaseColor = color
            cachedBaseAttributes = [.font: font, .foregroundColor: color]
        }

        func textDidChange(_ notification: Notification) {
            guard !isNormalizingAttributes,
                  let textView = notification.object as? NSTextView else { return }
            normalizePlainTextAttributes(in: textView)
            text.wrappedValue = canonicalText(in: textView)
            let isEmpty = textView.string.isEmpty
            if isEmpty != wasEmpty {
                wasEmpty = isEmpty
                textView.needsDisplay = true
            }
            recalculateHeight(scrollToCursor: true)
        }

        @discardableResult
        func completeTab(in textView: SubmitTextView) -> Bool {
            let selectedRange = textView.selectedRange()
            let result = tabCompletion(textView.string, selectedRange)
            guard let completion = result.completion else { return result.shouldConsume }
            guard NSMaxRange(completion.replacementRange) <= (textView.string as NSString).length else { return result.shouldConsume }
            guard textView.shouldChangeText(in: completion.replacementRange, replacementString: completion.replacement) else { return result.shouldConsume }
            textView.replaceCharacters(in: completion.replacementRange, with: completion.replacement)
            textView.didChangeText()
            let cursor = completion.cursorLocation ?? completion.replacementRange.location + (completion.replacement as NSString).length
            textView.setSelectedRange(NSRange(location: cursor, length: 0))
            text.wrappedValue = canonicalText(in: textView)
            recalculateHeight(scrollToCursor: true)
            scheduleRecalculateHeight(scrollToCursor: true)
            return true
        }

        private func matchesBaseAttributes(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
            attributes.count == 2
                && (attributes[.font] as? NSFont) == cachedBaseFont
                && (attributes[.foregroundColor] as? NSColor) == cachedBaseColor
        }

        private func normalizePlainTextAttributes(in textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            var rangesToNormalize: [NSRange] = []
            var index = 0
            while index < storage.length {
                var range = NSRange()
                let attributes = storage.attributes(at: index, effectiveRange: &range)
                if attributes[.attachment] == nil, !matchesBaseAttributes(attributes) {
                    rangesToNormalize.append(range)
                }
                index = NSMaxRange(range)
            }
            if !rangesToNormalize.isEmpty {
                isNormalizingAttributes = true
                defer { isNormalizingAttributes = false }
                storage.beginEditing()
                for range in rangesToNormalize {
                    storage.setAttributes(cachedBaseAttributes, range: range)
                }
                storage.endEditing()
            }
            if !matchesBaseAttributes(textView.typingAttributes) {
                textView.typingAttributes = cachedBaseAttributes
            }
        }

        func canonicalText(in textView: NSTextView) -> String {
            guard let storage = textView.textStorage else { return textView.string }
            var result = ""
            var index = 0
            while index < storage.length {
                var range = NSRange()
                let character = (storage.string as NSString).character(at: index)
                if character == 0xFFFC,
                   let marker = storage.attribute(.pigComposerToken, at: index, effectiveRange: &range) as? String {
                    result += marker
                    index += 1
                } else {
                    storage.attribute(.pigComposerToken, at: index, effectiveRange: &range)
                    let safeEnd = min(NSMaxRange(range), storage.length)
                    let safeRange = NSRange(location: index, length: max(1, safeEnd - index))
                    result += storage.attributedSubstring(from: safeRange).string
                    index = NSMaxRange(safeRange)
                }
            }
            return result
        }

        func applyCanonicalText(_ canonical: String, to textView: NSTextView) {
            let previousSelection = textView.selectedRange()
            let attributed = NSMutableAttributedString()
            let base = cachedBaseAttributes
            for segment in ComposerTokenCodec.rawSegments(in: canonical) {
                switch segment {
                case .text(let value):
                    attributed.append(NSAttributedString(string: value, attributes: base))
                case .token(let token, let rawMarker):
                    let attachment = NSTextAttachment()
                    attachment.attachmentCell = ComposerTokenAttachmentCell(token: token, palette: theme.palette)
                    attributed.append(NSAttributedString(
                        string: "\u{FFFC}",
                        attributes: [.attachment: attachment, .pigComposerToken: rawMarker]
                    ))
                }
            }
            textView.textStorage?.setAttributedString(attributed)
            textView.typingAttributes = base
            wasEmpty = attributed.length == 0
            let location = min(previousSelection.location, attributed.length)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            textView.needsDisplay = true
            scheduleRecalculateHeight(scrollToCursor: true)
        }

        func insertFiles(_ urls: [URL], in textView: SubmitTextView) {
            guard !urls.isEmpty else { return }
            let markers = urls.map { url -> String in
                let path = url.standardizedFileURL.path
                let token = ComposerToken(kind: .file, value: path, label: url.lastPathComponent, detail: path, resourcePath: path)
                return ComposerTokenCodec.marker(for: token)
            }.joined()
            let updated = ComposerTokenCodec.replacingEditingRange(textView.selectedRange(), in: canonicalText(in: textView), with: markers)
            applyCanonicalText(updated, to: textView)
            text.wrappedValue = updated
        }

        func scheduleRecalculateHeight(scrollToCursor: Bool = false) {
            guard !recalculationScheduled else { return }
            recalculationScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.recalculationScheduled = false
                self.recalculateHeight(scrollToCursor: scrollToCursor)
            }
        }

        func recalculateHeight(scrollToCursor: Bool = false) {
            guard Thread.isMainThread else {
                DispatchQueue.main.async { [weak self] in self?.recalculateHeight(scrollToCursor: scrollToCursor) }
                return
            }
            guard let textView, let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }

            let viewWidth = measuredContentWidth(for: textView)
            let containerWidth = max(viewWidth - textView.textContainerInset.width * 2, 20)
            let storageLength = textView.textStorage?.length ?? (textView.string as NSString).length

            textView.textContainer?.widthTracksTextView = false
            textView.frame = NSRect(x: 0, y: 0, width: viewWidth, height: max(lastDocumentHeight, minHeight))

            if abs(containerWidth - lastMeasuredWidth) > 0.5 {
                lastMeasuredWidth = containerWidth
                layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storageLength), actualCharacterRange: nil)
            }

            textContainer.containerSize = NSSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: textContainer)

            let textKitHeight = ceil(layoutManager.usedRect(for: textContainer).height)
            let fallbackHeight = fallbackTextHeight(for: textView.string, width: containerWidth, font: textView.font)
            let hardLineHeight = minimumHeightForHardLines(in: textView.string, font: textView.font)
            let contentHeight = max(textKitHeight, fallbackHeight, hardLineHeight)
            let documentHeight = max(ceil(contentHeight + textView.textContainerInset.height * 2 + 2), minHeight)
            let next = min(documentHeight, maxHeight)

            lastDocumentHeight = documentHeight
            textView.frame = NSRect(x: 0, y: 0, width: viewWidth, height: documentHeight)
            scrollView?.hasVerticalScroller = documentHeight > maxHeight + 0.5

            if abs(height.wrappedValue - next) > 0.5 { height.wrappedValue = next }
            if scrollToCursor { textView.scrollRangeToVisible(textView.selectedRange()) }
        }

        private func measuredContentWidth(for textView: NSTextView) -> CGFloat {
            let candidates: [CGFloat] = [
                scrollView?.contentView.bounds.width ?? 0,
                scrollView?.bounds.width ?? 0,
                textView.enclosingScrollView?.contentView.bounds.width ?? 0,
                textView.bounds.width
            ]
            if let width = candidates.first(where: { $0.isFinite && $0 > 20 }) {
                return width
            }
            if lastMeasuredWidth > 20 {
                return lastMeasuredWidth + textView.textContainerInset.width * 2
            }
            return 100
        }

        private func fallbackTextHeight(for text: String, width: CGFloat, font: NSFont?) -> CGFloat {
            let font = font ?? AppFonts.nsUI(15.5)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: paragraph
            ]
            let measuredText = text.isEmpty ? " " : text
            let rect = (measuredText as NSString).boundingRect(
                with: NSSize(width: max(width, 20), height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes
            )
            return ceil(rect.height)
        }

        private func minimumHeightForHardLines(in text: String, font: NSFont?) -> CGFloat {
            let font = font ?? AppFonts.nsUI(15.5)
            let lineCount = text.reduce(1) { count, character in
                character == "\n" ? count + 1 : count
            }
            return CGFloat(lineCount) * ceil(font.ascender - font.descender + font.leading)
        }
    }

    final class ComposerScrollView: NSScrollView {
        var onLayout: (() -> Void)?
        private var lastContentSize: CGSize = .zero

        override func layout() {
            super.layout()
            notifyIfSizeChanged()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onLayout?()
        }

        private func notifyIfSizeChanged() {
            let size = contentView.bounds.size
            guard abs(size.width - lastContentSize.width) > 0.5 || abs(size.height - lastContentSize.height) > 0.5 else { return }
            lastContentSize = size
            onLayout?()
        }
    }

    final class SubmitTextView: NSTextView {
        var onSubmit: (() -> Void)?
        var onFollowUpSubmit: (() -> Void)?
        var onDequeue: (() -> Void)?
        var onTab: ((SubmitTextView) -> Bool)?
        var onKeyCommand: ((ComposerKeyCommand) -> Bool)?
        var onCyclePinnedModel: (() -> Bool)?
        var onFocusChange: ((Bool) -> Void)?
        var onFilesInserted: (([URL], SubmitTextView) -> Void)?
        var onImagePasted: (([ImageAttachment]) -> Void)?
        var placeholder = ""
        var placeholderColor = NSColor.placeholderTextColor

        override var acceptsFirstResponder: Bool { true }

        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became { onFocusChange?(true) }
            return became
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { onFocusChange?(false) }
            return resigned
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty, !placeholder.isEmpty else { return }
            let font = font ?? AppFonts.nsUI(15.5)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: placeholderColor
            ]
            placeholder.draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height), withAttributes: attributes)
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : super.draggingEntered(sender)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            guard !urls.isEmpty else { return super.performDragOperation(sender) }
            onFilesInserted?(urls, self)
            return true
        }

        override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
            var types = super.readablePasteboardTypes
            for type in composerImagePasteboardTypes where !types.contains(type) {
                types.insert(type, at: 0)
            }
            return types
        }

        override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
            if item.action == #selector(paste(_:)) || item.action == #selector(pasteAsPlainText(_:)) {
                let pasteboard = NSPasteboard.general
                if pasteboardHasComposerImage(pasteboard) { return true }
                if pasteboard.availableType(from: [.fileURL]) != nil { return true }
            }
            return super.validateUserInterfaceItem(item)
        }

        override func paste(_ sender: Any?) {
            if insertPastedContent(from: NSPasteboard.general) { return }
            super.paste(sender)
        }

        override func pasteAsPlainText(_ sender: Any?) {
            if insertPastedContent(from: NSPasteboard.general) { return }
            super.pasteAsPlainText(sender)
        }

        private func insertPastedContent(from pasteboard: NSPasteboard) -> Bool {
            // Image bytes before file URLs: screenshot boards can advertise
            // promised files, and reading those would consume the image.
            // Skip image paste when real text is present so HTML/web copies
            // still paste as text.
            let hasText = pasteboard.string(forType: .string)?.isEmpty == false
            if !hasText, let image = pastedImageAttachment(from: pasteboard) {
                onImagePasted?([image])
                return true
            }
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            if !urls.isEmpty {
                onFilesInserted?(urls, self)
                return true
            }
            return false
        }

        override func copy(_ sender: Any?) {
            let range = selectedRange()
            guard range.length > 0, let storage = textStorage else { return super.copy(sender) }
            let selected = storage.attributedSubstring(from: range)
            var plain = ""
            var index = 0
            while index < selected.length {
                var effective = NSRange()
                let character = (selected.string as NSString).character(at: index)
                if character == 0xFFFC,
                   let marker = selected.attribute(.pigComposerToken, at: index, effectiveRange: &effective) as? String,
                   let token = ComposerTokenCodec.tokens(in: marker).first {
                    plain += token.plainText
                    index += 1
                } else {
                    selected.attribute(.pigComposerToken, at: index, effectiveRange: &effective)
                    let safeEnd = min(NSMaxRange(effective), selected.length)
                    let safeRange = NSRange(location: index, length: max(1, safeEnd - index))
                    plain += selected.attributedSubstring(from: safeRange).string
                    index = NSMaxRange(safeRange)
                }
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(plain, forType: .string)
        }

        override func deleteBackward(_ sender: Any?) {
            let selection = selectedRange()
            let tokenRange: NSRange?
            if selection.length == 0, selection.location > 0,
               isToken(at: selection.location - 1) {
                tokenRange = NSRange(location: selection.location - 1, length: 1)
            } else if selection.length == 1, isToken(at: selection.location) {
                tokenRange = selection
            } else {
                tokenRange = nil
            }
            guard var deletion = tokenRange else {
                super.deleteBackward(sender)
                return
            }
            if NSMaxRange(deletion) < (string as NSString).length,
               isHorizontalWhitespace(at: NSMaxRange(deletion)) {
                deletion.length += 1
            }
            guard shouldChangeText(in: deletion, replacementString: "") else { return }
            replaceCharacters(in: deletion, with: "")
            didChangeText()
        }

        override func deleteForward(_ sender: Any?) {
            let selection = selectedRange()
            let tokenRange: NSRange?
            if selection.length == 0, selection.location < (string as NSString).length,
               isToken(at: selection.location) {
                tokenRange = NSRange(location: selection.location, length: 1)
            } else if selection.length == 1, isToken(at: selection.location) {
                tokenRange = selection
            } else {
                tokenRange = nil
            }
            guard var deletion = tokenRange else {
                super.deleteForward(sender)
                return
            }
            if NSMaxRange(deletion) < (string as NSString).length,
               isHorizontalWhitespace(at: NSMaxRange(deletion)) {
                deletion.length += 1
            }
            guard shouldChangeText(in: deletion, replacementString: "") else { return }
            replaceCharacters(in: deletion, with: "")
            didChangeText()
        }

        private func isToken(at location: Int) -> Bool {
            guard location >= 0, location < (string as NSString).length else { return false }
            return (string as NSString).character(at: location) == 0xFFFC
                && textStorage?.attribute(.pigComposerToken, at: location, effectiveRange: nil) != nil
        }

        private func isHorizontalWhitespace(at location: Int) -> Bool {
            guard location >= 0, location < (string as NSString).length else { return false }
            let character = (string as NSString).character(at: location)
            return character == 32 || character == 9
        }

        override func mouseDown(with event: NSEvent) {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(self)
            super.mouseDown(with: event)
        }

        override func keyDown(with event: NSEvent) {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let commandModifiers = modifiers.subtracting([.capsLock, .numericPad, .function])
            if commandModifiers == .control {
                switch event.keyCode {
                case 35: // control-p
                    if onKeyCommand?(.moveUp) == true { return }
                case 45: // control-n
                    if onKeyCommand?(.moveDown) == true { return }
                default:
                    break
                }
            } else if commandModifiers == .option, event.keyCode == 126 { // option-up
                onDequeue?()
                return
            } else if commandModifiers == .shift, event.keyCode == 48 { // shift-tab
                if onCyclePinnedModel?() == true { return }
            } else if commandModifiers.isEmpty {
                // Arrow keys, Escape, and Tab steer the suggestion popup when
                // it is visible; the handler returns false to pass through.
                switch event.keyCode {
                case 126: // up arrow
                    if onKeyCommand?(.moveUp) == true { return }
                case 125: // down arrow
                    if onKeyCommand?(.moveDown) == true { return }
                case 53: // escape
                    if onKeyCommand?(.dismiss) == true { return }
                case 48: // tab
                    if onKeyCommand?(.accept) == true { return }
                    if onTab?(self) == true { return }
                default:
                    break
                }
            }
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            if isReturn {
                if commandModifiers.contains(.shift) {
                    insertNewline(nil)
                } else if onKeyCommand?(.accept) == true {
                    // Return accepted the highlighted suggestion.
                } else if commandModifiers.contains(.option) {
                    onFollowUpSubmit?()
                } else {
                    onSubmit?()
                }
                return
            }
            super.keyDown(with: event)
        }
    }
}
