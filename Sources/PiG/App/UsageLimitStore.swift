import Combine

@MainActor
final class UsageLimitStore: ObservableObject {
    @Published var limits: [UsageLimitProvider: UsageLimitSnapshot] = [:]
}
