import SwiftUI
import AppKit
import ImageIO

struct ChatPaneView: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    let controller: SessionController?
    @State private var drafts: [String: String] = [:]
    @State private var imageDrafts: [String: [ImageAttachment]] = [:]

    var body: some View {
        ChatTabContent(
            controller: controller,
            selectedProjectPath: model.selectedProjectPath,
            theme: model.selectedTheme,
            draft: draftBinding(forKey: controller?.id ?? "__none__"),
            imageAttachments: imageDraftBinding(forKey: controller?.id ?? "__none__")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(appTheme.background)
    }

    // Drafts are stored per session so a half-typed message never follows
    // the user into a different session.
    private func draftBinding(forKey key: String) -> Binding<String> {
        Binding(
            get: { drafts[key] ?? "" },
            set: { drafts[key] = $0 }
        )
    }

    private func imageDraftBinding(forKey key: String) -> Binding<[ImageAttachment]> {
        Binding(
            get: { imageDrafts[key] ?? [] },
            set: { imageDrafts[key] = $0 }
        )
    }
}
