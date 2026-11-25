import Foundation

enum UsageLimitWindowRole: Hashable {
    case primary
    case weekly
    case extra
}

struct UsageLimitWindow: Hashable {
    var label: String
    var remainingPercent: Int
    var resetText: String?
    var role: UsageLimitWindowRole = .primary
    var groupName: String? = nil
    var groupSubtitle: String? = nil
    var isActiveGroup: Bool = true
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

    static let antigravityOverview = UsageLimitProvider.antigravity("")

    var serviceName: String {
        switch self {
        case .codex: return "Codex"
        case .claude, .claudeBridge: return "Claude Code"
        case .grok: return "Grok"
        case .antigravity: return ACPProvider.antigravityDisplayName
        }
    }

    var accountSubtitle: String? {
        switch self {
        case .codex(let key): return key
        case .claudeBridge: return "Reported by active chat"
        case .claude, .grok, .antigravity: return nil
        }
    }

    var colorKey: String {
        switch self {
        case .codex(let key): return key
        case .claude, .claudeBridge: return "anthropic"
        case .grok: return "xai"
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

    static func configuredAccounts(
        authEntries: [String: Any]? = nil,
        claudeInstalled: Bool? = nil,
        antigravityInstalled: Bool? = nil,
        includeClaudeBridge: Bool = false
    ) -> [UsageLimitProvider] {
        let entries = authEntries ?? (try? UsageLimitHelpers.authEntries()) ?? [:]
        let hasClaudeCLI = claudeInstalled ?? (PiEnvironment.executable(named: "claude") != nil)
        let hasAntigravity = antigravityInstalled ?? ACPPaths.isAntigravityInstalled

        func isValidOAuth(_ entry: Any?) -> [String: Any]? {
            guard let dict = entry as? [String: Any],
                  (dict["type"] as? String)?.lowercased() == "oauth",
                  let access = dict["access"] as? String, !access.isEmpty else { return nil }
            return dict
        }

        var providers: [UsageLimitProvider] = []
        if hasAntigravity {
            providers.append(.antigravityOverview)
        }

        let codexKeys = entries.keys.sorted().filter { key in
            let lower = key.lowercased()
            guard lower.contains("openai") || lower.contains("codex"),
                  let dict = isValidOAuth(entries[key]),
                  let account = dict["accountId"] as? String, !account.isEmpty else { return false }
            return true
        }
        providers.append(contentsOf: codexKeys.map { .codex($0) })

        if hasClaudeCLI {
            providers.append(.claude)
        } else if includeClaudeBridge {
            providers.append(.claudeBridge)
        }

        if isValidOAuth(entries["xai"]) != nil {
            providers.append(.grok)
        }

        return providers
    }
}

enum UsageLimitService {
    static func fetch(_ provider: UsageLimitProvider, forceRefresh: Bool = false) async -> UsageLimitSnapshot {
        do {
            switch provider {
            case .codex(let key): return try await CodexUsageService.fetch(provider: key)
            case .claude: return try await ClaudeUsageService.fetch()
            case .claudeBridge: return UsageLimitSnapshot(serviceName: provider.serviceName)
            case .grok: return try await GrokUsageService.fetch()
            case .antigravity(let modelName): return try await AntigravityUsageService.fetch(modelName: modelName, forceRefresh: forceRefresh)
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
            window: UsageLimitWindow(
                label: label,
                remainingPercent: 100 - used,
                resetText: "in \(UsageLimitHelpers.formatDuration(window.resetAfterSeconds ?? secondsUntil(window.resetAt)))",
                role: kind == .weekly ? .weekly : .primary
            )
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
        func window(_ key: String, label: String, role: UsageLimitWindowRole) -> UsageLimitWindow? {
            guard let raw = headers["\(key)-utilization"],
                  let used = Double(raw), used.isFinite else { return nil }
            let reset = headers["\(key)-reset"].flatMap(Double.init)
            let resetText: String?
            if let reset, reset.isFinite {
                resetText = "in \(UsageLimitHelpers.formatDuration(max(0, reset - Date().timeIntervalSince1970)))"
            } else {
                resetText = nil
            }
            return UsageLimitWindow(
                label: label,
                remainingPercent: Int(((1 - min(1, max(0, used))) * 100).rounded()),
                resetText: resetText,
                role: role
            )
        }
        let primary = window("5h", label: "5h", role: .primary)
        let weekly = window("7d", label: "Weekly", role: .weekly)
        let extra = window("7d_oi", label: "Weekly (extra)", role: .extra)
        let details = [primary, weekly, extra].compactMap { $0 }
        guard !details.isEmpty else { return nil }
        return UsageLimitSnapshot(serviceName: "Claude Code", primary: primary, weekly: weekly, details: details)
    }
}

enum ClaudeUsageService {
    static func fetch() async throws -> UsageLimitSnapshot {
        try parseSnapshot(from: try await runUsageCommand())
    }

    static func parseSnapshot(from text: String) throws -> UsageLimitSnapshot {
        let windows = parseWindows(from: text)
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

    private enum ClaudeWindowKind {
        case session, weeklyAllModels, weeklyModel, other

        var sortRank: Int {
            switch self {
            case .session: return 0
            case .weeklyAllModels: return 1
            case .weeklyModel: return 2
            case .other: return 3
            }
        }

        var role: UsageLimitWindowRole {
            switch self {
            case .session: return .primary
            case .weeklyAllModels, .weeklyModel: return .weekly
            case .other: return .extra
            }
        }
    }
    private struct ParsedClaudeWindow { var kind: ClaudeWindowKind; var window: UsageLimitWindow }

    private static func parseWindows(from text: String) -> [ParsedClaudeWindow] {
        text.split(whereSeparator: \.isNewline)
            .compactMap { parseLine(String($0)) }
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.kind.sortRank != rhs.element.kind.sortRank {
                    return lhs.element.kind.sortRank < rhs.element.kind.sortRank
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
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
            window: UsageLimitWindow(
                label: label,
                remainingPercent: 100 - UsageLimitHelpers.clamp(Int(used.rounded()), 0, 100),
                resetText: resetText(in: line),
                role: kind.role
            )
        )
    }

    private static func percentUsed(in line: String) -> Double? {
        guard let percentRange = line.range(of: "% used") else { return nil }
        let prefix = line[..<percentRange.lowerBound]
        let number = prefix.split(separator: " ").last.map(String.init) ?? ""
        return Double(number)
    }

    private static func resetText(in line: String) -> String? {
        guard let range = line.range(of: "resets ") else { return nil }
        var text = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if let paren = text.range(of: "(") {
            text = String(text[..<paren.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }

    private static func textBetween(_ text: String, _ start: Character, _ end: Character) -> String? {
        guard let startIndex = text.firstIndex(of: start), let endIndex = text[startIndex...].firstIndex(of: end), startIndex < endIndex else { return nil }
        return String(text[text.index(after: startIndex)..<endIndex])
    }
}

// `agy -p /usage` reports quota per model group, each with 5-hour and weekly buckets.
// One fetch serves every model for a minute; the selected model picks its group.
enum AntigravityUsageService {
    static func fetch(modelName: String, forceRefresh: Bool = false) async throws -> UsageLimitSnapshot {
        let groups = try await cache.groups(forceRefresh: forceRefresh)
        guard !groups.isEmpty else { throw FetchError.invalidResponse(ACPProvider.antigravityDisplayName) }
        return makeSnapshot(groups: groups, modelName: modelName)
    }

    static func makeSnapshot(groups: [AntigravityUsageGroup], modelName: String) -> UsageLimitSnapshot {
        let trimmedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let isOverview = trimmedModel.isEmpty
        let selected = isOverview ? groups[0] : group(for: trimmedModel, in: groups)
        let ordered = isOverview ? groups : ([selected] + groups.filter { $0.name != selected.name })
        return UsageLimitSnapshot(
            serviceName: ACPProvider.antigravityDisplayName,
            primary: window(selected, kind: "5h", label: "5h", role: .primary),
            weekly: window(selected, kind: "weekly", label: "Weekly", role: .weekly),
            details: ordered.flatMap { group in
                let isActive = isOverview || group.name == selected.name
                let subtitle = memberSubtitle(group)
                return sortedBuckets(group.buckets).compactMap { bucket in
                    let normalized = bucket.window?.lowercased()
                    let kindLabel: String
                    let role: UsageLimitWindowRole
                    if normalized == "5h" {
                        kindLabel = "5h"
                        role = .primary
                    } else if normalized == "weekly" {
                        kindLabel = "Weekly"
                        role = .weekly
                    } else {
                        kindLabel = bucket.window?.nonEmptyTrimmed ?? "Limit"
                        role = .extra
                    }
                    return window(
                        bucket,
                        label: "\(group.name) · \(kindLabel)",
                        role: role,
                        groupName: group.name,
                        groupSubtitle: subtitle,
                        isActiveGroup: isActive
                    )
                }
            }
        )
    }

    private static let cache = Cache()

    private actor Cache {
        private var cached: [AntigravityUsageGroup]?
        private var fetchedAt: Date?
        private var inFlight: Task<[AntigravityUsageGroup], Error>?

        func groups(forceRefresh: Bool) async throws -> [AntigravityUsageGroup] {
            if !forceRefresh, let cached, let fetchedAt, Date().timeIntervalSince(fetchedAt) < 60 { return cached }
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

    private static func sortedBuckets(_ buckets: [AntigravityUsageBucket]) -> [AntigravityUsageBucket] {
        buckets.enumerated()
            .sorted { lhs, rhs in
                let lhsRank = bucketRank(lhs.element.window)
                let rhsRank = bucketRank(rhs.element.window)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func bucketRank(_ window: String?) -> Int {
        switch window?.lowercased() {
        case "5h": return 0
        case "weekly": return 1
        default: return 2
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
        rawMemberNames(group).map { $0.lowercased() }
    }

    private static func memberSubtitle(_ group: AntigravityUsageGroup) -> String? {
        let names = rawMemberNames(group)
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    private static func rawMemberNames(_ group: AntigravityUsageGroup) -> [String] {
        guard let description = group.description,
              let range = description.range(of: "Models within this group:", options: .caseInsensitive) else { return [] }
        return description[range.upperBound...]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "."))) }
            .filter { !$0.isEmpty }
    }

    private static func window(_ group: AntigravityUsageGroup, kind: String, label: String, role: UsageLimitWindowRole) -> UsageLimitWindow? {
        group.buckets.first { $0.window?.lowercased() == kind }.flatMap { window($0, label: label, role: role) }
    }

    private static func window(
        _ bucket: AntigravityUsageBucket,
        label: String,
        role: UsageLimitWindowRole,
        groupName: String? = nil,
        groupSubtitle: String? = nil,
        isActiveGroup: Bool = true
    ) -> UsageLimitWindow? {
        guard let fraction = bucket.remainingFraction, fraction.isFinite else { return nil }
        let resetText = bucket.resetTime
            .flatMap { ISO8601DateFormatter().date(from: $0) }
            .map { "in \(UsageLimitHelpers.formatDuration($0.timeIntervalSinceNow))" }
        return UsageLimitWindow(
            label: label,
            remainingPercent: UsageLimitHelpers.clamp(Int((fraction * 100).rounded()), 0, 100),
            resetText: resetText,
            role: role,
            groupName: groupName,
            groupSubtitle: groupSubtitle,
            isActiveGroup: isActiveGroup
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

        return try parseSnapshot(from: data)
    }

    static func parseSnapshot(from data: Data, now: Date = Date()) throws -> UsageLimitSnapshot {
        let decoded = try JSONDecoder().decode(GrokBillingResponse.self, from: data)
        guard let config = decoded.config else { throw FetchError.invalidGrokUsage }
        let resetISO = config.currentPeriod?.end ?? config.billingPeriodEnd
        // Proto3 JSON omits scalar numeric fields when 0 (e.g. 0% credit usage).
        guard config.creditUsagePercent != nil || config.currentPeriod != nil || resetISO != nil else {
            throw FetchError.invalidGrokUsage
        }
        let usedPercent = config.creditUsagePercent ?? 0
        let periodLabel = config.currentPeriod?.type?.uppercased().contains("MONTHLY") == true ? "Monthly" : "Weekly"
        let resetText = resetISO
            .flatMap(parseISO8601)
            .map { "in \(UsageLimitHelpers.formatDuration(max(0, $0.timeIntervalSince(now))))" }
        let primary = UsageLimitWindow(
            label: periodLabel,
            remainingPercent: UsageLimitHelpers.clamp(100 - Int(usedPercent.rounded()), 0, 100),
            resetText: resetText,
            role: .primary
        )
        let extra = extraWindow(cap: config.onDemandCap?.val, used: config.onDemandUsed?.val, resetText: resetText)
        return UsageLimitSnapshot(
            serviceName: UsageLimitProvider.grok.serviceName,
            primary: primary,
            weekly: extra,
            details: [primary, extra].compactMap { $0 }
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

    private static func extraWindow(cap: Double?, used: Double?, resetText: String?) -> UsageLimitWindow? {
        guard let cap, cap > 0 else { return nil }
        let usedPercent = ((used ?? 0) / cap) * 100
        return UsageLimitWindow(
            label: "Extra",
            remainingPercent: UsageLimitHelpers.clamp(100 - Int(usedPercent.rounded()), 0, 100),
            resetText: resetText,
            role: .weekly
        )
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

struct AntigravityUsageGroup: Decodable {
    var name: String
    var description: String?
    var buckets: [AntigravityUsageBucket]
}

struct AntigravityUsageBucket: Decodable {
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
    var type: String?
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
