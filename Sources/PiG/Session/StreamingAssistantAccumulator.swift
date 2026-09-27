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

    func message(id: String) -> ChatMessage {
        var text: [String] = []
        var thinking: [String] = []
        var tools: [ToolDisplay] = []
        for index in blocks.keys.sorted() {
            guard let block = blocks[index] else { continue }
            switch block.kind {
            case .text:
                text.append(block.content)
            case .thinking:
                thinking.append(block.content)
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

    private func block(at contentIndex: Int, kind: BlockKind) -> Block {
        if let existing = blocks[contentIndex], existing.kind == kind { return existing }
        return Block(kind: kind)
    }
}
