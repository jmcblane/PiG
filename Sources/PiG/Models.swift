import Foundation
import SwiftUI

enum PiPaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let appSupport = home.appendingPathComponent("Library/Application Support/PiG", isDirectory: true)
    static let registryFile = appSupport.appendingPathComponent("projects.json")
    static let customActionsFile = appSupport.appendingPathComponent("custom-actions.json")
    static let sessionSummaryCacheFile = appSupport.appendingPathComponent("session-summaries.json")
    static var agentDir: URL {
        let value = PiEnvironment.current["PI_CODING_AGENT_DIR"]
        guard let value, !value.isEmpty else { return home.appendingPathComponent(".pi/agent", isDirectory: true) }
        let expanded = value == "~" ? home.path : value.hasPrefix("~/") ? home.appendingPathComponent(String(value.dropFirst(2))).path : value
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }
    static var piSessions: URL { agentDir.appendingPathComponent("sessions", isDirectory: true) }
    static let defaultQuickChatsProject = appSupport.appendingPathComponent("Quick Chats", isDirectory: true)
    static var quickChatsProject: URL {
        guard let path = QuickChatsFolderPreference.path else { return defaultQuickChatsProject }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    static var piExecutable: URL {
        if let path = PiExecutablePreference.path { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        return detectedPiExecutable
    }

    static var detectedPiExecutable: URL {
        let candidates = [
            home.appendingPathComponent(".local/bin/pi"),
            home.appendingPathComponent(".bin/pi"),
            URL(fileURLWithPath: "/opt/homebrew/bin/pi"),
            URL(fileURLWithPath: "/usr/local/bin/pi")
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) { return found }
        return PiEnvironment.executable(named: "pi") ?? URL(fileURLWithPath: "/usr/bin/env")
    }

    static var piDistIndex: URL? {
        let resolved = piExecutable.resolvingSymlinksInPath()
        guard resolved.lastPathComponent == "cli.js" else { return nil }
        let parent = resolved.deletingLastPathComponent()
        let dist = parent.lastPathComponent == "dist" ? parent : parent.deletingLastPathComponent()
        guard dist.lastPathComponent == "dist" else { return nil }
        let index = dist.appendingPathComponent("index.js")
        return FileManager.default.fileExists(atPath: index.path) ? index : nil
    }

    static func piArguments(noSession: Bool = false) -> [String] {
        var arguments = piExecutable.path == "/usr/bin/env" ? ["pi", "--mode", "rpc"] : ["--mode", "rpc"]
        if noSession { arguments.append("--no-session") }
        return arguments
    }
}

struct CustomAction: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var command: String
    var symbolName: String

    init(id: String = UUID().uuidString, title: String, command: String, symbolName: String = "play.fill") {
        self.id = id
        self.title = title
        self.command = command
        self.symbolName = symbolName
    }
}

struct ProjectCustomActions: Codable, Hashable {
    var actions: [CustomAction] = []
    var lastActionID: String?
}

struct ProjectInfo: Identifiable, Codable, Hashable {
    var id: String { path }
    var path: String
    var displayName: String
    var lastOpened: Date
    var isPinned: Bool
    var pinnedSortIndex: Int

    init(path: String, displayName: String? = nil, lastOpened: Date = Date(), isPinned: Bool = false, pinnedSortIndex: Int = 0) {
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        self.displayName = displayName ?? URL(fileURLWithPath: path).lastPathComponent
        self.lastOpened = lastOpened
        self.isPinned = isPinned
        self.pinnedSortIndex = pinnedSortIndex
    }

    enum CodingKeys: String, CodingKey {
        case path
        case displayName
        case lastOpened
        case isPinned
        case pinnedSortIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedPath = try container.decode(String.self, forKey: .path)
        path = URL(fileURLWithPath: decodedPath).standardizedFileURL.path
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? URL(fileURLWithPath: decodedPath).lastPathComponent
        lastOpened = try container.decodeIfPresent(Date.self, forKey: .lastOpened) ?? Date.distantPast
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        pinnedSortIndex = try container.decodeIfPresent(Int.self, forKey: .pinnedSortIndex) ?? 0
    }
}

struct SessionSummary: Identifiable, Hashable, Codable {
    var id: String { filePath }
    var filePath: String
    var projectPath: String
    var title: String
    var timestamp: Date
    var messageCount: Int
    var named: Bool
    var parentSessionPath: String?
    var isChildSession: Bool
    var delegationTitle: String?
}

struct ModelInfo: Identifiable, Hashable {
    var id: String
    var provider: String
    var modelId: String
    var name: String
    var reasoning: Bool
    var thinkingLevels: [String]
    var contextWindow: Int?

    var displayName: String { "\(provider)/\(name.isEmpty ? modelId : name)" }

    static func from(_ dict: [String: Any]) -> ModelInfo? {
        guard let modelId = dict["id"] as? String,
              let provider = dict["provider"] as? String else { return nil }
        let reasoning = dict["reasoning"] as? Bool ?? false
        return ModelInfo(
            id: "\(provider)/\(modelId)",
            provider: provider,
            modelId: modelId,
            name: dict["name"] as? String ?? modelId,
            reasoning: reasoning,
            thinkingLevels: supportedThinkingLevels(reasoning: reasoning, map: dict["thinkingLevelMap"]),
            contextWindow: dict["contextWindow"] as? Int
        )
    }

    static func supportedThinkingLevels(reasoning: Bool, map: Any?) -> [String] {
        guard reasoning else { return ["off"] }
        let levels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
        guard let map = map as? [String: Any] else { return Array(levels.prefix(5)) }
        return levels.filter { level in
            if map[level] is NSNull { return false }
            if level == "xhigh" || level == "max" { return map[level] != nil }
            return true
        }
    }
}

enum NewSessionModelMode: String, CaseIterable, Identifiable {
    case single
    case scheduled

    var id: String { rawValue }
    var title: String { self == .single ? "Single model" : "Scheduled" }
}

enum DefaultModelSchedule {
    private static let migratedKey = "PiG.modelDefaults.migrated"
    private static let modeKey = "PiG.modelDefaults.mode"
    private static let singleModelKey = "PiG.modelDefaults.singleModelID"
    private static let workModelKey = "PiG.modelDefaults.workModelID"
    private static let offHoursModelKey = "PiG.modelDefaults.offHoursModelID"
    private static let weekdaysKey = "PiG.modelDefaults.workWeekdays"
    private static let startMinutesKey = "PiG.modelDefaults.startMinutes"
    private static let endMinutesKey = "PiG.modelDefaults.endMinutes"
    private static let timeZoneKey = "PiG.modelDefaults.timeZone"

    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedKey) else { return }
        if defaults.object(forKey: singleModelKey) == nil,
           let modelID = defaults.trimmedString(forKey: "PiG.globalSelectedModelID") {
            defaults.set(modelID, forKey: singleModelKey)
        }
        defaults.set(true, forKey: migratedKey)
    }

    static var mode: NewSessionModelMode {
        get {
            migrateIfNeeded()
            return UserDefaults.standard.storedEnum(forKey: modeKey, default: .single)
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    static var singleModelID: String? {
        get { migrateIfNeeded(); return UserDefaults.standard.trimmedString(forKey: singleModelKey) }
        set { UserDefaults.standard.setTrimmedString(newValue, forKey: singleModelKey) }
    }

    static var workModelID: String? {
        get { UserDefaults.standard.trimmedString(forKey: workModelKey) }
        set { UserDefaults.standard.setTrimmedString(newValue, forKey: workModelKey) }
    }

    static var offHoursModelID: String? {
        get { UserDefaults.standard.trimmedString(forKey: offHoursModelKey) }
        set { UserDefaults.standard.setTrimmedString(newValue, forKey: offHoursModelKey) }
    }

    static var workWeekdays: Set<Int> {
        get { Set(UserDefaults.standard.array(forKey: weekdaysKey) as? [Int] ?? [2, 3, 4, 5, 6]) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: weekdaysKey) }
    }

    static var startMinutes: Int {
        get { UserDefaults.standard.integer(forKey: startMinutesKey, default: 8 * 60) }
        set { UserDefaults.standard.set(min(max(newValue, 0), 1439), forKey: startMinutesKey) }
    }

    static var endMinutes: Int {
        get { UserDefaults.standard.integer(forKey: endMinutesKey, default: 18 * 60) }
        set { UserDefaults.standard.set(min(max(newValue, 1), 1440), forKey: endMinutesKey) }
    }

    static let systemTimeZoneID = "__system__"

    static var timeZoneID: String {
        get { UserDefaults.standard.string(forKey: timeZoneKey, default: systemTimeZoneID) }
        set {
            let value = newValue == systemTimeZoneID || TimeZone(identifier: newValue) != nil
                ? newValue
                : systemTimeZoneID
            UserDefaults.standard.set(value, forKey: timeZoneKey)
        }
    }

    static var scheduleTimeZone: TimeZone {
        timeZoneID == systemTimeZoneID ? .autoupdatingCurrent : TimeZone(identifier: timeZoneID) ?? .autoupdatingCurrent
    }

    static var timeZoneDisplayName: String {
        timeZoneID == systemTimeZoneID ? "System (\(TimeZone.autoupdatingCurrent.identifier))" : timeZoneID
    }

    static var isValid: Bool { !workWeekdays.isEmpty && startMinutes < endMinutes }

    static func effectiveModelID(at date: Date = Date()) -> String? {
        guard mode == .scheduled else { return singleModelID }
        guard isValid else { return offHoursModelID }
        let calendar = scheduleCalendar
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let isWorkTime = workWeekdays.contains(calendar.component(.weekday, from: date))
            && minute >= startMinutes && minute < endMinutes
        return isWorkTime ? workModelID : offHoursModelID
    }

    static func nextTransition(after date: Date = Date()) -> Date? {
        guard mode == .scheduled, isValid else { return nil }
        let calendar = scheduleCalendar
        let today = calendar.startOfDay(for: date)
        var candidates: [Date] = []
        for dayOffset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today),
                  workWeekdays.contains(calendar.component(.weekday, from: day)) else { continue }
            for minutes in [startMinutes, endMinutes] {
                let candidate = minutes == 1440
                    ? calendar.date(byAdding: .day, value: 1, to: day)
                    : calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)
                if let candidate, candidate > date {
                    candidates.append(candidate)
                }
            }
        }
        return candidates.min()
    }

    private static var scheduleCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = scheduleTimeZone
        return calendar
    }
}

enum QuickModelSlots {
    static func key(_ slot: Int) -> String { "PiG.quickModelSlot\(slot)" }
}

enum PinnedModels {
    private static let key = "PiG.pinnedModelIDs"

    static var ids: [String] {
        get { UserDefaults.standard.stringArray(forKey: key, default: []) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func isPinned(_ id: String) -> Bool { ids.contains(id) }

    static func toggle(_ id: String) {
        var list = ids
        if let index = list.firstIndex(of: id) {
            list.remove(at: index)
        } else {
            list.append(id)
        }
        ids = list
    }
}

enum GlobalThinkingSelection {
    private static let key = "PiG.globalThinkingLevel"
    static let defaultLevel = "medium"

    /// Default thinking level for new sessions. Existing sessions keep their own level.
    static var level: String {
        get { UserDefaults.standard.string(forKey: key, default: defaultLevel) }
        set { UserDefaults.standard.set(newValue.isEmpty ? defaultLevel : newValue, forKey: key) }
    }
}

enum SessionNamingModelMode: String, CaseIterable, Identifiable {
    case session
    case specific
    case apple

    var id: String { rawValue }
    var title: String {
        switch self {
        case .session: return "Use session’s model"
        case .specific: return "Specific model"
        case .apple: return "Apple Intelligence (on-device)"
        }
    }
}

enum SessionNamingPreference {
    private static let enabledKey = "PiG.sessionNaming.enabled"
    private static let modelKey = "PiG.sessionNaming.modelID"
    private static let modeKey = "PiG.sessionNaming.modelMode"
    private static let thinkingKey = "PiG.sessionNaming.thinkingLevel"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var modelMode: SessionNamingModelMode {
        get { UserDefaults.standard.storedEnum(forKey: modeKey, default: modelID == nil ? .session : .specific) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    static var modelID: String? {
        get { UserDefaults.standard.trimmedString(forKey: modelKey) }
        set { UserDefaults.standard.setTrimmedString(newValue, forKey: modelKey) }
    }

    static var thinkingLevel: String {
        get { UserDefaults.standard.string(forKey: thinkingKey, default: "medium") }
        set { UserDefaults.standard.set(newValue.isEmpty ? "medium" : newValue, forKey: thinkingKey) }
    }
}

enum SessionRuntimePolicy: String, CaseIterable, Identifiable {
    case hybrid = "hybrid"
    case manual = "manual"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hybrid: return "Hybrid Auto-Unload"
        case .manual: return "Manual Unload Only"
        }
    }

    private static let key = "PiG.sessionRuntimePolicy"

    static var stored: SessionRuntimePolicy {
        get { UserDefaults.standard.storedEnum(forKey: key, default: .hybrid) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

enum ModelCatalog {
    static func configuredModelsAsync(projectPath: String? = nil) async -> [ModelInfo] {
        _ = await PiEnvironment.mergedAsync()
        return await Task.detached(priority: .utility) {
            configuredModels(projectPath: projectPath)
        }.value
    }

    static func configuredModels(projectPath: String? = nil) -> [ModelInfo] {
        let url = PiPaths.agentDir.appendingPathComponent("models.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = root["providers"] as? [String: Any] else { return [] }

        var models: [ModelInfo] = []
        for (providerName, providerValue) in providers {
            guard let provider = providerValue as? [String: Any],
                  let modelDicts = provider["models"] as? [[String: Any]] else { continue }
            for modelDict in modelDicts {
                var fields = modelDict
                fields["provider"] = providerName
                if let model = ModelInfo.from(fields) { models.append(model) }
            }
        }
        let sorted = models.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return EnabledModelScope.scopedModels(sorted, projectPath: projectPath)
    }
}

/// Mirrors pi's `enabledModels` scope (`resolveModelScopeFromModels` in pi's
/// `core/model-resolver.js`, settings precedence in `core/settings-manager.js`).
///
/// Precedence: `<project>/.pi/settings.json` `enabledModels` replaces
/// `~/.pi/agent/settings.json` when the key is present (arrays replace, they do
/// not merge). Absent or empty means no scope: the full catalog is kept.
///
/// Patterns are read from disk on every call so catalog reloads never serve a
/// stale scope. Existing sessions keep their current model via the
/// `refreshState` append path, which runs after scoping and is untouched.
enum EnabledModelScope {
    static let thinkingLevels: Set<String> = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]

    /// Effective patterns, or nil when no scope applies.
    static func patterns(projectPath: String?) -> [String]? {
        if let projectPath, !projectPath.isEmpty {
            let url = URL(fileURLWithPath: projectPath).appendingPathComponent(".pi/settings.json")
            if let project = readPatterns(at: url, keyMustExist: true) {
                return project.isEmpty ? nil : project
            }
        }
        guard let global = readPatterns(at: PiPaths.agentDir.appendingPathComponent("settings.json"), keyMustExist: false),
              !global.isEmpty else { return nil }
        return global
    }

    /// Filters a catalog to the effective scope. Returns the input unchanged
    /// when no scope applies.
    static func scopedModels(_ models: [ModelInfo], projectPath: String?) -> [ModelInfo] {
        guard let patterns = patterns(projectPath: projectPath) else { return models }
        return filter(models, patterns: patterns)
    }

    /// pi's `resolveModelScopeFromModels`: pattern order, duplicates removed.
    /// Glob patterns use case-insensitive `*`/`?`/`[...]` matching against
    /// `provider/modelId` or the bare model id; plain patterns use pi's exact
    /// then substring resolution (thinking-level `:suffix` included).
    static func filter(_ models: [ModelInfo], patterns: [String]) -> [ModelInfo] {
        var scoped: [ModelInfo] = []
        var seen = Set<String>()
        func push(_ model: ModelInfo) {
            if seen.insert(model.id).inserted { scoped.append(model) }
        }
        for pattern in patterns {
            if isGlob(pattern) {
                var glob = pattern
                if thinkingSuffix(of: pattern) != nil, let colon = pattern.lastIndex(of: ":") {
                    glob = String(pattern[..<colon])
                }
                if let exact = exactMatch(glob, in: models) { push(exact); continue }
                for model in models
                where globMatch("\(model.provider)/\(model.modelId)", pattern: glob)
                    || globMatch(model.modelId, pattern: glob) {
                    push(model)
                }
            } else if let model = matchWithColonFallback(pattern, in: models) {
                push(model)
            }
        }
        return scoped
    }

    // MARK: - Settings

    /// Reads `enabledModels` as `[String]`. Returns nil when the file is
    /// unreadable, or — with `keyMustExist` — when the key is absent so the
    /// caller can fall through to the next precedence level.
    private static func readPatterns(at url: URL, keyMustExist: Bool) -> [String]? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let value = root["enabledModels"] else { return keyMustExist ? nil : [] }
        guard let list = value as? [Any] else { return keyMustExist ? nil : [] }
        return list.compactMap { $0 as? String }.filter { !$0.isEmpty }
    }

    // MARK: - Pattern resolution (mirrors pi's model-resolver.js)

    private static func isGlob(_ pattern: String) -> Bool {
        pattern.contains("*") || pattern.contains("?") || pattern.contains("[")
    }

    private static func thinkingSuffix(of pattern: String) -> String? {
        guard let colon = pattern.lastIndex(of: ":") else { return nil }
        let suffix = String(pattern[pattern.index(after: colon)...])
        return thinkingLevels.contains(suffix) ? suffix : nil
    }

    /// pi's `parseModelPattern` membership: full pattern first, then strip a
    /// trailing `:suffix` (non-strict fallback) and retry.
    private static func matchWithColonFallback(_ pattern: String, in models: [ModelInfo]) -> ModelInfo? {
        var current: String? = pattern
        while let candidate = current, !candidate.isEmpty {
            if let model = matchModel(candidate, in: models) { return model }
            guard let colon = candidate.lastIndex(of: ":") else { return nil }
            current = String(candidate[..<colon])
        }
        return nil
    }

    /// pi's `findExactModelReferenceMatch`: canonical `provider/id`, then
    /// provider+id split, then unambiguous bare id (all case-insensitive).
    static func exactMatch(_ reference: String, in models: [ModelInfo]) -> ModelInfo? {
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        let canonical = models.filter { "\($0.provider)/\($0.modelId)".lowercased() == lower }
        if canonical.count == 1 { return canonical[0] }
        if canonical.count > 1 { return nil }
        if let slash = trimmed.firstIndex(of: "/") {
            let provider = trimmed[..<slash].trimmingCharacters(in: .whitespaces)
            let modelId = trimmed[trimmed.index(after: slash)...].trimmingCharacters(in: .whitespaces)
            if !provider.isEmpty, !modelId.isEmpty {
                let split = models.filter {
                    $0.provider.lowercased() == provider.lowercased()
                        && $0.modelId.lowercased() == modelId.lowercased()
                }
                if split.count == 1 { return split[0] }
                if split.count > 1 { return nil }
            }
        }
        let bare = models.filter { $0.modelId.lowercased() == lower }
        return bare.count == 1 ? bare[0] : nil
    }

    /// pi's `tryMatchModel`: exact match, else substring on id or name
    /// preferring aliases (`-latest` or no `-YYYYMMDD` date suffix).
    static func matchModel(_ pattern: String, in models: [ModelInfo]) -> ModelInfo? {
        if let exact = exactMatch(pattern, in: models) { return exact }
        let lower = pattern.lowercased()
        let matches = models.filter {
            $0.modelId.lowercased().contains(lower) || $0.name.lowercased().contains(lower)
        }
        guard !matches.isEmpty else { return nil }
        let aliases = matches.filter { isAlias($0.modelId) }
        let pool = aliases.isEmpty ? matches : aliases
        return pool.sorted { $0.modelId > $1.modelId }.first
    }

    private static func isAlias(_ id: String) -> Bool {
        if id.hasSuffix("-latest") { return true }
        let range = NSRange(id.startIndex..<id.endIndex, in: id)
        return (try? NSRegularExpression(pattern: "-\\d{8}$"))?.firstMatch(in: id, range: range) == nil
    }

    /// Case-insensitive glob (`*`, `?`, `[...]`, whole-segment `**`) like pi's
    /// `minimatch(value, glob, { nocase: true })` for these constructs.
    /// Verified against pi's minimatch: `*`, `?` and classes never match `/`;
    /// only a literal `/` (or a whole-segment `**`) crosses segments.
    static func globMatch(_ value: String, pattern: String) -> Bool {
        globMatch(Array(value.lowercased()), Array(pattern.lowercased()))
    }

    private static func globMatch(_ value: [Character], _ pattern: [Character]) -> Bool {
        var vi = 0
        var pi = 0
        var star = -1
        var starMatch = 0
        var starCrossesSegments = false
        // Consumes one more value char via the last star, honoring `/`.
        func backtrack(_ vi: inout Int, _ pi: inout Int, _ starMatch: inout Int) -> Bool {
            guard star != -1 else { return false }
            if !starCrossesSegments, starMatch < value.count, value[starMatch] == "/" { return false }
            pi = star + 1
            starMatch += 1
            vi = starMatch
            return true
        }
        while vi < value.count {
            if pi < pattern.count, pattern[pi] == "\\", pi + 1 < pattern.count {
                pi += 1
                if pattern[pi] != value[vi] {
                    guard backtrack(&vi, &pi, &starMatch) else { return false }
                } else {
                    pi += 1
                    vi += 1
                }
            } else if pi < pattern.count, pattern[pi] == "[" {
                guard value[vi] != "/", let (matched, next) = matchClass(value[vi], pattern, from: pi) else {
                    if value[vi] == "/" { return false }
                    return false
                }
                guard matched else {
                    guard backtrack(&vi, &pi, &starMatch) else { return false }
                    continue
                }
                pi = next
                vi += 1
            } else if pi < pattern.count, pattern[pi] == "?" {
                if value[vi] == "/" {
                    guard backtrack(&vi, &pi, &starMatch) else { return false }
                    continue
                }
                pi += 1
                vi += 1
            } else if pi < pattern.count, pattern[pi] == "*" {
                let runStart = pi
                while pi < pattern.count, pattern[pi] == "*" { pi += 1 }
                let crosses = pi - runStart >= 2 && isWholeSegment(pattern, runStart..<pi)
                if pi == pattern.count {
                    if crosses { return true }
                    return !value[vi...].contains("/")
                }
                star = pi - 1
                starMatch = vi
                starCrossesSegments = crosses
            } else if pi < pattern.count, pattern[pi] == value[vi] {
                pi += 1
                vi += 1
            } else {
                guard backtrack(&vi, &pi, &starMatch) else { return false }
            }
        }
        while pi < pattern.count, pattern[pi] == "*" { pi += 1 }
        return pi == pattern.count
    }

    /// Whether a `*` run covers a whole `/`-separated segment (the only case
    /// where minimatch lets `**` cross segments).
    private static func isWholeSegment(_ pattern: [Character], _ range: Range<Int>) -> Bool {
        let beforeOK = range.lowerBound == 0 || pattern[range.lowerBound - 1] == "/"
        let afterOK = range.upperBound == pattern.count || pattern[range.upperBound] == "/"
        return beforeOK && afterOK
    }

    /// Matches one char against a `[...]` class starting at `pattern[from]`.
    /// Returns (matched, indexAfterClosingBracket), or nil if unterminated.
    private static func matchClass(_ char: Character, _ pattern: [Character], from: Int) -> (Bool, Int)? {
        var i = from + 1
        var negated = false
        if i < pattern.count, pattern[i] == "!" || pattern[i] == "^" { negated = true; i += 1 }
        var matched = false
        var first = true
        while i < pattern.count {
            if pattern[i] == "]", !first { return (matched != negated, i + 1) }
            var low = pattern[i]
            if low == "\\", i + 1 < pattern.count { i += 1; low = pattern[i] }
            if i + 2 < pattern.count, pattern[i + 1] == "-", pattern[i + 2] != "]" {
                var high = pattern[i + 2]
                if high == "\\", i + 3 < pattern.count { high = pattern[i + 3]; i += 1 }
                if low <= char, char <= high { matched = true }
                i += 3
            } else {
                if low == char { matched = true }
                i += 1
            }
            first = false
        }
        return nil
    }
}

struct ImageAttachment: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let mimeType: String
    let data: String?

    init(id: String = UUID().uuidString, name: String, mimeType: String, data: String?) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.data = data
    }

    static func == (lhs: ImageAttachment, rhs: ImageAttachment) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var rpcValue: [String: Any]? {
        guard let data else { return nil }
        return ["type": "image", "data": data, "mimeType": mimeType]
    }
}

enum MessageRole: String, Codable, Hashable, Sendable {
    case user
    case assistant
    case system
    case custom
}

enum ToolStatus: String, Codable, Sendable {
    case pending
    case running
    case succeeded
    case failed
}

struct ToolDisplay: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var arguments: String
    var result: String
    var details: String? = nil
    var images: [ImageAttachment] = []
    var status: ToolStatus
    var isError: Bool
    // Set for commands run directly by the user (!, !!, custom actions).
    var userLabel: String? = nil

    var summary: String { displayTitle }

    var displayTitle: String {
        let tool = shortName
        guard let args = jsonObject(arguments) else {
            return arguments.isEmpty ? tool.capitalized : "\(tool.capitalized) \(arguments.oneLine(max: 100))"
        }

        switch tool {
        case "read":
            return "Read \(pathWithRange(args))"
        case "write":
            return "Write \(string(args, "path") ?? "file")"
        case "edit":
            return "Edit \(editTarget(args))"
        case "bash":
            return string(args, "description")?.nonEmptyTrimmed
                ?? string(args, "command")
                ?? "Run shell command"
        case "delegate_agent", "subagent":
            return "Subagent — \(subagentSummary(args))"
        default:
            return "\(tool.capitalized) \(primaryArgument(args))".trimmingCharacters(in: .whitespaces)
        }
    }

    var bashCommand: String? {
        guard shortName == "bash", let args = jsonObject(arguments) else { return nil }
        return string(args, "command")?.nonEmptyTrimmed
    }

    var readableCall: String {
        guard let args = jsonObject(arguments) else { return arguments }
        var lines = ["Tool: \(name)"]
        if !displayTitle.isEmpty { lines.append("Summary: \(displayTitle)") }
        lines.append("")
        lines.append("Arguments:")
        for key in args.keys.sorted() {
            lines.append("  \(key): \(readableValue(args[key]))")
        }
        return lines.joined(separator: "\n")
    }

    func readImagePath(projectPath: String?) -> String? {
        guard shortName == "read",
              let args = jsonObject(arguments),
              let path = string(args, "path") else { return nil }
        let resolved = resolvePath(path, projectPath: projectPath)
        guard isImagePath(resolved), FileManager.default.fileExists(atPath: resolved) else { return nil }
        return resolved
    }

    func editDiff(projectPath: String?) -> EditDiffSummary? {
        guard status == .succeeded,
              shortName == "edit",
              let args = jsonObject(arguments),
              let path = string(args, "path"),
              let edits = args["edits"] as? [[String: Any]],
              !edits.isEmpty else { return nil }

        let absolutePath = resolvePath(path, projectPath: projectPath)
        let currentContent = try? String(contentsOfFile: absolutePath, encoding: .utf8)

        let hunks = edits.enumerated().compactMap { index, edit -> EditDiffHunk? in
            guard let oldText = edit["oldText"] as? String,
                  let newText = edit["newText"] as? String else { return nil }
            let startLine = currentContent.flatMap { findLineNumber(of: newText, in: $0) ?? findLineNumber(of: oldText, in: $0) }
            return EditDiffHunk(index: index, lines: makeDiffLines(oldText: oldText, newText: newText, startLine: startLine))
        }
        guard !hunks.isEmpty else { return nil }
        return EditDiffSummary(path: path, hunks: hunks)
    }

    func writePreview(maxLines: Int = 16) -> CodePreviewSummary? {
        guard shortName == "write",
              let args = jsonObject(arguments),
              let path = string(args, "path") else { return nil }
        let content = string(args, "content") ?? string(args, "text") ?? string(args, "data") ?? ""
        guard !content.isEmpty else { return nil }
        let allLines = splitLines(content)
        let shown = allLines.prefix(maxLines).enumerated().map { index, text in
            CodePreviewLine(number: index + 1, text: text)
        }
        return CodePreviewSummary(title: path, lines: Array(shown), hiddenLineCount: max(0, allLines.count - maxLines), hiddenLinePosition: .bottom)
    }

    func bashOutputPreview(maxLines: Int? = 7) -> CodePreviewSummary? {
        guard shortName == "bash", !result.isEmpty else { return nil }
        let allLines = splitLines(result)
        let start = maxLines.map { max(0, allLines.count - $0) } ?? 0
        let shown = allLines[start...].enumerated().map { index, text in
            CodePreviewLine(number: start + index + 1, text: text)
        }
        return CodePreviewSummary(title: "", lines: Array(shown), hiddenLineCount: start)
    }

    var shortName: String { name.split(separator: ".").last.map(String.init) ?? name }

    var hasExpandableDetails: Bool {
        if !images.isEmpty || status == .failed || isError { return true }
        switch shortName {
        case "read": return false
        case "write", "edit": return true
        case "bash": return !result.isEmpty || details?.isEmpty == false
        default: return !arguments.isEmpty || !result.isEmpty || details?.isEmpty == false
        }
    }

    var argumentsObject: [String: Any]? { jsonObject(arguments) }
    var resultObject: [String: Any]? { jsonObject(result) }

    private func resolvePath(_ path: String, projectPath: String?) -> String {
        let expandedPath = path.hasPrefix("~/") ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(path.dropFirst(2))).path : path
        if expandedPath.hasPrefix("/") { return expandedPath }
        if let projectPath { return URL(fileURLWithPath: projectPath).appendingPathComponent(expandedPath).path }
        return expandedPath
    }

    private func isImagePath(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private func subagentSummary(_ args: [String: Any]) -> String {
        if let chain = args["chain"] as? [[String: Any]], !chain.isEmpty {
            return chainSummary(chain)
        }
        if let tasks = args["tasks"] as? [[String: Any]], !tasks.isEmpty {
            let labels = tasks.map { item in
                if let chain = item["chain"] as? [[String: Any]], !chain.isEmpty {
                    return chainSummary(chain)
                }
                return subagentLabel(item)
            }
            return labels.isEmpty ? "agent" : labels.joined(separator: ", ")
        }
        return subagentLabel(args)
    }

    private func chainSummary(_ chain: [[String: Any]]) -> String {
        let labels = chain.enumerated().map { index, step in
            let label = subagentLabel(step)
            return label == "agent" ? "step-\(index + 1)" : label
        }
        return labels.isEmpty ? "agent" : labels.joined(separator: " → ")
    }

    private func subagentLabel(_ args: [String: Any]) -> String {
        for key in ["description", "title", "agent"] {
            if let value = string(args, key)?.nonEmptyTrimmed { return value.oneLine(max: 100) }
        }
        return "agent"
    }

    private func pathWithRange(_ args: [String: Any]) -> String {
        let path = string(args, "path") ?? "file"
        guard let offset = int(args, "offset") else { return path }
        if let limit = int(args, "limit") { return "\(path):\(offset)-\(offset + max(limit - 1, 0))" }
        return "\(path):\(offset)"
    }

    private func editTarget(_ args: [String: Any]) -> String {
        let path = string(args, "path") ?? "file"
        guard let edits = args["edits"] as? [[String: Any]], edits.count == 1,
              let old = edits.first?["oldText"] as? String else { return path }
        let lineCount = max(old.split(separator: "\n", omittingEmptySubsequences: false).count, 1)
        return lineCount > 1 ? "\(path) (\(lineCount) lines)" : path
    }

    private func primaryArgument(_ args: [String: Any]) -> String {
        for key in ["title", "path", "reference", "ref", "query", "command"] {
            if let value = string(args, key), !value.isEmpty { return value.oneLine(max: 100) }
        }
        return ""
    }

    private func jsonObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func string(_ obj: [String: Any], _ key: String) -> String? { obj[key] as? String }

    private func int(_ obj: [String: Any], _ key: String) -> Int? {
        if let value = obj[key] as? Int { return value }
        if let value = obj[key] as? Double { return Int(value) }
        return nil
    }

    private func findLineNumber(of needle: String, in haystack: String) -> Int? {
        guard !needle.isEmpty, let range = haystack.range(of: needle) else { return nil }
        return haystack[..<range.lowerBound].reduce(1) { count, character in character == "\n" ? count + 1 : count }
    }

    private func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [""] }
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n"), lines.last == "" { lines.removeLast() }
        return lines
    }

    private func makeDiffLines(oldText: String, newText: String, startLine: Int?) -> [EditDiffLine] {
        let oldLines = splitLines(oldText)
        let newLines = splitLines(newText)
        let operations = diffOperations(oldLines: oldLines, newLines: newLines)
        var oldLine = startLine
        var newLine = startLine
        var lines: [EditDiffLine] = []

        for operation in operations {
            switch operation {
            case .equal(let text):
                lines.append(EditDiffLine(kind: .context, oldNumber: oldLine, newNumber: newLine, text: text))
                oldLine = oldLine.map { $0 + 1 }
                newLine = newLine.map { $0 + 1 }
            case .delete(let text):
                lines.append(EditDiffLine(kind: .delete, oldNumber: oldLine, newNumber: nil, text: text))
                oldLine = oldLine.map { $0 + 1 }
            case .insert(let text):
                lines.append(EditDiffLine(kind: .insert, oldNumber: nil, newNumber: newLine, text: text))
                newLine = newLine.map { $0 + 1 }
            }
        }
        return compactDiffLines(lines)
    }

    private enum DiffOperation {
        case equal(String)
        case delete(String)
        case insert(String)
    }

    private func diffOperations(oldLines: [String], newLines: [String]) -> [DiffOperation] {
        let oldCount = oldLines.count
        let newCount = newLines.count
        if oldCount * newCount > 40_000 { return prefixSuffixDiff(oldLines: oldLines, newLines: newLines) }
        var table = Array(repeating: Array(repeating: 0, count: newCount + 1), count: oldCount + 1)
        if oldCount > 0 && newCount > 0 {
            for i in stride(from: oldCount - 1, through: 0, by: -1) {
                for j in stride(from: newCount - 1, through: 0, by: -1) {
                    if oldLines[i] == newLines[j] {
                        table[i][j] = table[i + 1][j + 1] + 1
                    } else {
                        table[i][j] = max(table[i + 1][j], table[i][j + 1])
                    }
                }
            }
        }

        var i = 0
        var j = 0
        var operations: [DiffOperation] = []
        while i < oldCount || j < newCount {
            if i < oldCount, j < newCount, oldLines[i] == newLines[j] {
                operations.append(.equal(oldLines[i]))
                i += 1
                j += 1
            } else if j < newCount, (i == oldCount || table[i][j + 1] >= table[i + 1][j]) {
                operations.append(.insert(newLines[j]))
                j += 1
            } else if i < oldCount {
                operations.append(.delete(oldLines[i]))
                i += 1
            }
        }
        return operations
    }

    private func prefixSuffixDiff(oldLines: [String], newLines: [String]) -> [DiffOperation] {
        var prefix = 0
        while prefix < oldLines.count, prefix < newLines.count, oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }

        var oldSuffix = oldLines.count - 1
        var newSuffix = newLines.count - 1
        var suffix: [(String, String)] = []
        while oldSuffix >= prefix, newSuffix >= prefix, oldLines[oldSuffix] == newLines[newSuffix] {
            suffix.append((oldLines[oldSuffix], newLines[newSuffix]))
            oldSuffix -= 1
            newSuffix -= 1
        }

        var operations: [DiffOperation] = []
        operations.append(contentsOf: oldLines.prefix(prefix).map(DiffOperation.equal))
        if prefix <= oldSuffix { operations.append(contentsOf: oldLines[prefix...oldSuffix].map(DiffOperation.delete)) }
        if prefix <= newSuffix { operations.append(contentsOf: newLines[prefix...newSuffix].map(DiffOperation.insert)) }
        operations.append(contentsOf: suffix.reversed().map { DiffOperation.equal($0.0) })
        return operations
    }

    private func compactDiffLines(_ lines: [EditDiffLine]) -> [EditDiffLine] {
        let changed = lines.indices.filter { lines[$0].kind == .delete || lines[$0].kind == .insert }
        guard let firstChange = changed.first, let lastChange = changed.last, lines.count > 18 else { return lines }
        let start = max(0, firstChange - 3)
        let end = min(lines.count - 1, lastChange + 3)
        var compact: [EditDiffLine] = []
        if start > 0 { compact.append(EditDiffLine(kind: .ellipsis, oldNumber: nil, newNumber: nil, text: "...")) }
        compact.append(contentsOf: lines[start...end])
        if end < lines.count - 1 { compact.append(EditDiffLine(kind: .ellipsis, oldNumber: nil, newNumber: nil, text: "...")) }
        return compact
    }

    private func readableValue(_ value: Any?) -> String {
        switch value {
        case let value as String: return value
        case let value as [Any]: return "[\(value.count) item\(value.count == 1 ? "" : "s")]"
        case let value as [String: Any]: return "{\(value.keys.sorted().joined(separator: ", "))}"
        case nil: return "null"
        default: return String(describing: value!)
        }
    }
}

struct CodePreviewSummary: Hashable {
    var title: String
    var lines: [CodePreviewLine]
    var hiddenLineCount: Int
    var hiddenLinePosition: CodePreviewHiddenLinePosition = .top
}

enum CodePreviewHiddenLinePosition: Hashable {
    case top
    case bottom
}

struct CodePreviewLine: Identifiable, Hashable {
    var id = UUID()
    var number: Int?
    var text: String
}

struct EditDiffSummary: Hashable {
    var path: String
    var hunks: [EditDiffHunk]
}

struct EditDiffHunk: Identifiable, Hashable {
    var index: Int
    var lines: [EditDiffLine]
    var id: Int { index }
}

struct EditDiffLine: Identifiable, Hashable {
    enum Kind: Hashable {
        case context
        case delete
        case insert
        case ellipsis
    }

    var id = UUID()
    var kind: Kind
    var oldNumber: Int?
    var newNumber: Int?
    var text: String
}

enum SessionTreeEntryKind: String, Hashable, Sendable {
    case user
    case assistant
    case tool
    case message
    case model
    case thinking
    case compaction
    case branchSummary
    case label
    case custom
    case sessionInfo
    case unknown
}

struct SessionTreeNode: Identifiable, Hashable, Sendable {
    var id: String
    var parentID: String?
    var kind: SessionTreeEntryKind
    var preview: String
    var label: String?
    var children: [SessionTreeNode]
    var isForkable: Bool
    var hasDisplayableText: Bool

    var flattened: [SessionTreeNode] {
        [self] + children.flatMap(\.flattened)
    }
}

struct SessionTreeSnapshot: Hashable, Sendable {
    var roots: [SessionTreeNode]
    var leafID: String?
    var activePathIDs: Set<String>

    var nodes: [SessionTreeNode] { roots.flatMap(\.flattened) }

    var activePath: [SessionTreeNode] {
        // If IDs repeat, the last node in flattened root order wins.
        var byID: [String: SessionTreeNode] = [:]
        for node in nodes { byID[node.id] = node }
        var path: [SessionTreeNode] = []
        var cursor = leafID
        var seen: Set<String> = []
        while let id = cursor, let node = byID[id], seen.insert(id).inserted {
            path.append(node)
            cursor = node.parentID
        }
        return path.reversed()
    }
}

enum SessionTreeLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

struct ComposerPrefillRequest: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var images: [ImageAttachment] = []
    var appendsToDraft = false
    var insertsAtEnd = false
}

struct MessageScrollRequest: Identifiable, Equatable {
    let id = UUID()
    let messageID: String
}

struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var role: MessageRole
    var text: String
    /// Composer token markers preserved in their original positions for inline history rendering.
    var canonicalText: String?
    var thinking: String
    var tools: [ToolDisplay]
    var references: [MessageReference]
    var images: [ImageAttachment]
    var timestamp: Date?
    /// Provider completion reason for assistant messages (for example `toolUse` or `stop`).
    var stopReason: String?
    var isStreaming: Bool

    init(id: String = UUID().uuidString,
         role: MessageRole,
         text: String = "",
         canonicalText: String? = nil,
         thinking: String = "",
         tools: [ToolDisplay] = [],
         references: [MessageReference] = [],
         images: [ImageAttachment] = [],
         timestamp: Date? = nil,
         stopReason: String? = nil,
         isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.canonicalText = canonicalText
        self.thinking = thinking
        self.tools = tools
        self.references = references
        self.images = images
        self.timestamp = timestamp
        self.stopReason = stopReason
        self.isStreaming = isStreaming
    }
}

struct FileNode: Identifiable, Hashable {
    let id: String
    let url: URL
    let isDirectory: Bool
    var children: [FileNode]?

    init(url: URL, isDirectory: Bool, children: [FileNode]? = nil) {
        self.url = url
        self.id = url.path
        self.isDirectory = isDirectory
        self.children = children
    }
}

extension String {
    func oneLine(max: Int) -> String {
        let squashed = replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
        if squashed.count <= max { return squashed }
        return String(squashed.prefix(max - 1)) + "…"
    }

    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Date {
    var sidebarLabel: String {
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(self) {
            formatter.dateFormat = "h:mm a"
        } else if Calendar.current.isDate(self, equalTo: Date(), toGranularity: .year) {
            formatter.dateFormat = "MMM d"
        } else {
            formatter.dateFormat = "MMM d, yyyy"
        }
        return formatter.string(from: self)
    }
}

func jsonString(_ value: Any) -> String {
    if let string = value as? String { return string }
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return String(describing: value) }
    return text
}
