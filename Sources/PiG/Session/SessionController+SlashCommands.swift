import Foundation
import AppKit

extension SessionController {
    func executeSlashCommand(_ text: String) async -> Bool {
        guard let parsed = SlashCommandParsing.split(text) else { return false }
        let name = parsed.name.lowercased()
        let args = parsed.arguments
        errorText = nil

        if GUIBuiltinSlashCommands.named(name) != nil {
            return await executeBuiltinSlashCommand(name: name, arguments: args)
        }

        if let command = slashCommands.first(where: { $0.name.caseInsensitiveCompare(parsed.name) == .orderedSame }) {
            return await sendDynamicSlashCommand(command, arguments: args, originalText: text)
        }

        do {
            try await ensureRPC()
            await refreshSlashCommands()
            if let command = slashCommands.first(where: { $0.name.caseInsensitiveCompare(parsed.name) == .orderedSame }) {
                return await sendDynamicSlashCommand(command, arguments: args, originalText: text)
            } else {
                // Unknown slash-prefixed text is a normal prompt. This keeps
                // paths, prose, and command typos from becoming hard failures.
                return await sendPrompt(text)
            }
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    private func sendDynamicSlashCommand(_ command: SlashCommandInfo, arguments: String, originalText: String) async -> Bool {
        guard command.source == "skill" else {
            return await sendPrompt(originalText)
        }
        let token = ComposerToken(
            kind: .skill,
            value: command.name,
            label: ComposerTokenCodec.skillDisplayName(command),
            detail: command.description.nonEmptyTrimmed,
            resourcePath: command.path
        )
        let canonical = ComposerTokenCodec.marker(for: token) + (arguments.isEmpty ? "" : " " + arguments)
        return await sendPrompt(canonical)
    }

    private func executeBuiltinSlashCommand(name: String, arguments args: String) async -> Bool {
        if agentID != nil, ["fork", "clone", "tree"].contains(name) {
            addSystemNotice("Agent chats do not support branching. Use /new for a fresh chat.")
            return true
        }
        if let notice = Self.builtinNotices[name] {
            addSystemNotice(notice)
            return true
        }
        switch name {
        case "help", "commands":
            if name == "commands" { await refreshSlashCommands() }
            addSystemNotice(commandHelpMarkdown())
        case "abort":
            guard await abort() else { return false }
            addSystemNotice("Abort requested.")
        case "model":
            return await handleModelSlash(args)
        case "cycle-model":
            return await handleCycleModelSlash()
        case "thinking":
            return await handleThinkingSlash(args)
        case "cycle-thinking":
            return await handleCycleThinkingSlash()
        case "update":
            let action: PiUpdateAction?
            switch args.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "": action = .pi
            case "--extensions": action = .extensions
            case "--models": action = .models
            case "--all": action = .all
            case "--self", "pi", "self": action = .pi
            default:
                addSystemNotice("Usage: `/update`, `/update --extensions`, `/update --models`, or `/update --all`")
                return false
            }
            eventHandler(.showPiUpdates(cwd: projectPath, projectName: projectName, action: action))
        case "changelog":
            eventHandler(.showPiChangelog)
        case "export":
            return await handleExportSlash(args)
        case "copy":
            handleCopySlash()
        case "name":
            return await handleNameSlash(args)
        case "session":
            return await handleSessionSlash()
        case "new":
            return await handleNewSlash()
        case "compact":
            return await handleCompactSlash(args)
        case "auto-compact":
            return await handleBooleanRPCSlash(args, commandType: "set_auto_compaction", key: "enabled", label: "Auto compaction")
        case "auto-retry":
            return await handleBooleanRPCSlash(args, commandType: "set_auto_retry", key: "enabled", label: "Auto retry")
        case "steering-mode":
            return await handleModeSlash(args, commandType: "set_steering_mode", key: "mode", label: "Steering mode")
        case "follow-up-mode":
            return await handleModeSlash(args, commandType: "set_follow_up_mode", key: "mode", label: "Follow-up mode")
        case "steer":
            return await handleQueuedMessageSlash(args, type: "steer")
        case "follow-up":
            return await handleQueuedMessageSlash(args, type: "follow_up")
        case "bash":
            return await executeBash(args, excludeFromContext: false)
        case "hidden-bash":
            return await executeBash(args, excludeFromContext: true)
        case "fork":
            return await handleForkSlash(args)
        case "clone":
            return await handleCloneSlash()
        case "reload":
            return await handleReloadSlash()
        case "unload":
            return handleUnloadSlash()
        case "unload-others":
            eventHandler(.unloadOthers(id))
            addSystemNotice("Requested unload of other idle chat runtimes.")
        case "unload-all-idle":
            eventHandler(.unloadAllIdle)
            addSystemNotice("Requested unload of all idle chat runtimes.")
        case "refresh":
            await performRecoveryCheck(refreshMessagesWhenIdle: true)
            await refreshSlashCommands()
        case "clear-error":
            errorText = nil
            addSystemNotice("Error cleared.")
        case "tree":
            eventHandler(.showSessionTree)
        case "quit":
            NSApp.terminate(nil)
        default:
            addSystemNotice("Not implemented in PiG: `/\(name)`")
        }
        return true
    }

    func withSlashRPC(onError: () -> Void = {}, _ body: (PiRPCClient) async throws -> Bool) async -> Bool {
        do {
            try await ensureRPC()
            guard let rpc else { throw PiRPCClient.RPCError.notRunning }
            return try await body(rpc)
        } catch {
            onError()
            errorText = error.localizedDescription
            return false
        }
    }

    private func handleExportSlash(_ args: String) async -> Bool {
        await withSlashRPC { rpc in
            var command: [String: Any] = ["type": "export_html"]
            if !args.isEmpty { command["outputPath"] = args }
            let response = try await rpc.command(command)
            let path = (response["data"] as? [String: Any])?["path"] as? String ?? args
            addSystemNotice("Exported chat: `\(path)`")
            return true
        }
    }

    private func handleCopySlash() {
        guard let text = messages.reversed().first(where: { $0.role == .assistant && !$0.text.isEmpty })?.text else {
            addSystemNotice("No assistant message to copy.")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        addSystemNotice("Copied last assistant message.")
    }

    private func handleNameSlash(_ args: String) async -> Bool {
        guard !args.isEmpty else {
            addSystemNotice(title.isEmpty ? "Chat has no name." : "Chat name: `\(title)`")
            return true
        }
        return await renameSession(args)
    }

    func renameSession(_ name: String) async -> Bool {
        guard !showsActivityIndicator else {
            errorText = "Cannot rename a working chat."
            return false
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        automaticTitleTask?.cancel()
        automaticTitleTask = nil
        automaticTitleRequestID = nil
        automaticTitleGenerationStarted = true
        do {
            try await ensureRPC()
            guard !showsActivityIndicator else { throw PiRPCClient.RPCError.commandFailed("Cannot rename a working chat.") }
            guard let rpc else { throw PiRPCClient.RPCError.notRunning }
            _ = try await rpc.command(["type": "set_session_name", "name": name])
            title = name
            eventHandler(.titleChanged)
            addSystemNotice("Chat name set: `\(name)`")
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    private func handleSessionSlash() async -> Bool {
        await withSlashRPC { rpc in
            let stats = try await requestSessionStatistics(using: rpc)
            let display = SessionStatistics.display
            let percent = stats.contextPercent.map { String(format: "%.1f%%", $0) } ?? "Unavailable"
            let lines = [
                "**Chat Info**",
                "",
                "Name: `\(title)`",
                "File: `\(sessionPath ?? stats.sessionFile ?? "In-memory")`",
                "ID: `\(stats.sessionID ?? "unknown")`",
                "",
                "Messages: `\(display(stats.totalMessages))` total, `\(display(stats.userMessages))` user, `\(display(stats.assistantMessages))` assistant",
                "Tool calls: `\(display(stats.toolCalls))`",
                "Tokens: `\(display(stats.totalTokens))` total (`\(display(stats.inputTokens))` in, `\(display(stats.outputTokens))` out)",
                "Context: `\(display(stats.contextTokens))` / `\(display(stats.contextWindow))` (`\(percent)`)",
            ]
            addSystemNotice(lines.joined(separator: "\n"))
            return true
        }
    }

    private func handleNewSlash() async -> Bool {
        guard !isStartingNewChat else { return false }
        if agentID != nil, showsActivityIndicator || isSendingPrompt {
            addSystemNotice("Wait for the agent to finish before starting a new chat.")
            return false
        }
        isStartingNewChat = true
        defer { isStartingNewChat = false }
        return await withSlashRPC { rpc in
            var command: [String: Any] = ["type": "new_session"]
            // Agent chats cannot open the tree, so /new starts an independent
            // thread rather than a child that would only be reachable through it.
            if agentID == nil, let sessionPath { command["parentSession"] = sessionPath }
            let response = try await rpc.command(command)
            if let data = response["data"] as? [String: Any], data["cancelled"] as? Bool == true {
                addSystemNotice("New chat cancelled by extension.")
                return false
            }
            messages.removeAll()
            sessionPath = nil
            sessionTree = nil
            sessionTreeLoadState = .idle
            title = "Untitled"
            automaticTitleTask?.cancel()
            automaticTitleRequestID = nil
            automaticTitleGenerationStarted = false
            if agentID != nil {
                hasExplicitModelSelection = false
                hasExplicitThinkingSelection = false
                // Changes to persona/skills/extensions take effect on /new as well as /reload.
                let nextResources = agentConfiguration?().map { PiLaunchResources(agent: $0) }
                do {
                    if let nextResources, nextResources.arguments != launchResources.arguments {
                        stopRPC()
                        try await ensureRPC(reloadMessages: false)
                    } else {
                        try await applyAgentChatDefaults(using: rpc)
                    }
                } catch {
                    // Never let a failed default selection silently start the next
                    // turn on the preceding chat's model/thinking configuration.
                    stopRPC()
                    throw error
                }
            }
            await refreshState()
            eventHandler(.sessionsChanged)
            bottomScrollRequest += 1
            addSystemNotice("New chat started.")
            return true
        }
    }

    private func handleCompactSlash(_ args: String) async -> Bool {
        await withSlashRPC(onError: { isCompacting = false }) { rpc in
            isCompacting = true
            var command: [String: Any] = ["type": "compact"]
            if !args.isEmpty { command["customInstructions"] = args }
            let response = try await rpc.command(command)
            isCompacting = false
            await refreshState()
            if let data = response["data"] as? [String: Any], let summary = data["summary"] as? String {
                addSystemNotice("Compaction complete.\n\n\(summary)")
            } else {
                addSystemNotice("Compaction complete.")
            }
            return true
        }
    }

    private func handleBooleanRPCSlash(_ args: String, commandType: String, key: String, label: String) async -> Bool {
        guard let value = parseBoolean(args) else {
            addSystemNotice("Usage: `/\(commandType.replacingOccurrences(of: "set_", with: "").replacingOccurrences(of: "_", with: "-")) <on|off>`")
            return false
        }
        return await withSlashRPC { rpc in
            _ = try await rpc.command(["type": commandType, key: value])
            await refreshState()
            addSystemNotice("\(label): `\(value ? "on" : "off")`")
            return true
        }
    }

    private func handleModeSlash(_ args: String, commandType: String, key: String, label: String) async -> Bool {
        guard ["all", "one-at-a-time"].contains(args) else {
            addSystemNotice("Usage: `/\(commandType.replacingOccurrences(of: "set_", with: "").replacingOccurrences(of: "_", with: "-")) <all|one-at-a-time>`")
            return false
        }
        return await withSlashRPC { rpc in
            _ = try await rpc.command(["type": commandType, key: args])
            await refreshState()
            addSystemNotice("\(label): `\(args)`")
            return true
        }
    }

    private func handleQueuedMessageSlash(_ args: String, type: String) async -> Bool {
        guard !args.isEmpty else {
            addSystemNotice("Usage: `/\(type == "follow_up" ? "follow-up" : "steer") <message>`")
            return false
        }
        return await withSlashRPC { rpc in
            _ = try await rpc.command(["type": type, "message": args])
            messages.append(ChatMessage(role: .user, text: args, timestamp: Date()))
            bottomScrollRequest += 1
            await refreshState()
            return true
        }
    }

    private func handleForkSlash(_ args: String) async -> Bool {
        await withSlashRPC { rpc in
            let response = try await rpc.command(["type": "get_fork_messages"])
            let forkMessages = ((response["data"] as? [String: Any])?["messages"] as? [[String: Any]]) ?? []
            guard !forkMessages.isEmpty else {
                addSystemNotice("No user messages available to fork from.")
                return false
            }
            if args.isEmpty {
                let lines = forkMessages.enumerated().map { index, item in
                    let text = (item["text"] as? String ?? "").oneLine(max: 110)
                    let id = item["entryId"] as? String ?? ""
                    return "\(index + 1). `\(id)` — \(text)"
                }.joined(separator: "\n")
                addSystemNotice("Fork points:\n\n\(lines)\n\nRun `/fork <number>` or `/fork <entryId>`.")
                return true
            }
            let entryId: String?
            if let number = Int(args), forkMessages.indices.contains(number - 1) {
                entryId = forkMessages[number - 1]["entryId"] as? String
            } else {
                entryId = args
            }
            guard let entryId else { return false }
            return await forkFromTree(entryID: entryId)
        }
    }

    private func handleCloneSlash() async -> Bool {
        let shouldRefreshTree = sessionTree != nil
        return await withSlashRPC { rpc in
            let response = try await rpc.command(["type": "clone"])
            if let data = response["data"] as? [String: Any], data["cancelled"] as? Bool == true {
                addSystemNotice("Clone cancelled by extension.")
                return false
            }
            await refreshState()
            await reloadMessagesFromRPC()
            if shouldRefreshTree { await loadSessionTree(force: true) }
            addSystemNotice("Cloned chat.")
            return true
        }
    }

    private func handleReloadSlash() async -> Bool {
        guard !hasBackgroundJobs else {
            addSystemNotice(backgroundJobsNotice)
            return false
        }
        stopRPC()
        return await withSlashRPC { _ in
            await refreshSlashCommands()
            await reloadMessagesFromRPC()
            await refreshState()
            addSystemNotice("Reloaded chat runtime, models, prompts, skills, and extension commands.")
            return true
        }
    }

    private var backgroundJobsNotice: String {
        "Background jobs are running. Wait for them or cancel with `/jobs cancel all`."
    }

    private func handleUnloadSlash() -> Bool {
        guard !showsActivityIndicator else {
            addSystemNotice("Cannot unload while the agent is working. Abort or wait for completion.")
            return false
        }
        guard !hasBackgroundJobs else {
            addSystemNotice(backgroundJobsNotice)
            return false
        }
        guard isProcessActive else {
            addSystemNotice("Chat runtime is already unloaded.")
            return false
        }
        stopRPC()
        addSystemNotice("Chat runtime unloaded. Send a message or press Reconnect to reload it.")
        return true
    }

    func executeBash(_ commandText: String, excludeFromContext: Bool) async -> Bool {
        guard !commandText.isEmpty else {
            addSystemNotice("Usage: `\(excludeFromContext ? "!!" : "!")<command>` or `/\(excludeFromContext ? "hidden-bash" : "bash") <command>`")
            return false
        }
        return await withSlashRPC(onError: {
            isWorking = false
            eventHandler(.activityChanged)
        }) { rpc in
            isWorking = true
            eventHandler(.activityChanged)
            let response = try await rpc.command(["type": "bash", "command": commandText, "excludeFromContext": excludeFromContext])
            isWorking = false
            eventHandler(.activityChanged)
            await refreshState()
            if let data = response["data"] as? [String: Any] {
                let output = data["output"] as? String ?? ""
                let exitCode = data["exitCode"] ?? "?"
                let failed = SessionParser.shellExitFailed(exitCode)
                var result = output
                if data["truncated"] as? Bool == true {
                    result += "\n... output truncated. Full output: \(data["fullOutputPath"] as? String ?? "")"
                }
                if failed { result += "\nExit: \(exitCode)" }
                let tool = userCommandTool(id: UUID().uuidString,
                                           command: commandText,
                                           label: excludeFromContext ? "you · hidden" : "you",
                                           result: result,
                                           status: failed ? .failed : .succeeded)
                messages.append(ChatMessage(role: .system, tools: [tool], timestamp: Date()))
                bottomScrollRequest += 1
            }
            return true
        }
    }

    func refreshSlashCommands() async {
        guard let rpc, rpc.isRunning else { return }
        if let response = try? await rpc.command(["type": "get_commands"]),
           let data = response["data"] as? [String: Any],
           let commandDicts = data["commands"] as? [[String: Any]] {
            guard self.rpc === rpc, !Task.isCancelled else { return }
            slashCommands = commandDicts.compactMap(SlashCommandInfo.fromRPC)
        }
    }

    private func commandHelpMarkdown() -> String {
        let builtin = GUIBuiltinSlashCommands.commands.map { command in
            "- `/\(command.name)` — \(command.description)"
        }.joined(separator: "\n")
        let dynamic = slashCommands.isEmpty ? "No prompt, skill, or extension commands loaded yet." : slashCommands.map { command in
            let hint = command.argumentHint.map { " \($0)" } ?? ""
            let description = command.description.isEmpty ? command.displaySource : "\(command.displaySource): \(command.description)"
            return "- `/\(command.name)`\(hint) — \(description)"
        }.joined(separator: "\n")
        return "**GUI Slash Commands**\n\n\(builtin)\n\n**Prompt Templates, Skills, Extensions**\n\n\(dynamic)\n\nUse `//text` to send a leading slash as a normal message."
    }

    private func parseBoolean(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "on", "true", "yes", "1", "enable", "enabled": return true
        case "off", "false", "no", "0", "disable", "disabled": return false
        default: return nil
        }
    }

    private func userCommandTool(id: String, command: String, label: String, result: String, status: ToolStatus) -> ToolDisplay {
        let arguments = (try? JSONSerialization.data(withJSONObject: ["command": command]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return ToolDisplay(id: id, name: "bash", arguments: arguments, result: result,
                           status: status, isError: status == .failed, userLabel: label)
    }

    private func updateUserCommandTool(messageID: String, result: String, status: ToolStatus) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              !messages[index].tools.isEmpty else { return }
        messages[index].tools[0].result = result
        messages[index].tools[0].status = status
        messages[index].tools[0].isError = status == .failed
    }

    func runCustomAction(_ action: CustomAction) async {
        guard !action.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let messageID = UUID().uuidString
        let tool = userCommandTool(id: messageID,
                                   command: action.command,
                                   label: action.title,
                                   result: "",
                                   status: .running)
        messages.append(ChatMessage(id: messageID, role: .system, tools: [tool], timestamp: Date()))
        bottomScrollRequest += 1

        var streamedOutput = ""
        let exitCode = await LocalShell.stream(command: action.command, in: projectPath) { [weak self] chunk in
            guard let self else { return }
            streamedOutput += chunk
            self.updateUserCommandTool(messageID: messageID, result: streamedOutput.truncatedForChatOutput, status: .running)
        }
        var result = streamedOutput.isEmpty ? "(no output)" : streamedOutput.truncatedForChatOutput
        if exitCode != 0 { result += "\nExit: \(exitCode)" }
        updateUserCommandTool(messageID: messageID, result: result, status: exitCode == 0 ? .succeeded : .failed)
    }

}
