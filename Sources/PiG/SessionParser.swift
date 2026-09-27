import Foundation
import CryptoKit

enum SessionParser {
    struct Input: @unchecked Sendable {
        let value: Any
    }

    struct ParsedSession {
        var summary: SessionSummary
        var messages: [ChatMessage]
    }

    private struct RawEntry {
        let id: String?
        let parentId: String?
        let type: String
        let timestamp: Date?
        let dict: [String: Any]
    }

    private struct SummaryEntry {
        let id: String?
        let parentId: String?
        let type: String
        let timestampText: String?
        let role: String?
        let sessionName: String?
        let userText: String?
    }

    static func parseFileAsync(_ url: URL) async -> ParsedSession? {
        await Task.detached(priority: .utility) {
            parseFile(url)
        }.value
    }

    static func parseMessagesResponseAsync(_ input: Input) async -> [ChatMessage] {
        await Task.detached(priority: .userInitiated) {
            parseMessagesResponse(input.value)
        }.value
    }

    static func parseEntriesResponseAsync(_ input: Input) async -> [ChatMessage]? {
        await Task.detached(priority: .userInitiated) {
            parseEntriesResponse(input.value)
        }.value
    }

    static func parseTreeResponseAsync(_ input: Input) async -> SessionTreeSnapshot? {
        await Task.detached(priority: .userInitiated) {
            parseTreeResponse(input.value)
        }.value
    }

    static func parseSummaryFile(_ url: URL) -> SessionSummary? {
        var rawProjectPath: String?
        var parentSessionPath: String?
        var isChildSession = false
        var delegationTitle: String?
        var entries: [SummaryEntry] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lineNumber = 0

        guard enumerateLines(in: url, body: { line in
            defer { lineNumber += 1 }
            guard let type = fastJSONStringField("type", in: line) else { return }
            if lineNumber == 0 && type == "session" {
                guard let dict = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
                rawProjectPath = (dict["cwd"] as? String)?.nonEmptyTrimmed
                let child = childSessionMetadata(dict)
                parentSessionPath = child.parentSessionPath
                isChildSession = child.isChildSession
                delegationTitle = child.delegationTitle
                return
            }
            let role = type == "message" ? fastJSONStringField("role", in: line) : nil
            var sessionName: String?
            var userText: String?
            if type == "session_info" || role == "user",
               let dict = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                sessionName = type == "session_info" ? dict["name"] as? String : nil
                if role == "user", let message = dict["message"] as? [String: Any] {
                    let rawText = contentText(message["content"])
                    userText = PromptEnvelope.parse(rawText)?.text ?? rawText
                }
            }
            entries.append(SummaryEntry(
                id: fastJSONStringField("id", in: line),
                parentId: fastJSONStringField("parentId", in: line),
                type: type,
                timestampText: fastJSONStringField("timestamp", in: line),
                role: role,
                sessionName: sessionName,
                userText: userText
            ))
        }) else { return nil }
        guard lineNumber > 0 else { return nil }

        let projectPath = URL(
            fileURLWithPath: rawProjectPath
                ?? projectPathFromSessionDirectory(url.deletingLastPathComponent().lastPathComponent)
        ).standardizedFileURL.path
        let branch = activeSummaryBranch(entries)
        let name = branch.reversed().compactMap(\.sessionName).first
            ?? entries.reversed().compactMap(\.sessionName).first
        let firstUser = branch.first(where: { $0.role == "user" })?.userText?.oneLine(max: 70)
        let title = name?.nonEmptyTrimmed
            ?? delegationTitle?.nonEmptyTrimmed
            ?? firstUser?.nonEmptyTrimmed
            ?? url.deletingPathExtension().lastPathComponent

        return SessionSummary(
            filePath: url.path,
            projectPath: projectPath,
            title: title,
            timestamp: branch.last?.timestampText.flatMap { iso.date(from: $0) } ?? fileDate(url) ?? Date.distantPast,
            messageCount: branch.filter { $0.role == "user" || $0.role == "assistant" }.count,
            named: name != nil,
            parentSessionPath: parentSessionPath,
            isChildSession: isChildSession,
            delegationTitle: delegationTitle
        )
    }

    static func parseFile(_ url: URL) -> ParsedSession? {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else { return nil }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return nil }

        var header: [String: Any] = [:]
        var entries: [RawEntry] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for (index, line) in lines.enumerated() {
            guard let dict = parseJSONLine(line), let type = dict["type"] as? String else { continue }
            if index == 0 && type == "session" {
                header = dict
                continue
            }
            let timestamp = (dict["timestamp"] as? String).flatMap { iso.date(from: $0) }
            entries.append(RawEntry(
                id: dict["id"] as? String,
                parentId: dict["parentId"] as? String,
                type: type,
                timestamp: timestamp,
                dict: dict
            ))
        }

        let rawProjectPath = (header["cwd"] as? String)?.nonEmptyTrimmed
            ?? projectPathFromSessionDirectory(url.deletingLastPathComponent().lastPathComponent)
        let projectPath = URL(fileURLWithPath: rawProjectPath).standardizedFileURL.path
        let branch = activeBranch(entries)
        let messages = parseMessages(branch)
        let name = latestSessionName(branch) ?? latestSessionName(entries)
        let firstUser = messages.first(where: { $0.role == .user })?.text.oneLine(max: 70)
        let childMetadata = childSessionMetadata(header)
        let title = name?.nonEmptyTrimmed ?? childMetadata.delegationTitle?.nonEmptyTrimmed ?? firstUser?.nonEmptyTrimmed ?? url.deletingPathExtension().lastPathComponent
        let timestamp = branch.last?.timestamp ?? fileDate(url) ?? Date.distantPast

        let summary = SessionSummary(
            filePath: url.path,
            projectPath: projectPath,
            title: title,
            timestamp: timestamp,
            messageCount: messages.filter { $0.role == .user || $0.role == .assistant }.count,
            named: name != nil,
            parentSessionPath: childMetadata.parentSessionPath,
            isChildSession: childMetadata.isChildSession,
            delegationTitle: childMetadata.delegationTitle
        )
        return ParsedSession(summary: summary, messages: messages)
    }

    static func parseMessagesResponse(_ data: Any) -> [ChatMessage] {
        guard let dict = data as? [String: Any], let messages = dict["messages"] as? [[String: Any]] else { return [] }
        return parseAgentMessages(messages)
    }

    static func parseEntriesResponse(_ data: Any) -> [ChatMessage]? {
        guard let dict = data as? [String: Any],
              let rawEntries = dict["entries"] as? [[String: Any]] else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entries = rawEntries.compactMap { entry -> RawEntry? in
            guard let type = entry["type"] as? String else { return nil }
            let timestamp = (entry["timestamp"] as? String).flatMap { iso.date(from: $0) }
            return RawEntry(
                id: entry["id"] as? String,
                parentId: entry["parentId"] as? String,
                type: type,
                timestamp: timestamp,
                dict: entry
            )
        }
        return parseMessages(activeBranch(entries, leafID: dict["leafId"] as? String))
    }

    static func chatMessage(fromAgentMessage message: [String: Any], id: String = UUID().uuidString, streaming: Bool = false) -> ChatMessage? {
        guard let role = message["role"] as? String else { return nil }
        let timestamp = timestampFromAgent(message)
        switch role {
        case "user":
            let rawText = contentText(message["content"])
            let images = contentImages(message["content"])
            if let envelope = PromptEnvelope.parse(rawText) {
                return ChatMessage(
                    id: id,
                    role: .user,
                    text: envelope.text,
                    canonicalText: envelope.canonicalText,
                    references: envelope.references,
                    images: images,
                    timestamp: timestamp,
                    isStreaming: streaming
                )
            }
            return ChatMessage(id: id, role: .user, text: rawText, images: images, timestamp: timestamp, isStreaming: streaming)
        case "assistant":
            let parts = assistantParts(message["content"])
            return ChatMessage(
                id: id,
                role: .assistant,
                text: parts.text,
                thinking: parts.thinking,
                tools: parts.tools,
                images: contentImages(message["content"]),
                timestamp: timestamp,
                stopReason: message["stopReason"] as? String,
                isStreaming: streaming
            )
        case "toolResult":
            let toolName = message["toolName"] as? String ?? "tool"
            let toolId = message["toolCallId"] as? String ?? UUID().uuidString
            let isError = message["isError"] as? Bool ?? false
            let details = message["details"].map(jsonString)
            let tool = ToolDisplay(id: toolId, name: toolName, arguments: "", result: contentText(message["content"]), details: details, images: contentImages(message["content"]), status: isError ? .failed : .succeeded, isError: isError)
            return ChatMessage(id: id, role: .system, text: "", tools: [tool], timestamp: timestamp, isStreaming: streaming)
        case "bashExecution":
            let command = message["command"] as? String ?? "bash"
            let arguments = jsonString(["command": command])
            let exitCode = message["exitCode"]
            let failed = message["cancelled"] as? Bool == true || shellExitFailed(exitCode)
            var result = message["output"] as? String ?? ""
            if message["truncated"] as? Bool == true {
                result += "\n... output truncated. Full output: \(message["fullOutputPath"] as? String ?? "")"
            }
            if let exitCode { result += "\nExit: \(String(describing: exitCode))" }
            let label = message["excludeFromContext"] as? Bool == true ? "you · hidden" : "you"
            let tool = ToolDisplay(
                id: id,
                name: "bash",
                arguments: arguments,
                result: result,
                status: failed ? .failed : .succeeded,
                isError: failed,
                userLabel: label
            )
            return ChatMessage(id: id, role: .system, tools: [tool], timestamp: timestamp, isStreaming: streaming)
        case "custom":
            if message["display"] as? Bool == false { return nil }
            return ChatMessage(id: id, role: .custom, text: contentText(message["content"]), timestamp: timestamp, isStreaming: streaming)
        case "branchSummary":
            return ChatMessage(id: id, role: .system, text: "Branch summary\n\n\(message["summary"] as? String ?? "")", timestamp: timestamp, isStreaming: streaming)
        case "compactionSummary":
            return ChatMessage(id: id, role: .system, text: "Compaction summary\n\n\(message["summary"] as? String ?? "")", timestamp: timestamp, isStreaming: streaming)
        default:
            return nil
        }
    }

    static func parseTreeResponse(_ data: Any) -> SessionTreeSnapshot? {
        guard let dict = data as? [String: Any],
              let rawRoots = dict["tree"] as? [[String: Any]] else { return nil }
        let roots = rawRoots.compactMap(parseTreeNode)
        let leafID = dict["leafId"] as? String
        let nodes = roots.flatMap(\.flattened)
        // Later nodes with the same ID win, matching the branch walker.
        let byID = nodes.reduce(into: [String: SessionTreeNode]()) { $0[$1.id] = $1 }
        var activePathIDs: Set<String> = []
        var cursor = leafID
        while let id = cursor, let node = byID[id], activePathIDs.insert(id).inserted {
            cursor = node.parentID
        }
        return SessionTreeSnapshot(roots: roots, leafID: leafID, activePathIDs: activePathIDs)
    }

    private static func parseTreeNode(_ rawNode: [String: Any]) -> SessionTreeNode? {
        guard let entry = rawNode["entry"] as? [String: Any],
              let id = entry["id"] as? String,
              let type = entry["type"] as? String else { return nil }
        let message = entry["message"] as? [String: Any]
        let role = message?["role"] as? String
        let kind: SessionTreeEntryKind
        switch (type, role) {
        case ("message", "user"): kind = .user
        case ("message", "assistant"): kind = .assistant
        case ("message", "toolResult"), ("message", "bashExecution"): kind = .tool
        case ("message", _): kind = .message
        case ("model_change", _): kind = .model
        case ("thinking_level_change", _): kind = .thinking
        case ("compaction", _): kind = .compaction
        case ("branch_summary", _): kind = .branchSummary
        case ("label", _): kind = .label
        case ("custom", _), ("custom_message", _): kind = .custom
        case ("session_info", _): kind = .sessionInfo
        default: kind = .unknown
        }
        let children = (rawNode["children"] as? [[String: Any]] ?? []).compactMap(parseTreeNode)
        let label = rawNode["label"] as? String
        let messageText = contentText(message?["content"])
        return SessionTreeNode(
            id: id,
            parentID: entry["parentId"] as? String,
            kind: kind,
            preview: treeEntryPreview(entry, message: message, kind: kind),
            label: label?.nonEmptyTrimmed,
            children: children,
            isForkable: type == "message" && role == "user",
            hasDisplayableText: type == "message"
                && (role == "user" || role == "assistant")
                && messageText.nonEmptyTrimmed != nil
        )
    }

    private static func treeEntryPreview(
        _ entry: [String: Any],
        message: [String: Any]?,
        kind: SessionTreeEntryKind
    ) -> String {
        let text: String
        switch kind {
        case .user:
            let rawText = contentText(message?["content"])
            text = PromptEnvelope.parse(rawText)?.text ?? rawText
        case .assistant, .message:
            text = contentText(message?["content"])
        case .tool:
            let name = message?["toolName"] as? String ?? message?["command"] as? String ?? "Tool result"
            let result = contentText(message?["content"])
            text = result.isEmpty ? name : "\(name) — \(result)"
        case .model:
            let provider = entry["provider"] as? String ?? ""
            let model = entry["modelId"] as? String ?? "Model change"
            text = provider.isEmpty ? model : "\(provider)/\(model)"
        case .thinking:
            text = "Thinking: \(entry["thinkingLevel"] as? String ?? "changed")"
        case .compaction, .branchSummary:
            text = entry["summary"] as? String ?? "Summary"
        case .label:
            text = entry["label"] as? String ?? "Label change"
        case .custom:
            text = contentText(entry["content"]).nonEmptyTrimmed
                ?? (entry["customType"] as? String)
                ?? "Custom entry"
        case .sessionInfo:
            text = entry["name"] as? String ?? "Session info"
        case .unknown:
            text = entry["type"] as? String ?? "Entry"
        }
        let resolved = text.nonEmptyTrimmed ?? kind.rawValue
        let limit: Int
        switch kind {
        case .tool: limit = 320
        case .assistant: limit = 4_000
        default: limit = 1_200
        }
        guard resolved.count > limit else { return resolved }
        return String(resolved.prefix(limit - 1)) + "…"
    }

    static func contentText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { block in
                guard let type = block["type"] as? String else { return nil }
                switch type {
                case "text": return block["text"] as? String
                case "image": return nil
                default: return nil
                }
            }.joined(separator: "\n")
        }
        return ""
    }

    static func contentImages(_ content: Any?) -> [ImageAttachment] {
        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.enumerated().compactMap { index, block in
            guard block["type"] as? String == "image" else { return nil }
            let mimeType = block["mimeType"] as? String ?? ""
            let data = block["data"] as? String
            let name = block["fileName"] as? String ?? block["name"] as? String ?? "Image"
            let identityData: String
            if let data {
                identityData = SHA256.hash(data: Data(data.utf8))
                    .map { String(format: "%02x", $0) }
                    .joined()
            } else {
                identityData = "missing"
            }
            return ImageAttachment(id: "image-\(index)-\(mimeType)-\(identityData)", name: name, mimeType: mimeType, data: data)
        }
    }

    private static func parseAgentMessages(_ agentMessages: [[String: Any]]) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        for agent in agentMessages {
            guard let msg = chatMessage(fromAgentMessage: agent) else { continue }
            if msg.role == .system, msg.text.isEmpty, let tool = msg.tools.first, tool.userLabel == nil {
                attachToolResult(tool, to: &messages)
            } else {
                messages.append(msg)
            }
        }
        return messages
    }

    private static func parseMessages(_ entries: [RawEntry]) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        for entry in entries {
            switch entry.type {
            case "message":
                guard let agent = entry.dict["message"] as? [String: Any],
                      let msg = chatMessage(fromAgentMessage: agent, id: entry.id ?? UUID().uuidString) else { continue }
                if msg.role == .system, msg.text.isEmpty, let tool = msg.tools.first, tool.userLabel == nil {
                    attachToolResult(tool, to: &messages)
                } else {
                    messages.append(msg)
                }
            case "compaction":
                let summary = entry.dict["summary"] as? String ?? ""
                messages.append(ChatMessage(id: entry.id ?? UUID().uuidString, role: .system, text: "Compaction summary\n\n\(summary)", timestamp: entry.timestamp))
            case "branch_summary":
                let summary = entry.dict["summary"] as? String ?? ""
                messages.append(ChatMessage(id: entry.id ?? UUID().uuidString, role: .system, text: "Branch summary\n\n\(summary)", timestamp: entry.timestamp))
            case "custom_message":
                if entry.dict["display"] as? Bool == false { continue }
                messages.append(ChatMessage(id: entry.id ?? UUID().uuidString, role: .custom, text: contentText(entry.dict["content"]), timestamp: entry.timestamp))
            default:
                continue
            }
        }
        return messages
    }

    static func shellExitFailed(_ value: Any?) -> Bool {
        if let code = value as? Int { return code != 0 }
        if let code = value as? Int32 { return code != 0 }
        if let code = value as? Double { return code != 0 }
        if let text = value as? String, let code = Int(text) { return code != 0 }
        return false
    }

    private static func attachToolResult(_ result: ToolDisplay, to messages: inout [ChatMessage]) {
        for index in messages.indices.reversed() {
            if let toolIndex = messages[index].tools.firstIndex(where: { $0.id == result.id }) {
                messages[index].tools[toolIndex].result = result.result
                messages[index].tools[toolIndex].details = result.details
                messages[index].tools[toolIndex].images = result.images
                messages[index].tools[toolIndex].status = result.status
                messages[index].tools[toolIndex].isError = result.isError
                return
            }
        }
        messages.append(ChatMessage(role: .system, text: "", tools: [result]))
    }

    private static func assistantParts(_ content: Any?) -> (text: String, thinking: String, tools: [ToolDisplay]) {
        guard let blocks = content as? [[String: Any]] else { return (contentText(content), "", []) }
        var text: [String] = []
        var thinking: [String] = []
        var tools: [ToolDisplay] = []
        for block in blocks {
            guard let type = block["type"] as? String else { continue }
            switch type {
            case "text":
                text.append(block["text"] as? String ?? "")
            case "thinking":
                thinking.append(block["thinking"] as? String ?? "")
            case "toolCall":
                let id = block["id"] as? String ?? UUID().uuidString
                let name = block["name"] as? String ?? "tool"
                let args = block["arguments"].map(jsonString) ?? ""
                tools.append(ToolDisplay(id: id, name: name, arguments: args, result: "", status: .pending, isError: false))
            default:
                continue
            }
        }
        return (text.joined(separator: "\n"), thinking.joined(separator: "\n"), tools)
    }

    private static func activeSummaryBranch(_ entries: [SummaryEntry]) -> [SummaryEntry] {
        activeBranch(entries, id: \.id, parentID: \.parentId)
    }

    private static func enumerateLines(in url: URL, body: (Data) -> Void) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var buffer = Data()
        var searchStart = buffer.startIndex
        do {
            while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                buffer.append(chunk)
                while searchStart < buffer.endIndex,
                      let newline = buffer[searchStart...].firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    searchStart = buffer.startIndex
                    if !line.isEmpty { body(line) }
                }
                searchStart = buffer.endIndex
            }
            if !buffer.isEmpty { body(buffer) }
            return true
        } catch {
            return false
        }
    }

    private static func fastJSONStringField(_ key: String, in line: Data) -> String? {
        let prefix = String(decoding: line.prefix(4096), as: UTF8.self)
        let marker = "\"\(key)\":\""
        guard let markerRange = prefix.range(of: marker) else { return nil }
        let valueStart = markerRange.upperBound
        guard let valueEnd = prefix[valueStart...].firstIndex(of: "\"") else { return nil }
        return String(prefix[valueStart..<valueEnd])
    }

    private static func activeBranch(_ entries: [RawEntry], leafID: String? = nil) -> [RawEntry] {
        activeBranch(entries, leafID: leafID, id: \.id, parentID: \.parentId)
    }

    private static func activeBranch<Entry>(
        _ entries: [Entry], leafID: String? = nil,
        id: KeyPath<Entry, String?>, parentID: KeyPath<Entry, String?>
    ) -> [Entry] {
        var byID: [String: Entry] = [:]
        for entry in entries {
            if let key = entry[keyPath: id] { byID[key] = entry } // Last duplicate wins.
        }
        guard let resolvedLeafID = leafID.flatMap({ byID[$0] != nil ? $0 : nil })
            ?? entries.reversed().compactMap({ $0[keyPath: id] }).first else { return entries }
        var branch: [Entry] = []
        var current: String? = resolvedLeafID
        var seen = Set<String>()
        while let key = current, seen.insert(key).inserted, let entry = byID[key] {
            branch.append(entry)
            current = entry[keyPath: parentID]
        }
        return branch.reversed()
    }

    private static func latestSessionName(_ entries: [RawEntry]) -> String? {
        entries.reversed().first(where: { $0.type == "session_info" })?.dict["name"] as? String
    }

    private static func childSessionMetadata(_ header: [String: Any]) -> (parentSessionPath: String?, isChildSession: Bool, delegationTitle: String?) {
        let delegateAgent = header["delegateAgent"] as? [String: Any]
        let parentSessionPath = (header["parentSession"] as? String) ?? (delegateAgent?["parentSessionPath"] as? String)
        let delegationTitle = (header["delegationTitle"] as? String) ?? (delegateAgent?["title"] as? String)
        let isChildSession = (header["childSession"] as? Bool == true) || delegateAgent != nil
        return (parentSessionPath, isChildSession, delegationTitle)
    }

    private static func parseJSONLine(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func projectPathFromSessionDirectory(_ encoded: String) -> String {
        var stripped = encoded
        if stripped.hasPrefix("--") { stripped.removeFirst(2) }
        if stripped.hasSuffix("--") { stripped.removeLast(2) }
        return "/" + stripped.replacingOccurrences(of: "-", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func fileDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private static func timestampFromAgent(_ message: [String: Any]) -> Date? {
        if let ms = message["timestamp"] as? Double { return Date(timeIntervalSince1970: ms / 1000) }
        if let ms = message["timestamp"] as? Int { return Date(timeIntervalSince1970: Double(ms) / 1000) }
        return nil
    }
}
