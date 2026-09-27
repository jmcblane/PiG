import Foundation

struct ComposerTextCompletion {
    var replacementRange: NSRange
    var replacement: String
    var cursorLocation: Int?

    init(replacementRange: NSRange, replacement: String, cursorLocation: Int? = nil) {
        self.replacementRange = replacementRange
        self.replacement = replacement
        self.cursorLocation = cursorLocation
    }
}

struct ComposerTabCompletionResult {
    var completion: ComposerTextCompletion?
    var shouldConsume: Bool

    static let passThrough = ComposerTabCompletionResult(completion: nil, shouldConsume: false)
    static let block = ComposerTabCompletionResult(completion: nil, shouldConsume: true)
}

enum ComposerKeyCommand {
    case moveUp
    case moveDown
    case accept
    case dismiss
}

struct ComposerSkillSuggestion: Identifiable, Hashable {
    var command: SlashCommandInfo
    var replacementRange: NSRange

    var id: String { command.id }
}

struct ComposerFileSuggestion: Identifiable, Hashable {
    var relativePath: String
    var isDirectory: Bool
    var replacementRange: NSRange
    var replacementText: String

    var id: String { "\(relativePath):\(isDirectory)" }
    var displayName: String { URL(fileURLWithPath: relativePath).lastPathComponent + (isDirectory ? "/" : "") }
    var displayPath: String { relativePath + (isDirectory && !relativePath.hasSuffix("/") ? "/" : "") }
    var kind: String { isDirectory ? "DIR" : "FILE" }
}

enum ComposerCompletion {
    static func completion(
        for text: String,
        selectedRange: NSRange,
        slashCommands: [SlashCommandInfo]
    ) -> ComposerTabCompletionResult {
        slashCompletion(for: text, selectedRange: selectedRange, commands: slashCommands) ?? .passThrough
    }

    static func skillSuggestions(for canonicalText: String, commands: [SlashCommandInfo], limit: Int = 9) -> [ComposerSkillSuggestion] {
        let text = ComposerTokenCodec.editingString(from: canonicalText)
        let range = NSRange(location: (text as NSString).length, length: 0)
        guard let context = skillContext(for: text, selectedRange: range) else { return [] }
        let token = context.typed.lowercased()
        let skills = uniqueCommands(commands.filter { $0.source == "skill" })
        var matches = skills.filter {
            let name = ComposerTokenCodec.skillDisplayName($0).lowercased()
            return token.isEmpty || name.hasPrefix(token)
        }
        if matches.isEmpty {
            matches = skills.filter { ComposerTokenCodec.skillDisplayName($0).localizedCaseInsensitiveContains(token) }
        }
        return matches.prefix(limit).map { ComposerSkillSuggestion(command: $0, replacementRange: context.fullRange) }
    }

    static func replacingSkillSuggestion(_ suggestion: ComposerSkillSuggestion, in canonicalText: String) -> String {
        let command = suggestion.command
        let token = ComposerToken(
            kind: .skill,
            value: command.name,
            label: ComposerTokenCodec.skillDisplayName(command),
            detail: command.description.nonEmptyTrimmed,
            resourcePath: command.path
        )
        return ComposerTokenCodec.replacingEditingRange(
            suggestion.replacementRange,
            in: canonicalText,
            with: ComposerTokenCodec.marker(for: token)
        )
    }

    static func fileSuggestions(for text: String, selectedRange: NSRange, projectPath: String, limit: Int = 9) -> [ComposerFileSuggestion] {
        guard let context = fileContext(for: text, selectedRange: selectedRange) else { return [] }
        return fileMatches(for: context.typed, projectPath: projectPath)
            .prefix(limit)
            .map { suggestion(for: $0, replacementRange: context.fullRange, text: text) }
    }

    /// Cheap check for an `@` file token at the end of the draft, used to
    /// skip the background scan entirely when there is nothing to complete.
    static func hasFileToken(in canonicalText: String) -> Bool {
        let text = ComposerTokenCodec.editingString(from: canonicalText)
        let range = NSRange(location: (text as NSString).length, length: 0)
        return fileContext(for: text, selectedRange: range) != nil
    }

    /// Directory scans can touch tens of thousands of entries; run them off
    /// the main thread. The cursor is assumed to sit at the end of the draft,
    /// matching the composer's suggestion popup semantics.
    static func fileSuggestionsAsync(for canonicalText: String, projectPath: String, limit: Int = 9) async -> [ComposerFileSuggestion] {
        let worker = Task.detached(priority: .userInitiated) {
            let text = ComposerTokenCodec.editingString(from: canonicalText)
            let range = NSRange(location: (text as NSString).length, length: 0)
            return fileSuggestions(for: text, selectedRange: range, projectPath: projectPath, limit: limit)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func replacingFileSuggestion(_ suggestion: ComposerFileSuggestion, in canonicalText: String) -> String {
        if suggestion.isDirectory {
            return ComposerTokenCodec.replacingEditingRange(
                suggestion.replacementRange,
                in: canonicalText,
                with: "@" + suggestion.displayPath
            )
        }
        let token = ComposerToken(
            kind: .file,
            value: suggestion.relativePath,
            label: URL(fileURLWithPath: suggestion.relativePath).lastPathComponent,
            detail: suggestion.displayPath,
            resourcePath: nil
        )
        return ComposerTokenCodec.replacingEditingRange(
            suggestion.replacementRange,
            in: canonicalText,
            with: ComposerTokenCodec.marker(for: token)
        )
    }

    private struct TokenContext {
        var typed: String
        var fullRange: NSRange
        var tokenEnd: Int
    }

    private static func slashCompletion(for text: String, selectedRange: NSRange, commands: [SlashCommandInfo]) -> ComposerTabCompletionResult? {
        guard let context = slashContext(for: text, selectedRange: selectedRange) else { return nil }
        let matches = GUIBuiltinSlashCommands.suggestions(for: context.typed, in: uniqueCommands(commands))
        guard let match = matches.first else { return .passThrough }
        guard !context.typed.isEmpty || matches.count == 1 else { return .block }

        let ns = text as NSString
        let hasSeparatorAfter = context.tokenEnd < ns.length && isWhitespace(ns.character(at: context.tokenEnd))
        let replacement = "/\(match.name)\(hasSeparatorAfter ? "" : " ")"
        guard ns.substring(with: context.fullRange) != replacement else { return .block }
        return ComposerTabCompletionResult(
            completion: ComposerTextCompletion(replacementRange: context.fullRange, replacement: replacement),
            shouldConsume: true
        )
    }

    private static func slashContext(for text: String, selectedRange: NSRange) -> TokenContext? {
        let ns = text as NSString
        guard selectedRange.location >= 0, selectedRange.location <= ns.length else { return nil }
        let cursor = selectedRange.location
        let beforeCursor = ns.substring(to: cursor)
        guard !beforeCursor.contains("\n") else { return nil }

        var slashStart = 0
        while slashStart < cursor, isWhitespace(ns.character(at: slashStart)) { slashStart += 1 }
        guard slashStart < ns.length, ns.character(at: slashStart) == 47 else { return nil } // /
        guard slashStart + 1 >= ns.length || ns.character(at: slashStart + 1) != 47 else { return nil }

        var tokenEnd = max(cursor, NSMaxRange(selectedRange))
        while tokenEnd < ns.length, !isWhitespace(ns.character(at: tokenEnd)) { tokenEnd += 1 }
        let tokenRange = NSRange(location: slashStart + 1, length: max(0, cursor - slashStart - 1))
        let token = ns.substring(with: tokenRange)
        guard !token.contains("/"), !token.contains(where: { $0.isWhitespace }) else { return nil }
        return TokenContext(typed: token, fullRange: NSRange(location: slashStart, length: tokenEnd - slashStart), tokenEnd: tokenEnd)
    }

    private static func skillContext(for text: String, selectedRange: NSRange) -> TokenContext? {
        referenceContext(for: text, selectedRange: selectedRange, marker: 36) // $
    }

    private static func fileContext(for text: String, selectedRange: NSRange) -> TokenContext? {
        referenceContext(for: text, selectedRange: selectedRange, marker: 64) // @
    }

    private static func referenceContext(for text: String, selectedRange: NSRange, marker: unichar) -> TokenContext? {
        let ns = text as NSString
        guard selectedRange.location >= 0, selectedRange.location <= ns.length else { return nil }
        let cursor = selectedRange.location

        var tokenStart = cursor
        while tokenStart > 0, !isWhitespace(ns.character(at: tokenStart - 1)) { tokenStart -= 1 }
        guard tokenStart < ns.length, ns.character(at: tokenStart) == marker else { return nil }
        if tokenStart > 0, ns.character(at: tokenStart - 1) == 92 { return nil } // escaped
        let beforeToken = ns.substring(to: tokenStart)
        if beforeToken.filter({ $0 == "`" }).count.isMultiple(of: 2) == false { return nil }

        var tokenEnd = max(cursor, NSMaxRange(selectedRange))
        while tokenEnd < ns.length, !isWhitespace(ns.character(at: tokenEnd)) { tokenEnd += 1 }

        let typedRange = NSRange(location: tokenStart + 1, length: max(0, cursor - tokenStart - 1))
        let typed = ns.substring(with: typedRange)
        return TokenContext(typed: typed, fullRange: NSRange(location: tokenStart, length: tokenEnd - tokenStart), tokenEnd: tokenEnd)
    }

    private struct FileCandidate {
        var relativePath: String
        var isDirectory: Bool
        var insertionPath: String { isDirectory && !relativePath.hasSuffix("/") ? relativePath + "/" : relativePath }
    }

    private static func suggestion(for candidate: FileCandidate, replacementRange: NSRange, text: String) -> ComposerFileSuggestion {
        let ns = text as NSString
        let hasSeparatorAfter = NSMaxRange(replacementRange) < ns.length && isWhitespace(ns.character(at: NSMaxRange(replacementRange)))
        let replacement = "@\(candidate.insertionPath)\(!candidate.isDirectory && !hasSeparatorAfter ? " " : "")"
        return ComposerFileSuggestion(
            relativePath: candidate.relativePath,
            isDirectory: candidate.isDirectory,
            replacementRange: replacementRange,
            replacementText: replacement
        )
    }

    private static func fileMatches(for token: String, projectPath: String) -> [FileCandidate] {
        let root = URL(fileURLWithPath: projectPath, isDirectory: true).standardizedFileURL
        let normalized = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

        if normalized.isEmpty || normalized.contains("/") {
            return pathComponentMatches(for: normalized, root: root)
        }
        return recursiveFilenameMatches(for: normalized, root: root)
    }

    private static func pathComponentMatches(for token: String, root: URL) -> [FileCandidate] {
        let directory: String
        let prefix: String
        if token.hasSuffix("/") {
            directory = String(token.dropLast())
            prefix = ""
        } else if let slash = token.lastIndex(of: "/") {
            directory = String(token[..<slash])
            prefix = String(token[token.index(after: slash)...])
        } else {
            directory = ""
            prefix = token
        }
        let directoryURL = directory.isEmpty ? root : root.appendingPathComponent(directory, isDirectory: true)

        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let lowerPrefix = prefix.lowercased()
        var prefixMatches: [FileCandidate] = []
        var containsMatches: [FileCandidate] = []
        for (index, url) in urls.enumerated() {
            if index.isMultiple(of: 128), Task.isCancelled { return [] }
            let name = url.lastPathComponent
            guard !name.hasPrefix(".") else { continue }
            let lowerName = name.lowercased()
            guard lowerPrefix.isEmpty || lowerName.hasPrefix(lowerPrefix) || lowerName.contains(lowerPrefix) else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            let relative = directory.isEmpty ? name : directory + "/" + name
            let candidate = FileCandidate(relativePath: relative, isDirectory: values?.isDirectory == true)
            if lowerPrefix.isEmpty || lowerName.hasPrefix(lowerPrefix) {
                prefixMatches.append(candidate)
            } else {
                containsMatches.append(candidate)
            }
        }
        let primary = prefixMatches.isEmpty ? containsMatches : prefixMatches
        return sorted(primary, preferDirectories: true, prefix: prefix)
    }

    private static func recursiveFilenameMatches(for token: String, root: URL) -> [FileCandidate] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let rootPath = root.path
        let lowerToken = token.lowercased()
        let skippedDirectories: Set<String> = [".git", ".build", ".swiftpm", "node_modules", "DerivedData"]
        var prefixMatches: [FileCandidate] = []
        var containsMatches: [FileCandidate] = []
        var seen = 0
        let maxVisited = 30000
        let maxMatches = 200

        for case let url as URL in enumerator {
            seen += 1
            if seen.isMultiple(of: 128), Task.isCancelled { break }
            if seen > maxVisited { break }

            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            let isDirectory = values?.isDirectory == true
            if isDirectory, skippedDirectories.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            guard !name.hasPrefix(".") else {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }

            let lowerName = name.lowercased()
            guard lowerName.hasPrefix(lowerToken) || lowerName.contains(lowerToken) else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relative = String(path.dropFirst(rootPath.count + 1))
            let candidate = FileCandidate(relativePath: relative, isDirectory: isDirectory)
            if lowerName.hasPrefix(lowerToken) {
                prefixMatches.append(candidate)
            } else {
                containsMatches.append(candidate)
            }
            if prefixMatches.count + containsMatches.count >= maxMatches { break }
        }

        let primary = prefixMatches.isEmpty ? containsMatches : prefixMatches
        return sorted(primary, preferDirectories: false, prefix: token)
    }

    private static func sorted(_ candidates: [FileCandidate], preferDirectories: Bool, prefix: String) -> [FileCandidate] {
        candidates.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return preferDirectories ? lhs.isDirectory : !lhs.isDirectory
            }
            let leftName = URL(fileURLWithPath: lhs.relativePath).lastPathComponent
            let rightName = URL(fileURLWithPath: rhs.relativePath).lastPathComponent
            let leftPrefix = leftName.lowercased().hasPrefix(prefix.lowercased())
            let rightPrefix = rightName.lowercased().hasPrefix(prefix.lowercased())
            if leftPrefix != rightPrefix { return leftPrefix }
            let nameCompare = leftName.localizedStandardCompare(rightName)
            if nameCompare != .orderedSame { return nameCompare == .orderedAscending }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }

    private static func uniqueCommands(_ commands: [SlashCommandInfo]) -> [SlashCommandInfo] {
        var seen = Set<String>()
        var result: [SlashCommandInfo] = []
        for command in commands {
            let key = command.name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(command)
        }
        return result
    }

    private static func isWhitespace(_ value: unichar) -> Bool {
        guard let scalar = UnicodeScalar(Int(value)) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}
