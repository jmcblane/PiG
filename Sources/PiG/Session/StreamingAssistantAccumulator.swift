import Foundation

struct StreamingAssistantAccumulator {
    private enum BlockKind: Equatable {
        case text
        case thinking
        case toolCall
    }

    private struct Block {
        var kind: BlockKind
        var content = ""
        var toolID: String?
        var toolName: String?
        var toolArguments = ""
        var completedToolCall: [String: Any]?
        var isComplete = false
        let fallbackToolID = UUID().uuidString
    }

    private var blocks: [Int: Block] = [:]

    var hasActiveThinking: Bool {
        blocks.values.contains { $0.kind == .thinking && !$0.isComplete }
    }

    mutating func apply(_ event: [String: Any]) {
        guard let type = event["type"] as? String,
              let contentIndex = event["contentIndex"] as? Int else { return }

        switch type {
        case "text_start", "text_delta", "text_end":
            var block = block(at: contentIndex, kind: .text)
            if type == "text_delta" {
                block.content += event["delta"] as? String ?? ""
            } else if type == "text_end" {
                if let content = event["content"] as? String { block.content = content }
                block.isComplete = true
            }
            blocks[contentIndex] = block
        case "thinking_start", "thinking_delta", "thinking_end":
            var block = block(at: contentIndex, kind: .thinking)
            if type == "thinking_delta" {
                block.content += event["delta"] as? String ?? ""
            } else if type == "thinking_end" {
                if let content = event["content"] as? String { block.content = content }
                block.isComplete = true
            }
            blocks[contentIndex] = block
        case "toolcall_start", "toolcall_delta", "toolcall_end":
            var block = block(at: contentIndex, kind: .toolCall)
            if type == "toolcall_start" {
                block.toolID = event["id"] as? String ?? block.toolID
                block.toolName = event["toolName"] as? String ?? block.toolName
            } else if type == "toolcall_delta" {
                block.toolArguments += event["delta"] as? String ?? ""
            } else {
                if let toolCall = event["toolCall"] as? [String: Any] {
                    block.completedToolCall = toolCall
                }
                block.isComplete = true
            }
            blocks[contentIndex] = block
        default:
            break
        }
    }

    /// `finishedParagraphsOnly` holds back the unfinished tail of each still-streaming
    /// text and thinking block (see `StreamingParagraphs`).
    func message(id: String, finishedParagraphsOnly: Bool = false) -> ChatMessage {
        var text: [String] = []
        var thinking: [String] = []
        var tools: [ToolDisplay] = []
        for index in blocks.keys.sorted() {
            guard let block = blocks[index] else { continue }
            switch block.kind {
            case .text:
                text.append(visibleContent(of: block, finishedParagraphsOnly: finishedParagraphsOnly))
            case .thinking:
                thinking.append(visibleContent(of: block, finishedParagraphsOnly: finishedParagraphsOnly))
            case .toolCall:
                let toolCall = block.completedToolCall
                let toolID = block.toolID ?? (toolCall?["id"] as? String) ?? block.fallbackToolID
                let toolName = block.toolName ?? (toolCall?["name"] as? String) ?? (toolCall?["toolName"] as? String) ?? "tool"
                let arguments = toolCall?["arguments"].map(jsonString) ?? block.toolArguments
                tools.append(ToolDisplay(id: toolID, name: toolName, arguments: arguments, result: "", status: .pending, isError: false))
            }
        }
        return ChatMessage(id: id, role: .assistant, text: text.joined(separator: "\n"), thinking: thinking.joined(separator: "\n"), tools: tools, isStreaming: true)
    }

    private func visibleContent(of block: Block, finishedParagraphsOnly: Bool) -> String {
        guard finishedParagraphsOnly, !block.isComplete else { return block.content }
        return StreamingParagraphs.finishedPrefix(of: block.content)
    }

    private func block(at contentIndex: Int, kind: BlockKind) -> Block {
        if let existing = blocks[contentIndex], existing.kind == kind { return existing }
        return Block(kind: kind)
    }
}

/// Line-based paragraph boundaries for streaming markdown, after T3 Code's
/// `splitBufferedAssistantText`. Only terminated lines count, except that the
/// start of the next list item ends the previous one. Code fences stay hidden
/// until they close, and headings or bold section titles wait for content.
enum StreamingParagraphs {
    static func finishedPrefix(of text: String) -> String {
        let bytes = Array(text.utf8)
        var openFence: (marker: UInt8, length: Int, indent: Int)?
        var boundary = 0
        var lineStart = 0
        var titleAwaitingContent = false
        while true {
            let newline = bytes[lineStart...].firstIndex(of: UInt8(ascii: "\n"))
            let line = trimmingTrailingWhitespace(bytes[lineStart..<(newline ?? bytes.count)])
            if openFence == nil, lineStart > 0, !titleAwaitingContent, isListItemStart(line) {
                boundary = lineStart
            }
            guard let newline else { break }
            if let fence = fence(in: line) {
                if let open = openFence {
                    // CommonMark: a closing fence carries no info string.
                    if fence.marker == open.marker, fence.length >= open.length,
                       fence.indent <= open.indent + 3, line.count == fence.indent + fence.length {
                        openFence = nil
                        boundary = newline + 1
                    }
                } else {
                    openFence = fence
                    titleAwaitingContent = false
                }
            } else if openFence == nil, line.isEmpty, lineStart > 0 {
                if !titleAwaitingContent { boundary = newline + 1 }
            } else if openFence == nil {
                // Unindented ATX headings end preceding paragraphs and lists without a blank line.
                if lineStart > 0, !titleAwaitingContent, isATXHeading(line) { boundary = lineStart }
                titleAwaitingContent = isSectionTitle(line)
            }
            lineStart = newline + 1
        }
        // Boundaries sit just after a newline, so the prefix is valid UTF-8.
        return String(decoding: bytes[..<boundary], as: UTF8.self)
    }

    private static let space = UInt8(ascii: " ")
    private static let tab = UInt8(ascii: "\t")
    private static let hash = UInt8(ascii: "#")
    private static let star = UInt8(ascii: "*")

    private static func trimmingTrailingWhitespace(_ line: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var end = line.endIndex
        while end > line.startIndex, [space, tab, UInt8(ascii: "\r")].contains(line[end - 1]) { end -= 1 }
        return line[line.startIndex..<end]
    }

    private static func dropLeading(_ line: ArraySlice<UInt8>, _ bytes: Set<UInt8>, max: Int = .max) -> ArraySlice<UInt8> {
        var start = line.startIndex
        while start < line.endIndex, start - line.startIndex < max, bytes.contains(line[start]) { start += 1 }
        return line[start...]
    }

    // Fences open at any space indentation.
    private static func fence(in line: ArraySlice<UInt8>) -> (marker: UInt8, length: Int, indent: Int)? {
        let rest = dropLeading(line, [space])
        guard let marker = rest.first, marker == UInt8(ascii: "`") || marker == UInt8(ascii: "~") else { return nil }
        let length = rest.prefix { $0 == marker }.count
        return length >= 3 ? (marker, length, rest.startIndex - line.startIndex) : nil
    }

    // The line is already trimmed, so a bare "-" mid-stream does not match until content follows.
    private static func isListItemStart(_ line: ArraySlice<UInt8>) -> Bool {
        let rest = dropLeading(line, [space, tab])
        guard let first = rest.first else { return false }
        var markerEnd = rest.startIndex + 1
        if ![UInt8(ascii: "-"), star, UInt8(ascii: "+")].contains(first) {
            let digits = rest.prefix { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }.count
            guard (1...9).contains(digits), rest.startIndex + digits < rest.endIndex,
                  [UInt8(ascii: "."), UInt8(ascii: ")")].contains(rest[rest.startIndex + digits]) else { return false }
            markerEnd = rest.startIndex + digits + 1
        }
        return markerEnd < rest.endIndex && [space, tab].contains(rest[markerEnd])
    }

    private static func isATXHeading(_ line: ArraySlice<UInt8>) -> Bool {
        let hashes = line.prefix { $0 == hash }.count
        guard (1...6).contains(hashes) else { return false }
        let after = line.startIndex + hashes
        return after == line.endIndex || [space, tab].contains(line[after])
    }

    // An ATX heading indented up to three spaces, or a line that is only `**Title**` or `**Title**:`.
    private static func isSectionTitle(_ line: ArraySlice<UInt8>) -> Bool {
        let rest = dropLeading(line, [space], max: 3)
        if isATXHeading(rest) { return true }
        var body = rest
        if body.last == UInt8(ascii: ":") { body = body.dropLast() }
        guard body.count >= 5, body.prefix(2).allSatisfy({ $0 == star }), body.suffix(2).allSatisfy({ $0 == star }) else { return false }
        let inner = body.dropFirst(2).dropLast(2)
        guard inner.last != star else { return false }
        return !zip(inner, inner.dropFirst()).contains { $0 == star && $1 == star }
    }
}
