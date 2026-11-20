import Foundation

private let maxOutputBytes = 50 * 1024
private let maxStderrBytes = 8 * 1024
private let thinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]

let piSubagentTool: [String: Any] = [
    "name": "pi_subagent",
    "description":
        "Run a Pi coding agent as a subagent with a fresh context. It starts with only the task you give it, " +
        "shares this machine's filesystem, loads Pi's own AGENTS.md, skills, and extensions, and cannot delegate further. " +
        "Returns the child's final reply. Write the task for a stranger: include the outcome, relevant absolute paths, " +
        "scope, and what to report back. Use only when the user asks for a Pi subagent.",
    "inputSchema": [
        "type": "object",
        "additionalProperties": false,
        "required": ["agent", "task"],
        "properties": [
            "agent": [
                "type": "string",
                "description": "Short, distinct name for this child, shown in PiG",
                "minLength": 1,
                "maxLength": 60
            ],
            "task": [
                "type": "string",
                "description": "Complete, self-contained instructions for the child",
                "minLength": 1
            ],
            "model": [
                "type": "string",
                "description": "Pi model as provider/id. Omit to use Pi's default model."
            ],
            "thinkingLevel": [
                "type": "string",
                "enum": thinkingLevels
            ],
            "cwd": [
                "type": "string",
                "description": "Working directory, absolute or relative to the project. Defaults to the project."
            ]
        ]
    ]
]

private final class SubagentJob {
    var process: Process?
    var cancelled = false
    var settled = false
    var settleGeneration = 0
    var stoppedAfterSettle = false
}

final class PiSubagentRunner {
    private let lock = NSLock()
    private var jobs: [String: SubagentJob] = [:]
    private var shuttingDown = false
    private let piExecutable: String?
    private let baseDirectory: String

    init(piExecutable: String?, baseDirectory: String) {
        self.piExecutable = piExecutable
        self.baseDirectory = baseDirectory
    }

    func register(requestKey: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !shuttingDown, jobs[requestKey] == nil else { return false }
        jobs[requestKey] = SubagentJob()
        return true
    }

    func cancel(requestKey: String) {
        lock.lock()
        guard let job = jobs[requestKey] else {
            lock.unlock()
            return
        }
        job.cancelled = true
        let process = job.process
        lock.unlock()
        if let process { stop(process) }
    }

    func shutdown() {
        lock.lock()
        shuttingDown = true
        for job in jobs.values { job.cancelled = true }
        let running = jobs.values.compactMap(\.process)
        lock.unlock()
        running.forEach(stop)
        let deadline = Date().addingTimeInterval(4)
        while running.contains(where: \.isRunning), Date() < deadline {
            usleep(50_000)
        }
        for process in running where process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    func run(requestKey: String, arguments: [String: Any], progress: ((Int, String) -> Void)?) -> [String: Any]? {
        lock.lock()
        let job = jobs[requestKey]
        lock.unlock()
        guard let job else { return toolError("Subagent request was not registered.") }
        let result = execute(job: job, arguments: arguments, progress: progress)
        lock.lock()
        jobs[requestKey] = nil
        let cancelled = job.cancelled
        lock.unlock()
        return cancelled ? nil : result
    }

    private func execute(job: SubagentJob, arguments: [String: Any], progress: ((Int, String) -> Void)?) -> [String: Any] {
        guard let agent = (arguments["agent"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !agent.isEmpty else {
            return toolError("Missing required parameter: agent.")
        }
        guard let task = (arguments["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty else {
            return toolError("Missing required parameter: task.")
        }

        var piArguments = ["--mode", "json", "-p", "--no-session"]
        if let model = (arguments["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            piArguments += ["--model", model]
        }
        if let thinking = (arguments["thinkingLevel"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !thinking.isEmpty {
            guard thinkingLevels.contains(thinking) else {
                return toolError("thinkingLevel must be one of: \(thinkingLevels.joined(separator: ", ")).")
            }
            piArguments += ["--thinking", thinking]
        }
        piArguments.append("Task: \(task)")

        var directory = baseDirectory
        if let cwd = (arguments["cwd"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
            let expanded = (cwd as NSString).expandingTildeInPath
            directory = expanded.hasPrefix("/") ? expanded : (baseDirectory as NSString).appendingPathComponent(expanded)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            return toolError("Working directory does not exist: \(directory)")
        }

        let process = Process()
        if let piExecutable {
            process.executableURL = URL(fileURLWithPath: piExecutable)
            process.arguments = piArguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["pi"] + piArguments
        }
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment["PI_SUBAGENT_CHILD"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let stderrLock = NSLock()
        var stderrData = Data()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stderrLock.lock()
            stderrData.append(chunk)
            if stderrData.count > maxStderrBytes { stderrData = stderrData.suffix(maxStderrBytes) }
            stderrLock.unlock()
        }

        lock.lock()
        if job.cancelled {
            lock.unlock()
            stderr.fileHandleForReading.readabilityHandler = nil
            return toolError("Subagent was cancelled.")
        }
        do {
            try process.run()
        } catch {
            lock.unlock()
            stderr.fileHandleForReading.readabilityHandler = nil
            return toolError("Could not start Pi: \(error.localizedDescription)")
        }
        job.process = process
        lock.unlock()

        var finalText = ""
        var stopReason: String?
        var errorMessage: String?
        var steps = 0
        var buffer = Data()

        let handleLine = { (line: Data) in
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = event["type"] as? String else { return }
            if type == "agent_start" {
                self.lock.lock()
                job.settled = false
                job.settleGeneration += 1
                self.lock.unlock()
                return
            }
            if type == "agent_settled" {
                self.lock.lock()
                job.settled = true
                job.settleGeneration += 1
                let generation = job.settleGeneration
                self.lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    self.lock.lock()
                    let shouldStop = job.settled && job.settleGeneration == generation && !job.cancelled && process.isRunning
                    if shouldStop { job.stoppedAfterSettle = true }
                    self.lock.unlock()
                    if shouldStop { self.stop(process) }
                }
                return
            }
            guard type == "message_end",
                  let message = event["message"] as? [String: Any],
                  message["role"] as? String == "assistant" else { return }
            let parts = message["content"] as? [[String: Any]] ?? []
            let text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { finalText = text }
            if let reason = message["stopReason"] as? String { stopReason = reason }
            if let error = (message["errorMessage"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
                errorMessage = error
            }
            steps += 1
            let tools = parts.compactMap { $0["type"] as? String == "toolCall" ? $0["name"] as? String : nil }
            let summary = tools.isEmpty ? String(text.prefix(120)) : "\(agent): \(tools.joined(separator: ", "))"
            progress?(steps, summary.isEmpty ? agent : summary)
        }

        let reader = stdout.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                var line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.last == 0x0D { line.removeLast() }
                if !line.isEmpty { handleLine(line) }
            }
        }
        if !buffer.isEmpty { handleLine(buffer) }

        stop(process)
        process.waitUntilExit()
        stderr.fileHandleForReading.readabilityHandler = nil

        lock.lock()
        let stoppedAfterSettle = job.stoppedAfterSettle
        lock.unlock()
        let stoppedBySIGTERM = (process.terminationReason == .exit && process.terminationStatus == 128 + SIGTERM)
            || (process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGTERM)
        let exitedCleanly = (process.terminationReason == .exit && process.terminationStatus == 0)
            || (stoppedAfterSettle && stoppedBySIGTERM)
        if !exitedCleanly || stopReason == "error" || stopReason == "aborted" {
            stderrLock.lock()
            let stderrText = String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            stderrLock.unlock()
            let detail = errorMessage ?? (stderrText.isEmpty ? nil : stderrText) ?? "Pi exited with status \(process.terminationStatus)."
            return toolError("Subagent \(agent) failed: \(detail)")
        }

        let output = finalText.isEmpty ? "(no output)" : truncated(finalText)
        return ["content": [["type": "text", "text": output]]]
    }

    private func truncated(_ text: String) -> String {
        let data = Data(text.utf8)
        guard data.count > maxOutputBytes else { return text }
        let head = String(decoding: data.prefix(maxOutputBytes), as: UTF8.self)
        return head + "\n\n[Output truncated: \(data.count - maxOutputBytes) bytes omitted.]"
    }
}
