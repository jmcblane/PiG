import XCTest
@testable import PiG

final class ComposerTokensTests: XCTestCase {
    func testMarkerEncodingIsDeterministic() {
        let skillToken = ComposerToken(
            kind: .skill,
            value: "skill:pdf-tools",
            label: "pdf-tools",
            detail: "Work with PDFs",
            resourcePath: "/tmp/skills/pdf-tools/SKILL.md"
        )
        let fileToken = ComposerToken(
            kind: .file,
            value: "Sources/PiG/Theme.swift",
            label: "Theme.swift",
            detail: "Sources/PiG/Theme.swift",
            resourcePath: nil
        )

        let expectedSkill = ComposerTokenCodec.marker(for: skillToken)
        let expectedFile = ComposerTokenCodec.marker(for: fileToken)

        var heapChurn: [String] = []
        for i in 0..<100 {
            heapChurn.append(String(repeating: "x", count: 32 + i))
            XCTAssertEqual(ComposerTokenCodec.marker(for: skillToken), expectedSkill)
            XCTAssertEqual(ComposerTokenCodec.marker(for: fileToken), expectedFile)
        }
        _ = heapChurn.count
    }

    func testNormalizeExactReferencesPreservesExistingTokensVerbatim() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pig-composer-tokens-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("Notes.md")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

        let skill = SlashCommandInfo(
            name: "skill:pdf-tools",
            description: "PDF helper",
            source: "skill",
            location: nil,
            path: "/tmp/SKILL.md",
            argumentHint: nil
        )

        // Construct a legacy token marker with unsorted JSON keys to ensure
        // existing markers are passed through untouched even during normalization.
        let unsortedJSON = #"{"value":"skill:pdf-tools","kind":"skill","label":"pdf-tools","detail":"PDF helper","resourcePath":"/tmp/SKILL.md"}"#
        let legacyMarker = "\u{E000}pig-token:" + Data(unsortedJSON.utf8).base64EncodedString() + "\u{E001}"

        let draft = legacyMarker + " check this out"
        let normalized = ComposerTokenCodec.normalizeExactReferences(
            in: draft,
            skills: [skill],
            projectPath: tempDir.path
        )
        XCTAssertEqual(normalized, draft)

        // When a new raw @file reference is present alongside the existing legacy marker,
        // the new reference is tokenized while the existing marker remains verbatim.
        let withRawFile = legacyMarker + " see @Notes.md please"
        let normalizedWithFile = ComposerTokenCodec.normalizeExactReferences(
            in: withRawFile,
            skills: [skill],
            projectPath: tempDir.path
        )
        XCTAssertTrue(normalizedWithFile.hasPrefix(legacyMarker + " see "))
        XCTAssertEqual(ComposerTokenCodec.tokens(in: normalizedWithFile).count, 2)
        XCTAssertEqual(
            ComposerTokenCodec.normalizeExactReferences(
                in: normalizedWithFile,
                skills: [skill],
                projectPath: tempDir.path
            ),
            normalizedWithFile
        )
    }

    func testRawSegmentsPreserveExactMarkerBytes() {
        let unsortedJSON = #"{"label":"Theme.swift","kind":"file","value":"Sources/PiG/Theme.swift","detail":"Sources/PiG/Theme.swift"}"#
        let legacyMarker = "\u{E000}pig-token:" + Data(unsortedJSON.utf8).base64EncodedString() + "\u{E001}"
        let canonical = "Before " + legacyMarker + " after"

        let segments = ComposerTokenCodec.rawSegments(in: canonical)
        XCTAssertEqual(segments.count, 3)

        var rebuilt = ""
        for segment in segments {
            switch segment {
            case .text(let value):
                rebuilt += value
            case .token(let token, let rawMarker):
                XCTAssertEqual(token.label, "Theme.swift")
                XCTAssertEqual(rawMarker, legacyMarker)
                rebuilt += rawMarker
            }
        }
        XCTAssertEqual(rebuilt, canonical)
    }

    func testCompletionChecksWithExistingTokens() {
        let skill = SlashCommandInfo(
            name: "skill:pdf-tools",
            description: "PDF helper",
            source: "skill",
            location: nil,
            path: "/tmp/SKILL.md",
            argumentHint: nil
        )
        let token = ComposerToken(
            kind: .file,
            value: "README.md",
            label: "README.md",
            detail: "README.md",
            resourcePath: nil
        )
        let marker = ComposerTokenCodec.marker(for: token)

        XCTAssertFalse(ComposerCompletion.hasFileToken(in: marker + " typing normal words"))
        XCTAssertTrue(ComposerCompletion.hasFileToken(in: marker + " @Read"))
        XCTAssertTrue(ComposerCompletion.skillSuggestions(for: marker + " typing normal words", commands: [skill]).isEmpty)
        XCTAssertEqual(ComposerCompletion.skillSuggestions(for: marker + " $pdf", commands: [skill]).count, 1)
    }
}
