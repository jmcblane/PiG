import SwiftUI

extension Color {
    /// "#rrggbb" from a `Look` palette.
    init(lookHex hex: String) {
        let c = RGBA(hex)
        self.init(.sRGB, red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255, opacity: 1)
    }
}

@MainActor
private enum AgentPortraitCache {
    private static var heads: [Look: CGImage] = [:]

    /// Head-and-shoulders crop of the front pose.
    static func head(_ look: Look) -> CGImage {
        if let img = heads[look] { return img }
        let body = PixelPeople.image(look)
        let img = body.cropping(to: CGRect(x: 4, y: 1, width: 24, height: 24)) ?? body
        heads[look] = img
        return img
    }
}

/// Pixel-art head with no tile behind it. Sized for sidebar rows (~26pt) and the
/// title bar (~18pt).
struct AgentAvatar: View {
    let look: Look
    var size: CGFloat = 26

    var body: some View {
        Image(decorative: AgentPortraitCache.head(look), scale: 1)
            .interpolation(.none)
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Full-body pixel person for the agent editor.
struct AgentPortrait: View {
    @Environment(\.appTheme) private var appTheme
    let look: Look
    var scale: CGFloat = 3

    var body: some View {
        Image(decorative: PixelPeople.image(look), scale: 1)
            .interpolation(.none)
            .resizable()
            .frame(width: CGFloat(PixelPeople.width) * scale, height: CGFloat(PixelPeople.height) * scale)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(lookHex: look.shirt).opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(appTheme.line, lineWidth: 1)
            )
            .accessibilityHidden(true)
    }
}
