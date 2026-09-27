import Foundation

struct ComposerToken: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case skill
        case file
    }

    var kind: Kind
    /// Skill command name (for example `skill:pdf-tools`) or project-relative file path.
    var value: String
    var label: String
    var detail: String?
    var resourcePath: String? = nil

    var plainText: String {
        switch kind {
        case .skill: return "$\(skillName)"
        case .file: return "@\(value)"
        }
    }

    var skillName: String {
        value.hasPrefix("skill:") ? String(value.dropFirst("skill:".count)) : value
    }
}

struct MessageReference: Codable, Hashable, Sendable, Identifiable {
    var kind: ComposerToken.Kind
    var value: String
    var label: String
    var detail: String?
    var resourcePath: String?
    var isAvailable: Bool

    var id: String { "\(kind.rawValue):\(value)" }
    var plainText: String { ComposerToken(kind: kind, value: value, label: label, detail: detail, resourcePath: resourcePath).plainText }
}

enum ComposerTokenSegment {
    case text(String)
    case token(ComposerToken)
}

enum ComposerTokenCodec {
    private static let start = "\u{E000}pig-token:"
    private static let end = "\u{E001}"

    static func marker(for token: ComposerToken) -> String {
        guard let data = try? JSONEncoder().encode(token) else { return token.plainText }
        return start + data.base64EncodedString() + end
    }

    static func segments(in text: String) -> [ComposerTokenSegment] {
        components(in: text).map { component in
            switch component {
            case .text(let value): return .text(value)
            case .token(let token): return .token(token)
            }
        }
    }

    static func tokens(in text: String) -> [ComposerToken] {
        components(in: text).compactMap { component in
            if case .token(let token) = component { return token }
            return nil
        }
    }

    static func editingString(from text: String) -> String {
        components(in: text).map { component in
            switch component {
            case .text(let value): return value
            case .token: return "\u{FFFC}"
            }
        }.joined()
    }

    static func plainText(from text: String) -> String {
        let parts = components(in: text)
        var result = ""
        for (index, component) in parts.enumerated() {
            switch component {
            case .text(let value):
                result += value
            case .token(let token):
                result += token.plainText
                guard index + 1 < parts.count else { continue }
                switch parts[index + 1] {
                case .token:
                    result += " "
                case .text(let following):
                    if let first = following.first,
                       !first.isWhitespace,
                       !",.;:!?)]}".contains(first) {
                        result += " "
                    }
                }
            }
        }
        return result
    }

    static func messageText(from text: String) -> String {
        let result = plainText(from: text)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func replacingEditingRange(_ range: NSRange, in canonical: String, with replacement: String) -> String {
        let components = components(in: canonical)
        var editingOffset = 0
        var canonicalOffset = 0
        var canonicalStart: Int?
        var canonicalEnd: Int?

        for component in components {
            let canonicalLength = component.canonicalLength
            let editingLength = component.editingLength
            if canonicalStart == nil, range.location <= editingOffset + editingLength {
                canonicalStart = canonicalOffset + min(max(0, range.location - editingOffset), canonicalLength)
            }
            if range.location + range.length <= editingOffset + editingLength {
                canonicalEnd = canonicalOffset + min(max(0, range.location + range.length - editingOffset), canonicalLength)
                break
            }
            editingOffset += editingLength
            canonicalOffset += canonicalLength
        }
        let ns = canonical as NSString
        let startOffset = canonicalStart ?? ns.length
        let endOffset = canonicalEnd ?? ns.length
        return ns.replacingCharacters(in: NSRange(location: startOffset, length: max(0, endOffset - startOffset)), with: replacement)
    }

    static func normalizeExactReferences(
        in text: String,
        skills: [SlashCommandInfo],
        projectPath: String
    ) -> String {
        var result = text
        let skillByName = Dictionary(uniqueKeysWithValues: skills.filter { $0.source == "skill" }.map { command in
            (skillDisplayName(command).lowercased(), command)
        })

        result = replaceRawReferences(in: result, prefix: "$", resolver: { raw in
            guard let command = skillByName[raw.lowercased()] else { return nil }
            return ComposerToken(
                kind: .skill,
                value: command.name,
                label: skillDisplayName(command),
                detail: command.description.nonEmptyTrimmed,
                resourcePath: command.path
            )
        })

        let root = URL(fileURLWithPath: projectPath, isDirectory: true).standardizedFileURL
        result = replaceRawReferences(in: result, prefix: "@", preferLongest: true) { raw in
            let clean = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !clean.isEmpty, !clean.hasPrefix("/") else { return nil }
            let url = root.appendingPathComponent(clean).standardizedFileURL
            guard url.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: url.path) else { return nil }
            return ComposerToken(kind: .file, value: clean, label: url.lastPathComponent, detail: clean, resourcePath: nil)
        }
        return result
    }

    static func skillDisplayName(_ command: SlashCommandInfo) -> String {
        command.name.hasPrefix("skill:") ? String(command.name.dropFirst("skill:".count)) : command.name
    }

    private enum Component {
        case text(String)
        case token(ComposerToken)

        var canonicalLength: Int {
            switch self {
            case .text(let value): return (value as NSString).length
            case .token(let token): return (ComposerTokenCodec.marker(for: token) as NSString).length
            }
        }

        var editingLength: Int {
            switch self {
            case .text(let value): return (value as NSString).length
            case .token: return 1
            }
        }
    }

    private static func components(in text: String) -> [Component] {
        var result: [Component] = []
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let startRange = text.range(of: start, range: cursor..<text.endIndex) {
            if startRange.lowerBound > cursor { result.append(.text(String(text[cursor..<startRange.lowerBound]))) }
            guard let endRange = text.range(of: end, range: startRange.upperBound..<text.endIndex) else {
                result.append(.text(String(text[startRange.lowerBound...])))
                return result
            }
            let encoded = String(text[startRange.upperBound..<endRange.lowerBound])
            if let data = Data(base64Encoded: encoded), let token = try? JSONDecoder().decode(ComposerToken.self, from: data) {
                result.append(.token(token))
            } else {
                result.append(.text(String(text[startRange.lowerBound..<endRange.upperBound])))
            }
            cursor = endRange.upperBound
        }
        if cursor < text.endIndex { result.append(.text(String(text[cursor...]))) }
        return result
    }

    private static func replaceRawReferences(
        in text: String,
        prefix: Character,
        preferLongest: Bool = false,
        resolver: (String) -> ComposerToken?
    ) -> String {
        // Work on plain segments only so existing tokens, escaped references, and code stay untouched.
        var output = ""
        for component in components(in: text) {
            guard case .text(let segment) = component else {
                if case .token(let token) = component { output += marker(for: token) }
                continue
            }
            output += replaceRawReferences(inPlainText: segment, prefix: prefix, preferLongest: preferLongest, resolver: resolver)
        }
        return output
    }

    private static func replaceRawReferences(
        inPlainText text: String,
        prefix: Character,
        preferLongest: Bool,
        resolver: (String) -> ComposerToken?
    ) -> String {
        let ns = text as NSString
        var replacements: [(NSRange, String)] = []
        var inCode = false
        var index = 0
        while index < ns.length {
            let value = ns.character(at: index)
            if value == 96 { inCode.toggle(); index += 1; continue } // `
            guard !inCode, value == prefix.asciiValue.map(unichar.init) else { index += 1; continue }
            if index > 0, ns.character(at: index - 1) == 92 { index += 1; continue } // escaped
            if index > 0, !isBoundary(ns.character(at: index - 1)) { index += 1; continue }

            var ends: [Int] = []
            var cursor = index + 1
            while cursor <= ns.length {
                if cursor < ns.length, isBoundary(ns.character(at: cursor)) { ends.append(cursor) }
                if cursor == ns.length || ns.character(at: cursor) == 10 { break }
                cursor += 1
            }
            let candidates = preferLongest ? ends.reversed() : ends
            var matched: (Int, ComposerToken)?
            for end in candidates {
                guard end > index + 1 else { continue }
                let raw = ns.substring(with: NSRange(location: index + 1, length: end - index - 1))
                if let token = resolver(raw) { matched = (end, token); break }
            }
            if let (end, token) = matched {
                replacements.append((NSRange(location: index, length: end - index), marker(for: token)))
                index = end
            } else {
                index += 1
            }
        }
        var result = text
        for (range, replacement) in replacements.reversed() {
            result = (result as NSString).replacingCharacters(in: range, with: replacement)
        }
        return result
    }

    private static func isBoundary(_ value: unichar) -> Bool {
        guard let scalar = UnicodeScalar(Int(value)) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}

private extension Character {
    var asciiValue: UInt8? { String(self).utf8.count == 1 ? String(self).utf8.first : nil }
}
