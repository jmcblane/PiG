import XCTest
@testable import PiG

@MainActor
final class ACPTests: XCTestCase {
    private func makeController(
        models: [ModelInfo] = [],
        modes: [ACPModeInfo] = ACPModeInfo.antigravityDefaults
    ) -> ACPChatController {
        ACPChatController(
            id: "test-chat",
            sessionID: "sess-1",
            projectPath: "/tmp/project",
            isQuickChat: false,
            title: "Test ACP",
            models: models,
            selectedModelID: models.first?.id ?? "",
            thinkingLevel: "medium",
            modes: modes,
            modeID: "default",
            eventHandler: { _ in }
        )
    }

    // MARK: - Catalog parsing

    func testModelCatalogParserExtractsModelsThinkingLevelsAndModes() throws {
        let sessionResult: [String: Any] = [
            "modes": [
                "currentModeId": "default",
                "availableModes": [
                    ["id": "default", "name": "Ask before edits"],
                    ["id": "auto", "name": "Auto"]
                ]
            ],
            "configOptions": [
                [
                    "id": "model",
                    "name": "Model",
                    "category": "model",
                    "currentValue": "gemini-3-pro",
                    "options": [
                        ["value": "gemini-3-pro", "name": "Gemini 3 Pro"],
                        ["value": "claude-sonnet-4-6", "name": "Claude Sonnet 4.6"]
                    ]
                ],
                [
                    "id": "thought_level",
                    "name": "Thought Level",
                    "category": "thought_level",
                    "currentValue": "medium",
                    "options": [
                        ["value": "off", "name": "Off"],
                        ["value": "low", "name": "Low"],
                        ["value": "medium", "name": "Medium"],
                        ["value": "high", "name": "High"]
                    ]
                ]
            ]
        ]

        let configOptions = ACPModelCatalogParser.parseConfigOptions(sessionResult["configOptions"])
        let parsedModes = ACPModelCatalogParser.parseModes(from: sessionResult, configOptions: configOptions)
        let parsedModels = ACPModelCatalogParser.parseModels(from: sessionResult, configOptions: configOptions)

        XCTAssertEqual(parsedModes.currentModeID, "default")
        XCTAssertEqual(parsedModes.modes.map(\.id), ["default", "auto"])
        XCTAssertEqual(parsedModels.models.map(\.id), ["antigravity-acp/gemini-3-pro", "antigravity-acp/claude-sonnet-4-6"])
        XCTAssertEqual(parsedModels.currentModelID, "antigravity-acp/gemini-3-pro")
        XCTAssertEqual(parsedModels.currentThinkingLevel, "medium")

        let model = try XCTUnwrap(parsedModels.models.first)
        XCTAssertEqual(model.provider, ACPProvider.antigravity)
        XCTAssertTrue(model.isAntigravityACP)
        XCTAssertEqual(model.displayName, "Antigravity/Gemini 3 Pro")
        XCTAssertTrue(model.reasoning)
        XCTAssertEqual(model.thinkingLevels, ["off", "low", "medium", "high"])
    }

    func testEnabledModelScopePreservesAntigravityModels() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pig-acp-scope-\(UUID().uuidString)")
        let piDir = tempDir.appendingPathComponent(".pi")
        try FileManager.default.createDirectory(at: piDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settings = #"{"enabledModels": ["openai/*"]}"#
        try settings.write(to: piDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

        let piModel = ModelInfo(
            id: "anthropic/claude-sonnet",
            provider: "anthropic",
            modelId: "claude-sonnet",
            name: "Claude Sonnet",
            reasoning: true,
            thinkingLevels: ["low", "high"]
        )
        let agyModel = ModelInfo(
            id: "antigravity-acp/gemini-3-pro",
            provider: ACPProvider.antigravity,
            modelId: "gemini-3-pro",
            name: "Gemini 3 Pro",
            reasoning: true,
            thinkingLevels: ["low", "medium", "high"]
        )

        let scoped = EnabledModelScope.scopedModels([piModel, agyModel], projectPath: tempDir.path)
        XCTAssertEqual(scoped.map(\.id), [agyModel.id])
    }

    // MARK: - HTML Render MCP Bridge

    func testHTMLRenderBridgeProducesValidHTMLArtifact() throws {
        let rawInput: [String: Any] = [
            "title": "Deploy Check",
            "html": "<div><button data-pig-action=\"deploy\">Deploy</button></div>",
            "height": 320,
            "actions": [
                ["id": "deploy", "message": "Run deploy now"]
            ]
        ]

        let detailsJSON = ACPHTMLRenderBridge.pigHTMLDetailsJSON(
            rawInput: rawInput,
            outputText: "Rendered interactive HTML: Deploy Check ([[pig-ui:0123456789abcdef]])",
            fallbackSeed: "call-html-1"
        )
        XCTAssertNotNil(detailsJSON)

        let tool = ToolDisplay(
            id: "call-html-1",
            name: "html_render",
            arguments: "{\"title\":\"Deploy Check\"}",
            result: "Rendered interactive HTML: Deploy Check",
            details: detailsJSON,
            status: .succeeded,
            isError: false
        )

        let artifact = try XCTUnwrap(HTMLArtifact(tool: tool))
        XCTAssertEqual(artifact.title, "Deploy Check")
        XCTAssertEqual(artifact.height, 320)
        XCTAssertEqual(artifact.actions.map(\.message), ["Run deploy now"])
        XCTAssertEqual(artifact.reference, "0123456789abcdef")
        XCTAssertEqual(artifact.html, "<div><button data-pig-action=\"deploy\">Deploy</button></div>")
    }

    // MARK: - ACPChatController session/update handling

    func testStreamingThoughtToolsAndFinalAssistantSplit() {
        let controller = makeController()

        controller.handleSessionUpdate([
            "sessionUpdate": "agent_thought_chunk",
            "content": ["type": "text", "text": "Let me inspect README."]
        ])
        controller.handleSessionUpdate([
            "sessionUpdate": "agent_message_chunk",
            "content": ["type": "text", "text": "Checking the file now."]
        ])
        controller.handleSessionUpdate([
            "sessionUpdate": "tool_call",
            "toolCallId": "tc-1",
            "title": "Read README.md",
            "kind": "read",
            "status": "in_progress",
            "rawInput": ["path": "README.md"]
        ])
        controller.handleSessionUpdate([
            "sessionUpdate": "tool_call_update",
            "toolCallId": "tc-1",
            "status": "completed",
            "content": [
                ["type": "content", "content": ["type": "text", "text": "# PiG"]]
            ]
        ])
        controller.handleSessionUpdate([
            "sessionUpdate": "agent_message_chunk",
            "content": ["type": "text", "text": "Done! README starts with # PiG."]
        ])

        XCTAssertEqual(controller.messages.count, 2)
        XCTAssertEqual(controller.messages[0].role, .assistant)
        XCTAssertEqual(controller.messages[0].thinking, "Let me inspect README.")
        XCTAssertEqual(controller.messages[0].text, "Checking the file now.")
        XCTAssertEqual(controller.messages[0].tools.count, 1)
        let tool = controller.messages[0].tools[0]
        XCTAssertEqual(tool.status, .succeeded)
        XCTAssertEqual(tool.acpTitle, "Read README.md")
        XCTAssertEqual(tool.acpKind, "read")
        XCTAssertEqual(tool.result, "# PiG")
        XCTAssertEqual(tool.rowTitle(projectPath: "/tmp/project").verb, "Read README.md")

        XCTAssertEqual(controller.messages[1].role, .assistant)
        XCTAssertEqual(controller.messages[1].text, "Done! README starts with # PiG.")
        XCTAssertTrue(controller.messages[1].tools.isEmpty)
    }

    func testMCPHTMLRenderToolCallProducesInteractiveArtifactInTranscript() throws {
        let controller = makeController()

        controller.handleSessionUpdate([
            "sessionUpdate": "tool_call",
            "toolCallId": "tc-html",
            "title": "mcp__pig__html_render",
            "kind": "other",
            "status": "in_progress",
            "rawInput": [
                "title": "Metrics Card",
                "html": "<section><button data-pig-action=\"refresh\">Refresh</button></section>",
                "height": 240,
                "actions": [
                    ["id": "refresh", "message": "Refresh stats"]
                ]
            ]
        ])
        controller.handleSessionUpdate([
            "sessionUpdate": "tool_call_update",
            "toolCallId": "tc-html",
            "status": "completed",
            "content": [
                ["type": "content", "content": ["type": "text", "text": "Rendered interactive HTML: Metrics Card"]]
            ]
        ])

        XCTAssertEqual(controller.messages.count, 1)
        let tool = try XCTUnwrap(controller.messages[0].tools.first)
        XCTAssertEqual(tool.name, "html_render")
        XCTAssertEqual(tool.status, .succeeded)
        XCTAssertNotNil(HTMLArtifact(tool: tool))
    }

    func testDiffToolCallContentAndMetadataUpdates() {
        let controller = makeController()

        controller.handleSessionUpdate([
            "sessionUpdate": "tool_call",
            "toolCallId": "tc-edit",
            "title": "Edit App.swift",
            "kind": "edit",
            "status": "in_progress"
        ])
        controller.handleSessionUpdate([
            "sessionUpdate": "tool_call_update",
            "toolCallId": "tc-edit",
            "status": "completed",
            "content": [
                ["type": "diff", "path": "Sources/App.swift", "oldText": "let a = 1", "newText": "let a = 2"]
            ]
        ])
        controller.handleSessionUpdate([
            "sessionUpdate": "plan",
            "entries": [
                ["content": "Inspect code", "status": "completed", "priority": "high"],
                ["content": "Run tests", "status": "in_progress", "priority": "medium"]
            ]
        ])
        controller.handleSessionUpdate([
            "sessionUpdate": "usage_update",
            "used": 12_000,
            "size": 200_000
        ])
        controller.handleSessionUpdate([
            "sessionUpdate": "session_info_update",
            "title": "Refactor ACP Client"
        ])
        controller.handleSessionUpdate([
            "sessionUpdate": "current_mode_update",
            "currentModeId": "auto"
        ])

        let tool = controller.messages.first?.tools.first
        XCTAssertEqual(tool?.status, .succeeded)
        XCTAssertTrue(tool?.result.contains("Sources/App.swift") == true)
        XCTAssertEqual(controller.planEntries.count, 2)
        XCTAssertEqual(controller.planEntries[0].status, "completed")
        XCTAssertEqual(controller.contextUsed, 12_000)
        XCTAssertEqual(controller.contextWindow, 200_000)
        XCTAssertEqual(controller.contextPercent ?? 0, 6.0, accuracy: 0.01)
        XCTAssertEqual(controller.title, "Refactor ACP Client")
        XCTAssertEqual(controller.currentModeID, "auto")
    }

    func testACPJSONIDParsing() {
        XCTAssertEqual(ACPJSONID(42), .int(42))
        XCTAssertEqual(ACPJSONID(NSNumber(value: 7)), .int(7))
        XCTAssertEqual(ACPJSONID("req-abc"), .string("req-abc"))
        XCTAssertNil(ACPJSONID(NSNumber(value: true)))
        XCTAssertNil(ACPJSONID(nil))
        XCTAssertEqual(ACPJSONID.int(42).key, "i:42")
        XCTAssertEqual(ACPJSONID.string("req-abc").key, "s:req-abc")
    }
}
