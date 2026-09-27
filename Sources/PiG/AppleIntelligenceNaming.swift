import Foundation
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AppleIntelligenceNamingStatus: Equatable {
    case available
    case requiresNewerMacOS
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unavailable

    var isReady: Bool { self == .available }

    var message: String {
        switch self {
        case .available:
            return "On-device Apple Intelligence is ready."
        case .requiresNewerMacOS:
            return "On-device naming requires macOS 26 or later."
        case .deviceNotEligible:
            return "This Mac doesn’t support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in System Settings to use on-device naming."
        case .modelNotReady:
            return "The on-device model isn’t ready yet. It may still be downloading."
        case .unavailable:
            return "Apple Intelligence is unavailable on this Mac."
        }
    }
}

enum AppleIntelligenceNaming {
    private static let timeoutSeconds: TimeInterval = 20
    // Only used on macOS versions without token counting.
    private static let legacyPromptCharacters = 1800
    private static let maxResponseTokens = 96
    private static let contextSafetyTokens = 256
    private static let logger = Logger(subsystem: "PiG", category: "SessionNaming")

    static var status: AppleIntelligenceNamingStatus {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return systemModelStatus()
        }
        #endif
        return .requiresNewerMacOS
    }

    static func generateTitle(from initialPrompt: String) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return nil }
        let task = Task.detached(priority: .utility) {
            await generateOnDevice(from: initialPrompt)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        #else
        return nil
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private static func systemModelStatus() -> AppleIntelligenceNamingStatus {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .deviceNotEligible
            case .appleIntelligenceNotEnabled:
                return .appleIntelligenceNotEnabled
            case .modelNotReady:
                return .modelNotReady
            @unknown default:
                return .unavailable
            }
        }
    }

    @available(macOS 26, *)
    @Generable
    fileprivate struct SessionTitle {
        @Guide(description: "A specific 3–7 word session title describing the user's main goal.")
        var title: String
    }

    @available(macOS 26, *)
    private static func generateOnDevice(from initialPrompt: String) async -> String? {
        let model = SystemLanguageModel.default
        guard model.isAvailable, !Task.isCancelled else { return nil }
        do {
            return try await withTimeout(seconds: timeoutSeconds) {
                let prompt = try await budgetedPrompt(initialPrompt, model: model)
                try Task.checkCancellation()
                let session = LanguageModelSession(
                    model: model,
                    instructions: SessionTitleGenerator.namingInstructions
                )
                let response = try await session.respond(
                    to: prompt,
                    generating: SessionTitle.self,
                    options: GenerationOptions(sampling: .greedy, maximumResponseTokens: maxResponseTokens)
                )
                try Task.checkCancellation()
                guard let title = SessionTitleGenerator.sanitize(response.content.title),
                      (3...7).contains(title.split(separator: " ").count) else {
                    logger.notice("On-device naming returned an invalid title; keeping fallback.")
                    return nil
                }
                return title
            }
        } catch is CancellationError {
            return nil
        } catch is NamingTimeoutError {
            logger.notice("On-device naming timed out; keeping fallback.")
            return nil
        } catch {
            // Do not log error descriptions: framework diagnostics may contain prompt text.
            logger.notice("On-device naming failed (\(String(reflecting: type(of: error)), privacy: .public)); keeping fallback.")
            return nil
        }
    }

    @available(macOS 26, *)
    private static func budgetedPrompt(_ text: String, model: SystemLanguageModel) async throws -> String {
        guard #available(macOS 26.4, *) else {
            return SessionTitleGenerator.userPrompt(from: abbreviated(text, keeping: legacyPromptCharacters))
        }
        let instructionTokens = try await model.tokenCount(for: Instructions(SessionTitleGenerator.namingInstructions))
        let schemaTokens = try await model.tokenCount(for: SessionTitle.generationSchema)
        let budget = model.contextSize - instructionTokens - schemaTokens
            - maxResponseTokens - contextSafetyTokens
        guard budget > 0 else { throw NamingContextError() }

        var characterCount = text.count
        while true {
            try Task.checkCancellation()
            let prompt = SessionTitleGenerator.userPrompt(from: abbreviated(text, keeping: characterCount))
            let tokens = try await model.tokenCount(for: prompt)
            if tokens <= budget { return prompt }
            guard characterCount > 0 else { throw NamingContextError() }
            // Leave headroom when estimating the next cut; always verify with the tokenizer.
            characterCount = min(characterCount - 1, Int(Double(characterCount) * Double(budget) / Double(tokens) * 0.9))
        }
    }
    #endif

    private static func abbreviated(_ text: String, keeping count: Int) -> String {
        guard text.count > count else { return text }
        let headCount = (count + 1) / 2
        return String(text.prefix(headCount)) + "\n[Middle of initial prompt omitted]\n"
            + String(text.suffix(count / 2))
    }
}

private struct NamingTimeoutError: Error {}
private struct NamingContextError: Error {}

private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        defer { group.cancelAll() }
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw NamingTimeoutError()
        }
        guard let result = try await group.next() else { throw NamingTimeoutError() }
        return result
    }
}
