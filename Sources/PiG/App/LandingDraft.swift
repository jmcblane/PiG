import Combine

@MainActor
final class LandingDraft: ObservableObject {
    @Published var text: String = ""
    @Published var images: [ImageAttachment] = []
}
