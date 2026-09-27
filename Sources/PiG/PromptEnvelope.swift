import Foundation

enum PromptEnvelope {
    private static let prefix = "<!-- pig-message:"
    private static let suffix = " -->"

    private struct Metadata: Codable {
        var text: String
        var references: [MessageReference]
        /// Version-two messages retain composer markers so references can render inline.
        var canonicalText: String?
    }

    struct Prepared {
        var payload: String
        var displayText: String
        var canonicalText: String?
        var references: [MessageReference]
    }

    static func prepare(canonicalText: String, projectPath: String) -> Prepared {
        let tokens = deduplicated(ComposerTokenCodec.tokens(in: canonicalText))
        let plain = ComposerTokenCodec.messageText(from: canonicalText)
        guard !tokens.isEmpty else { return Prepared(payload: plain, displayText: plain, canonicalText: nil, references: []) }

        let references = tokens.map { token -> MessageReference in
            let available: Bool
            switch token.kind {
            case .skill:
                available = token.resourcePath.map(existingPath) ?? false
            case .file:
                let path = token.value.hasPrefix("/")
                    ? token.value
                    : URL(fileURLWithPath: projectPath).appendingPathComponent(token.value).path
                available = FileManager.default.fileExists(atPath: path)
            }
            return MessageReference(
                kind: token.kind,
                value: token.value,
                label: token.label,
                detail: token.detail,
                resourcePath: token.resourcePath,
                isAvailable: available
            )
        }

        var displayText = plain
        var modelText = plain
        for token in tokens {
            displayText = replacingReference(token.plainText, in: displayText, internalReplacement: token.label)
            if token.kind == .skill {
                modelText = replacingReference(token.plainText, in: modelText, internalReplacement: token.skillName)
            }
        }
        displayText = cleaned(displayText)
        modelText = cleaned(modelText)

        let storedCanonicalText = canonicalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let metadata = Metadata(text: displayText, references: references, canonicalText: storedCanonicalText)
        let encoded = (try? JSONEncoder().encode(metadata))?.base64EncodedString() ?? ""
        var sections = [prefix + encoded + suffix]
        for token in tokens where token.kind == .skill {
            let path = token.resourcePath?.expandingTildeInPath
            let content = path.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            if let content {
                sections.append("<skill name=\"\(token.skillName)\" path=\"\(path ?? "")\">\n\(content)\n</skill>")
            } else {
                sections.append("<skill name=\"\(token.skillName)\" unavailable=\"true\" />")
            }
        }
        sections.append("User: \(modelText)")
        return Prepared(
            payload: sections.joined(separator: "\n\n"),
            displayText: displayText,
            canonicalText: storedCanonicalText,
            references: references
        )
    }

    static func parse(_ payload: String) -> (text: String, canonicalText: String?, references: [MessageReference])? {
        guard payload.hasPrefix(prefix), let lineEnd = payload.firstIndex(of: "\n") else { return nil }
        let firstLine = String(payload[..<lineEnd])
        guard firstLine.hasSuffix(suffix) else { return nil }
        let start = firstLine.index(firstLine.startIndex, offsetBy: prefix.count)
        let end = firstLine.index(firstLine.endIndex, offsetBy: -suffix.count)
        guard start <= end,
              let data = Data(base64Encoded: String(firstLine[start..<end])),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data) else { return nil }
        return (metadata.text, metadata.canonicalText, metadata.references)
    }

    private static func deduplicated(_ tokens: [ComposerToken]) -> [ComposerToken] {
        var seen = Set<String>()
        return tokens.filter { seen.insert("\($0.kind.rawValue):\($0.value)").inserted }
    }

    private static func existingPath(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path.expandingTildeInPath)
    }

    private static func replacingReference(_ reference: String, in text: String, internalReplacement: String) -> String {
        let leadingWhitespace = text.prefix { $0.isWhitespace }
        let body = text.dropFirst(leadingWhitespace.count)
        if body.hasPrefix(reference) {
            return String(body.dropFirst(reference.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.replacingOccurrences(of: reference, with: internalReplacement)
    }

    private static func cleaned(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var expandingTildeInPath: String { (self as NSString).expandingTildeInPath }
}
