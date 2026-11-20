import Foundation

struct UsageLimitWindow: Hashable {
    var label: String
    var remainingPercent: Int
    var resetText: String
}

struct UsageLimitSnapshot: Hashable {
    var serviceName: String
    var primary: UsageLimitWindow?
    var weekly: UsageLimitWindow?
    var details: [UsageLimitWindow] = []
    var error: String? = nil
}

enum UsageLimitProvider: Hashable {
    case codex(String)
    case claude
    case claudeBridge
    case grok
    case antigravity(String)

    var serviceName: String {
        switch self {
        case .codex: return "Codex"
        case .claude, .claudeBridge: return "Claude Code"
        case .grok: return "Grok"
        case .antigravity: return ACPProvider.antigravityDisplayName
        }
    }

    static func from(model: ModelInfo?) -> UsageLimitProvider? {
        guard let model else { return nil }
        if model.isAntigravityACP {
            guard ACPPaths.isAntigravityInstalled else { return nil }
            return .antigravity(model.name.isEmpty ? model.modelId : model.name)
        }
        let provider = model.provider.lowercased()
        if provider == "claude-bridge" { return .claudeBridge }
        let kind: UsageLimitProvider
        if provider.contains("openai") || provider.contains("codex") { kind = .codex(model.provider) }
        else if provider.contains("anthropic") || provider.contains("claude") { kind = .claude }
        else if provider.contains("xai") || provider.contains("grok") { kind = .grok }
        else { return nil }
        guard let entries = try? UsageLimitHelpers.authEntries() else { return nil }
        let key = kind == .grok ? "xai" : model.provider
        guard let entry = entries[key] as? [String: Any],
              (entry["type"] as? String)?.lowercased() == "oauth",
              let access = entry["access"] as? String, !access.isEmpty else { return nil }
        if case .codex = kind {
            guard let account = entry["accountId"] as? String, !account.isEmpty else { return nil }
        }
        if kind == .claude && PiEnvironment.executable(named: "claude") == nil { return nil }
        return kind
    }
}

enum UsageLimitService {
    static func fetch(_ provider: UsageLimitProvider) async -> UsageLimitSnapshot {
        do {
            switch provider {
            case .codex(let key): return try await CodexUsageService.fetch(provider: key)
            case .claude: return try await ClaudeUsageService.fetch()
            case .claudeBridge: return UsageLimitSnapshot(serviceName: provider.serviceName)
            case .grok: return try await GrokUsageService.fetch()
            case .antigravity(let modelName): return try await AntigravityUsageService.fetch(modelName: modelName)
            }
        } catch {
            return UsageLimitSnapshot(serviceName: provider.serviceName, error: error.localizedDescription)
        }
    }
}

enum CodexUsageService {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static func fetch(provider: String) async throws -> UsageLimitSnapshot {
        let credential = try loadCredential(provider: provider)
        var request = URLRequest(url: usageURL)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "authorization")
        request.setValue("*/*", forHTTPHeaderField: "accept")
        request.setValue(credential.accountId, forHTTPHeaderField: "chatgpt-account-id")

        let (data, response) = try await URLSession.shared.data(for: request)
        try UsageLimitHelpers.checkHTTP(response, service: "Codex", authRejected: .authRejected(credential.provider))

        let decoded = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        let windows = [
            formatWindow(decoded.rateLimit?.primaryWindow, fallbackKind: .primary),
            formatWindow(decoded.rateLimit?.secondaryWindow, fallbackKind: .weekly)
        ].compactMap { $0 }
        let primary = windows.first { $0.kind == .primary }?.window
        let weekly = windows.first { $0.kind == .weekly }?.window
        return UsageLimitSnapshot(
            serviceName: "Codex",
            primary: primary,
            weekly: weekly,
            details: [primary, weekly].compactMap { $0 }
        )
    }

    private static func loadCredential(provider: String) throws -> CodexCredential {
        let root = try UsageLimitHelpers.authEntries()
        guard let entry = root[provider] as? [String: Any], entry["type"] as? String == "oauth" else { throw FetchError.noCredential(provider) }
        guard let access = entry["access"] as? String, !access.isEmpty else { throw FetchError.noCredential(provider) }
        guard let accountId = entry["accountId"] as? String, !accountId.isEmpty else { throw FetchError.noCredential(provider) }
        return CodexCredential(provider: provider, accessToken: access, accountId: accountId)
    }

    private enum WindowKind { case primary, weekly }
    private struct FormattedWindow { var kind: WindowKind; var window: UsageLimitWindow }

    private static func formatWindow(_ window: CodexWindowResponse?, fallbackKind: WindowKind) -> FormattedWindow? {
        guard let window else { return nil }
        let kind = window.limitWindowSeconds.map { $0 >= 86_400 ? WindowKind.weekly : .primary } ?? fallbackKind
        let label = kind == .weekly ? "Weekly" : "5h"
        let used = UsageLimitHelpers.clamp(Int((window.usedPercent ?? 0).rounded()), 0, 100)
        return FormattedWindow(
            kind: kind,
            window: UsageLimitWindow(label: label, remainingPercent: 100 - used, resetText: "in \(UsageLimitHelpers.formatDuration(window.resetAfterSeconds ?? secondsUntil(window.resetAt)))")
        )
    }

    private static func secondsUntil(_ unixSeconds: Double?) -> Double {
        guard let unixSeconds else { return 0 }
        return max(0, unixSeconds - Date().timeIntervalSince1970)
    }
}

// Claude Code's bridge emits utilization fractions (0...1) and Unix reset times.
// Parse only known windows, ignoring missing or malformed values.
enum ClaudeBridgeUsageService {
    static func snapshot(from text: String) -> UsageLimitSnapshot? {
        guard let data = text.data(using: .utf8),
              let headers = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        func window(_ key: String, label: String) -> UsageLimitWindow? {
            guard let raw = headers["\(key)-utilization"],
                  let used = Double(raw), used.isFinite else { return nil }
            let reset = headers["\(key)-reset"].flatMap(Double.init)
            let resetText: String
            if let reset, reset.isFinite {
                resetText = "in \(UsageLimitHelpers.formatDuration(max(0, reset - Date().timeIntervalSince1970)))"
            } else {
                resetText = "unknown"
            }
            return UsageLimitWindow(
                label: label,
                remainingPercent: Int(((1 - min(1, max(0, used))) * 100).rounded()),
                resetText: resetText
            )
        }
        let primary = window("5h", label: "5h")
        let weekly = window("7d", label: "Weekly")
        let extra = window("7d_oi", label: "Weekly (extra)")
        let details = [primary, weekly, extra].compactMap { $0 }
        guard !details.isEmpty else { return nil }
        return UsageLimitSnapshot(serviceName: "Claude Code", primary: primary, weekly: weekly, details: details)
    }
}

enum ClaudeUsageService {
    static func fetch() async throws -> UsageLimitSnapshot {
        let windows = parseWindows(from: try await runUsageCommand())
        guard !windows.isEmpty else { throw FetchError.invalidResponse("Claude") }
        return UsageLimitSnapshot(
            serviceName: UsageLimitProvider.claude.serviceName,
            primary: windows.first { $0.kind == .session }?.window,
            weekly: windows.first { $0.kind == .weeklyAllModels }?.window,
            details: windows.map(\.window)
        )
    }

    private static func runUsageCommand() async throws -> String {
        try await Task.detached(priority: .utility) {
            let result = try ProcessRunner.capture(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["claude", "-p", "/usage", "--output-format", "json"],
                environment: PiEnvironment.merged(), timeout: 25
            )
            guard result.status == 0 else {
                let errorText = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw FetchError.claudeCommandFailed(errorText?.isEmpty == false ? errorText! : "exit \(result.status)")
            }
            guard let output = String(data: result.stdout, encoding: .utf8), !output.isEmpty else { throw FetchError.invalidResponse("Claude") }
            guard let data = output.data(using: .utf8),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = root["result"] as? String else { throw FetchError.invalidResponse("Claude") }
            return result
        }.value
    }

    private enum ClaudeWindowKind { case session, weeklyAllModels, weeklyModel, other }
    private struct ParsedClaudeWindow { var kind: ClaudeWindowKind; var window: UsageLimitWindow }

    private static func parseWindows(from text: String) -> [ParsedClaudeWindow] {
        text.split(whereSeparator: \.isNewline).compactMap { parseLine(String($0)) }
    }

    private static func parseLine(_ line: String) -> ParsedClaudeWindow? {
        let lower = line.lowercased()
        guard lower.hasPrefix("current session:") || lower.hasPrefix("current week") else { return nil }
        guard let used = percentUsed(in: line) else { return nil }

        let kind: ClaudeWindowKind
        let label: String
        if lower.hasPrefix("current session:") {
            kind = .session
            label = "Session"
        } else if lower.hasPrefix("current week (all models):") {
            kind = .weeklyAllModels
            label = "Weekly"
        } else if let model = textBetween(line, "(", ")") {
            kind = .weeklyModel
            label = "Weekly (\(model))"
        } else {
            kind = .other
            label = "Weekly"
        }

        return ParsedClaudeWindow(
            kind: kind,
            window: UsageLimitWindow(label: label, remainingPercent: 100 - UsageLimitHelpers.clamp(Int(used.rounded()), 0, 100), resetText: resetText(in: line))
        )
    }

    private static func percentUsed(in line: String) -> Double? {
        guard let percentRange = line.range(of: "% used") else { return nil }
        let prefix = line[..<percentRange.lowerBound]
        let number = prefix.split(separator: " ").last.map(String.init) ?? ""
        return Double(number)
    }

    private static func resetText(in line: String) -> String {
        guard let range = line.range(of: "resets ") else { return "unknown" }
        var text = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if let paren = text.range(of: "(") {
            text = String(text[..<paren.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? "unknown" : text
    }

    private static func textBetween(_ text: String, _ start: Character, _ end: Character) -> String? {
        guard let startIndex = text.firstIndex(of: start), let endIndex = text[startIndex...].firstIndex(of: end), startIndex < endIndex else { return nil }
        return String(text[text.index(after: startIndex)..<endIndex])
    }
}

// `agy -p /usage` reports quota per model group, each with 5-hour and weekly buckets.
// One fetch serves every model for a minute; the selected model picks its group.
enum AntigravityUsageService {
    static func fetch(modelName: String) async throws -> UsageLimitSnapshot {
        let groups = try await cache.groups()
        guard !groups.isEmpty else { throw FetchError.invalidResponse(ACPProvider.antigravityDisplayName) }
        let selected = group(for: modelName, in: groups)
        let ordered = [selected] + groups.filter { $0.name != selected.name }
        return UsageLimitSnapshot(
            serviceName: ACPProvider.antigravityDisplayName,
            primary: window(selected, kind: "5h", label: "5h"),
            weekly: window(selected, kind: "weekly", label: "Weekly"),
            details: ordered.flatMap { group in
                group.buckets.compactMap { bucket in
                    let kind = bucket.window == "5h" ? "5h" : "Weekly"
                    return window(bucket, label: "\(group.name) · \(kind)")
                }
            }
        )
    }

    private static let cache = Cache()

    private actor Cache {
        private var cached: [AntigravityUsageGroup]?
        private var fetchedAt: Date?
        private var inFlight: Task<[AntigravityUsageGroup], Error>?

        func groups() async throws -> [AntigravityUsageGroup] {
            if let cached, let fetchedAt, Date().timeIntervalSince(fetchedAt) < 60 { return cached }
            if let inFlight { return try await inFlight.value }
            let task = Task.detached(priority: .utility) { try AntigravityUsageService.runUsageCommand() }
            inFlight = task
            defer { inFlight = nil }
            let groups = try await task.value
            cached = groups
            fetchedAt = Date()
            return groups
        }
    }

    private static func runUsageCommand() throws -> [AntigravityUsageGroup] {
        let executable = ACPPaths.antigravityExecutable
        let prefix = executable.path == "/usr/bin/env" ? ["agy"] : []
        let result = try ProcessRunner.capture(
            executable: executable,
            arguments: prefix + ["-p", "/usage", "--output-format", "json"],
            environment: PiEnvironment.merged(), timeout: 25
        )
        guard result.status == 0 else {
            let errorText = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw FetchError.agyCommandFailed(errorText?.isEmpty == false ? errorText! : "exit \(result.status)")
        }
        let decoded = try JSONDecoder().decode(AntigravityUsageResponse.self, from: result.stdout)
        return decoded.command?.data?.groups ?? []
    }

    private static func group(for modelName: String, in groups: [AntigravityUsageGroup]) -> AntigravityUsageGroup {
        let name = modelName.lowercased()
        let members = groups.map { group in (group, memberNames(group)) }
        if let exact = members.first(where: { $0.1.contains(name) }) { return exact.0 }
        let prefixed = members.compactMap { group, names -> (AntigravityUsageGroup, Int)? in
            guard let best = names.filter({ name.hasPrefix($0) }).map(\.count).max() else { return nil }
            return (group, best)
        }
        if let best = prefixed.max(by: { $0.1 < $1.1 }) { return best.0 }
        return groups.first { $0.name.lowercased() == name } ?? groups[0]
    }

    private static func memberNames(_ group: AntigravityUsageGroup) -> [String] {
        guard let description = group.description,
              let range = description.range(of: "Models within this group:", options: .caseInsensitive) else { return [] }
        return description[range.upperBound...]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "."))).lowercased() }
            .filter { !$0.isEmpty }
    }

    private static func window(_ group: AntigravityUsageGroup, kind: String, label: String) -> UsageLimitWindow? {
        group.buckets.first { $0.window == kind }.flatMap { window($0, label: label) }
    }

    private static func window(_ bucket: AntigravityUsageBucket, label: String) -> UsageLimitWindow? {
        guard let fraction = bucket.remainingFraction, fraction.isFinite else { return nil }
        let resetText = bucket.resetTime
            .flatMap { ISO8601DateFormatter().date(from: $0) }
            .map { "in \(UsageLimitHelpers.formatDuration($0.timeIntervalSinceNow))" } ?? "unknown"
        return UsageLimitWindow(
            label: label,
            remainingPercent: UsageLimitHelpers.clamp(Int((fraction * 100).rounded()), 0, 100),
            resetText: resetText
        )
    }
}

enum GrokUsageService {
    private static let usageURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!

    static func fetch() async throws -> UsageLimitSnapshot {
        let token = try loadAccessToken()
        var request = URLRequest(url: usageURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")

        let (data, response) = try await URLSession.shared.data(for: request)
        try UsageLimitHelpers.checkHTTP(response, service: "Grok", authRejected: .grokAuthRejected)

        let decoded = try JSONDecoder().decode(GrokBillingResponse.self, from: data)
        guard let config = decoded.config, let usedPercent = config.creditUsagePercent else { throw FetchError.invalidGrokUsage }
        let weekly = UsageLimitWindow(
            label: "Weekly",
            remainingPercent: UsageLimitHelpers.clamp(100 - Int(usedPercent.rounded()), 0, 100),
            resetText: "in \(UsageLimitHelpers.formatDuration(secondsUntil(config.currentPeriod?.end ?? config.billingPeriodEnd)))"
        )
        let extra = extraWindow(cap: config.onDemandCap?.val, used: config.onDemandUsed?.val, reset: config.currentPeriod?.end ?? config.billingPeriodEnd)
        return UsageLimitSnapshot(
            serviceName: UsageLimitProvider.grok.serviceName,
            primary: weekly,
            weekly: extra,
            details: [weekly, extra].compactMap { $0 }
        )
    }

    private static func loadAccessToken() throws -> String {
        let root = try UsageLimitHelpers.authEntries()
        guard let entry = root["xai"] as? [String: Any] else { throw FetchError.noGrokCredential }
        let type = (entry["type"] as? String)?.lowercased()
        guard type == "oauth" else { throw FetchError.noGrokCredential }
        guard let access = entry["access"] as? String, !access.isEmpty else { throw FetchError.noGrokCredential }
        return access
    }

    private static func extraWindow(cap: Double?, used: Double?, reset: String?) -> UsageLimitWindow? {
        guard let cap, cap > 0 else { return nil }
        let usedPercent = ((used ?? 0) / cap) * 100
        return UsageLimitWindow(
            label: "Extra",
            remainingPercent: UsageLimitHelpers.clamp(100 - Int(usedPercent.rounded()), 0, 100),
            resetText: "in \(UsageLimitHelpers.formatDuration(secondsUntil(reset)))"
        )
    }

    private static func secondsUntil(_ isoDate: String?) -> Double {
        guard let isoDate, let date = parseISO8601(isoDate) else { return 0 }
        return max(0, date.timeIntervalSinceNow)
    }

    private static func parseISO8601(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}

private enum UsageLimitHelpers {
    static func authEntries() throws -> [String: Any] {
        let url = PiPaths.agentDir.appendingPathComponent("auth.json")
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FetchError.invalidAuthFile }
        return root
    }

    static func checkHTTP(_ response: URLResponse, service: String, authRejected: FetchError) throws {
        guard let response = response as? HTTPURLResponse else { throw FetchError.invalidResponse(service) }
        guard response.statusCode != 401 && response.statusCode != 403 else { throw authRejected }
        guard (200..<300).contains(response.statusCode) else { throw FetchError.http(service, response.statusCode) }
    }

    static func formatDuration(_ totalSeconds: Double) -> String {
        var seconds = max(0, Int(totalSeconds.rounded()))
        let days = seconds / 86_400
        seconds %= 86_400
        let hours = seconds / 3_600
        seconds %= 3_600
        let minutes = seconds / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    static func clamp(_ value: Int, _ minValue: Int, _ maxValue: Int) -> Int {
        min(max(value, minValue), maxValue)
    }
}

private struct CodexCredential {
    var provider: String
    var accessToken: String
    var accountId: String
}

private struct CodexUsageResponse: Decodable {
    var planType: String?
    var rateLimit: CodexRateLimitResponse?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
    }
}

private struct CodexRateLimitResponse: Decodable {
    var primaryWindow: CodexWindowResponse?
    var secondaryWindow: CodexWindowResponse?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct CodexWindowResponse: Decodable {
    var usedPercent: Double?
    var limitWindowSeconds: Double?
    var resetAfterSeconds: Double?
    var resetAt: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAt = "reset_at"
    }
}

private struct AntigravityUsageResponse: Decodable {
    var command: Command?

    struct Command: Decodable {
        var data: Payload?
    }

    struct Payload: Decodable {
        var groups: [AntigravityUsageGroup]?
    }
}

private struct AntigravityUsageGroup: Decodable {
    var name: String
    var description: String?
    var buckets: [AntigravityUsageBucket]
}

private struct AntigravityUsageBucket: Decodable {
    var window: String?
    var remainingFraction: Double?
    var resetTime: String?

    enum CodingKeys: String, CodingKey {
        case window
        case remainingFraction = "remaining_fraction"
        case resetTime = "reset_time"
    }
}

private struct GrokBillingResponse: Decodable {
    var config: GrokBillingConfig?
}

private struct GrokBillingConfig: Decodable {
    var creditUsagePercent: Double?
    var currentPeriod: GrokBillingPeriod?
    var billingPeriodEnd: String?
    var onDemandCap: GrokBillingVal?
    var onDemandUsed: GrokBillingVal?
}

private struct GrokBillingPeriod: Decodable {
    var end: String?
}

private struct GrokBillingVal: Decodable {
    var val: Double?
}

private enum FetchError: LocalizedError {
    case invalidAuthFile
    case noCredential(String)
    case invalidResponse(String)
    case authRejected(String)
    case http(String, Int)
    case claudeCommandFailed(String)
    case agyCommandFailed(String)
    case noGrokCredential
    case grokAuthRejected
    case invalidGrokUsage

    var errorDescription: String? {
        switch self {
        case .invalidAuthFile: return "Could not read \(PiPaths.agentDir.appendingPathComponent("auth.json").path)"
        case .noCredential(let provider): return "No Codex credential found. Run /login \(provider)."
        case .invalidResponse(let service): return "\(service) usage returned an invalid response."
        case .authRejected(let provider): return "Codex auth rejected for \(provider). Run /login \(provider)."
        case .http(let service, let code): return "\(service) usage request failed: HTTP \(code)."
        case .claudeCommandFailed(let message): return "Claude usage request failed: \(message)"
        case .agyCommandFailed(let message): return "Antigravity usage request failed: \(message)"
        case .noGrokCredential: return "No Grok OAuth credential found. Run /login xai."
        case .grokAuthRejected: return "Grok auth rejected. Run /login xai."
        case .invalidGrokUsage: return "Grok usage returned no weekly credit data."
        }
    }
}
