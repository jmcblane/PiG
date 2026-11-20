import Foundation
import CryptoKit

// Minimal stdio MCP server exposing PiG's `html_render` and `pi_subagent` tools for ACP agents
// such as Antigravity (`agy acp`). Passed per-session via ACP `session/new.mcpServers`
// without modifying any global agent configuration.

private let maxHTMLBytes = 256 * 1024
private let actionIDRegex = try! NSRegularExpression(pattern: "^[a-zA-Z][a-zA-Z0-9_-]{0,63}$")

private let htmlRenderTool: [String: Any] = [
    "name": "html_render",
    "description":
        "Create a small interactive HTML fragment that blends into PiG's native chat between Markdown paragraphs. " +
        "Keep explanations, headings, notes, and recommendations in your normal reply, NOT in the HTML. " +
        "Do not build a full webpage, dashboard shell, card wrapper, title bar, or viewport-sized layout. " +
        "PiG supplies compact themed buttons, inputs, typography, spacing, and automatic height. " +
        "Use inline CSS/JavaScript only for the interactive piece; inline SVG and data URLs work. " +
        "Local JavaScript can manipulate the UI. To optionally send a chat message, declare an action and use " +
        "<button data-pig-action=\"action-id\">Label</button>. PiG confirms the declared message before sending; " +
        "JavaScript cannot send arbitrary messages or access native APIs. State is temporary, not saved. " +
        "Network, external dependencies, local files, forms, popups, and WebRTC are blocked. " +
        "After this tool returns, insert its exact [[pig-ui:...]] marker on its own line between paragraphs of your reply, outside code fences.",
    "inputSchema": [
        "type": "object",
        "additionalProperties": false,
        "required": ["html"],
        "properties": [
            "title": [
                "type": "string",
                "description": "Accessible name for the controls (not a visible heading)",
                "minLength": 1,
                "maxLength": 120
            ],
            "html": [
                "type": "string",
                "description": "Small self-contained HTML fragment, not a full document (maximum 256 KiB UTF-8)",
                "minLength": 1,
                "maxLength": maxHTMLBytes
            ],
            "height": [
                "type": "integer",
                "description": "Initial height hint only; PiG measures the actual content height",
                "minimum": 1,
                "maximum": 1000
            ],
            "actions": [
                "type": "array",
                "description": "Optional allowlisted chat-message actions, triggered by data-pig-action buttons",
                "maxItems": 16,
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["id", "message"],
                    "properties": [
                        "id": [
                            "type": "string",
                            "description": "Action ID used by a button's data-pig-action attribute",
                            "pattern": "^[a-zA-Z][a-zA-Z0-9_-]{0,63}$"
                        ],
                        "message": [
                            "type": "string",
                            "description": "Exact chat message PiG will show for confirmation before sending to the agent",
                            "minLength": 1,
                            "maxLength": 2000
                        ]
                    ]
                ]
            ]
        ]
    ]
]

private let outputLock = NSLock()

private func writeJSON(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    var out = data
    out.append(0x0A)
    outputLock.lock()
    FileHandle.standardOutput.write(out)
    outputLock.unlock()
}

private struct Options {
    var htmlRender = false
    var piSubagent = false
    var piExecutable: String?
    var cwd = FileManager.default.currentDirectoryPath
}

private let options: Options = {
    var result = Options()
    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    var sawFlag = false
    while let argument = iterator.next() {
        switch argument {
        case "--html-render": result.htmlRender = true; sawFlag = true
        case "--pi-subagent": result.piSubagent = true; sawFlag = true
        case "--pi": result.piExecutable = iterator.next()
        case "--cwd": if let cwd = iterator.next() { result.cwd = cwd }
        default: break
        }
    }
    if !sawFlag { result.htmlRender = true }
    if ProcessInfo.processInfo.environment["PI_SUBAGENT_CHILD"] == "1" { result.piSubagent = false }
    return result
}()

private let subagentRunner = PiSubagentRunner(piExecutable: options.piExecutable, baseDirectory: options.cwd)

private func requestKey(_ id: Any) -> String {
    if let string = id as? String { return "s:\(string)" }
    return "n:\(id)"
}

private func respond(id: Any, result: [String: Any]) {
    writeJSON([
        "jsonrpc": "2.0",
        "id": id,
        "result": result
    ])
}

private func respondError(id: Any, code: Int, message: String) {
    writeJSON([
        "jsonrpc": "2.0",
        "id": id,
        "error": [
            "code": code,
            "message": message
        ]
    ])
}

func toolError(_ message: String) -> [String: Any] {
    [
        "isError": true,
        "content": [
            ["type": "text", "text": message]
        ]
    ]
}

private func executeHTMLRender(arguments: [String: Any]) -> [String: Any] {
    guard let html = arguments["html"] as? String else {
        return toolError("Missing required parameter: html.")
    }
    if html.utf8.count > maxHTMLBytes {
        return toolError("HTML exceeds the 256 KiB limit. Use a smaller self-contained fragment.")
    }
    if html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return toolError("HTML must not be empty.")
    }

    if let actions = arguments["actions"] as? [[String: Any]] {
        if actions.count > 16 {
            return toolError("At most 16 actions may be declared per widget.")
        }
        var seen = Set<String>()
        for action in actions {
            guard let id = action["id"] as? String else {
                return toolError("Each action must declare an id.")
            }
            let range = NSRange(location: 0, length: id.utf16.count)
            guard actionIDRegex.firstMatch(in: id, range: range) != nil else {
                return toolError("Invalid action id: \(id).")
            }
            guard seen.insert(id).inserted else {
                return toolError("Action IDs must be unique within a widget.")
            }
            guard let message = action["message"] as? String else {
                return toolError("Each action must declare a message.")
            }
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.utf16.count > 2000 {
                return toolError("Action messages must be between 1 and 2000 characters.")
            }
            if trimmed.hasPrefix("/") || trimmed.hasPrefix("!") {
                return toolError("Actions must contain ordinary chat messages, not shell or slash commands.")
            }
        }
    }

    let seed = "\(UUID().uuidString):\(html)"
    let digest = SHA256.hash(data: Data(seed.utf8))
    let reference = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    return [
        "content": [
            [
                "type": "text",
                "text": "Controls ready. Insert [[pig-ui:\(reference)]] on its own line between paragraphs in your normal Markdown reply. Keep your explanation outside the HTML."
            ]
        ]
    ]
}

private func handleMessage(_ message: [String: Any]) {
    guard let method = message["method"] as? String else { return }
    let id = message["id"]

    if method == "notifications/cancelled" {
        if let params = message["params"] as? [String: Any], let requestID = params["requestId"] {
            subagentRunner.cancel(requestKey: requestKey(requestID))
        }
        return
    }

    // Notifications (no id) require no response.
    guard let id else { return }

    let params = message["params"] as? [String: Any] ?? [:]

    switch method {
    case "initialize":
        let requestedVersion = params["protocolVersion"] as? String ?? "2024-11-05"
        respond(id: id, result: [
            "protocolVersion": requestedVersion,
            "capabilities": [
                "tools": [:]
            ],
            "serverInfo": [
                "name": "pig-html-mcp",
                "version": "1.0.0"
            ]
        ])
    case "ping":
        respond(id: id, result: [:])
    case "tools/list":
        var tools: [[String: Any]] = []
        if options.htmlRender { tools.append(htmlRenderTool) }
        if options.piSubagent { tools.append(piSubagentTool) }
        respond(id: id, result: [
            "tools": tools
        ])
    case "tools/call":
        guard let name = params["name"] as? String else {
            respondError(id: id, code: -32602, message: "Missing tool name")
            return
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        switch name {
        case "html_render" where options.htmlRender:
            respond(id: id, result: executeHTMLRender(arguments: arguments))
        case "pi_subagent" where options.piSubagent:
            let key = requestKey(id)
            guard subagentRunner.register(requestKey: key) else {
                respond(id: id, result: toolError("Subagent request was rejected: the bridge is shutting down or the request ID is already running."))
                return
            }
            let progressToken = (params["_meta"] as? [String: Any])?["progressToken"]
            let progress: ((Int, String) -> Void)? = progressToken.map { token in
                { step, summary in
                    writeJSON([
                        "jsonrpc": "2.0",
                        "method": "notifications/progress",
                        "params": ["progressToken": token, "progress": step, "message": summary]
                    ])
                }
            }
            DispatchQueue.global().async {
                if let result = subagentRunner.run(requestKey: key, arguments: arguments, progress: progress) {
                    respond(id: id, result: result)
                }
            }
        default:
            respond(id: id, result: toolError("Unknown tool: \(name)"))
        }
    default:
        respondError(id: id, code: -32601, message: "Method not found: \(method)")
    }
}

// Main stdio NDJSON loop.
let stdin = FileHandle.standardInput
var buffer = Data()

while true {
    let chunk = stdin.availableData
    if chunk.isEmpty { break }
    buffer.append(chunk)
    while let newline = buffer.firstIndex(of: 0x0A) {
        let lineData = buffer[..<newline]
        buffer.removeSubrange(...newline)
        var line = Data(lineData)
        if line.last == 0x0D { line.removeLast() }
        guard !line.isEmpty else { continue }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
        handleMessage(object)
    }
}
subagentRunner.shutdown()
