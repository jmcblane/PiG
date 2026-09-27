import SwiftUI
import AppKit

// Shared typography constants for the native text and code renderers.
enum MarkdownTypography {
    static let bodySize: CGFloat = 15.5
    static let bodyLineSpacing: CGFloat = 3.5
    static let codeSize: CGFloat = 13.2

    static func headingSize(forLevel level: Int) -> CGFloat {
        switch level {
        case 1: return 27
        case 2: return 23
        case 3: return 19
        default: return 16.5
        }
    }
}

enum MarkdownListMarker: Hashable {
    case unordered
    case ordered(Int)
}

struct MarkdownListItem: Hashable {
    let depth: Int
    let marker: MarkdownListMarker
    let text: String
}

enum MarkdownBlock: Hashable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(String, language: String?)
    case quote(String)
    case list(items: [MarkdownListItem])
    case table(header: [String]?, rows: [[String]])
    case rule
}

// Line-based block parser: the single markdown parser in the app. Streaming
// and finalized messages both render from these blocks, so a message can
// never reflow because two renderers disagreed.
enum MarkdownBlockParser {
    private enum ParsedListMarker {
        case unordered
        case ordered(Int)
    }

    private static func listItem(_ line: String) -> (indentation: Int, marker: ParsedListMarker, text: String)? {
        var index = line.startIndex
        var indentation = 0
        while index < line.endIndex {
            if line[index] == " " {
                indentation += 1
            } else if line[index] == "\t" {
                indentation += 4
            } else {
                break
            }
            index = line.index(after: index)
        }
        let content = line[index...]
        for prefix in ["- ", "* ", "+ "] where content.hasPrefix(prefix) {
            return (indentation, .unordered, String(content.dropFirst(2)))
        }

        // Both `1. item` and `1) item` are ordered list markers.
        guard let delimiter = content.firstIndex(where: { $0 == "." || $0 == ")" }) else { return nil }
        let numberText = content[..<delimiter]
        guard !numberText.isEmpty,
              numberText.allSatisfy({ $0.isNumber }),
              let number = Int(numberText) else { return nil }
        let after = content[content.index(after: delimiter)...]
        guard after.first == " " else { return nil }
        return (indentation, .ordered(number), String(after.dropFirst()))
    }

    static func isTableLine(_ s: String) -> Bool {
        s.contains("|") && s.split(separator: "|", omittingEmptySubsequences: false).count >= 3
    }

    static func isTableSeparatorLine(_ s: String) -> Bool {
        let cells = splitRow(s)
        guard cells.count >= 2 else { return false }
        return cells.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var inCode = false
        var codeLanguage: String?
        var codeLines: [String] = []
        var listItems: [MarkdownListItem] = []
        var listIndents: [Int] = []
        var orderedCounters: [Int: Int] = [:]
        var quoteLines: [String] = []
        var tableLines: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }
        }
        func flushList() {
            if !listItems.isEmpty {
                blocks.append(.list(items: listItems))
                listItems.removeAll()
                listIndents.removeAll()
                orderedCounters.removeAll()
            }
        }
        func listDepth(for indentation: Int) -> Int {
            if let existing = listIndents.lastIndex(of: indentation) {
                listIndents.removeSubrange((existing + 1)..<listIndents.count)
                return existing
            }
            while let last = listIndents.last, indentation < last {
                listIndents.removeLast()
            }
            if listIndents.isEmpty || indentation > listIndents.last! {
                listIndents.append(indentation)
            }
            return max(0, listIndents.count - 1)
        }
        func flushQuote() {
            if !quoteLines.isEmpty {
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
                quoteLines.removeAll()
            }
        }
        func flushTable() {
            // A table needs a `|---|---|` separator under its header.
            // Without that requirement any two consecutive prose lines
            // containing a pipe (shell pipelines, `a | b` prose) turned into
            // a grid. Non-tables fall back to a paragraph; appending them to
            // `paragraph` instead dropped them at the final flush, which
            // always flushes the paragraph first.
            guard tableLines.count >= 2, isTableSeparatorLine(tableLines[1]) else {
                if !tableLines.isEmpty {
                    blocks.append(.paragraph(tableLines.joined(separator: "\n")))
                }
                tableLines.removeAll()
                return
            }
            blocks.append(tableBlock(tableLines))
            tableLines.removeAll()
        }
        func flushBlocks() {
            flushParagraph(); flushList(); flushQuote(); flushTable()
        }

        for raw in lines {
            let line = raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if inCode {
                    blocks.append(.code(codeLines.joined(separator: "\n"), language: codeLanguage))
                    codeLines.removeAll()
                    codeLanguage = nil
                    inCode = false
                } else {
                    flushBlocks()
                    // Info string: ```swift -> "swift". Only the language
                    // word is kept; the rest (```js title=x) is ignored.
                    let info = trimmed.drop(while: { $0 == "`" || $0 == "~" }).trimmingCharacters(in: .whitespaces)
                    let language = info.split(separator: " ").first.map(String.init)
                    codeLanguage = (language?.isEmpty == false) ? language : nil
                    inCode = true
                }
                continue
            }
            if inCode { codeLines.append(line); continue }

            if trimmed.isEmpty {
                flushParagraph(); flushQuote(); flushTable()
                continue
            }

            if isTableLine(trimmed) {
                flushParagraph(); flushList(); flushQuote()
                tableLines.append(trimmed)
                continue
            } else if !tableLines.isEmpty {
                flushTable()
            }

            if isThematicBreak(trimmed) {
                flushBlocks()
                blocks.append(.rule)
                continue
            }

            if trimmed.hasPrefix("#") {
                let count = trimmed.prefix(while: { $0 == "#" }).count
                if count <= 6, trimmed.dropFirst(count).first == " " {
                    flushBlocks()
                    let text = trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces)
                    blocks.append(.heading(level: count, text: text))
                    continue
                }
            }

            if trimmed.hasPrefix(">") {
                flushParagraph(); flushList(); flushTable()
                quoteLines.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }

            if let item = listItem(line) {
                flushParagraph(); flushQuote(); flushTable()
                let depth = listDepth(for: item.indentation)
                for key in orderedCounters.keys.filter({ $0 > depth }) {
                    orderedCounters.removeValue(forKey: key)
                }
                let marker: MarkdownListMarker
                switch item.marker {
                case .unordered:
                    orderedCounters.removeValue(forKey: depth)
                    marker = .unordered
                case .ordered(let start):
                    let number = orderedCounters[depth].map { $0 + 1 } ?? start
                    orderedCounters[depth] = number
                    marker = .ordered(number)
                }
                listItems.append(MarkdownListItem(depth: depth, marker: marker, text: item.text))
                continue
            }

            flushList(); flushQuote()
            paragraph.append(line)
        }

        if inCode { blocks.append(.code(codeLines.joined(separator: "\n"), language: codeLanguage)) }
        flushBlocks()
        return blocks
    }

    static func isThematicBreak(_ s: String) -> Bool {
        let stripped = s.filter { !$0.isWhitespace }
        guard stripped.count >= 3, let first = stripped.first, "-*_".contains(first) else { return false }
        return stripped.allSatisfy { $0 == first }
    }

    // Splits one table row. Trimming the whole row against "| " (as this used
    // to) ate empty edge cells — `| | b |` collapsed to a single cell and the
    // row no longer lined up with the header.
    static func splitRow(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        return row
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func tableBlock(_ lines: [String]) -> MarkdownBlock {
        // Callers only build a table once the separator row is confirmed.
        var rows = lines.map(splitRow)
        let header: [String]? = rows.count > 1 ? rows.removeFirst() : nil
        if header != nil { rows.removeFirst() }
        // Ragged rows made the Grid columns drift; pad every row to the
        // widest one so cells stay under their header.
        let columns = max(header?.count ?? 0, rows.map(\.count).max() ?? 0)
        func padded(_ row: [String]) -> [String] {
            row + Array(repeating: "", count: max(0, columns - row.count))
        }
        return .table(header: header.map(padded), rows: rows.map(padded))
    }
}

enum MarkdownInlineRenderer {
    private static let cache = MarkdownFIFOCache<String, AttributedString>(limit: 800, costLimit: 2 << 20)

    static func attributed(_ markdown: String, theme: AppThemeChoice, cacheable: Bool) -> AttributedString {
        let key = "\(TextSizePreference.step)|\(theme.rawValue)|\(markdown)"
        if let cached = cache.value(for: key) { return cached }

        let palette = theme.palette.markdown
        var attributed = (try? AttributedString(
            markdown: autoLinkedMarkdown(markdown),
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(markdown)

        for run in attributed.runs {
            if run.link != nil {
                attributed[run.range].underlineStyle = .single
                attributed[run.range].foregroundColor = palette.link.color
            }
            guard let intent = run.inlinePresentationIntent else { continue }
            if intent.contains(.stronglyEmphasized) {
                attributed[run.range].foregroundColor = palette.strong.color
            } else if intent.contains(.emphasized) {
                attributed[run.range].foregroundColor = palette.emphasis.color
            }
            if intent.contains(.strikethrough) {
                attributed[run.range].foregroundColor = palette.deleted.color
            }
            if intent.contains(.code) {
                attributed[run.range].font = AppFonts.code(MarkdownTypography.codeSize)
                attributed[run.range].foregroundColor = theme.palette.markdownCodeForeground.color
                attributed[run.range].backgroundColor = palette.codeBackground.color
            }
        }

        if cacheable { cache.insert(attributed, for: key, cost: markdown.utf8.count) }
        return attributed
    }

    // AttributedString's inline markdown parser does not auto-link bare URLs
    // or email addresses, so convert them to [text](href) links first,
    // leaving code spans and existing links untouched.
    static func autoLinkedMarkdown(_ text: String) -> String {
        guard text.range(of: #"(https?://|www\.|mailto:|@)"#, options: [.regularExpression, .caseInsensitive]) != nil else { return text }

        var protected: [String] = []
        var working = protectMatches(in: text, pattern: #"`[^`]+`"#, store: &protected)
        working = protectMatches(in: working, pattern: #"\[[^\]]+\]\([^)]+\)"#, store: &protected)

        let pattern = #"(https?://[^\s<>\"'\]\)]+|www\.[^\s<>\"'\]\)]+|mailto:[^\s<>\"'\]\)]+|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return restoreMatches(in: working, store: protected)
        }
        let nsRange = NSRange(working.startIndex..., in: working)
        let matches = regex.matches(in: working, range: nsRange)
        if !matches.isEmpty {
            var result = ""
            var cursor = working.startIndex
            for match in matches {
                guard let range = Range(match.range, in: working) else { continue }
                result += working[cursor..<range.lowerBound]
                var display = String(working[range])
                var suffix = ""
                while let last = display.unicodeScalars.last,
                      CharacterSet(charactersIn: ".,;:!?").contains(last) {
                    suffix.insert(Character(last), at: suffix.startIndex)
                    display.removeLast()
                }
                if display.isEmpty {
                    result += working[range]
                } else {
                    let lower = display.lowercased()
                    let href: String
                    if lower.hasPrefix("www.") {
                        href = "https://\(display)"
                    } else if display.contains("@") && !lower.hasPrefix("mailto:") && !lower.hasPrefix("http") {
                        href = "mailto:\(display)"
                    } else {
                        href = display
                    }
                    result += "[\(display)](\(href))\(suffix)"
                }
                cursor = range.upperBound
            }
            result += working[cursor..<working.endIndex]
            working = result
        }
        return restoreMatches(in: working, store: protected)
    }

    private static func protectMatches(in text: String, pattern: String, store: inout [String]) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[cursor..<range.lowerBound]
            result += protectionToken(store.count)
            store.append(String(text[range]))
            cursor = range.upperBound
        }
        result += text[cursor..<text.endIndex]
        return result
    }

    private static func restoreMatches(in text: String, store: [String]) -> String {
        var result = text
        for (index, original) in store.enumerated() {
            result = result.replacingOccurrences(of: protectionToken(index), with: original)
        }
        return result
    }

    private static func protectionToken(_ index: Int) -> String {
        "\u{E004}\(index)\u{E005}"
    }
}

// The markdown renderer for streaming and finalized messages. Text-like
// blocks merge into a single selectable NSTextView (SelectableMarkdownText)
// so selection and copy work across paragraphs; code blocks and tables stay
// SwiftUI views.
private final class PreparedNativeMarkdown: @unchecked Sendable {
    struct Key: Hashable {
        var markdown: String
        var role: MessageRole
        var theme: AppThemeChoice
        var projectPath: String?
        var textSizeStep: Int
    }

    let segments: [MarkdownRenderSegment]
    let attributedText: [Int: MarkdownAttributedText]
    let attributedTableCells: [String: AttributedString]

    init(markdown: String, role: MessageRole, theme: AppThemeChoice, projectPath: String?, cacheable: Bool) {
        // Parsing is cheap; the prepared result is cached for finalized messages.
        // Streaming frames never enter that cache.
        segments = MarkdownRenderSegment.segments(from: MarkdownBlockParser.parse(markdown))
        var attributedText: [Int: MarkdownAttributedText] = [:]
        var attributedTableCells: [String: AttributedString] = [:]
        for (index, segment) in segments.enumerated() {
            switch segment {
            case .text(let blocks):
                // While streaming, the trailing segment is the one still
                // growing; every other segment is settled and worth caching.
                attributedText[index] = MarkdownSelectableTextBuilder.build(
                    blocks: blocks,
                    role: role,
                    theme: theme,
                    projectPath: projectPath,
                    cacheable: cacheable || index != segments.count - 1
                )
            case .table(let header, let rows):
                let cells = (header ?? []) + rows.flatMap { $0 }
                for (cellIndex, cell) in cells.enumerated() where attributedTableCells[cell] == nil {
                    // Only the final cell of a trailing table may still grow.
                    attributedTableCells[cell] = MarkdownInlineRenderer.attributed(
                        cell, theme: theme,
                        cacheable: cacheable || index != segments.count - 1 || cellIndex != cells.count - 1
                    )
                }
            case .code:
                break
            }
        }
        self.attributedText = attributedText
        self.attributedTableCells = attributedTableCells
    }

    static func key(markdown: String, role: MessageRole, theme: AppThemeChoice, projectPath: String?) -> Key {
        Key(markdown: markdown, role: role, theme: theme, projectPath: projectPath, textSizeStep: TextSizePreference.step)
    }
}

private final class PreparedNativeMarkdownCache: @unchecked Sendable {
    static let shared = PreparedNativeMarkdownCache()
    private let cache = MarkdownFIFOCache<PreparedNativeMarkdown.Key, PreparedNativeMarkdown>(limit: 300, costLimit: 8 << 20)

    func prepared(markdown: String, role: MessageRole, theme: AppThemeChoice, projectPath: String? = nil, cacheable: Bool) -> PreparedNativeMarkdown {
        let key = PreparedNativeMarkdown.key(markdown: markdown, role: role, theme: theme, projectPath: projectPath)
        if let cached = cache.value(for: key) { return cached }
        let prepared = PreparedNativeMarkdown(markdown: markdown, role: role, theme: theme, projectPath: projectPath, cacheable: cacheable)
        if cacheable { cache.insert(prepared, for: key, cost: markdown.utf8.count) }
        return prepared
    }
}

// Rendering is synchronous at layout time, so publishing a session's
// messages prepares every visible one during that layout pass. Callers await
// this first, while the previous session is still on screen, so the work
// happens off the main thread and the first layout is all cache hits.
//
// This must run *before* the messages are published: a warm-up kicked off
// after the rows exist is pure duplicated work, since the synchronous render
// has already populated the cache by then.
enum MarkdownPrewarmer {
    // Only the window the transcript actually shows (see
    // SessionController.visibleMessages) is worth preparing up front.
    static let windowSize = 60

    static func warm(_ messages: [ChatMessage], theme: AppThemeChoice) async {
        let pending = messages.suffix(windowSize).filter { !$0.isStreaming && !$0.text.isEmpty }
        guard !pending.isEmpty else { return }
        await Task.detached(priority: .userInitiated) {
            for message in pending {
                _ = PreparedNativeMarkdownCache.shared.prepared(
                    markdown: message.text,
                    role: message.role,
                    theme: theme,
                    cacheable: true
                )
            }
        }.value
    }
}

struct NativeMarkdownView: View {
    let markdown: String
    let role: MessageRole
    let theme: AppThemeChoice
    var isStreaming = false
    var projectPath: String? = nil
    var textSizeStep: Int = TextSizePreference.step

    // Preparation is synchronous. It used to hop to a background task and
    // render a 1pt placeholder until the result arrived, which collapsed the
    // row and then re-expanded it every time a message finalized. Inline
    // rendering is cached per block, so a streaming frame only pays for the
    // block that changed, and a finalized message is usually a cache hit.
    var body: some View {
        let prepared = PreparedNativeMarkdownCache.shared.prepared(
            markdown: markdown,
            role: role,
            theme: theme,
            projectPath: projectPath,
            cacheable: !isStreaming
        )
        let palette = theme.palette.markdown
        VStack(alignment: .leading, spacing: 10) {
            ForEach(prepared.segments.indices, id: \.self) { index in
                segmentView(prepared.segments[index], index: index, prepared: prepared, palette: palette)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bodyColor: Color {
        role == .user
            ? theme.palette.markdown.userForeground.color
            : theme.palette.markdown.assistantForeground.color
    }

    @ViewBuilder private func segmentView(_ segment: MarkdownRenderSegment, index: Int, prepared: PreparedNativeMarkdown, palette: MarkdownThemePalette) -> some View {
        switch segment {
        case .text:
            if let text = prepared.attributedText[index] {
                SelectableMarkdownText(text: text)
            }
        case .code(let code, let language):
            NativeCodeBlockView(code: code, language: language, theme: theme, textSizeStep: textSizeStep)
        case .table(let header, let rows):
            tableView(header: header, rows: rows, prepared: prepared, palette: palette)
        }
    }

    private func tableView(header: [String]?, rows: [[String]], prepared: PreparedNativeMarkdown, palette: MarkdownThemePalette) -> some View {
        let border = palette.codeBorder.color
        return Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            if let header {
                GridRow {
                    ForEach(header.indices, id: \.self) { column in
                        tableCell(prepared.attributedTableCells[header[column]] ?? AttributedString(header[column]), color: palette.strong.color, weight: .semibold)
                            .background(palette.tableHeaderBackground.color)
                            .border(border, width: 0.5)
                    }
                }
            }
            ForEach(rows.indices, id: \.self) { rowIndex in
                GridRow {
                    ForEach(rows[rowIndex].indices, id: \.self) { column in
                        tableCell(prepared.attributedTableCells[rows[rowIndex][column]] ?? AttributedString(rows[rowIndex][column]), color: bodyColor)
                            .background(rowIndex % 2 == 1 ? palette.evenRowBackground.color : Color.clear)
                            .border(border, width: 0.5)
                    }
                }
            }
        }
        .overlay(Rectangle().stroke(border, lineWidth: 1))
    }

    private func tableCell(_ text: AttributedString, color: Color, weight: Font.Weight = .regular) -> some View {
        Text(text)
            .font(AppFonts.ui(13, weight: weight))
            .foregroundStyle(color)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct NativeCodeBlockView: View {
    let code: String
    var language: String?
    let theme: AppThemeChoice
    var textSizeStep: Int = TextSizePreference.step
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        let palette = theme.palette.markdown
        Text(code)
            .font(AppFonts.code(MarkdownTypography.codeSize))
            .foregroundStyle(palette.assistantForeground.color)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
            // Allow the proposed width to soft-wrap at word boundaries.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 13)
            .padding(.leading, 17)
            .padding(.trailing, 14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.palette.markdownPreBackground.color))
        .overlay(alignment: .leading) {
            theme.palette.markdownAccent.color
                .frame(width: 3)
        }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(palette.codeBorder.color, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .topTrailing) {
            // Shares the Copy button's slot: the language label is only
            // useful when the pointer is away, and stacking them would
            // collide with the code text.
            if let language, !language.isEmpty, !hovering {
                Text(language)
                    .font(AppFonts.ui(11, weight: .semibold))
                    .foregroundStyle(palette.assistantForeground.color.opacity(0.75))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .padding(6)
            }
            if hovering {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 900_000_000)
                        copied = false
                    }
                } label: {
                    Text(copied ? "Copied" : "Copy")
                        .font(AppFonts.ui(12, weight: .semibold))
                        .foregroundStyle(palette.assistantForeground.color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.codeBackground.color))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(palette.codeBorder.color, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(6)
            }
        }
        .onHover { hovering = $0 }
    }
}
