import Foundation
import Darwin

enum ProcessRunner {
    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    private final class ReadBuffer: @unchecked Sendable {
        var data = Data() // Written by one reader, accessed only after the group finishes.
    }

    /// Synchronous for callers already running off the main thread (including git status).
    static func capture(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        cwd: URL? = nil,
        timeout: TimeInterval? = nil,
        mergeOutput: Bool = false
    ) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = cwd
        let stdout = Pipe()
        let stderr = mergeOutput ? stdout : Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let timer = timeout.map { seconds in
            let item = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
            return item
        }
        // Both pipes drain concurrently while the child is running.
        let group = DispatchGroup()
        let output = ReadBuffer()
        let error = ReadBuffer()
        group.enter()
        DispatchQueue.global().async {
            output.data = stdout.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if !mergeOutput {
            group.enter()
            DispatchQueue.global().async {
                error.data = stderr.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }
        process.waitUntilExit()
        group.wait()
        timer?.cancel()
        return Result(status: process.terminationStatus, stdout: output.data, stderr: error.data)
    }

    static func stream(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        cwd: URL? = nil,
        onChunk: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> Int32 {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = cwd
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let handle = pipe.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                let text = String(data: data, encoding: .utf8) ?? ""
                if !text.isEmpty { await MainActor.run { onChunk(text) } }
            }
            process.waitUntilExit()
            return process.terminationStatus
        }.value
    }
}
