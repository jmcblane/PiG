import Foundation

struct SlashCommandInfo: Identifiable, Hashable {
    var name: String
    var description: String
    var source: String
    var location: String?
    var path: String?
    var argumentHint: String?

    var id: String { "\(source):\(name):\(path ?? "")" }

    var displaySource: String {
        switch source {
        case "builtin": return "GUI"
        case "prompt": return location.map { "PROMPT · \($0.uppercased())" } ?? "PROMPT"
        case "skill": return location.map { "SKILL · \($0.uppercased())" } ?? "SKILL"
        case "extension": return "EXT"
        default: return source.uppercased()
        }
    }

    var insertionText: String { "/\(name) " }

    static func fromRPC(_ dict: [String: Any]) -> SlashCommandInfo? {
        guard let name = dict["name"] as? String else { return nil }
        let sourceInfo = dict["sourceInfo"] as? [String: Any]
        return SlashCommandInfo(
            name: name,
            description: dict["description"] as? String ?? "",
            source: dict["source"] as? String ?? "command",
            location: dict["location"] as? String ?? sourceInfo?["scope"] as? String,
            path: dict["path"] as? String ?? sourceInfo?["path"] as? String,
            argumentHint: dict["argument-hint"] as? String ?? dict["argumentHint"] as? String
        )
    }
}

enum GUIBuiltinSlashCommands {
    private static let suggestionOnlyExcludedNames: Set<String> = [
        "login", "logout", "share", "scoped-models", "resume", "trust"
    ]

    // Keep command execution and /help independent of suggestion visibility.
    static func suggestions(for token: String, in commands: [SlashCommandInfo], limit: Int = 9) -> [SlashCommandInfo] {
        let needle = token.lowercased()
        var tiers = [[SlashCommandInfo]](repeating: [], count: 4)
        for command in commands {
            guard command.source != "builtin" || !suggestionOnlyExcludedNames.contains(command.name.lowercased()) else { continue }
            let name = command.name.lowercased()
            if needle.isEmpty {
                tiers[1].append(command)
            } else if name == needle {
                tiers[0].append(command)
            } else if name.hasPrefix(needle) {
                tiers[1].append(command)
            } else if name.contains(needle) {
                var searchStart = name.startIndex
                var atBoundary = false
                while searchStart < name.endIndex,
                      let range = name.range(of: needle, range: searchStart..<name.endIndex) {
                    if range.lowerBound > name.startIndex,
                       "-_:.".contains(name[name.index(before: range.lowerBound)]) {
                        atBoundary = true
                        break
                    }
                    searchStart = name.index(after: range.lowerBound)
                }
                tiers[atBoundary ? 2 : 3].append(command)
            }
        }
        return Array(tiers.flatMap { $0 }.prefix(limit))
    }

    static let commands: [SlashCommandInfo] = [
        command("help", "Show slash commands"),
        command("commands", "Refresh and show extension, prompt, and skill commands"),
        command("abort", "Abort agent, bash, and retry work"),
        command("model", "Show or switch model: /model <name>"),
        command("cycle-model", "Cycle to the next scoped/available model"),
        command("thinking", "Show or set thinking: /thinking <level>"),
        command("cycle-thinking", "Cycle thinking level"),
        command("settings", "Show GUI settings locations"),
        command("update", "Check or update Pi: /update [--extensions|--models|--all]"),
        command("changelog", "Show Pi version history"),
        command("export", "Export session HTML: /export [path]"),
        command("copy", "Copy last assistant message"),
        command("name", "Set session display name: /name <name>"),
        command("session", "Show session stats"),
        command("new", "Start a fresh session in this tab"),
        command("compact", "Compact context: /compact [instructions]"),
        command("auto-compact", "Enable/disable auto compaction: on|off"),
        command("auto-retry", "Enable/disable auto retry: on|off"),
        command("steering-mode", "Set steering mode: all|one-at-a-time"),
        command("follow-up-mode", "Set follow-up mode: all|one-at-a-time"),
        command("steer", "Queue steering message while agent runs"),
        command("follow-up", "Queue follow-up message"),
        command("bash", "Run bash and include output in context"),
        command("hidden-bash", "Run bash without adding output to context"),
        command("fork", "List or fork from a user message: /fork [n|entryId]"),
        command("clone", "Clone active branch into a new session"),
        command("reload", "Restart RPC and reload prompts/skills/extensions"),
        command("unload", "Unload this session's RPC runtime"),
        command("unload-others", "Unload other idle session runtimes"),
        command("unload-all-idle", "Unload every idle session runtime"),
        command("refresh", "Refresh state, models, stats, and commands"),
        command("clear-error", "Clear the visible error"),
        command("hotkeys", "Show GUI keyboard shortcuts"),
        command("resume", "Use the sidebar session list"),
        command("tree", "Show the in-session tree and fork points"),
        command("scoped-models", "Use model picker; scoped model UI is TUI-only"),
        command("trust", "PiG automatically trusts explicitly added or created projects; discovered projects are not bulk-trusted."),
        command("login", "Authentication is TUI/CLI-only"),
        command("logout", "Authentication is TUI/CLI-only"),
        command("share", "Sharing via gist is TUI-only"),
        command("quit", "Quit PiG")
    ]

    static func command(_ name: String, _ description: String) -> SlashCommandInfo {
        SlashCommandInfo(name: name, description: description, source: "builtin", location: nil, path: nil, argumentHint: nil)
    }

    static func named(_ name: String) -> SlashCommandInfo? {
        commands.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

enum SlashCommandParsing {
    static func split(_ text: String) -> (name: String, arguments: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), !trimmed.hasPrefix("//") else { return nil }
        let body = String(trimmed.dropFirst())
        guard !body.isEmpty else { return nil }
        if let space = body.firstIndex(where: { $0.isWhitespace }) {
            let name = String(body[..<space])
            let args = String(body[space...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (name, args)
        }
        return (body, "")
    }
}
