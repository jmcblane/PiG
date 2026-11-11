import Foundation

extension SessionController {
    func preserveFailedPromptDraft(_ draft: String) {
        failedPrompt?.composerDraft = draft
    }

    func dismissFailedPrompt() {
        guard !isSendingPrompt else { return }
        failedPrompt = nil
    }

    func retryFailedPrompt() async -> Bool {
        guard let submission = failedPrompt, !isSendingPrompt, !quickChatClosed else { return false }
        resumeRuntimeLoading()
        return await sendPrompt(
            submission.text,
            images: submission.images,
            requestFollowUp: submission.requestFollowUp,
            forceQueue: submission.forceQueue,
            composerDraft: submission.composerDraft
        )
    }

    @discardableResult
    func send(_ rawText: String, images: [ImageAttachment] = [], requestFollowUp: Bool = false) async -> Bool {
        let text = rawText.nonEmptyTrimmed ?? ""
        guard !text.isEmpty || !images.isEmpty else { return false }
        guard !isStartingNewChat else { errorText = "A new chat is starting. Try again in a moment."; return false }
        guard !quickChatClosed else {
            errorText = closedQuickChatNotice
            return false
        }
        lastRuntimeUse = Date()
        if !images.isEmpty, text.hasPrefix("/"), let parsed = SlashCommandParsing.split(text) {
            let name = parsed.name.lowercased()
            if name == "steer" || name == "follow-up" {
                return await sendPrompt(parsed.arguments, images: images, requestFollowUp: name == "follow-up", forceQueue: true)
            }
            if GUIBuiltinSlashCommands.named(name) != nil {
                errorText = "Images cannot be attached to the local /\(name) command. Send them with a normal prompt."
                return false
            }
            return await sendPrompt(text, images: images, requestFollowUp: requestFollowUp)
        }
        if text.hasPrefix("//") {
            return await sendPrompt(String(text.dropFirst()), images: images, requestFollowUp: requestFollowUp)
        }
        if text.hasPrefix("!!") || text.hasPrefix("!") {
            guard images.isEmpty else {
                errorText = "Images cannot be attached to shell commands. Send them with a normal prompt."
                return false
            }
            if text.hasPrefix("!!") {
                return await executeBash(String(text.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines), excludeFromContext: true)
            } else {
                return await executeBash(String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines), excludeFromContext: false)
            }
        }
        if text.hasPrefix("/") {
            if SlashCommandParsing.split(text) == nil {
                return await sendPrompt(text, images: images)
            }
            return await executeSlashCommand(text)
        }
        return await sendPrompt(text, images: images, requestFollowUp: requestFollowUp)
    }

    @discardableResult
    func sendHTMLWidgetMessage(_ rawText: String) async -> Bool {
        guard let text = rawText.nonEmptyTrimmed, text.utf16.count <= 2000,
              !text.hasPrefix("/"), !text.hasPrefix("!") else { return false }
        guard !quickChatClosed else {
            errorText = closedQuickChatNotice
            return false
        }
        guard !isSendingPrompt else {
            errorText = "A message is already being sent. Try this control again in a moment."
            return false
        }
        lastRuntimeUse = Date()
        resumeRuntimeLoading()
        // Only ordinary prompts: never route generated text through send(),
        // which interprets !shell and /local commands. Queue as a follow-up
        // rather than interrupting an active run with steering.
        return await sendPrompt(text, requestFollowUp: true)
    }

    func sendPrompt(
        _ rawText: String,
        images: [ImageAttachment] = [],
        requestFollowUp: Bool = false,
        forceQueue: Bool = false,
        composerDraft: String? = nil
    ) async -> Bool {
        let text = rawText.nonEmptyTrimmed ?? ""
        guard !isStartingNewChat, !isSendingPrompt, !text.isEmpty || !images.isEmpty else { return false }
        isSendingPrompt = true
        defer { isSendingPrompt = false }
        let isQueueing = forceQueue || showsActivityIndicator
        let prepared = PromptEnvelope.prepare(canonicalText: text, projectPath: projectPath)
        errorText = nil
        isAgentSettled = false
        bottomScrollRequest += 1
        var optimisticMessageID: String?
        var commandAttempted = false
        do {
            try await ensureRPC()
            let messageID = UUID().uuidString
            optimisticMessageID = messageID
            messages.append(ChatMessage(
                id: messageID,
                role: .user,
                text: prepared.displayText,
                canonicalText: prepared.canonicalText,
                references: prepared.references,
                images: images,
                timestamp: Date()
            ))
            let wasUntitled = title.isEmpty || title == "Untitled" || title == "Quick Chat"
            let shouldGenerateTitle = createdAsNewSession && !automaticTitleGenerationStarted && wasUntitled
            let fallbackSource = prepared.displayText.nonEmptyTrimmed ?? images.first?.name ?? prepared.references.map(\.label).joined(separator: ", ")
            let fallbackTitle = fallbackSource.oneLine(max: 70)
            if wasUntitled {
                title = fallbackTitle
                eventHandler(.titleChanged)
            }
            var command: [String: Any]
            if isQueueing {
                command = [
                    "type": requestFollowUp ? "follow_up" : "steer",
                    "message": prepared.payload
                ]
            } else {
                // Extensions can start a run while PiG believes pi is idle (for example
                // a finished background job). Pi rejects a prompt during a run unless it
                // names a streaming behavior; when idle, the field is ignored.
                command = [
                    "type": "prompt",
                    "message": prepared.payload,
                    "streamingBehavior": requestFollowUp ? "followUp" : "steer"
                ]
            }
            if !images.isEmpty { command["images"] = images.compactMap(\.rpcValue) }
            guard let rpc else { throw PiRPCClient.RPCError.notRunning }
            commandAttempted = true
            let response = try await rpc.command(command)
            failedPrompt = nil
            // An extension command or input handler consumed the input: no run
            // starts, so agent_settled never arrives.
            let handled = (response["data"] as? [String: Any])?["disposition"] as? String == "handled"
            if handled, !showsActivityIndicator { isAgentSettled = true }
            if isQueueing, !images.isEmpty, !handled {
                queuedImageSubmissions.append(QueuedImageSubmission(composerText: text, images: images))
                queuedImageCount = queuedImageSubmissions.reduce(0) { $0 + $1.images.count }
            }
            if shouldGenerateTitle {
                automaticTitleGenerationStarted = true
                requestAutomaticSessionTitle(for: prepared.displayText, replacing: fallbackTitle)
            }
            await refreshState()
            if agentID != nil { eventHandler(.sessionsChanged) }
            return true
        } catch {
            eventHandler(.log(error.localizedDescription))
            // Once a write was attempted, a lost response or connection cannot
            // prove non-delivery. Keep the optimistic message and never offer a
            // resend that could duplicate it. An explicit rejection is different.
            let wasRejected: Bool
            if let rpcError = error as? PiRPCClient.RPCError, case .commandFailed = rpcError {
                wasRejected = true
            } else {
                wasRejected = false
            }
            if commandAttempted && !wasRejected {
                failedPrompt = nil
                if isQueueing, !images.isEmpty {
                    queuedImageSubmissions.append(QueuedImageSubmission(composerText: text, images: images))
                    queuedImageCount = queuedImageSubmissions.reduce(0) { $0 + $1.images.count }
                }
                if rpc?.isRunning != true { isAgentSettled = true }
                await refreshState()
                return true
            }
            if let optimisticMessageID { messages.removeAll { $0.id == optimisticMessageID } }
            isAgentSettled = true
            failedPrompt = FailedPromptSubmission(
                text: text,
                displayText: prepared.displayText,
                images: images,
                requestFollowUp: requestFollowUp,
                forceQueue: isQueueing,
                composerDraft: composerDraft
            )
            return false
        }
    }

    private func requestAutomaticSessionTitle(for initialPrompt: String, replacing fallbackTitle: String) {
        guard SessionNamingPreference.enabled else { return }
        let mode = SessionNamingPreference.modelMode
        let modelID: String
        switch mode {
        case .apple:
            modelID = ""
        case .session:
            modelID = selectedModelID
        case .specific:
            modelID = SessionNamingPreference.modelID ?? ""
        }
        let thinkingLevel = SessionNamingPreference.thinkingLevel
        let requestID = UUID()
        automaticTitleTask?.cancel()
        automaticTitleRequestID = requestID
        automaticTitleTask = Task { [weak self] in
            let generatedTitle: String?
            if mode == .apple {
                generatedTitle = await AppleIntelligenceNaming.generateTitle(from: initialPrompt)
            } else {
                let configuredTitle = modelID.isEmpty ? nil : await SessionTitleGenerator.generate(
                    from: initialPrompt,
                    modelID: modelID,
                    thinkingLevel: thinkingLevel
                )
                if configuredTitle != nil || Task.isCancelled {
                    generatedTitle = configuredTitle
                } else {
                    generatedTitle = await AppleIntelligenceNaming.generateTitle(from: initialPrompt)
                }
            }
            guard let self, self.automaticTitleRequestID == requestID else { return }
            defer { self.automaticTitleTask = nil }
            guard !Task.isCancelled else {
                self.automaticTitleRequestID = nil
                return
            }
            guard let generatedTitle else {
                self.automaticTitleRequestID = nil
                return
            }
            await self.applyAutomaticSessionTitle(generatedTitle, replacing: fallbackTitle, requestID: requestID)
        }
    }

    private func applyAutomaticSessionTitle(_ generatedTitle: String, replacing fallbackTitle: String, requestID: UUID) async {
        guard automaticTitleRequestID == requestID else { return }
        guard title == fallbackTitle else {
            automaticTitleRequestID = nil
            return
        }
        if !isQuickChat {
            do {
                try await ensureRPC(reloadMessages: false)
                _ = try await rpc?.command(["type": "set_session_name", "name": generatedTitle])
            } catch {
                if automaticTitleRequestID == requestID { automaticTitleRequestID = nil }
                return
            }
        }
        guard automaticTitleRequestID == requestID, title == fallbackTitle else { return }
        automaticTitleRequestID = nil
        title = generatedTitle
        eventHandler(.titleChanged)
    }

    func restoreQueuedMessages() async {
        guard let client = rpc, client.isRunning else { return }
        _ = await clearQueue(using: client)
    }

    func abort() async -> Bool {
        var accepted = true
        do {
            try await ensureRPC()
            guard let client = rpc else { throw PiRPCClient.RPCError.notRunning }
            accepted = await clearQueue(using: client)
            _ = try await client.command(["type": "abort"])
            _ = try? await client.command(["type": "abort_bash"])
            _ = try? await client.command(["type": "abort_retry"])
        } catch {
            errorText = error.localizedDescription
            accepted = false
        }
        resetStreamingState()
        resetIdleActivity()
        eventHandler(.activityChanged)
        return accepted
    }

    private func clearQueue(using client: PiRPCClient) async -> Bool {
        do {
            let response = try await client.command(["type": "clear_queue"])
            restoreQueuedContent(from: response)
            if rpc === client { clearQueueState() }
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    private func restoreQueuedContent(from response: [String: Any]) {
        guard let data = response["data"] as? [String: Any] else { return }
        let steering = data["steering"] as? [String] ?? []
        let followUps = data["followUp"] as? [String] ?? []
        let text = (steering + followUps).joined(separator: "\n\n")
        let images = queuedImageSubmissions.flatMap(\.images)
        guard !text.isEmpty || !images.isEmpty else { return }
        composerPrefillRequest = ComposerPrefillRequest(text: text, images: images, appendsToDraft: true)
    }

    func markQueuedImagesDelivered(in content: Any?) {
        let delivered = SessionParser.contentImages(content).compactMap(\.data)
        guard !delivered.isEmpty,
              let index = queuedImageSubmissions.firstIndex(where: { submission in
                  submission.images.compactMap(\.data) == delivered
              }) else { return }
        queuedImageSubmissions.remove(at: index)
        queuedImageCount = queuedImageSubmissions.reduce(0) { $0 + $1.images.count }
    }

    func restoreLocalQueuedImagesIfNeeded() {
        let images = queuedImageSubmissions.flatMap(\.images)
        guard !images.isEmpty else { return }
        let text = queuedImageSubmissions.map(\.composerText).filter { !$0.isEmpty }.joined(separator: "\n\n")
        composerPrefillRequest = ComposerPrefillRequest(text: text, images: images, appendsToDraft: true)
        errorText = "The RPC runtime stopped before queued images were delivered. Their local text and image copies were restored to the composer; Pi does not expose queued image payloads or message grouping."
    }

    func clearQueueState() {
        queuedSteering.removeAll()
        queuedFollowUps.removeAll()
        queuedImageSubmissions.removeAll()
        queuedImageCount = 0
    }

}
