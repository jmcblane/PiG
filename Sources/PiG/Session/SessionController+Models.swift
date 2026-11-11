import Foundation

extension SessionController {
    func handleModelSlash(_ args: String) async -> Bool {
        await withSlashRPC { rpc in
            if args.isEmpty {
                let current = selectedModelID.isEmpty ? "none" : selectedModelID
                let list = models.map { "- `\($0.displayName)`" }.joined(separator: "\n")
                addSystemNotice("Current model: `\(current)`\n\n\(list.isEmpty ? "No models loaded." : list)")
                return true
            }
            let needle = args.lowercased()
            let exact = models.first { model in
                [model.id, model.displayName, model.modelId, model.name].contains { $0.lowercased() == needle }
            }
            let match = exact ?? models.first { model in
                [model.id, model.displayName, model.modelId, model.name].contains { $0.lowercased().contains(needle) }
            }
            guard let model = match else {
                addSystemNotice("Model not found: `\(args)`")
                return false
            }
            selectedModelID = model.id
            _ = try await rpc.command(["type": "set_model", "provider": model.provider, "modelId": model.modelId])
            await refreshState()
            addSystemNotice("Model set: `\(model.displayName)`")
            return true
        }
    }

    func handleCycleModelSlash() async -> Bool {
        await withSlashRPC { rpc in
            let response = try await rpc.command(["type": "cycle_model"])
            if let data = response["data"] as? [String: Any], let modelDict = data["model"] as? [String: Any], let model = ModelInfo.from(modelDict) {
                selectedModelID = model.id
                if !models.contains(model) { models.append(model) }
                addSystemNotice("Model set: `\(model.displayName)`")
            } else {
                addSystemNotice("No alternate model available.")
            }
            await refreshState()
            return true
        }
    }

    func handleThinkingSlash(_ args: String) async -> Bool {
        let levels = availableThinkingLevels
        if args.isEmpty {
            addSystemNotice("Thinking level: `\(thinkingLevel)`\n\nLevels: `\(levels.joined(separator: "`, `"))`")
            return true
        }
        guard levels.contains(args) else {
            addSystemNotice("Unknown thinking level: `\(args)`\n\nLevels: `\(levels.joined(separator: "`, `"))`")
            return false
        }
        guard await applyThinkingLevel(args) else { return false }
        addSystemNotice("Thinking level set: `\(args)`")
        return true
    }

    func handleCycleThinkingSlash() async -> Bool {
        await withSlashRPC { rpc in
            let response = try await rpc.command(["type": "cycle_thinking_level"])
            if let data = response["data"] as? [String: Any], let level = data["level"] as? String {
                thinkingLevel = level
                addSystemNotice("Thinking level set: `\(level)`")
            } else {
                addSystemNotice("Current model does not expose thinking levels.")
            }
            await refreshState()
            return true
        }
    }

    func refreshNewSessionDefaults() {
        guard createdAsNewSession || agentID != nil, sessionPath == nil,
              messages.isEmpty || (agentID != nil && messages.allSatisfy { $0.role == .system }), !isProcessActive else { return }
        if !hasExplicitModelSelection { selectedModelID = agentConfiguration?()?.modelID ?? DefaultModelSchedule.effectiveModelID() ?? "" }
        if !hasExplicitThinkingSelection { thinkingLevel = agentConfiguration?()?.thinking ?? GlobalThinkingSelection.level }
    }

    func setModel(_ id: String) {
        hasExplicitModelSelection = true
        selectedModelID = id
        guard let model = models.first(where: { $0.id == id }) else { return }
        guard isProcessActive || sessionPath != nil else { return }
        Task {
            do {
                try await ensureRPC()
                _ = try await rpc?.command(["type": "set_model", "provider": model.provider, "modelId": model.modelId])
                await refreshState()
            } catch { errorText = error.localizedDescription }
        }
    }

    func setThinkingLevel(_ level: String) {
        hasExplicitThinkingSelection = true
        thinkingLevel = level
        Task { _ = await applyThinkingLevel(level, updateSelection: false) }
    }

    private func applyThinkingLevel(_ level: String, updateSelection: Bool = true) async -> Bool {
        if updateSelection { thinkingLevel = level }
        guard isProcessActive || sessionPath != nil else { return true }
        do {
            try await ensureRPC()
            _ = try await rpc?.command(["type": "set_thinking_level", "level": level])
            await refreshState()
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    func applyAgentChatDefaults(using client: PiRPCClient) async throws {
        let preferredID = agentConfiguration?()?.modelID ?? DefaultModelSchedule.effectiveModelID() ?? ""
        guard let model = models.first(where: { $0.id == preferredID }) else {
            throw PiRPCClient.RPCError.commandFailed("The agent's default model is unavailable. Choose a model in the composer.")
        }
        _ = try await client.command(["type": "set_model", "provider": model.provider, "modelId": model.modelId])
        selectedModelID = model.id
        thinkingLevel = agentConfiguration?()?.thinking ?? GlobalThinkingSelection.level
        _ = try await client.command(["type": "set_thinking_level", "level": thinkingLevel])
    }

    func loadConfiguredModels() async {
        let configured = await ModelCatalog.configuredModelsAsync(projectPath: projectPath)
        guard models.isEmpty, !configured.isEmpty else { return }
        models = configured
        guard createdAsNewSession, selectedModelID.isEmpty else { return }
        selectedModelID = DefaultModelSchedule.effectiveModelID() ?? ""
    }

}
