import Foundation

struct SessionStatistics {
    let sessionFile: String?
    let sessionID: String?
    let totalMessages: Int?
    let userMessages: Int?
    let assistantMessages: Int?
    let toolResults: Int?
    let toolCalls: Int?
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadTokens: Int?
    let cacheWriteTokens: Int?
    let totalTokens: Int?
    let contextTokens: Int?
    let contextWindow: Int?
    let contextPercent: Double?

    init(_ data: [String: Any]) {
        let tokens = data["tokens"] as? [String: Any] ?? [:]
        let usage = data["contextUsage"] as? [String: Any] ?? [:]
        sessionFile = data["sessionFile"] as? String
        sessionID = data["sessionId"] as? String
        totalMessages = data["totalMessages"] as? Int
        userMessages = data["userMessages"] as? Int
        assistantMessages = data["assistantMessages"] as? Int
        toolResults = data["toolResults"] as? Int
        toolCalls = data["toolCalls"] as? Int
        inputTokens = tokens["input"] as? Int
        outputTokens = tokens["output"] as? Int
        cacheReadTokens = tokens["cacheRead"] as? Int
        cacheWriteTokens = tokens["cacheWrite"] as? Int
        totalTokens = tokens["total"] as? Int
        contextTokens = usage["tokens"] as? Int
        contextWindow = usage["contextWindow"] as? Int
        let percent = (usage["percent"] as? NSNumber)?.doubleValue
        contextPercent = percent.flatMap { $0.isFinite ? $0 : nil }
    }

    static func display(_ value: Int?) -> String { value?.formatted() ?? "Unavailable" }
}
