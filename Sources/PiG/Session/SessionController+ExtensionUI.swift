import Foundation

extension SessionController {
    func respondToExtensionPrompt(_ id: String, value: String) {
        completeExtensionPrompt(id, payload: ["value": value])
    }

    func respondToExtensionConfirmation(_ id: String, confirmed: Bool) {
        completeExtensionPrompt(id, payload: ["confirmed": confirmed])
    }

    func cancelExtensionPrompt(_ id: String) {
        completeExtensionPrompt(id, payload: ["cancelled": true])
    }

    func dismissExtensionNotification(_ id: String) {
        extensionUINotifications.removeAll { $0.id == id }
        eventHandler(.extensionUIChanged)
    }

    private func completeExtensionPrompt(_ id: String, payload: [String: Any]) {
        guard extensionUIPrompt?.id == id else { return }
        extensionUITimeoutTasks.removeValue(forKey: id)?.cancel()
        var response = payload
        response["type"] = "extension_ui_response"
        response["id"] = id
        try? rpc?.notify(response)
        extensionUIPrompt = nil
        showNextExtensionPrompt()
        eventHandler(.extensionUIChanged)
    }

    func handleExtensionUIRequest(_ request: [String: Any]) {
        guard let id = request["id"] as? String,
              let method = request["method"] as? String else { return }
        let clean: (String) -> String = { $0.strippingTerminalControlSequences }
        let title = clean(request["title"] as? String ?? "Extension Request")
        let timeout = (request["timeout"] as? NSNumber).map { $0.doubleValue / 1_000 }

        switch method {
        case "select":
            enqueueExtensionPrompt(ExtensionUIPrompt(
                id: id,
                title: title,
                kind: .select((request["options"] as? [String] ?? []).map(clean)),
                initialValue: "",
                timeout: timeout
            ))
        case "confirm":
            enqueueExtensionPrompt(ExtensionUIPrompt(
                id: id,
                title: title,
                kind: .confirm(message: (request["message"] as? String).map(clean)),
                initialValue: "",
                timeout: timeout
            ))
        case "input":
            enqueueExtensionPrompt(ExtensionUIPrompt(
                id: id,
                title: title,
                kind: .input(placeholder: (request["placeholder"] as? String).map(clean)),
                initialValue: "",
                timeout: timeout
            ))
        case "editor":
            enqueueExtensionPrompt(ExtensionUIPrompt(
                id: id,
                title: title,
                kind: .editor,
                initialValue: clean(request["prefill"] as? String ?? ""),
                timeout: timeout
            ))
        case "notify":
            let kind = ExtensionUINotification.Kind(rawValue: request["notifyType"] as? String ?? "info") ?? .info
            let message = clean(request["message"] as? String ?? "")
            guard !message.isEmpty else { return }
            let signature = "\(kind.rawValue):\(message)"
            let now = Date()
            recentExtensionNotices = recentExtensionNotices.filter { now.timeIntervalSince($0.value) < 30 }
            guard recentExtensionNotices[signature] == nil,
                  !extensionUINotifications.contains(where: { $0.message == message && $0.kind == kind }) else { return }
            recentExtensionNotices[signature] = now
            extensionUINotifications.removeAll { $0.id == id }
            extensionUINotifications.append(ExtensionUINotification(id: id, message: message, kind: kind))
            // Bounded pending queue: expiry is owned by the toast UI, so
            // drop the oldest here to stop hidden items accumulating.
            if extensionUINotifications.count > ExtensionUINotification.maxPending {
                extensionUINotifications.removeFirst(extensionUINotifications.count - ExtensionUINotification.maxPending)
            }
            eventHandler(.extensionUIChanged)
            // Expiry is owned by ExtensionNotificationsView (auto-dismiss
            // toast) so hovering/keyboard focus can pause it.
        case "setStatus":
            guard let key = request["statusKey"] as? String else { return }
            if key == "pig:claude-usage" {
                claudeBridgeUsageHeaders = request["statusText"] as? String
                return
            }
            if let text = request["statusText"] as? String, !text.isEmpty {
                extensionUIStatuses[key] = clean(text)
            } else {
                extensionUIStatuses.removeValue(forKey: key)
            }
            eventHandler(.extensionUIChanged)
        case "setWidget":
            guard let key = request["widgetKey"] as? String else { return }
            if let lines = request["widgetLines"] as? [String] {
                let placement = ExtensionUIWidget.Placement(rawValue: request["widgetPlacement"] as? String ?? "aboveEditor") ?? .aboveEditor
                extensionUIWidgets[key] = ExtensionUIWidget(key: key, lines: lines.map(clean), placement: placement)
            } else {
                extensionUIWidgets.removeValue(forKey: key)
            }
            eventHandler(.extensionUIChanged)
        case "setTitle":
            extensionWindowTitle = (request["title"] as? String).map(clean)?.nonEmptyTrimmed
            eventHandler(.extensionUIChanged)
        case "set_editor_text":
            composerPrefillRequest = ComposerPrefillRequest(text: clean(request["text"] as? String ?? ""))
            eventHandler(.extensionUIChanged)
        default:
            try? rpc?.notify([
                "type": "extension_ui_response",
                "id": id,
                "cancelled": true
            ])
            eventHandler(.log("Unsupported extension UI method: \(method)"))
        }
    }

    private func enqueueExtensionPrompt(_ prompt: ExtensionUIPrompt) {
        guard extensionUIPrompt?.id != prompt.id,
              !extensionUIPromptQueue.contains(where: { $0.id == prompt.id }) else { return }
        if extensionUIPrompt == nil {
            extensionUIPrompt = prompt
        } else {
            extensionUIPromptQueue.append(prompt)
        }
        if let timeout = prompt.timeout, timeout > 0 {
            extensionUITimeoutTasks[prompt.id] = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                } catch {
                    return
                }
                self?.expireExtensionPrompt(prompt.id)
            }
        }
        eventHandler(.extensionUIChanged)
    }

    private func expireExtensionPrompt(_ id: String) {
        extensionUITimeoutTasks.removeValue(forKey: id)
        if extensionUIPrompt?.id == id {
            extensionUIPrompt = nil
            showNextExtensionPrompt()
        } else {
            extensionUIPromptQueue.removeAll { $0.id == id }
        }
        eventHandler(.extensionUIChanged)
    }

    private func showNextExtensionPrompt() {
        while !extensionUIPromptQueue.isEmpty {
            let next = extensionUIPromptQueue.removeFirst()
            if extensionUITimeoutTasks[next.id] != nil || next.timeout == nil {
                extensionUIPrompt = next
                return
            }
        }
    }

    func clearExtensionUIRuntimeState() {
        for task in extensionUITimeoutTasks.values { task.cancel() }
        extensionUITimeoutTasks.removeAll()
        extensionUIPromptQueue.removeAll()
        extensionUIPrompt = nil
        extensionUIStatuses.removeAll()
        claudeBridgeUsageHeaders = nil
        extensionUIWidgets.removeAll()
        extensionWindowTitle = nil
        eventHandler(.extensionUIChanged)
    }

}
