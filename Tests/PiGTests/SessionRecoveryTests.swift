import XCTest
@testable import PiG

@MainActor
final class SessionRecoveryTests: XCTestCase {
    private func message(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, text: text)
    }

    private func controller(
        sessionPath: String? = "/tmp/session.jsonl",
        messages: [ChatMessage] = [],
        requests: SessionRecoveryRequests
    ) -> SessionController {
        let controller = SessionController(
            projectPath: "/tmp",
            sessionPath: sessionPath,
            title: "Test",
            messages: messages,
            recoveryRequests: requests,
            eventHandler: { _ in }
        )
        controller.isProcessActive = true
        controller.isAgentSettled = false
        controller.isWorking = true
        return controller
    }

    func testMissedCompletionReloadsMessagesAndSettlesActivity() async {
        let finished = message("finished")
        let requests = SessionRecoveryRequests(
            getState: { ["isStreaming": false, "isCompacting": false, "pendingMessageCount": 0] },
            getMessages: { [finished] },
            loadSavedMessages: { _ in nil }
        )
        let controller = controller(messages: [message("stale")], requests: requests)
        controller.errorText = SessionController.liveUpdatesUnavailableNotice
        controller.receiveRPCEvent(["type": "queue_update", "steering": ["stale queue"]])

        await controller.performRecoveryCheck()

        XCTAssertEqual(controller.messages, [finished])
        XCTAssertFalse(controller.isWorking)
        XCTAssertFalse(controller.isThinking)
        XCTAssertFalse(controller.isCompacting)
        XCTAssertTrue(controller.isAgentSettled)
        XCTAssertNil(controller.errorText)
        XCTAssertTrue(controller.queuedSteering.isEmpty)
    }

    func testTimeoutRefreshesSavedTranscriptWithoutClearingBusyState() async {
        let saved = message("saved result")
        var requestedMessages = false
        let requests = SessionRecoveryRequests(
            getState: { throw PiRPCClient.RPCError.timedOut("get_state") },
            getMessages: {
                requestedMessages = true
                return []
            },
            loadSavedMessages: { _ in [saved] }
        )
        let controller = controller(messages: [message("stale")], requests: requests)

        await controller.performRecoveryCheck()

        XCTAssertEqual(controller.messages, [saved])
        XCTAssertTrue(controller.isWorking)
        XCTAssertFalse(controller.isAgentSettled)
        XCTAssertFalse(requestedMessages)
        XCTAssertEqual(controller.errorText, SessionController.liveUpdatesUnavailableNotice)
    }

    func testSnapshotStartedBeforeLiveEventIsRejected() async throws {
        let started = expectation(description: "getState started")
        var stateContinuation: CheckedContinuation<[String: Any], Error>?
        let requests = SessionRecoveryRequests(
            getState: {
                try await withCheckedThrowingContinuation {
                    stateContinuation = $0
                    started.fulfill()
                }
            },
            getMessages: { [self.message("finished")] },
            loadSavedMessages: { _ in nil }
        )
        let stale = message("stale")
        let controller = controller(messages: [stale], requests: requests)

        let check = Task { await controller.performRecoveryCheck() }
        await fulfillment(of: [started], timeout: 2)
        controller.receiveRPCEvent(["type": "agent_start"])
        try XCTUnwrap(stateContinuation).resume(returning: [
            "isStreaming": false,
            "isCompacting": false,
            "pendingMessageCount": 0
        ])
        await check.value

        XCTAssertEqual(controller.messages, [stale])
        XCTAssertTrue(controller.isWorking)
        XCTAssertFalse(controller.isAgentSettled)
    }

    func testTranscriptSnapshotRejectsLocalChangesAndSessionSwitches() async throws {
        for changeSession in [false, true] {
            let started = expectation(description: "getMessages started")
            var continuation: CheckedContinuation<[ChatMessage], Error>?
            let original = message("original")
            let requests = SessionRecoveryRequests(
                getState: { ["isStreaming": false, "isCompacting": false, "pendingMessageCount": 0] },
                getMessages: {
                    try await withCheckedThrowingContinuation {
                        continuation = $0
                        started.fulfill()
                    }
                },
                loadSavedMessages: { _ in nil }
            )
            let controller = controller(messages: [original], requests: requests)
            let check = Task { await controller.performRecoveryCheck(refreshMessagesWhenIdle: true) }
            await fulfillment(of: [started], timeout: 2)
            if changeSession {
                controller.sessionPath = "/tmp/other-session.jsonl"
            } else {
                controller.messages.append(message("new local message"))
            }
            let expected = controller.messages
            try XCTUnwrap(continuation).resume(returning: [message("outdated snapshot")])
            await check.value
            XCTAssertEqual(controller.messages, expected)
            XCTAssertTrue(controller.isWorking)
        }
    }

    func testTimeoutDiskSnapshotDoesNotOverwriteNewLiveOutput() async throws {
        let started = expectation(description: "loadSavedMessages started")
        var continuation: CheckedContinuation<[ChatMessage]?, Never>?
        let requests = SessionRecoveryRequests(
            getState: { throw PiRPCClient.RPCError.timedOut("get_state") },
            getMessages: { [] },
            loadSavedMessages: { _ in
                await withCheckedContinuation {
                    continuation = $0
                    started.fulfill()
                }
            }
        )
        let controller = controller(requests: requests)
        let check = Task { await controller.performRecoveryCheck() }
        await fulfillment(of: [started], timeout: 2)
        controller.receiveRPCEvent(["type": "agent_start"])
        let live = message("new live output")
        controller.messages = [live]
        try XCTUnwrap(continuation).resume(returning: [message("old disk snapshot")])
        await check.value
        XCTAssertEqual(controller.messages, [live])
        XCTAssertTrue(controller.isWorking)
        XCTAssertNil(controller.errorText)
    }

    func testRecoveryChecksDoNotOverlap() async throws {
        var callCount = 0
        var messageCallCount = 0
        let started = expectation(description: "getState started")
        var stateContinuation: CheckedContinuation<[String: Any], Error>?
        let requests = SessionRecoveryRequests(
            getState: {
                callCount += 1
                return try await withCheckedThrowingContinuation {
                    stateContinuation = $0
                    started.fulfill()
                }
            },
            getMessages: {
                messageCallCount += 1
                return []
            },
            loadSavedMessages: { _ in nil }
        )
        let controller = controller(requests: requests)

        let first = Task { await controller.performRecoveryCheck() }
        await fulfillment(of: [started], timeout: 2)
        await controller.performRecoveryCheck()
        XCTAssertEqual(callCount, 1)

        try XCTUnwrap(stateContinuation).resume(returning: [
            "isStreaming": true,
            "isCompacting": false,
            "pendingMessageCount": 0
        ])
        await first.value
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(messageCallCount, 0)
        XCTAssertTrue(controller.isWorking)
        XCTAssertFalse(controller.isAgentSettled)
    }
}
