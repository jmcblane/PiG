import Foundation

enum LocalShell {
    static func stream(command: String, in directory: String, onChunk: @escaping @MainActor @Sendable (String) -> Void) async -> Int32 {
        do {
            let environment = await PiEnvironment.mergedAsync()
            return try await ProcessRunner.stream(
                executable: PiEnvironment.userShell, arguments: ["-l", "-c", command],
                environment: environment, cwd: URL(fileURLWithPath: directory, isDirectory: true), onChunk: onChunk
            )
        } catch {
            await MainActor.run { onChunk(error.localizedDescription) }
            return 1
        }
    }
}

extension String {
    var truncatedForChatOutput: String {
        let maxCount = 48_000
        guard count > maxCount else { return self }
        return String(prefix(maxCount)) + "\n… output truncated …"
    }
}
