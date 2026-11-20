import Foundation
import Darwin

private struct ACPSendableValue<Value>: @unchecked Sendable {
    var value: Value
}

private final class ACPOutputDecoder: @unchecked Sendable {
    struct DecodedLine: @unchecked Sendable {
        var text: String
        var dictionary: [String: Any]?
    }

    private let queue = DispatchQueue(label: "ACPClient.stdout.decode", qos: .userInitiated)
    private var buffer = Data()

    func append(_ data: Data, onLine: @escaping @Sendable (DecodedLine) -> Void) {
        queue.async { [self] in
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newline]
                buffer.removeSubrange(...newline)
                var line = String(data: lineData, encoding: .utf8) ?? ""
                if line.hasSuffix("\r") { line.removeLast() }
                guard !line.isEmpty else { continue }
                let dict = line.data(using: .utf8)
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                onLine(DecodedLine(text: line, dictionary: dict))
            }
        }
    }
}

/// Standard ACP v1 bidirectional JSON-RPC 2.0 client over stdio.
@MainActor
final class ACPClient {
    enum ACPError: Error, LocalizedError {
        case notRunning
        case executableMissing(String)
        case launchFailed(String)
        case invalidPayload
        case sessionLoadUnsupported
        case modeUnavailable(String)
        case settingUnconfirmed(String, String)
        case rpcError(code: Int, message: String)
        case authRequired(String)
        case timedOut(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notRunning: return "ACP process is not running."
            case .executableMissing(let path): return "ACP executable not found at \(path)."
            case .launchFailed(let message): return message
            case .invalidPayload: return "Invalid ACP JSON-RPC payload."
            case .sessionLoadUnsupported: return "This ACP agent cannot load saved sessions."
            case .modeUnavailable(let mode): return "Permission mode ‘\(mode)’ is unavailable. Choose another mode before sending."
            case .settingUnconfirmed(let setting, let value): return "Antigravity did not confirm \(setting) ‘\(value)’."
            case .rpcError(_, let message): return message
            case .authRequired(let message): return message.isEmpty ? "Authentication required. Log in to Antigravity to continue." : message
            case .timedOut(let method): return "ACP \(method) request timed out."
            case .writeFailed(let message): return "Failed to write to ACP process: \(message)"
            }
        }

        var isAuthRequired: Bool {
            if case .authRequired = self { return true }
            if case .rpcError(let code, _) = self, code == -32000 { return true }
            return false
        }
    }

    private struct PendingRequest {
        let continuation: CheckedContinuation<[String: Any], Error>
        let timeoutTask: Task<Void, Never>?
    }

    let config: ACPServerConfig
    let workingDirectory: String

    private var process: Process?
    private var stdin: Pipe?
    private var outputDecoder: ACPOutputDecoder?
    private var writeQueue = DispatchQueue(label: "ACPClient.stdin.write")
    private var pendingRequests: [String: PendingRequest] = [:]
    private var nextRequestID = 1
    private var connectionGeneration = 0
    private var stoppingProcesses: [ObjectIdentifier: Process] = [:]
    private var terminationFallbackTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let terminationGraceNanoseconds: UInt64 = 2_000_000_000

    var onNotification: ((_ method: String, _ params: [String: Any]) -> Void)?
    var onRequest: ((_ id: ACPJSONID, _ method: String, _ params: [String: Any]) -> Void)?
    var onLog: ((String) -> Void)?
    var onTermination: ((Int32) -> Void)?

    var isRunning: Bool { process?.isRunning == true }

    init(config: ACPServerConfig = .antigravity(), workingDirectory: String) {
        self.config = config
        self.workingDirectory = workingDirectory
    }

    func start() async throws {
        try Task.checkCancellation()
        if isRunning { return }
        guard FileManager.default.isExecutableFile(atPath: config.executableURL.path) else {
            throw ACPError.executableMissing(config.executableURL.path)
        }
        connectionGeneration &+= 1
        let generation = connectionGeneration
        let environment = await PiEnvironment.mergedAsync()
        try Task.checkCancellation()
        guard connectionGeneration == generation else { throw ACPError.notRunning }

        let proc = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        proc.executableURL = config.executableURL
        proc.arguments = config.arguments
        proc.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        proc.standardInput = input
        proc.standardOutput = output
        proc.standardError = error
        proc.environment = environment

        let decoder = ACPOutputDecoder()
        output.fileHandleForReading.readabilityHandler = { [weak self, weak proc] handle in
            let data = handle.availableData
            guard !data.isEmpty, let proc else { return }
            decoder.append(data) { [weak self] decoded in
                DispatchQueue.main.async {
                    guard let self, self.isCurrentConnection(proc, generation: generation) else { return }
                    self.handleLine(decoded)
                }
            }
        }
        error.fileHandleForReading.readabilityHandler = { [weak self, weak proc] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let proc,
                  let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }
            Task { @MainActor in
                guard let self, self.isCurrentConnection(proc, generation: generation) else { return }
                self.onLog?(text)
            }
        }
        proc.terminationHandler = { [weak self] terminated in
            Task { @MainActor in
                self?.handleProcessTermination(terminated, generation: generation)
            }
        }

        process = proc
        stdin = input
        outputDecoder = decoder
        writeQueue = DispatchQueue(label: "ACPClient.stdin.write.\(generation)")

        do {
            try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try proc.run()
                }.value
                try Task.checkCancellation()
            } onCancel: { [weak self] in
                Task { @MainActor in
                    guard let self, self.connectionGeneration == generation else { return }
                    self.stop()
                }
            }
            guard isCurrentConnection(proc, generation: generation), proc.isRunning else {
                requestTermination(of: proc)
                throw ACPError.notRunning
            }
        } catch {
            requestTermination(of: proc)
            if isCurrentConnection(proc, generation: generation) {
                stdin = nil
                process = nil
                outputDecoder = nil
                failAll(error)
            }
            if error is CancellationError || error is ACPError { throw error }
            throw ACPError.launchFailed("Failed to launch \(config.name) ACP: \(error.localizedDescription)")
        }
    }

    func stop() {
        connectionGeneration &+= 1
        outputDecoder = nil
        let input = stdin
        stdin = nil
        let proc = process
        process = nil
        if let proc { requestTermination(of: proc) }
        writeQueue.async { try? input?.fileHandleForWriting.close() }
        failAll(ACPError.notRunning)
    }

    func request(method: String, params: [String: Any] = [:], timeout: TimeInterval? = 30, beforeQueue: (() throws -> Void)? = nil, onQueued: (() -> Void)? = nil) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard isRunning, let stdin else { throw ACPError.notRunning }

        let idInt = nextRequestID
        nextRequestID += 1
        let idKey = ACPJSONID.int(idInt).key
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": idInt,
            "method": method,
            "params": params
        ]
        let sendable = ACPSendableValue(value: payload)
        let data = try await Task.detached(priority: .userInitiated) {
            guard JSONSerialization.isValidJSONObject(sendable.value) else { throw ACPError.invalidPayload }
            return try JSONSerialization.data(withJSONObject: sendable.value)
        }.value

        guard isRunning, self.stdin === stdin else { throw ACPError.notRunning }
        var line = String(data: data, encoding: .utf8) ?? "{}"
        line.append("\n")
        let generation = connectionGeneration

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try Task.checkCancellation()
                    guard isRunning, self.stdin === stdin else { throw ACPError.notRunning }
                    try beforeQueue?()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let timeoutTask = makeTimeoutTask(forKey: idKey, method: method, timeout: timeout)
                pendingRequests[idKey] = PendingRequest(continuation: continuation, timeoutTask: timeoutTask)
                writeLine(line, to: stdin, generation: generation)
                onQueued?()
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.completeRequest(idKey, throwing: CancellationError()) }
        })
    }

    func notify(method: String, params: [String: Any] = [:]) throws {
        guard isRunning, let stdin else { throw ACPError.notRunning }
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ]
        guard JSONSerialization.isValidJSONObject(payload) else { throw ACPError.invalidPayload }
        let data = try JSONSerialization.data(withJSONObject: payload)
        var line = String(data: data, encoding: .utf8) ?? "{}"
        line.append("\n")
        writeLine(line, to: stdin, generation: connectionGeneration)
    }

    func respond(id: ACPJSONID, result: [String: Any]) throws {
        guard isRunning, let stdin else { throw ACPError.notRunning }
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id.jsonValue,
            "result": result
        ]
        guard JSONSerialization.isValidJSONObject(payload) else { throw ACPError.invalidPayload }
        let data = try JSONSerialization.data(withJSONObject: payload)
        var line = String(data: data, encoding: .utf8) ?? "{}"
        line.append("\n")
        writeLine(line, to: stdin, generation: connectionGeneration)
    }

    func respondError(id: ACPJSONID, code: Int, message: String) throws {
        guard isRunning, let stdin else { throw ACPError.notRunning }
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id.jsonValue,
            "error": [
                "code": code,
                "message": message
            ]
        ]
        guard JSONSerialization.isValidJSONObject(payload) else { throw ACPError.invalidPayload }
        let data = try JSONSerialization.data(withJSONObject: payload)
        var line = String(data: data, encoding: .utf8) ?? "{}"
        line.append("\n")
        writeLine(line, to: stdin, generation: connectionGeneration)
    }

    // MARK: - High-level ACP v1 methods

    func initialize(clientVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0") async throws -> ACPInitializeResult {
        let result = try await request(
            method: "initialize",
            params: [
                "protocolVersion": 1,
                "clientCapabilities": [:],
                "clientInfo": [
                    "name": "pig",
                    "title": "PiG",
                    "version": clientVersion
                ]
            ],
            timeout: 20
        )

        let version = result["protocolVersion"] as? Int ?? 1
        let agentInfo = result["agentInfo"] as? [String: Any] ?? [:]
        let agentName = agentInfo["name"] as? String ?? config.name
        let agentVersion = agentInfo["version"] as? String

        let capsDict = result["agentCapabilities"] as? [String: Any] ?? [:]
        let promptCaps = capsDict["promptCapabilities"] as? [String: Any] ?? [:]
        let sessionCaps = (capsDict["sessionCapabilities"] as? [String: Any])
            ?? (capsDict["session_capabilities"] as? [String: Any])
            ?? [:]
        let meta = capsDict["_meta"] as? [String: Any] ?? [:]
        let agyMeta = meta["antigravity"] as? [String: Any] ?? [:]
        let sysPromptMeta = agyMeta["systemPrompt"] as? [String: Any] ?? [:]

        let capabilities = ACPAgentCapabilities(
            loadSession: (capsDict["loadSession"] as? Bool) ?? (capsDict["load_session"] as? Bool) ?? (sessionCaps["load"] != nil),
            listSessions: sessionCaps["list"] != nil,
            closeSession: sessionCaps["close"] != nil,
            resumeSession: sessionCaps["resume"] != nil,
            supportsImages: promptCaps["image"] as? Bool ?? false,
            supportsEmbeddedContext: promptCaps["embeddedContext"] as? Bool ?? false,
            supportsAntigravitySystemPromptAppend: sysPromptMeta["append"] as? Bool ?? false
        )

        let authMethods = (result["authMethods"] as? [[String: Any]] ?? []).compactMap { item -> ACPAuthMethod? in
            guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
            return ACPAuthMethod(id: id, name: name, description: item["description"] as? String)
        }

        return ACPInitializeResult(
            protocolVersion: version,
            agentName: agentName,
            agentVersion: agentVersion,
            capabilities: capabilities,
            authMethods: authMethods
        )
    }

    func newSession(cwd: String, mcpServers: [[String: Any]], meta: [String: Any]? = nil) async throws -> [String: Any] {
        var params: [String: Any] = [
            "cwd": cwd,
            "mcpServers": mcpServers
        ]
        if let meta { params["_meta"] = meta }
        return try await request(method: "session/new", params: params, timeout: 30)
    }

    func loadSession(sessionID: String, cwd: String, mcpServers: [[String: Any]]) async throws -> [String: Any] {
        try await request(
            method: "session/load",
            params: [
                "sessionId": sessionID,
                "cwd": cwd,
                "mcpServers": mcpServers
            ],
            timeout: 45
        )
    }

    func listSessions(cwd: String? = nil) async throws -> [ACPSessionSummary] {
        var params: [String: Any] = [:]
        if let cwd { params["cwd"] = cwd }
        let result = try await request(method: "session/list", params: params, timeout: 20)
        let list = result["sessions"] as? [[String: Any]] ?? []
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        return list.compactMap { item -> ACPSessionSummary? in
            guard let sessionID = item["sessionId"] as? String else { return nil }
            let itemCWD = item["cwd"] as? String ?? cwd ?? ""
            let title = (item["title"] as? String)?.nonEmptyTrimmed ?? "Untitled"
            let updated = (item["updatedAt"] as? String).flatMap {
                formatter.date(from: $0) ?? fallbackFormatter.date(from: $0)
            }
            return ACPSessionSummary(sessionID: sessionID, cwd: itemCWD, title: title, updatedAt: updated)
        }
    }

    func closeSession(sessionID: String) async throws {
        _ = try await request(method: "session/close", params: ["sessionId": sessionID], timeout: 10)
    }

    func prompt(sessionID: String, blocks: [[String: Any]], beforeQueue: @escaping () throws -> Void, onQueued: @escaping () -> Void) async throws -> [String: Any] {
        // Prompt requests remain open for the full turn; cancellation is done via `session/cancel`.
        try await request(
            method: "session/prompt",
            params: [
                "sessionId": sessionID,
                "prompt": blocks
            ],
            timeout: nil,
            beforeQueue: beforeQueue,
            onQueued: onQueued
        )
    }

    func cancel(sessionID: String) throws {
        try notify(method: "session/cancel", params: ["sessionId": sessionID])
    }

    func setConfigOption(sessionID: String, configID: String, value: String) async throws -> [String: Any] {
        try await request(
            method: "session/set_config_option",
            params: [
                "sessionId": sessionID,
                "configId": configID,
                "value": value
            ],
            timeout: 15
        )
    }

    func setMode(sessionID: String, modeID: String) async throws -> [String: Any] {
        try await request(
            method: "session/set_mode",
            params: [
                "sessionId": sessionID,
                "modeId": modeID
            ],
            timeout: 15
        )
    }

    // MARK: - Line handling & process lifecycle

    private func handleLine(_ decoded: ACPOutputDecoder.DecodedLine) {
        guard let dict = decoded.dictionary else {
            onLog?(decoded.text)
            return
        }

        let method = dict["method"] as? String
        let jsonID = ACPJSONID(dict["id"])

        if method == nil, let jsonID {
            if let errorDict = dict["error"] as? [String: Any] {
                let code = errorDict["code"] as? Int ?? -1
                let message = errorDict["message"] as? String ?? "ACP request failed"
                if code == -32000 {
                    completeRequest(jsonID.key, throwing: ACPError.authRequired(message))
                } else {
                    completeRequest(jsonID.key, throwing: ACPError.rpcError(code: code, message: message))
                }
            } else {
                let result = dict["result"] as? [String: Any] ?? [:]
                completeRequest(jsonID.key, returning: result)
            }
            return
        }

        if let method, let jsonID {
            let params = dict["params"] as? [String: Any] ?? [:]
            onRequest?(jsonID, method, params)
            return
        }

        if let method {
            let params = dict["params"] as? [String: Any] ?? [:]
            onNotification?(method, params)
            return
        }

        onLog?(decoded.text)
    }

    private func writeLine(_ line: String, to pipe: Pipe, generation: Int) {
        let data = Data(line.utf8)
        let handle = pipe.fileHandleForWriting
        let queue = writeQueue
        queue.async { [weak self, weak pipe] in
            do {
                try handle.write(contentsOf: data)
            } catch {
                Task { @MainActor in
                    guard let self, let pipe else { return }
                    self.handleWriteFailure(error, pipe: pipe, generation: generation)
                }
            }
        }
    }

    private func handleWriteFailure(_ error: Error, pipe: Pipe, generation: Int) {
        guard connectionGeneration == generation, stdin === pipe else { return }
        onLog?("ACP write failed: \(error.localizedDescription)")
        failAll(ACPError.writeFailed(error.localizedDescription))
        stop()
    }

    private func requestTermination(of process: Process) {
        guard process.isRunning else { return }
        let key = ObjectIdentifier(process)
        guard stoppingProcesses[key] == nil else { return }
        stoppingProcesses[key] = process
        process.terminate()
        let grace = terminationGraceNanoseconds
        terminationFallbackTasks[key] = Task { @MainActor [weak self, process] in
            do {
                try await Task.sleep(nanoseconds: grace)
            } catch {
                return
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            self?.terminationFallbackTasks.removeValue(forKey: key)
        }
    }

    private func handleProcessTermination(_ terminated: Process, generation: Int) {
        let key = ObjectIdentifier(terminated)
        if stoppingProcesses[key] === terminated {
            stoppingProcesses.removeValue(forKey: key)
            terminationFallbackTasks.removeValue(forKey: key)?.cancel()
        }
        guard isCurrentConnection(terminated, generation: generation) else { return }
        stdin = nil
        process = nil
        outputDecoder = nil
        failAll(ACPError.notRunning)
        onTermination?(terminated.terminationStatus)
    }

    private func failAll(_ error: Error) {
        let requests = pendingRequests
        pendingRequests.removeAll()
        for request in requests.values {
            request.timeoutTask?.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func makeTimeoutTask(forKey key: String, method: String, timeout: TimeInterval?) -> Task<Void, Never>? {
        guard let timeout, timeout > 0 else { return nil }
        return Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            } catch {
                return
            }
            self?.completeRequest(key, throwing: ACPError.timedOut(method))
        }
    }

    private func completeRequest(_ key: String, returning response: [String: Any]) {
        guard let request = pendingRequests.removeValue(forKey: key) else { return }
        request.timeoutTask?.cancel()
        request.continuation.resume(returning: response)
    }

    private func completeRequest(_ key: String, throwing error: Error) {
        guard let request = pendingRequests.removeValue(forKey: key) else { return }
        request.timeoutTask?.cancel()
        request.continuation.resume(throwing: error)
    }

    private func isCurrentConnection(_ candidate: Process, generation: Int) -> Bool {
        connectionGeneration == generation && process === candidate
    }
}

/// Short-lived probes for discovering Antigravity's model catalog and listing sessions without
/// keeping a permanent background daemon running.
enum ACPCatalogProbe {
    @MainActor
    static func discoverAntigravityCatalog() async throws -> ACPCatalogSnapshot {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pig-acp-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let client = ACPClient(config: .antigravity(), workingDirectory: tempDir.path)
        defer { client.stop() }
        try await client.start()
        let initResult = try await client.initialize()
        let sessionResult = try await client.newSession(cwd: tempDir.path, mcpServers: [])
        if let sessionID = sessionResult["sessionId"] as? String {
            try? await client.closeSession(sessionID: sessionID)
        }

        let configOptions = ACPModelCatalogParser.parseConfigOptions(sessionResult["configOptions"])
        let parsedModels = ACPModelCatalogParser.parseModels(from: sessionResult, configOptions: configOptions)
        let parsedModes = ACPModelCatalogParser.parseModes(from: sessionResult, configOptions: configOptions)

        let snapshot = ACPCatalogSnapshot(
            models: parsedModels.models.map(ACPCachedModel.init(from:)),
            modes: parsedModes.modes,
            defaultModelID: parsedModels.currentModelID,
            defaultThinkingLevel: parsedModels.currentThinkingLevel,
            defaultModeID: parsedModes.currentModeID,
            agentVersion: initResult.agentVersion,
            updatedAt: Date()
        )
        if !snapshot.models.isEmpty {
            ACPModelsCache.save(snapshot)
        }
        return snapshot
    }

    @MainActor
    static func listSessions(cwd: String) async throws -> [ACPSessionSummary] {
        let client = ACPClient(config: .antigravity(), workingDirectory: cwd)
        defer { client.stop() }
        try await client.start()
        let initResult = try await client.initialize()
        guard initResult.capabilities.listSessions else { return [] }
        return try await client.listSessions(cwd: cwd)
    }
}
