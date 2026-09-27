import SwiftUI

struct SearchFieldSurface: ViewModifier {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    let isFocused: Bool

    func body(content: Content) -> some View {
        content
            .font(AppFonts.ui(12.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(appTheme.panel2, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isFocused && model.composerFocusAccent ? appTheme.brass.opacity(0.55) : appTheme.line, lineWidth: 1)
            }
    }
}
