import SwiftUI
import AppKit

/// What a chat looks like in the cast and palette: the agent's face, a pixel folder
/// in its project's color, or a pixel bolt for quick chats.
enum ChatIcon: Hashable {
    case agent(Look)
    case project(color: String)
    case quickChat

    static let quickChatColor = "#ffb703"

    /// Stable color per project path: a hue from the path's hash at fixed saturation and
    /// brightness, so projects rarely share a color. FNV-1a (`hashValue` is randomized per
    /// launch) plus a SplitMix64 finalizer, since FNV's low bits cluster for similar paths.
    static func project(path: String) -> ChatIcon {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        hash = (hash ^ (hash >> 30)) &* 0xbf58476d1ce4e5b9
        hash = (hash ^ (hash >> 27)) &* 0x94d049bb133111eb
        hash ^= hash >> 31
        let hue = Double(hash % 360) / 360
        return .project(color: ThemeRGB(nsColor: NSColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1)).hex)
    }

    /// Main color, used for the tile tint and the selection glow.
    var tint: String {
        switch self {
        case .agent(let look): return look.shirt
        case .project(let color): return color
        case .quickChat: return Self.quickChatColor
        }
    }
}

struct ChatIconView: View {
    @Environment(\.appTheme) private var appTheme
    let icon: ChatIcon
    var size: CGFloat = 26

    var body: some View {
        switch icon {
        case .agent(let look):
            AgentAvatar(look: look, size: size)
        case .project(let color):
            tile(PixelSprite(rows: Self.folder, palette: Self.folderPalette(color)), tint: color)
        case .quickChat:
            tile(PixelSprite(rows: Self.bolt, palette: Self.boltPalette), tint: ChatIcon.quickChatColor)
        }
    }

    private func tile(_ sprite: PixelSprite, tint: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: max(3, size * 0.22), style: .continuous)
        return sprite
            .padding(size * 0.14)
            .frame(width: size, height: size)
            .background(Color(lookHex: tint).opacity(0.18))
            .clipShape(shape)
            .overlay(shape.strokeBorder(appTheme.line, lineWidth: 1))
            .accessibilityHidden(true)
    }

    // t tab, l lip highlight, b body, s body shade, d bottom edge
    private static let folder = [
        "............",
        ".tttt.......",
        "tttttt......",
        "tllllllllllt",
        "tbbbbbbbbbbt",
        "tbbbbbbbbbbt",
        "tbbbbbbbbbbt",
        "tbbbbbbbbbst",
        "tsbbbbbbbsst",
        "dddddddddddd",
        "............",
        "............",
    ]

    private static func folderPalette(_ hex: String) -> [Character: RGBA] {
        let base = RGBA(hex)
        return [
            "t": base.shade(0.72),
            "l": base.mix(RGBA("#ffffff"), 0.38),
            "b": base,
            "s": base.shade(0.86),
            "d": base.shade(0.55),
        ]
    }

    // y bolt, h highlight, o outline
    private static let bolt = [
        "............",
        "......ooo...",
        ".....ohyo...",
        "....ohyo....",
        "...ohyo.....",
        "..ohyyyyyo..",
        "..oooyyyo...",
        "....oyyo....",
        "...oyyo.....",
        "...oyo......",
        "...oo.......",
        "............",
    ]

    private static let boltPalette: [Character: RGBA] = {
        let base = RGBA(ChatIcon.quickChatColor)
        return ["y": base, "h": base.mix(RGBA("#ffffff"), 0.5), "o": base.shade(0.5)]
    }()
}

/// Draws a character map as square pixels; `.` is transparent.
private struct PixelSprite: View {
    let rows: [String]
    let palette: [Character: RGBA]

    var body: some View {
        Canvas { context, size in
            let columns = rows.map(\.count).max() ?? 1
            let cell = min(size.width / CGFloat(columns), size.height / CGFloat(rows.count))
            let originX = (size.width - cell * CGFloat(columns)) / 2
            let originY = (size.height - cell * CGFloat(rows.count)) / 2
            for (y, row) in rows.enumerated() {
                for (x, character) in row.enumerated() {
                    guard let color = palette[character] else { continue }
                    let rect = CGRect(x: originX + CGFloat(x) * cell, y: originY + CGFloat(y) * cell, width: cell, height: cell)
                    // Slight overlap hides hairline seams at fractional cell sizes.
                    context.fill(Path(rect.insetBy(dx: -0.25, dy: -0.25)), with: .color(Color(
                        .sRGB,
                        red: Double(color.r) / 255,
                        green: Double(color.g) / 255,
                        blue: Double(color.b) / 255,
                        opacity: Double(color.a) / 255
                    )))
                }
            }
        }
    }
}
