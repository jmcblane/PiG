import AppKit
import Combine

@MainActor
final class AppOcclusion: ObservableObject {
    static let shared = AppOcclusion()

    @Published private(set) var isVisible = true

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                let visible = NSApplication.shared.occlusionState.contains(.visible)
                if self?.isVisible != visible { self?.isVisible = visible }
            }
        }
    }
}
