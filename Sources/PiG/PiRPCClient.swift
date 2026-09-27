import Foundation
import Darwin

struct PiLaunchResources {
    var extensions: [String] = []
    var skills: [String] = []
    var prompts: [String] = []

    init(extensions: [String] = [], skills: [String] = [], prompts: [String] = []) {
        self.extensions = extensions
        self.skills = skills
        self.prompts = prompts
    }

    init(items: [PiResourceItem]) {
        self.init(
            extensions: items.filter { $0.type == "extensions" }.map(\.path),
            skills: items.filter { $0.type == "skills" }.map(\.path),
            prompts: items.filter { $0.type == "prompts" }.map(\.path)
        )
    }

    var arguments: [String] {
        extensions.flatMap { ["--extension", $0] } +
        skills.flatMap { ["--skill", $0] } +
        prompts.flatMap { ["--prompt-template", $0] }
    }
}

private struct RPCSendableValue<Value>: @unchecked Sendable {
    var value: Value
}

private final class RPCOutputDecoder: @unchecked Sendable {
    struct DecodedLine: @unchecked Sendable {
        var text: String
        var dictionary: [String: Any]?
    }

    private let queue = DispatchQueue(label: "PiRPCClient.stdout.decode", qos: .userInitiated)
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
                onLine(decode(line))
            }
        }
    }

    private func decode(_ line: String) -> DecodedLine {
        guard let data = line.data(using: .utf8),
              var dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return DecodedLine(text: line, dictionary: nil)
        }

        if let type = dictionary["type"] as? String,
           type == "message_end",
           let agent = dictionary["message"] as? [String: Any],
           let message = SessionParser.chatMessage(fromAgentMessage: agent, streaming: false) {
            dictionary["_pigParsedChatMessage"] = message
        }
        return DecodedLine(text: line, dictionary: dictionary)
    }
}

@MainActor
final class PiRPCClient {
    enum RPCError: Error, LocalizedError {
        case notRunning
        case launchFailed(String)
        case commandFailed(String)
        case invalidResponse
        case timedOut(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notRunning: return "pi RPC process is not running"
            case .launchFailed(let message): return message
            case .commandFailed(let message): return message
            case .invalidResponse: return "Invalid RPC response"
            case .timedOut(let command): return "pi RPC \(command) request timed out. It may still have been accepted; check the session before retrying."
            case .writeFailed(let message): return "Failed to write to pi RPC: \(message)"
            }
        }
    }

    private struct PendingRequest {
        let continuation: CheckedContinuation<[String: Any], Error>
        let timeoutTask: Task<Void, Never>?
    }

    private static let fastCommandTypes: Set<String> = [
        "clear_queue", "cycle_model", "cycle_thinking_level",
        "steer", "follow_up", "abort_bash", "abort_retry",
        "get_available_models", "get_available_thinking_levels", "get_commands",
        "get_entries", "get_fork_messages", "get_last_assistant_text",
        "get_messages", "get_session_stats", "get_state", "get_tree",
        "set_auto_compaction", "set_auto_retry", "set_follow_up_mode",
        "set_model", "set_session_name", "set_steering_mode", "set_thinking_level"
    ]

    private let projectPath: String
    private let noSession: Bool
    private let launchResources: PiLaunchResources
    private let fastRequestTimeout: TimeInterval = 15
    private var process: Process?
    private var stdin: Pipe?
    private var pendingRequests: [String: PendingRequest] = [:]
    private var writeQueue = DispatchQueue(label: "PiRPCClient.stdin.write")
    private var outputDecoder: RPCOutputDecoder?
    private var connectionGeneration = 0
    private var stoppingProcesses: [ObjectIdentifier: Process] = [:]
    private var terminationFallbackTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let terminationGraceNanoseconds: UInt64 = 2_000_000_000

    var onEvent: (([String: Any]) -> Void)?
    var onExtensionUIRequest: (([String: Any]) -> Void)?
    var onLog: ((String) -> Void)?
    var onTermination: (() -> Void)?
    var isRunning: Bool { process?.isRunning == true }

    init(
        projectPath: String,
        noSession: Bool = false,
        launchResources: PiLaunchResources = PiLaunchResources()
    ) {
        self.projectPath = projectPath
        self.noSession = noSession
        self.launchResources = launchResources
    }

    func start() async throws {
        try Task.checkCancellation()
        if isRunning { return }
        connectionGeneration &+= 1
        let generation = connectionGeneration
        let environment = await PiEnvironment.mergedAsync()
        try Task.checkCancellation()
        guard connectionGeneration == generation else { throw RPCError.notRunning }
        let proc = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        // Report a closed peer as a throwing write error, not SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        proc.executableURL = PiPaths.piExecutable
        proc.arguments = PiPaths.piArguments(noSession: noSession) + launchResources.arguments
        proc.currentDirectoryURL = URL(fileURLWithPath: projectPath, isDirectory: true)
        proc.standardInput = input
        proc.standardOutput = output
        proc.standardError = error
        proc.environment = environment

        let decoder = RPCOutputDecoder()
        output.fileHandleForReading.readabilityHandler = { [weak self, weak proc] handle in
            let data = handle.availableData
            guard !data.isEmpty, let proc else { return }
            decoder.append(data) { [weak self] decoded in
                Task { @MainActor in
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
        proc.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.handleProcessTermination(process, generation: generation)
            }
        }

        process = proc
        stdin = input
        outputDecoder = decoder
        writeQueue = DispatchQueue(label: "PiRPCClient.stdin.write.\(generation)")

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
                throw RPCError.notRunning
            }
        } catch {
            requestTermination(of: proc)
            if isCurrentConnection(proc, generation: generation) {
                stdin = nil
                process = nil
                outputDecoder = nil
                failAll(error)
            }
            if error is CancellationError || error is RPCError { throw error }
            throw RPCError.launchFailed("Failed to launch pi RPC: \(error.localizedDescription)")
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
        // Never wait for an in-flight pipe write on the main actor.
        writeQueue.async { try? input?.fileHandleForWriting.close() }
        failAll(RPCError.notRunning)
        onTermination?()
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

    private func handleProcessTermination(_ terminatedProcess: Process, generation: Int) {
        let key = ObjectIdentifier(terminatedProcess)
        if stoppingProcesses[key] === terminatedProcess {
            stoppingProcesses.removeValue(forKey: key)
            terminationFallbackTasks.removeValue(forKey: key)?.cancel()
        }
        guard isCurrentConnection(terminatedProcess, generation: generation) else { return }
        onLog?("pi exited with status \(terminatedProcess.terminationStatus)")
        stdin = nil
        process = nil
        outputDecoder = nil
        failAll(PiRPCClient.RPCError.notRunning)
        onTermination?()
    }

    func command(_ command: [String: Any]) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard isRunning, let stdin else { throw RPCError.notRunning }
        let id = UUID().uuidString
        var payload = command
        payload["id"] = id
        let sendablePayload = RPCSendableValue(value: payload)
        let data = try await Task.detached(priority: .userInitiated) {
            guard JSONSerialization.isValidJSONObject(sendablePayload.value) else { throw RPCError.invalidResponse }
            return try JSONSerialization.data(withJSONObject: sendablePayload.value)
        }.value
        guard isRunning, self.stdin === stdin else { throw RPCError.notRunning }
        var line = String(data: data, encoding: .utf8) ?? "{}"
        line.append("\n")
        let generation = connectionGeneration
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let timeoutTask = makeTimeoutTask(for: id, command: command)
                pendingRequests[id] = PendingRequest(continuation: continuation, timeoutTask: timeoutTask)
                writeLine(line, to: stdin, generation: generation)
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.completeRequest(id, throwing: CancellationError()) }
        })
    }

    func notify(_ payload: [String: Any]) throws {
        guard isRunning, let stdin else { throw RPCError.notRunning }
        guard JSONSerialization.isValidJSONObject(payload) else { throw RPCError.invalidResponse }
        let data = try JSONSerialization.data(withJSONObject: payload)
        var line = String(data: data, encoding: .utf8) ?? "{}"
        line.append("\n")
        writeLine(line, to: stdin, generation: connectionGeneration)
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

    private func handleLine(_ decoded: RPCOutputDecoder.DecodedLine) {
        guard let dict = decoded.dictionary,
              let type = dict["type"] as? String else {
            onLog?(decoded.text)
            return
        }

        if type == "response" {
            let id = dict["id"] as? String
            if let id {
                if dict["success"] as? Bool == false {
                    completeRequest(id, throwing: RPCError.commandFailed(dict["error"] as? String ?? "RPC command failed"))
                } else {
                    completeRequest(id, returning: dict)
                }
            }
            return
        }

        if type == "extension_ui_request" {
            onExtensionUIRequest?(dict)
            return
        }

        onEvent?(dict)
    }

    private func failAll(_ error: Error) {
        let requests = pendingRequests
        pendingRequests.removeAll()
        for request in requests.values {
            request.timeoutTask?.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func makeTimeoutTask(for id: String, command: [String: Any]) -> Task<Void, Never>? {
        guard let commandName = command["type"] as? String,
              let timeout = timeout(for: command),
              timeout > 0 else { return nil }
        return Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            } catch {
                return
            }
            self?.completeRequest(id, throwing: RPCError.timedOut(commandName))
        }
    }

    private func timeout(for command: [String: Any]) -> TimeInterval? {
        guard let type = command["type"] as? String else { return nil }
        // Shell execution, compaction, and extension hooks may wait for human
        // input or long-running work. Their callers can cancel or stop the runtime.
        if type == "prompt" {
            let message = (command["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return message.hasPrefix("/") ? nil : fastRequestTimeout
        }
        return Self.fastCommandTypes.contains(type) ? fastRequestTimeout : nil
    }

    private func completeRequest(_ id: String, returning response: [String: Any]) {
        guard let request = pendingRequests.removeValue(forKey: id) else { return }
        request.timeoutTask?.cancel()
        request.continuation.resume(returning: response)
    }

    private func completeRequest(_ id: String, throwing error: Error) {
        guard let request = pendingRequests.removeValue(forKey: id) else { return }
        request.timeoutTask?.cancel()
        request.continuation.resume(throwing: error)
    }

    private func handleWriteFailure(_ error: Error, pipe: Pipe, generation: Int) {
        guard connectionGeneration == generation, stdin === pipe else { return }
        onLog?("pi RPC write failed: \(error.localizedDescription)")
        failAll(RPCError.writeFailed(error.localizedDescription))
        stop()
    }

    private func isCurrentConnection(_ candidate: Process, generation: Int) -> Bool {
        connectionGeneration == generation && process === candidate
    }

}
