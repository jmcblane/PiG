import Combine

@MainActor
final class StatusCenter: ObservableObject {
    @Published var line: String = ""
}
