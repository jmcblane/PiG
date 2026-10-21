import Foundation

/// Native API conversation. Polling is authoritative; SSE only improves tool/approval feedback.
@MainActor
final class HermesSession {
    enum Status { case idle, working, waiting }
    enum Event {
        case history([ChatMessage], reply: String?)
        case needsInput(HermesApprovalPrompt)
        case notice(String)
        case failed(String)
        case replyFinished
    }

    var onEvent: ((Event) -> Void)?
    var onState: ((Status, String?, HermesApprovalPrompt?, String?) -> Void)?
    private let api: HermesAPI
    private let chatID: String
    private var journal: HermesJournal
    private var cacheError: String?
    private var status: Status = .idle
    private var tool: String?
    private var prompt: HermesApprovalPrompt?
    private var approvalContext: [String] = []
    private var notice: String?
    private var monitor: Task<Void, Never>?
    private var stream: Task<Void, Never>?
    private var streamingRun: String?
    private var approvalTask: Task<Void, Never>?
    private var busy = false
    private var stopped = false
    private var name = "Conversation"

    init(connection: HermesConnection, chatID: String) {
        api = HermesAPI(connection: connection)
        self.chatID = chatID
        do { journal = try HermesCache.load(chatID) }
        catch { journal = HermesJournal(); cacheError = error.localizedDescription }
    }

    func resume(name: String) {
        self.name = name
        stopped = false
        onEvent?(.history(journal.messages, reply: nil))
        if let cacheError { notice = cacheError; publish(); return }
        status = journal.runID != nil || journal.pending != nil ? .working : .idle
        if let blocked = journal.pending?.recoveryNotice { status = .idle; notice = blocked }
        publish()
        startMonitoring()
    }

    func send(_ text: String, model: String?) async {
        guard cacheError == nil else { onEvent?(.failed(cacheError!)); return }
        // Serialize with polling/admission instead of dropping a send while a GET is in flight.
        while busy && !stopped {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
        }
        guard !stopped, !Task.isCancelled, cacheError == nil else { return }
        guard journal.pending == nil else {
            onEvent?(.notice(journal.pending?.recoveryNotice ?? "The previous Hermes admission is still being recovered with its original idempotency key; it has not been sent again as new work."))
            startMonitoring()
            return
        }
        busy = true
        defer { busy = false; if !stopped { startMonitoring() } }
        do {
            if let runID = journal.runID {
                guard journal.terminalStatus == nil else {
                    onEvent?(.notice("Hermes is recovering the completed reply. Wait before sending again."))
                    return
                }
                // Steering has no documented idempotency guarantee. Cache the attempt first,
                // but never automatically retry it after an ambiguous transport result.
                journal.messages.append(ChatMessage(role: .user, text: text, timestamp: .now))
                try persist()
                onEvent?(.history(journal.messages, reply: nil))
                _ = try await api.request("POST", runPath(runID) + "/steer", body: ["input": text])
            } else {
                // Identify route aliases before freezing the admission body for all retries.
                let aliases = model?.contains("/") == true
                    ? HermesJSON.models(try await api.request("GET", "/v1/models")) : []
                try Task.checkCancellation()
                guard !stopped else { return }
                let fields = HermesJSON.modelFields(model, aliases: aliases)
                journal.pending = HermesAdmission(key: UUID().uuidString, input: text, sessionID: journal.sessionID,
                                                  model: fields["model"] as? String,
                                                  provider: fields["provider"] as? String,
                                                  createdAt: .now)
                journal.messages.append(ChatMessage(role: .user, text: text, timestamp: .now))
                // This must succeed BEFORE any POST. Do not allocate another key after an ambiguous result.
                try persist()
                status = .working
                onEvent?(.history(journal.messages, reply: nil))
                publish()
                try await admit()
            }
            notice = nil
        } catch {
            notice = "Disconnected from Hermes: \(error.localizedDescription) " +
                (journal.pending != nil ? "Admission is saved; recovery uses the same key only within its 24-hour retention window." :
                    journal.runID != nil ? "A steering request may have arrived; it will not be automatically retried." : "No run admission was submitted.")
            onEvent?(.failed(error.localizedDescription))
        }
        publish()
    }

    func abort() async {
        guard !stopped, cacheError == nil else { return }
        guard let runID = journal.runID else {
            if journal.pending != nil {
                notice = journal.pending?.recoveryNotice ?? "Admission is unresolved. Reconnect to recover the run before stopping it."
                publish()
            }
            return
        }
        do { _ = try await api.request("POST", runPath(runID) + "/stop", body: [:]) }
        catch { notice = "Could not confirm Hermes stop: \(error.localizedDescription). Check run status after reconnecting."; publish() }
    }

    func respond(_ id: String, value: String?) {
        guard !stopped, cacheError == nil, approvalTask == nil,
              let runID = journal.runID, prompt?.id == id else { return }
        let choice: String
        switch value {
        case "Allow once", "once": choice = "once"
        case "Deny", "deny": choice = "deny"
        default: return
        }
        approvalTask = Task {
            defer { approvalTask = nil }
            do {
                _ = try await api.request("POST", runPath(runID) + "/approval", body: ["request_id": id, "choice": choice])
                // Only clear the same request; a newer approval may arrive while POST is in flight.
                if prompt?.id == id { prompt = nil; status = .working }
                notice = nil
            } catch { notice = "Hermes approval was not confirmed: \(error.localizedDescription). Reconnect to check whether it is still pending." }
            publish()
        }
    }

    func stop() {
        stopped = true
        monitor?.cancel(); monitor = nil
        stream?.cancel(); stream = nil; streamingRun = nil
        approvalTask?.cancel(); approvalTask = nil
        // Never send /stop on app exit, thread deletion, or transport loss.
    }

    private func persist() throws { try persist(journal) }
    private func persist(_ next: HermesJournal) throws {
        do {
            try HermesCache.save(next, for: chatID)
            journal = next
        }
        catch {
            cacheError = error.localizedDescription
            notice = cacheError
            throw error
        }
    }
    private func publish() {
        guard !stopped else { return }
        onState?(status, tool, prompt, notice)
    }
    private func runPath(_ id: String) -> String { "/v1/runs/" + HermesJSON.identifier(id) }

    private func startMonitoring() {
        guard monitor == nil, !stopped, cacheError == nil else { return }
        monitor = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self, !self.stopped, self.cacheError == nil else { break }
                if self.busy {
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                }
                if let blocked = self.journal.pending?.recoveryNotice {
                    self.status = .idle
                    self.notice = blocked
                    self.publish()
                    // Keep the unresolved input/key. There is no documented lookup-by-key API,
                    // so neither elapsed time nor transcript similarity proves acceptance.
                    try? await Task.sleep(for: .seconds(30))
                    continue
                }
                self.busy = true
                do {
                    if self.journal.pending != nil { try await self.admit() }
                    if let runID = self.journal.runID {
                        if let terminal = self.journal.terminalStatus {
                            // Final transcript recovery must not depend on the run-status record
                            // still being available after restart or a long disconnection.
                            try await self.finishRun(state: terminal)
                        } else {
                            self.startEvents(runID)
                            try await self.poll(runID)
                        }
                    } else {
                        try await self.recoverHistory(reply: false)
                    }
                    failures = 0
                    self.notice = self.status == .waiting && self.prompt == nil
                        ? "Hermes is waiting for approval, but the API has not supplied a request ID. Check the remote session; no approval was sent."
                        : nil
                } catch {
                    if Task.isCancelled { self.busy = false; break }
                    failures += 1
                    self.notice = "Disconnected from Hermes. Reconnecting: \(error.localizedDescription) Cached messages remain available; accepted work is not resent."
                }
                self.busy = false
                self.publish()
                let seconds = failures > 0 ? min(30, 1 << min(failures, 5)) : (self.journal.runID == nil && self.journal.pending == nil ? 15 : 2)
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    private func admit() async throws {
        guard let pending = journal.pending else { return }
        if let blocked = pending.recoveryNotice { throw HermesError.message(blocked) }
        if !journal.sessionReady {
            do {
                _ = try await api.request("POST", "/api/sessions", body: ["id": pending.sessionID,
                    "session_id": pending.sessionID, "title": String(name.prefix(60)) + " · " + pending.sessionID.prefix(8), "source": "api_server"])
            } catch HermesError.http(409) {
                // A lost create response may leave the requested ID already present.
                _ = try await api.request("GET", "/api/sessions/" + HermesJSON.identifier(pending.sessionID) + "/messages?limit=1&offset=0&order=oldest")
            }
            journal.sessionReady = true
            try persist()
        }
        var body: [String: Any] = ["input": pending.input, "session_id": pending.sessionID]
        if let model = pending.model, model != "hermes-agent" { body["model"] = model }
        if let provider = pending.provider { body["provider"] = provider }
        // Session creation and tunnel setup may have consumed the remaining retention time.
        if let blocked = pending.recoveryNotice { throw HermesError.message(blocked) }
        let response = HermesJSON.object(try await api.request("POST", "/v1/runs", body: body, idempotencyKey: pending.key,
                                                              expiresAt: pending.createdAt?.addingTimeInterval(86_400)))
        let run = response["run"] as? [String: Any] ?? response
        guard let id = run["run_id"] as? String ?? run["id"] as? String, !id.isEmpty else {
            throw HermesError.message("Hermes admission returned no run ID. The original admission key is retained for safe recovery.")
        }
        journal.runID = id
        if let sessionID = run["session_id"] as? String { rotateSession(to: sessionID) }
        journal.pending = nil
        journal.terminalStatus = nil
        try persist()
        status = .working
    }

    private func poll(_ runID: String) async throws {
        let response = HermesJSON.object(try await api.request("GET", runPath(runID)))
        let run = response["run"] as? [String: Any] ?? response
        if let sessionID = run["session_id"] as? String, !sessionID.isEmpty, sessionID != journal.sessionID {
            rotateSession(to: sessionID)
            try persist()
        }
        let state = (run["status"] as? String ?? "").lowercased()
        processFeedback(run)
        if ["running", "working", "queued", "in_progress"].contains(state), approval(in: run) == nil {
            // The native API removes approval entirely once the run is running again.
            prompt = nil
        }
        let terminal = ["completed", "complete", "succeeded", "success", "done", "failed", "error", "cancelled", "canceled", "stopped", "aborted"].contains(state)
        if terminal {
            journal.terminalStatus = state
            try persist()
            try await finishRun(state: state)
        } else if prompt == nil {
            status = ["waiting", "waiting_for_approval", "awaiting_approval", "needs_approval"].contains(state) ? .waiting : .working
        }
    }

    private func finishRun(state: String) async throws {
        stream?.cancel(); stream = nil; streamingRun = nil
        prompt = nil; tool = nil; status = .working
        let reply = try await recoverHistory(reply: true)
        journal.runID = nil
        journal.terminalStatus = nil
        try persist()
        status = .idle
        publish()
        if reply != nil { onEvent?(.replyFinished) }
        if ["failed", "error"].contains(state) { onEvent?(.notice("Hermes run failed. Its available history has been recovered.")) }
        if ["stopped", "aborted", "cancelled", "canceled"].contains(state) { onEvent?(.notice("Hermes run stopped. Its available history has been recovered.")) }
    }

    private func startEvents(_ runID: String) {
        guard streamingRun != runID, !stopped else { return }
        stream?.cancel()
        streamingRun = runID
        stream = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.journal.runID == runID {
                do {
                    try await self.api.events(self.runPath(runID) + "/events") { [weak self] event in
                        guard let self, !self.stopped, self.journal.runID == runID else { return }
                        self.processFeedback(event)
                        self.publish()
                    }
                } catch { /* Polling remains authoritative on older servers and stream loss. */ }
                if Task.isCancelled { break }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func processFeedback(_ event: [String: Any]) {
        let payload = event["data"] as? [String: Any] ?? event
        let type = (event["type"] as? String ?? event["event"] as? String ?? payload["type"] as? String ?? "").lowercased()
        if type.contains("tool") && (type.contains("start") || type.contains("call")) {
            tool = payload["tool"] as? String ?? payload["tool_name"] as? String
                ?? payload["toolName"] as? String ?? payload["name"] as? String
        }
        if type.contains("tool") && (type.contains("end") || type.contains("result") || type.contains("complete")) { tool = nil }
        if let current = payload["current_tool"] as? String { tool = current }
        if type.contains("approval") && ["resolved", "response", "decision", "granted", "denied"].contains(where: { type.contains($0) }) {
            let id = payload["request_id"] as? String
            if id == nil || id == prompt?.id { prompt = nil; status = .working }
            return
        }
        let approval = approval(in: payload)
            ?? (type.contains("approval") && !type.contains("resolved") ? payload : nil)
        guard let approval,
              let id = approval["request_id"] as? String ?? approval["id"] as? String,
              !id.isEmpty else { return }
        // A status envelope may contain less context than the preceding SSE request.
        var context = prompt?.id == id ? approvalContext : []
        for key in ["title", "description", "message", "reason"] {
            if let text = approval[key] as? String, !text.isEmpty, !context.contains(text) { context.append(text) }
        }
        if let command = approval["command"] as? String, !command.isEmpty {
            let detail = "Command: " + command
            if !context.contains(detail) { context.append(detail) }
        }
        approvalContext = context
        let title = context.isEmpty ? "Hermes requests approval (no command or reason supplied)." : context.joined(separator: "\n")
        let p = HermesApprovalPrompt(id: id, title: title)
        let changed = prompt?.id != id || prompt?.title != title
        prompt = p; status = .waiting; notice = nil
        if changed { onEvent?(.needsInput(p)) }
    }

    private func approval(in payload: [String: Any]) -> [String: Any]? {
        payload["pending_approval"] as? [String: Any]
            ?? payload["approval_request"] as? [String: Any]
            ?? payload["approval"] as? [String: Any]
            ?? (payload["pending_approvals"] as? [[String: Any]])?.first
    }

    @discardableResult
    private func recoverHistory(reply: Bool) async throws -> String? {
        guard journal.sessionReady else { return nil }
        let history = try await api.history(journal.sessionID)
        var next = journal
        if history.sessionID != next.sessionID {
            next.historyPrefix = next.messages
            next.historyKeys = []
            next.sessionID = history.sessionID
        }
        // Filter across page boundaries: only the last assistant text between users is mail.
        var visible: [(Int, [String: Any])] = []
        var lastAssistant: (Int, [String: Any])?
        for (index, row) in history.rows.enumerated() {
            let role = row["role"] as? String ?? ""
            if role == "user" {
                if let lastAssistant { visible.append(lastAssistant) }
                lastAssistant = nil
                visible.append((index, row))
            } else if role == "assistant" {
                let hasCalls = !(row["tool_calls"] as? [Any] ?? []).isEmpty
                let hasFunction = row["function_call"] != nil && !(row["function_call"] is NSNull)
                if hasCalls || hasFunction || row["finish_reason"] as? String == "tool_calls" {
                    lastAssistant = nil
                } else if !HermesJSON.text(row["content"] ?? row["text"]).isEmpty {
                    lastAssistant = (index, row)
                }
            } else if role == "tool" || role == "function" {
                lastAssistant = nil
            }
        }
        if let lastAssistant { visible.append(lastAssistant) }

        let oldMessages = next.messages.dropFirst(next.historyPrefix?.count ?? 0)
        let oldByKey = Dictionary(zip(next.historyKeys, oldMessages), uniquingKeysWith: { first, _ in first })
        var previousKeys = Set(next.historyKeys)
        var recovered: [ChatMessage] = []
        var keys: [String] = []
        for (index, row) in visible {
            let role = row["role"] as? String ?? ""
            let text = HermesJSON.text(row["content"] ?? row["text"])
            guard !text.isEmpty, let key = HermesJSON.messageID(row["id"]) else { continue }
            // Migrate earlier caches that used a content/index fallback for integer IDs.
            let legacyKey = "\(index):\(role):\(text)"
            let old = oldByKey[key] ?? oldByKey[legacyKey]
            if old != nil { previousKeys.insert(key) }
            let time = Self.timestamp(row["timestamp"] ?? row["created_at"]) ?? old?.timestamp ?? .now
            recovered.append(ChatMessage(id: old?.id ?? UUID().uuidString, role: role == "user" ? .user : .assistant, text: text, timestamp: time))
            keys.append(key)
        }
        // Never erase the offline cache when a fresh endpoint returns an unexpectedly empty history.
        let succeeded = ["completed", "complete", "succeeded", "success", "done"].contains(journal.terminalStatus ?? "")
        if recovered.isEmpty && !journal.messages.isEmpty {
            if reply && succeeded { throw HermesError.message("Hermes final history is not available yet; the completed run is retained for recovery.") }
            return nil
        }
        if reply, succeeded,
           recovered.last?.role != .assistant {
            throw HermesError.message("Hermes final reply has not appeared in history yet. The run ID is retained for recovery.")
        }
        var prefix = next.historyPrefix ?? []
        var overlap = 0
        if next.historyKeys.isEmpty && !prefix.isEmpty {
            // Rotated sessions can carry a suffix of the old transcript. Keep it once.
            for count in stride(from: min(prefix.count, recovered.count), through: 1, by: -1) {
                if zip(prefix.suffix(count), recovered.prefix(count)).allSatisfy({ $0.role == $1.role && $0.text == $1.text }) {
                    overlap = count
                    prefix.removeLast(count)
                    break
                }
            }
        }
        let newReply = reply ? Array(zip(keys, recovered)).dropFirst(overlap).last(where: { !previousKeys.contains($0.0) && $0.1.role == .assistant })?.1.text : nil
        if reply && succeeded && newReply == nil && journal.recoveredRunID != journal.runID {
            throw HermesError.message("Hermes has completed, but its new reply is not in history yet. Recovery will retry without resending the run.")
        }
        if reply { next.recoveredRunID = next.runID }
        next.historyPrefix = prefix.isEmpty ? nil : prefix
        next.messages = prefix + recovered
        next.historyKeys = keys
        try Task.checkCancellation()
        try persist(next)
        onEvent?(.history(journal.messages, reply: newReply))
        return newReply
    }

    private func rotateSession(to id: String) {
        guard !id.isEmpty, id != journal.sessionID else { return }
        journal.historyPrefix = journal.messages
        journal.historyKeys = []
        journal.sessionID = id
    }

    private static func timestamp(_ value: Any?) -> Date? {
        if let string = value as? String {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions.insert(.withFractionalSeconds)
            return formatter.date(from: string)
        }
        if let seconds = value as? Double { return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds) }
        return nil
    }
}
