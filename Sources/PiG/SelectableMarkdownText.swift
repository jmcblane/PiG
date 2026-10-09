import SwiftUI
import AppKit

// MARK: - Segmentation

// A message body renders as a few segments: consecutive text-like blocks
// (paragraphs, headings, quotes, lists, rules) merge into one selectable
// NSTextView so selection and copy work across block boundaries. Code blocks
// and tables stay SwiftUI views (copy button, horizontal scroll, Grid), so
// selection breaks only at those.
enum MarkdownRenderSegment: Hashable {
    case text([MarkdownBlock])
    case code(String, language: String?)
    case table(header: [String]?, rows: [[String]])
    case htmlWidget(String)

    static func segments(from blocks: [MarkdownBlock]) -> [MarkdownRenderSegment] {
        var segments: [MarkdownRenderSegment] = []
        var textRun: [MarkdownBlock] = []
        func flushText() {
            guard !textRun.isEmpty else { return }
            segments.append(.text(textRun))
            textRun.removeAll()
        }
        for block in blocks {
            switch block {
            case .code(let code, let language):
                flushText()
                segments.append(.code(code, language: language))
            case .table(let header, let rows):
                flushText()
                segments.append(.table(header: header, rows: rows))
            case .paragraph(let text):
                if let reference = HTMLArtifact.reference(in: text) {
                    flushText()
                    segments.append(.htmlWidget(reference))
                } else {
                    textRun.append(block)
                }
            default:
                textRun.append(block)
            }
        }
        flushText()
        return segments
    }
}

// MARK: - Decorations

// Non-text ornaments (quote bars, H1 underline, horizontal rules) drawn by
// MarkdownTextView behind the text; they are not part of the selectable text.
final class MarkdownTextDecoration: NSObject {
    enum Kind {
        case quoteBar
        case headingRule
        case horizontalRule
    }

    let kind: Kind
    let color: NSColor

    init(kind: Kind, color: NSColor) {
        self.kind = kind
        self.color = color
    }
}

extension NSAttributedString.Key {
    static let pigDecoration = NSAttributedString.Key("PiGMarkdownDecoration")
}

private final class MessageTokenAttachmentCell: NSTextAttachmentCell {
    let token: ComposerToken
    let palette: AppThemePalette
    let isAvailable: Bool

    init(token: ComposerToken, palette: AppThemePalette, isAvailable: Bool) {
        self.token = token
        self.palette = palette
        self.isAvailable = isAvailable
        super.init(textCell: token.label)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func cellSize() -> NSSize {
        let labelWidth = (token.label as NSString).size(withAttributes: [
            .font: AppFonts.nsUI(13.5, weight: .semibold)
        ]).width
        let warningWidth: CGFloat = isAvailable ? 0 : 18
        return NSSize(width: min(AppFonts.scaled(300), ceil(labelWidth + AppFonts.scaled(36 + warningWidth))), height: AppFonts.scaled(24))
    }

    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -AppFonts.scaled(5)) }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let rect = cellFrame.insetBy(dx: 1, dy: 1)
        let accent = isAvailable ? palette.accent.nsColor : palette.danger.nsColor
        palette.codeBackground.nsColor.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        accent.withAlphaComponent(isAvailable ? 0.45 : 0.8).setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        border.lineWidth = 1
        border.stroke()

        if token.kind == .skill {
            ("$" as NSString).draw(
                in: NSRect(x: rect.minX + 8, y: rect.minY + 3, width: 12, height: 18),
                withAttributes: [
                    .font: AppFonts.nsUI(14, weight: .bold),
                    .foregroundColor: accent
                ]
            )
        } else if let image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [accent])) {
            image.draw(in: NSRect(x: rect.minX + 8, y: rect.minY + 5, width: 13, height: 13))
        }

        let trailingInset: CGFloat = isAvailable ? 6 : 23
        (token.label as NSString).draw(
            in: NSRect(x: rect.minX + AppFonts.scaled(27), y: rect.minY + AppFonts.scaled(4), width: rect.width - AppFonts.scaled(27 + trailingInset), height: AppFonts.scaled(17)),
            withAttributes: [
                .font: AppFonts.nsUI(13.5, weight: .semibold),
                .foregroundColor: isAvailable ? palette.text.nsColor : palette.danger.nsColor
            ]
        )

        if !isAvailable,
           let warning = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [palette.danger.nsColor])) {
            warning.draw(in: NSRect(x: rect.maxX - 17, y: rect.minY + 6, width: 11, height: 11))
        }
    }
}

// A rendered text segment plus the two facts needed to update a text view
// incrementally while the segment streams: how much of the front is known
// unchanged, and a token identifying the styling it was built with.
struct MarkdownAttributedText {
    let attributed: NSAttributedString
    let stablePrefixLength: Int
    let styleKey: Int
}

// MARK: - Attributed string builder

// Mirrors the styling NativeMarkdownView previously produced with per-block
// SwiftUI Texts, using the shared MarkdownTypography constants.
enum MarkdownSelectableTextBuilder {
    private struct BlockKey: Hashable {
        let block: MarkdownBlock
        let role: MessageRole
        let theme: AppThemeChoice
        let projectPath: String?
        let textSizeStep: Int
    }

    private struct SegmentKey: Hashable {
        let blocks: [MarkdownBlock]
        let role: MessageRole
        let theme: AppThemeChoice
        let projectPath: String?
        let textSizeStep: Int
    }

    // Segments that did not change return the identical instance, which lets
    // the text view skip them outright rather than re-applying equal text.
    // Only the segment being streamed into is ever rebuilt.
    private static let segmentCache = MarkdownFIFOCache<SegmentKey, MarkdownAttributedText>(limit: 400)

    // Inline rendering (AttributedString's markdown parser, per run styling)
    // dominates the cost of drawing a message. Caching it per block means a
    // streaming frame re-renders only the block that grew, instead of the
    // whole message, which is what made long answers quadratic.
    private static let blockCache = MarkdownFIFOCache<BlockKey, NSAttributedString>(limit: 1200)

    // `cacheable` is false for the one segment currently being streamed
    // into: it differs every frame, so caching it would insert a whole copy
    // of the segment per frame and evict the stable segments that make this
    // cache worth having.
    static func build(
        blocks: [MarkdownBlock],
        role: MessageRole,
        theme: AppThemeChoice,
        projectPath: String? = nil,
        cacheable: Bool = true
    ) -> MarkdownAttributedText {
        let segmentKey = SegmentKey(blocks: blocks, role: role, theme: theme, projectPath: projectPath, textSizeStep: TextSizePreference.step)
        if let cached = segmentCache.value(for: segmentKey) { return cached }
        let built = makeText(blocks: blocks, role: role, theme: theme, projectPath: projectPath, cacheable: cacheable)
        if cacheable { segmentCache.insert(built, for: segmentKey) }
        return built
    }

    private static func makeText(blocks: [MarkdownBlock], role: MessageRole, theme: AppThemeChoice, projectPath: String?, cacheable: Bool) -> MarkdownAttributedText {
        let result = NSMutableAttributedString()
        var stablePrefixLength = 0
        let lastIndex = blocks.count - 1
        for (index, block) in blocks.enumerated() {
            // In a streaming segment only the final block can still grow.
            // Cache settled blocks, but do not retain one copy of the growing
            // block for every rendered frame.
            let rendered = render(
                block,
                role: role,
                theme: theme,
                projectPath: projectPath,
                cacheable: cacheable || index != lastIndex
            )
            guard rendered.length > 0 else { continue }
            // While a message streams, only the final block can still change
            // (earlier blocks are closed by the text that follows them), so
            // everything before it is a prefix the text view can keep.
            if index == lastIndex { stablePrefixLength = result.length }
            if result.length > 0 {
                // Carry only paragraph layout onto the separator. Copying all
                // attributes makes trailing inline styles color the newline.
                result.append(paragraphBreak(after: result))
            }
            result.append(rendered)
        }
        var styleHasher = Hasher()
        styleHasher.combine(role)
        styleHasher.combine(theme)
        styleHasher.combine(TextSizePreference.step)
        return MarkdownAttributedText(
            attributed: result.copy() as? NSAttributedString ?? NSAttributedString(),
            stablePrefixLength: stablePrefixLength,
            styleKey: styleHasher.finalize()
        )
    }

    private static func render(_ block: MarkdownBlock, role: MessageRole, theme: AppThemeChoice, projectPath: String?, cacheable: Bool) -> NSAttributedString {
        let key = BlockKey(block: block, role: role, theme: theme, projectPath: projectPath, textSizeStep: TextSizePreference.step)
        if let cached = blockCache.value(for: key) { return cached }

        let palette = theme.palette.markdown
        let bodyFont = AppFonts.nsUI(MarkdownTypography.bodySize)
        let bodyColor = role == .user
            ? palette.userForeground.nsColor
            : palette.assistantForeground.nsColor
        let rendered = render(block, bodyFont: bodyFont, bodyColor: bodyColor, theme: theme, projectPath: projectPath).copy() as? NSAttributedString
            ?? NSAttributedString()
        if cacheable { blockCache.insert(rendered, for: key) }
        return rendered
    }

    private static func paragraphBreak(after string: NSAttributedString) -> NSAttributedString {
        guard string.length > 0,
              let style = string.attribute(.paragraphStyle, at: string.length - 1, effectiveRange: nil) else {
            return NSAttributedString(string: "\n")
        }
        return NSAttributedString(string: "\n", attributes: [.paragraphStyle: style])
    }

    private static func render(_ block: MarkdownBlock, bodyFont: NSFont, bodyColor: NSColor, theme: AppThemeChoice, projectPath: String?) -> NSAttributedString {
        let palette = theme.palette.markdown
        switch block {
        case .paragraph(let text):
            let paragraph = inline(singleParagraph(text), font: bodyFont, color: bodyColor, theme: theme, projectPath: projectPath)
            paragraph.addAttribute(.paragraphStyle, value: bodyParagraphStyle(), range: fullRange(paragraph))
            return paragraph

        case .heading(let level, let text):
            let font = AppFonts.nsHeading(MarkdownTypography.headingSize(forLevel: level))
            let heading = inline(singleParagraph(text), font: font, color: palette.strong.nsColor, theme: theme, projectPath: projectPath)
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = 5
            // H1 reserves room below for its drawn accent underline.
            style.paragraphSpacing = level == 1 ? 17 : 10
            heading.addAttribute(.paragraphStyle, value: style, range: fullRange(heading))
            if level == 1 {
                heading.addAttribute(
                    .pigDecoration,
                    value: MarkdownTextDecoration(kind: .headingRule, color: theme.palette.markdownAccent.nsColor),
                    range: fullRange(heading)
                )
            }
            return heading

        case .quote(let text):
            let quote = inline(singleParagraph(text), font: bodyFont, color: palette.quoteForeground.nsColor, theme: theme, projectPath: projectPath)
            let style = bodyParagraphStyle()
            style.firstLineHeadIndent = 13
            style.headIndent = 13
            style.paragraphSpacingBefore = 3
            style.paragraphSpacing = 13
            quote.addAttributes([
                .paragraphStyle: style,
                .pigDecoration: MarkdownTextDecoration(kind: .quoteBar, color: theme.palette.markdownAccent.nsColor),
            ], range: fullRange(quote))
            return quote

        case .list(let items):
            return list(items: items, bodyFont: bodyFont, bodyColor: bodyColor, theme: theme, projectPath: projectPath)

        case .rule:
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = 4
            style.paragraphSpacing = 14
            return NSAttributedString(string: "\u{00A0}", attributes: [
                .font: AppFonts.nsUI(9),
                .paragraphStyle: style,
                .pigDecoration: MarkdownTextDecoration(kind: .horizontalRule, color: palette.codeBorder.nsColor),
            ])

        case .code, .table:
            // Rendered as separate segments, never reaches the builder.
            return NSAttributedString()
        }
    }

    // Returns (done: nil) when the item is not a task list item.
    private static func taskListItem(_ item: String) -> (done: Bool?, text: String) {
        let markers: [(String, Bool)] = [("[ ] ", false), ("[x] ", true), ("[X] ", true)]
        for (marker, done) in markers where item.hasPrefix(marker) {
            return (done, String(item.dropFirst(marker.count)))
        }
        return (nil, item)
    }

    private static func list(items: [MarkdownListItem], bodyFont: NSFont, bodyColor: NSColor, theme: AppThemeChoice, projectPath: String?) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, item) in items.enumerated() {
            let marker: String
            let text: String
            switch item.marker {
            case .unordered:
                let task = taskListItem(item.text)
                text = task.text
                switch task.done {
                case nil: marker = "•"
                case true?: marker = "☑"
                case false?: marker = "☐"
                }
            case .ordered(let number):
                marker = "\(number)."
                text = item.text
            }
            let paragraph = NSMutableAttributedString(string: "\(marker)\t", attributes: [
                .font: bodyFont,
                .foregroundColor: bodyColor,
            ])
            paragraph.append(inline(singleParagraph(text), font: bodyFont, color: bodyColor, theme: theme, projectPath: projectPath))
            let markerIndent = 8 + CGFloat(item.depth) * 24
            let textIndent = 30 + CGFloat(item.depth) * 24
            let style = bodyParagraphStyle()
            style.firstLineHeadIndent = markerIndent
            style.headIndent = textIndent
            style.tabStops = [NSTextTab(textAlignment: .left, location: textIndent)]
            style.paragraphSpacing = index == items.count - 1 ? 10 : 3
            paragraph.addAttribute(.paragraphStyle, value: style, range: fullRange(paragraph))
            if result.length > 0 {
                result.append(paragraphBreak(after: result))
            }
            result.append(paragraph)
        }
        return result
    }

    // Inline markdown for selectable AppKit text, including file tokens.
    private static func inline(_ text: String, font: NSFont, color: NSColor, theme: AppThemeChoice, projectPath: String?) -> NSMutableAttributedString {
        let palette = theme.palette.markdown
        let protected = protectingTokens(in: text)
        let parsed = (try? AttributedString(
            markdown: MarkdownInlineRenderer.autoLinkedMarkdown(protected.text),
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(text)

        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed.characters[run.range])
            var attrs: [NSAttributedString.Key: Any] = [:]
            var pieceFont = font
            var pieceColor = color

            if let link = run.link {
                attrs[.link] = link
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                pieceColor = palette.link.nsColor
            }
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.stronglyEmphasized) {
                pieceFont = applying(traits: .bold, to: pieceFont)
                pieceColor = palette.strong.nsColor
            }
            if intent.contains(.emphasized) {
                pieceFont = applying(traits: .italic, to: pieceFont)
                if !intent.contains(.stronglyEmphasized) {
                    pieceColor = palette.emphasis.nsColor
                }
            }
            if intent.contains(.strikethrough) {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                pieceColor = palette.deleted.nsColor
            }
            if intent.contains(.code) {
                pieceFont = AppFonts.nsCode(MarkdownTypography.codeSize)
                pieceColor = theme.palette.markdownCodeForeground.nsColor
                attrs[.backgroundColor] = palette.codeBackground.nsColor
            }

            attrs[.font] = pieceFont
            attrs[.foregroundColor] = pieceColor
            result.append(NSAttributedString(string: piece, attributes: attrs))
        }

        for item in protected.items.reversed() {
            let range = (result.string as NSString).range(of: item.placeholder)
            guard range.location != NSNotFound else { continue }
            let path = resolvedPath(for: item.token, projectPath: projectPath)
            let available = path.map { FileManager.default.fileExists(atPath: $0) } ?? false
            let attachment = NSTextAttachment()
            attachment.attachmentCell = MessageTokenAttachmentCell(
                token: item.token,
                palette: theme.palette,
                isAvailable: available
            )
            var attributes: [NSAttributedString.Key: Any] = [.attachment: attachment]
            if let path, available { attributes[.link] = URL(fileURLWithPath: path) }
            result.replaceCharacters(
                in: range,
                with: NSAttributedString(string: "\u{FFFC}", attributes: attributes)
            )
        }
        return result
    }

    private struct ProtectedToken {
        var placeholder: String
        var token: ComposerToken
    }

    private static func protectingTokens(in text: String) -> (text: String, items: [ProtectedToken]) {
        var protectedText = ""
        var items: [ProtectedToken] = []
        for segment in ComposerTokenCodec.segments(in: text) {
            switch segment {
            case .text(let value):
                protectedText += value
            case .token(let token):
                let placeholder = "\u{E006}PIGTOKEN\(items.count)\u{E007}"
                protectedText += placeholder
                items.append(ProtectedToken(placeholder: placeholder, token: token))
            }
        }
        return (protectedText, items)
    }

    private static func resolvedPath(for token: ComposerToken, projectPath: String?) -> String? {
        switch token.kind {
        case .skill:
            return token.resourcePath.map { ($0 as NSString).expandingTildeInPath }
        case .file:
            if token.value.hasPrefix("/") {
                return URL(fileURLWithPath: token.value).standardizedFileURL.path
            }
            guard let projectPath else { return nil }
            let root = URL(fileURLWithPath: projectPath, isDirectory: true).standardizedFileURL
            let url = root.appendingPathComponent(token.value).standardizedFileURL
            guard url.path.hasPrefix(root.path + "/") else { return nil }
            return url.path
        }
    }

    private static func bodyParagraphStyle() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = AppFonts.scaled(MarkdownTypography.bodyLineSpacing)
        style.paragraphSpacing = 10
        return style
    }

    // Source soft-wraps become line separators so a block stays one TextKit
    // paragraph and keeps one paragraph style.
    private static func singleParagraph(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "\u{2028}")
    }

    private static func applying(traits: NSFontDescriptor.SymbolicTraits, to font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    private static func fullRange(_ string: NSAttributedString) -> NSRange {
        NSRange(location: 0, length: string.length)
    }
}

// MARK: - Text view

final class MarkdownTextView: NSTextView {
    // Explicit TextKit 1 stack: deterministic measurement via
    // layoutManager.usedRect, and per-message documents are small.
    static func make() -> MarkdownTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        let view = MarkdownTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = NSSize.zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.minSize = NSSize.zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // Colors come from the attributed string; keep only the hand cursor.
        let linkAttributes: [NSAttributedString.Key: Any] = [.cursor: NSCursor.pointingHand]
        view.linkTextAttributes = linkAttributes
        return view
    }

    // Measured through this view's own layout manager, so the layout the
    // measurement produces is the same one used to draw. Measuring on a
    // separate TextKit stack would lay every message out twice per frame.
    func measuredHeight(forWidth width: CGFloat) -> CGFloat {
        guard let layoutManager, let textContainer else { return 0 }
        textContainer.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        return ceil(layoutManager.usedRect(for: textContainer).height)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawDecorations(in: dirtyRect)
        super.draw(dirtyRect)
    }

    // Only the characters intersecting `dirtyRect` are enumerated: scanning
    // the whole storage on every draw is O(message) per streaming frame.
    private func drawDecorations(in dirtyRect: NSRect) {
        guard let layoutManager, let textContainer, let textStorage, textStorage.length > 0 else { return }
        let origin = textContainerOrigin
        let dirtyGlyphs = layoutManager.glyphRange(
            forBoundingRect: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y),
            in: textContainer
        )
        var dirtyChars = layoutManager.characterRange(forGlyphRange: dirtyGlyphs, actualGlyphRange: nil)
        // Decorations draw outside their line fragment (quote bars, the H1
        // underline), so widen by a character on each side.
        dirtyChars = NSRange(
            location: max(0, dirtyChars.location - 1),
            length: min(textStorage.length, dirtyChars.location + dirtyChars.length + 1) - max(0, dirtyChars.location - 1)
        )
        guard dirtyChars.length > 0 else { return }
        textStorage.enumerateAttribute(.pigDecoration, in: dirtyChars) { value, range, _ in
            guard let decoration = value as? MarkdownTextDecoration else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let frame = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                .offsetBy(dx: origin.x, dy: origin.y)
            decoration.color.setFill()
            switch decoration.kind {
            case .quoteBar:
                NSRect(x: 0, y: max(0, frame.minY - 3), width: 2, height: frame.height + 6).fill()
            case .headingRule:
                NSRect(x: 0, y: frame.maxY + 6, width: bounds.width, height: 1).fill()
            case .horizontalRule:
                NSRect(x: 0, y: frame.midY - 0.5, width: bounds.width, height: 1).fill()
            }
        }
    }
}

// MARK: - Representable

struct SelectableMarkdownText: NSViewRepresentable {
    let text: MarkdownAttributedText

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MarkdownTextView {
        let view = MarkdownTextView.make()
        apply(to: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: MarkdownTextView, context: Context) {
        apply(to: nsView, coordinator: context.coordinator)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        // Push the current text in first: measuring is only valid against the
        // storage it will be drawn from, and this removes any dependence on
        // SwiftUI calling updateNSView before sizeThatFits.
        apply(to: nsView, coordinator: context.coordinator)
        if let cached = context.coordinator.heightForWidth[width] {
            return CGSize(width: width, height: cached)
        }
        let height = nsView.measuredHeight(forWidth: width)
        context.coordinator.heightForWidth[width] = height
        return CGSize(width: width, height: height)
    }

    // Streaming appends to a message, so replacing the whole text storage
    // every frame made TextKit re-lay-out the entire message each time —
    // O(message) per frame, quadratic over the message's life. Replacing only
    // the tail lets TextKit invalidate just the changed range.
    private func apply(to view: MarkdownTextView, coordinator: Coordinator) {
        guard coordinator.text?.attributed !== text.attributed else { return }
        let previous = coordinator.text
        coordinator.text = text
        coordinator.heightForWidth.removeAll()
        guard let storage = view.textStorage else { return }

        guard let previous,
              previous.styleKey == text.styleKey,
              storage.length == previous.attributed.length,
              case let reusable = min(previous.stablePrefixLength, text.stablePrefixLength),
              reusable > 0,
              reusable <= text.attributed.length,
              sharesTextPrefix(previous.attributed, text.attributed, length: reusable) else {
            storage.setAttributedString(text.attributed)
            return
        }

        let tail = text.attributed.attributedSubstring(
            from: NSRange(location: reusable, length: text.attributed.length - reusable)
        )
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: reusable, length: storage.length - reusable), with: tail)
        storage.endEditing()
    }

    // Cheap guard for the incremental path: the stable-prefix bookkeeping
    // should already guarantee this, but a plain-text comparison costs a
    // memcmp and rules out ever painting stale attributes.
    private func sharesTextPrefix(_ lhs: NSAttributedString, _ rhs: NSAttributedString, length: Int) -> Bool {
        guard lhs.length >= length, rhs.length >= length else { return false }
        return (lhs.string as NSString).substring(to: length) == (rhs.string as NSString).substring(to: length)
    }

    final class Coordinator {
        var text: MarkdownAttributedText?
        var heightForWidth: [CGFloat: CGFloat] = [:]
    }
}
