import Foundation
import CryptoKit

enum ACPProvider {
    static let antigravity = "antigravity-acp"
    static let antigravityDisplayName = "Antigravity"
    static let htmlMCPServerName = "pig"
}

extension ModelInfo {
    var isAntigravityACP: Bool { provider == ACPProvider.antigravity }

    static func isAntigravityACP(id: String) -> Bool {
        id.hasPrefix("\(ACPProvider.antigravity)/")
    }
}

enum AntigravityExecutablePreference {
    private static let key = "PiG.antigravityExecutablePath"

    static var path: String? {
        get { UserDefaults.standard.trimmedString(forKey: key) }
        set { UserDefaults.standard.setTrimmedString(newValue, forKey: key) }
    }
}

enum ACPDefaultModePreference {
    private static let key = "PiG.acp.defaultModeID"

    static var modeID: String {
        get { UserDefaults.standard.trimmedString(forKey: key) ?? "default" }
        set { UserDefaults.standard.setTrimmedString(newValue, forKey: key) }
    }
}

enum ACPPaths {
    static let chatsIndexFile = PiPaths.appSupport.appendingPathComponent("acp-chats.json")
    static let modelsCacheFile = PiPaths.appSupport.appendingPathComponent("acp-models-cache.json")

    static var antigravityExecutable: URL {
        if let path = AntigravityExecutablePreference.path {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return detectedAntigravityExecutable
    }

    static var detectedAntigravityExecutable: URL {
        let candidates = [
            PiPaths.home.appendingPathComponent(".local/bin/agy"),
            PiPaths.home.appendingPathComponent(".bin/agy"),
            PiPaths.home.appendingPathComponent(".antigravity/antigravity/bin/agy"),
            URL(fileURLWithPath: "/opt/homebrew/bin/agy"),
            URL(fileURLWithPath: "/usr/local/bin/agy"),
            URL(fileURLWithPath: "/Applications/Antigravity.app/Contents/Resources/app/bin/agy")
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return found
        }
        return PiEnvironment.executable(named: "agy") ?? URL(fileURLWithPath: "/usr/bin/env")
    }

    static var isAntigravityInstalled: Bool {
        let url = antigravityExecutable
        if url.path == "/usr/bin/env" { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    static func antigravityArguments() -> [String] {
        antigravityExecutable.path == "/usr/bin/env" ? ["agy", "acp"] : ["acp"]
    }

    static var htmlMCPExecutable: URL? {
        var candidates: [URL] = []
        if Bundle.main.bundleURL.pathExtension == "app" {
            candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/pig-html-mcp"))
        }
        if let arg0 = CommandLine.arguments.first, !arg0.isEmpty {
            let sibling = URL(fileURLWithPath: arg0).deletingLastPathComponent().appendingPathComponent("pig-html-mcp")
            candidates.append(sibling)
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(repoRoot.appendingPathComponent(".build/debug/pig-html-mcp"))
        candidates.append(repoRoot.appendingPathComponent(".build/release/pig-html-mcp"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

struct ACPServerConfig: Equatable {
    var name: String
    var executableURL: URL
    var arguments: [String]
    var isAntigravity: Bool

    static func antigravity() -> ACPServerConfig {
        ACPServerConfig(
            name: ACPProvider.antigravityDisplayName,
            executableURL: ACPPaths.antigravityExecutable,
            arguments: ACPPaths.antigravityArguments(),
            isAntigravity: true
        )
    }
}

struct ACPAuthMethod: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String?
}

struct ACPAgentCapabilities: Equatable {
    var loadSession: Bool = false
    var listSessions: Bool = false
    var closeSession: Bool = false
    var resumeSession: Bool = false
    var supportsImages: Bool = false
    var supportsEmbeddedContext: Bool = false
    var supportsAntigravitySystemPromptAppend: Bool = false
}

struct ACPInitializeResult: Equatable {
    let protocolVersion: Int
    let agentName: String
    let agentVersion: String?
    let capabilities: ACPAgentCapabilities
    let authMethods: [ACPAuthMethod]
}

struct ACPConfigChoice: Identifiable, Equatable, Hashable, Codable {
    var id: String { value }
    let value: String
    let name: String
    let description: String?
}

struct ACPConfigOption: Identifiable, Equatable {
    let id: String
    let name: String
    let category: String?
    let currentValue: String
    let options: [ACPConfigChoice]
}

struct ACPModeInfo: Identifiable, Equatable, Hashable, Codable {
    let id: String
    let name: String
    let description: String?

    static let antigravityDefaults: [ACPModeInfo] = [
        ACPModeInfo(id: "default", name: "Default", description: "Ask before edits and commands, per your permission settings."),
        ACPModeInfo(id: "accept-edits", name: "Accept edits", description: "Approve file edits in the workspace without asking."),
        ACPModeInfo(id: "auto", name: "Auto", description: "Approve edits and safe commands; ask before irreversible actions."),
        ACPModeInfo(id: "plan", name: "Plan", description: "Plan carefully before executing a task.")
    ]
}

struct ACPPlanEntry: Identifiable, Equatable {
    let id: String
    let content: String
    let status: String
    let priority: String?
}

struct ACPPermissionOption: Identifiable, Equatable {
    var id: String { optionId }
    let optionId: String
    let name: String
    let kind: String
}

struct ACPPermissionPrompt: Identifiable, Equatable {
    let id: String
    let rpcRequestID: ACPJSONID
    let toolCallID: String
    let title: String
    let detail: String?
    let kind: String?
    let options: [ACPPermissionOption]
}

/// Preserves exact JSON-RPC request ID type (integer vs string) when replying to server requests.
enum ACPJSONID: Equatable, Hashable {
    case int(Int)
    case string(String)

    init?(_ raw: Any?) {
        if let number = raw as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            self = .int(number.intValue)
        } else if let intVal = raw as? Int {
            self = .int(intVal)
        } else if let strVal = raw as? String {
            self = .string(strVal)
        } else {
            return nil
        }
    }

    var jsonValue: Any {
        switch self {
        case .int(let value): return value
        case .string(let value): return value
        }
    }

    var key: String {
        switch self {
        case .int(let value): return "i:\(value)"
        case .string(let value): return "s:\(value)"
        }
    }
}

struct ACPSessionSummary: Identifiable, Equatable, Hashable {
    var id: String { sessionID }
    let sessionID: String
    let cwd: String
    let title: String
    let updatedAt: Date
}

struct ACPChatRecord: Codable, Identifiable, Equatable, Hashable {
    let id: String
    var sessionID: String?
    var projectPath: String
    var title: String
    var modelID: String
    var thinkingLevel: String
    var modeID: String
    var isQuickChat: Bool
    let created: Date
    var lastActivity: Date

    var standardizedProjectPath: String {
        URL(fileURLWithPath: projectPath).standardizedFileURL.path
    }
}

enum ACPChatStore {
    static func load() -> [ACPChatRecord] {
        guard FileManager.default.fileExists(atPath: ACPPaths.chatsIndexFile.path) else { return [] }
        do {
            let records = try JSONDecoder().decode([ACPChatRecord].self, from: Data(contentsOf: ACPPaths.chatsIndexFile))
            var seen = Set<String>()
            return records.filter { seen.insert($0.id).inserted }
        } catch {
            NSLog("PiG: could not read acp-chats.json: \(error)")
            return []
        }
    }

    static func save(_ records: [ACPChatRecord]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: PiPaths.appSupport, withIntermediateDirectories: true)
        try encoder.encode(records).write(to: ACPPaths.chatsIndexFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ACPPaths.chatsIndexFile.path)
    }
}

struct ACPCachedModel: Codable, Equatable {
    let modelId: String
    let name: String
    let reasoning: Bool
    let thinkingLevels: [String]
    let contextWindow: Int?

    func toModelInfo(provider: String = ACPProvider.antigravity) -> ModelInfo {
        ModelInfo(
            id: "\(provider)/\(modelId)",
            provider: provider,
            modelId: modelId,
            name: name,
            reasoning: reasoning,
            thinkingLevels: thinkingLevels,
            contextWindow: contextWindow
        )
    }

    init(from model: ModelInfo) {
        self.modelId = model.modelId
        self.name = model.name
        self.reasoning = model.reasoning
        self.thinkingLevels = model.thinkingLevels
        self.contextWindow = model.contextWindow
    }
}

struct ACPCatalogSnapshot: Codable, Equatable {
    let models: [ACPCachedModel]
    let modes: [ACPModeInfo]
    let defaultModelID: String?
    let defaultThinkingLevel: String?
    let defaultModeID: String?
    let agentVersion: String?
    let updatedAt: Date

    var modelInfos: [ModelInfo] {
        models.map { $0.toModelInfo() }
    }
}

enum ACPModelsCache {
    static func load() -> ACPCatalogSnapshot? {
        guard FileManager.default.fileExists(atPath: ACPPaths.modelsCacheFile.path) else { return nil }
        do {
            return try JSONDecoder().decode(ACPCatalogSnapshot.self, from: Data(contentsOf: ACPPaths.modelsCacheFile))
        } catch {
            return nil
        }
    }

    static func save(_ snapshot: ACPCatalogSnapshot) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: PiPaths.appSupport, withIntermediateDirectories: true)
            try encoder.encode(snapshot).write(to: ACPPaths.modelsCacheFile, options: .atomic)
        } catch {
            NSLog("PiG: could not save acp-models-cache.json: \(error)")
        }
    }
}

/// Parses ACP `session/new` / `config_option_update` payloads into PiG `ModelInfo` and `ACPModeInfo`.
enum ACPModelCatalogParser {
    private static let orderedThinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]

    static func parseConfigOptions(_ raw: Any?) -> [ACPConfigOption] {
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let id = item["id"] as? String,
                  let name = item["name"] as? String else { return nil }
            let category = item["category"] as? String
            let currentValue = item["currentValue"] as? String ?? ""
            let rawOptions = item["options"] as? [[String: Any]] ?? []
            var choices: [ACPConfigChoice] = []
            for option in rawOptions {
                if let value = option["value"] as? String, let optName = option["name"] as? String {
                    choices.append(ACPConfigChoice(value: value, name: optName, description: option["description"] as? String))
                } else if let groupOptions = option["options"] as? [[String: Any]] {
                    for grouped in groupOptions {
                        if let value = grouped["value"] as? String, let optName = grouped["name"] as? String {
                            choices.append(ACPConfigChoice(value: value, name: optName, description: grouped["description"] as? String))
                        }
                    }
                }
            }
            return ACPConfigOption(id: id, name: name, category: category, currentValue: currentValue, options: choices)
        }
    }

    static func parseModes(from sessionResult: [String: Any], configOptions: [ACPConfigOption]) -> (modes: [ACPModeInfo], currentModeID: String) {
        if let modesDict = sessionResult["modes"] as? [String: Any],
           let rawModes = modesDict["availableModes"] as? [[String: Any]], !rawModes.isEmpty {
            let parsed = rawModes.compactMap { item -> ACPModeInfo? in
                guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
                return ACPModeInfo(id: id, name: name, description: item["description"] as? String)
            }
            let current = modesDict["currentModeId"] as? String ?? parsed.first?.id ?? "default"
            if !parsed.isEmpty { return (parsed, current) }
        }
        if let modeConfig = configOptions.first(where: { $0.category == "mode" || $0.id == "mode" }),
           !modeConfig.options.isEmpty {
            let parsed = modeConfig.options.map { ACPModeInfo(id: $0.value, name: $0.name, description: $0.description) }
            return (parsed, modeConfig.currentValue.isEmpty ? (parsed.first?.id ?? "default") : modeConfig.currentValue)
        }
        return (ACPModeInfo.antigravityDefaults, "default")
    }

    static func parseModels(
        from sessionResult: [String: Any],
        configOptions: [ACPConfigOption],
        provider: String = ACPProvider.antigravity
    ) -> (models: [ModelInfo], currentModelID: String?, currentThinkingLevel: String?) {
        let modelConfig = configOptions.first { $0.category == "model" || $0.id == "model" }
        let thoughtConfig = configOptions.first { $0.category == "thought_level" || $0.id == "thought_level" }

        let modelsDict = sessionResult["models"] as? [String: Any]
        let availableVariantIDs: [String] = (modelsDict?["availableModels"] as? [[String: Any]] ?? [])
            .compactMap { $0["modelId"] as? String }
        let globalThoughtLevels = thoughtConfig?.options.map(\.value) ?? []

        if let modelConfig, !modelConfig.options.isEmpty {
            let models: [ModelInfo] = modelConfig.options.map { choice in
                let matchedLevels = thinkingLevels(
                    forBaseModelID: choice.value,
                    variantIDs: availableVariantIDs,
                    fallback: choice.value == modelConfig.currentValue ? globalThoughtLevels : []
                )
                let hasReasoning = matchedLevels.contains { $0 != "off" }
                return ModelInfo(
                    id: "\(provider)/\(choice.value)",
                    provider: provider,
                    modelId: choice.value,
                    name: choice.name,
                    reasoning: hasReasoning,
                    thinkingLevels: matchedLevels.isEmpty ? ["off"] : matchedLevels,
                    contextWindow: nil
                )
            }
            let currentModel = modelConfig.currentValue.nonEmptyTrimmed.map { "\(provider)/\($0)" }
            let currentThought = thoughtConfig?.currentValue.nonEmptyTrimmed
            return (models, currentModel, currentThought)
        }

        // Fallback if a generic ACP server only exposes `models.availableModels` without `configOptions`.
        if let rawModels = modelsDict?["availableModels"] as? [[String: Any]], !rawModels.isEmpty {
            let models: [ModelInfo] = rawModels.compactMap { dict in
                guard let modelId = dict["modelId"] as? String else { return nil }
                let name = (dict["name"] as? String)?.nonEmptyTrimmed ?? modelId
                return ModelInfo(
                    id: "\(provider)/\(modelId)",
                    provider: provider,
                    modelId: modelId,
                    name: name,
                    reasoning: false,
                    thinkingLevels: ["off"],
                    contextWindow: nil
                )
            }
            let currentModel = (modelsDict?["currentModelId"] as? String)?.nonEmptyTrimmed.map { "\(provider)/\($0)" }
            return (models, currentModel, nil)
        }

        return ([], nil, nil)
    }

    private static func thinkingLevels(
        forBaseModelID baseID: String,
        variantIDs: [String],
        fallback: [String]
    ) -> [String] {
        let prefix = baseID + "-"
        var found = Set<String>()
        for variant in variantIDs where variant.hasPrefix(prefix) {
            let suffix = String(variant.dropFirst(prefix.count))
            if orderedThinkingLevels.contains(suffix) {
                found.insert(suffix)
            }
        }
        if !found.isEmpty {
            return orderedThinkingLevels.filter { found.contains($0) }
        }
        if !fallback.isEmpty {
            return fallback
        }
        return ["off"]
    }
}

/// Shared MCP & system prompt helpers for injecting PiG's `html_render` tool into ACP sessions.
enum ACPHTMLRenderBridge {
    static let systemPromptAppend = """
    You have access to PiG's `html_render` tool via the `pig` MCP server.
    - Use `html_render` for small interactive controls, not for prose or full webpages. Keep notes and explanations in Markdown.
    - Insert each returned `[[pig-ui:...]]` marker on its own line where its controls belong in your answer. Never put the marker in a code fence.
    - Use PiG's default control styles; avoid body backgrounds, enclosing cards, fixed/minimum viewport heights, and redundant titles.
    """

    static func mcpServersPayload() -> [[String: Any]] {
        guard HTMLRenderPreference.isEnabled, let executable = ACPPaths.htmlMCPExecutable else { return [] }
        return [[
            "name": ACPProvider.htmlMCPServerName,
            "command": executable.path,
            "args": [],
            "env": []
        ]]
    }

    static func sessionMeta(includeHTMLRender: Bool) -> [String: Any]? {
        guard includeHTMLRender else { return nil }
        return [
            "antigravity": [
                "systemPrompt": [
                    "append": systemPromptAppend
                ]
            ]
        ]
    }

    static func isHTMLRenderToolName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "html_render"
            || lower.hasSuffix("__html_render")
            || lower.hasSuffix("_html_render")
            || lower.hasSuffix(".html_render")
            || lower.hasSuffix("/html_render")
    }

    /// Reconstructs PiG's `pigHtml` v2 details JSON from an ACP `html_render` tool call's
    /// input arguments and returned `[[pig-ui:<16-hex>]]` text, so `HTMLArtifact(tool:)` renders
    /// it identically both live and on `session/load` replay.
    static func pigHTMLDetailsJSON(rawInput: [String: Any]?, outputText: String, fallbackSeed: String) -> String? {
        guard let rawInput,
              let html = rawInput["html"] as? String,
              !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let reference = extractMarkerReference(from: outputText) ?? deterministicReference(seed: fallbackSeed)
        let title = (rawInput["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyTrimmed ?? "Interactive controls"
        let height: Int
        if let h = rawInput["height"] as? Int { height = h }
        else if let h = rawInput["height"] as? Double { height = Int(h) }
        else { height = 44 }
        let actions = rawInput["actions"] as? [[String: Any]] ?? []

        let payload: [String: Any] = [
            "pigHtml": [
                "version": 2,
                "reference": reference,
                "title": title,
                "html": html,
                "height": min(1000, max(1, height)),
                "actions": actions
            ]
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    static func extractMarkerReference(from text: String) -> String? {
        guard let match = text.firstMatch(of: #/\[\[pig-ui:([a-f0-9]{16})\]\]/#) else { return nil }
        return String(match.1)
    }

    private static func deterministicReference(seed: String) -> String {
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
