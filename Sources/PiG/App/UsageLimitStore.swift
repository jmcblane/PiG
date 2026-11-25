import Combine
import Foundation

@MainActor
final class UsageLimitStore: ObservableObject {
    @Published var limits: [UsageLimitProvider: UsageLimitSnapshot] = [:]
    @Published var fetchDates: [UsageLimitProvider: Date] = [:]
    @Published var refreshing: Set<UsageLimitProvider> = []
}
