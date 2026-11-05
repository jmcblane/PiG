import Foundation

/// Copy the same blocks the transcript renders, without styling or Markdown delimiters.
/// Code stays verbatim; links keep their destinations even when their label is styled.
enum MarkdownPlainText {
    static func render(_ markdown: String) -> String {
        MarkdownBlockParser.parse(markdown).compactMap { block -> String? in
            switch block {
            case .paragraph(let text), .heading(_, let text):
                return inline(text)
            case .quote(let text):
                return render(text)
            case .code(let code, _):
                return code
            case .list(let items):
                return items.map { item in
                    let marker: String
                    switch item.marker {
                    case .unordered: marker = "•"
                    case .ordered(let number): marker = "\(number)."
                    }
                    return String(repeating: "  ", count: item.depth) + marker + " " + inline(item.text)
                }.joined(separator: "\n")
            case .table(let header, let rows):
                let allRows = (header.map { [$0] } ?? []) + rows
                return allRows.map { $0.map(inline).joined(separator: "\t") }
                    .joined(separator: "\n")
            case .rule:
                return nil
            }
        }.joined(separator: "\n\n")
    }

    private static func inline(_ markdown: String) -> String {
        guard let parsed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                           failurePolicy: .returnPartiallyParsedIfPossible)
        ) else { return markdown }

        var result = ""
        var link: URL?
        var label = ""
        func flushLink() {
            guard let link else { return }
            let destination = link.absoluteString
            result += label == destination ? label : "\(label) (\(destination))"
            label = ""
        }
        for run in parsed.runs {
            let destination = run.link ?? run.imageURL
            if destination != link {
                flushLink()
                link = destination
            }
            let text = String(parsed.characters[run.range])
            if link != nil { label += text }
            else { result += text }
        }
        flushLink()
        return result
    }
}
