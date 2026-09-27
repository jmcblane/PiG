import SwiftUI
import AppKit

struct ThemeRGB: Hashable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(hex: Int) {
        self.red = Double((hex >> 16) & 0xff) / 255.0
        self.green = Double((hex >> 8) & 0xff) / 255.0
        self.blue = Double(hex & 0xff) / 255.0
    }

    var color: Color { Color(red: red, green: green, blue: blue) }
    var nsColor: NSColor { NSColor(red: red, green: green, blue: blue, alpha: 1) }

    var relativeLuminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    var contrastingForeground: Color {
        relativeLuminance > 0.179 ? .black : .white
    }

    var hex: String {
        let r = Int((red * 255).rounded()).clamped(to: 0...255)
        let g = Int((green * 255).rounded()).clamped(to: 0...255)
        let b = Int((blue * 255).rounded()).clamped(to: 0...255)
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}

// Markdown colors are byte-quantized even in themes whose app palette uses
// decimal RGB components. Keep those decimal app colors intact.
struct MarkdownColor: Hashable {
    let rgb: ThemeRGB
    let opacity: Double

    init(hex: Int, opacity: Double = 1) {
        rgb = ThemeRGB(hex: hex)
        self.opacity = opacity
    }

    var color: Color { Color(red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: opacity) }
    var nsColor: NSColor { NSColor(color) }
}

struct MarkdownThemePalette: Hashable {
    let userForeground: MarkdownColor
    let assistantForeground: MarkdownColor
    let strong: MarkdownColor
    let emphasis: MarkdownColor
    let deleted: MarkdownColor
    let codeBackground: MarkdownColor
    let codeBorder: MarkdownColor
    let quoteForeground: MarkdownColor
    let link: MarkdownColor
    let tableHeaderBackground: MarkdownColor
    let evenRowBackground: MarkdownColor
}

struct AppThemePalette: Hashable {
    let background: ThemeRGB
    let panel: ThemeRGB
    let panel2: ThemeRGB
    let line: ThemeRGB
    let lineBright: ThemeRGB
    let text: ThemeRGB
    let secondaryText: ThemeRGB
    let muted: ThemeRGB
    let accent: ThemeRGB
    let danger: ThemeRGB
    let good: ThemeRGB
    let userRow: ThemeRGB
    let codeText: ThemeRGB
    let codeBackground: ThemeRGB
    let markdown: MarkdownThemePalette

    // The former CSS markdown colors used #rrggbb, not the unrounded
    // decimal components of the app palette in five of the themes.
    var markdownAccent: MarkdownColor { MarkdownColor(hex: accent.byteHex) }
    var markdownPreBackground: MarkdownColor { MarkdownColor(hex: codeBackground.byteHex) }
    var markdownCodeForeground: MarkdownColor { MarkdownColor(hex: codeText.byteHex) }
}

private extension ThemeRGB {
    var byteHex: Int {
        let r = Int((red * 255).rounded())
        let g = Int((green * 255).rounded())
        let b = Int((blue * 255).rounded())
        return (r << 16) | (g << 8) | b
    }
}

enum AppThemeChoice: String, CaseIterable, Identifiable, Hashable {
    case defaultTheme = "default"
    case oxocarbonDark = "oxocarbonDark"
    case seoul256 = "seoul256"
    case nord = "nord"
    case rosePine = "rosePine"
    case aura = "aura"
    case atomOneDark = "atomOneDark"
    case monokaiProSpectrum = "monokaiProSpectrum"
    case ayuLight = "ayuLight"
    case githubLight = "githubLight"
    case everforestDark = "everforestDark"
    case dracula = "dracula"
    case tokyoNightStorm = "tokyoNightStorm"

    private static let storageKey = "PiG.selectedTheme"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .defaultTheme: return "Finder Blue (Default)"
        case .oxocarbonDark: return "Oxocarbon Dark"
        case .seoul256: return "Seoul256"
        case .nord: return "Nord"
        case .rosePine: return "Rosé Pine"
        case .aura: return "Aura"
        case .atomOneDark: return "Atom One Dark"
        case .monokaiProSpectrum: return "Monokai Pro Spectrum"
        case .ayuLight: return "Ayu Light"
        case .githubLight: return "GitHub Light"
        case .everforestDark: return "Everforest Dark"
        case .dracula: return "Dracula"
        case .tokyoNightStorm: return "Tokyo Night Storm"
        }
    }

    static var stored: AppThemeChoice {
        get { AppThemeChoice(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .defaultTheme }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }

    var isLight: Bool { palette.background.relativeLuminance > 0.179 }

    private static let palettes: [AppThemeChoice: AppThemePalette] = Dictionary(
        uniqueKeysWithValues: allCases.map { ($0, $0.makePalette()) }
    )

    var palette: AppThemePalette { Self.palettes[self]! }

    private func makePalette() -> AppThemePalette {
        switch self {
        case .defaultTheme:
            // Keep the persisted "default" identifier so existing Default selections follow the new palette.
            return AppThemePalette(
                background: ThemeRGB(hex: 0x222426),
                panel: ThemeRGB(hex: 0x292b2f),
                panel2: ThemeRGB(hex: 0x303236),
                line: ThemeRGB(hex: 0x43464c),
                lineBright: ThemeRGB(hex: 0x4ca8ff),
                text: ThemeRGB(hex: 0xeceef1),
                secondaryText: ThemeRGB(hex: 0xb9bec5),
                muted: ThemeRGB(hex: 0x9ca1aa),
                accent: ThemeRGB(hex: 0x4ca8ff),
                danger: ThemeRGB(hex: 0xff6b61),
                good: ThemeRGB(hex: 0x65c88d),
                userRow: ThemeRGB(hex: 0x303236),
                codeText: ThemeRGB(hex: 0xa5ceff),
                codeBackground: ThemeRGB(hex: 0x1d1f22),
                markdown: MarkdownThemePalette(
                    userForeground: MarkdownColor(hex: 0xeceef1),
                    assistantForeground: MarkdownColor(hex: 0xd8dce1),
                    strong: MarkdownColor(hex: 0xf5f6f8),
                    emphasis: MarkdownColor(hex: 0xa5ceff),
                    deleted: MarkdownColor(hex: 0x9ca1aa),
                    codeBackground: MarkdownColor(hex: 0x4ca8ff, opacity: 0.12),
                    codeBorder: MarkdownColor(hex: 0x4ca8ff, opacity: 0.26),
                    quoteForeground: MarkdownColor(hex: 0xb9bec5),
                    link: MarkdownColor(hex: 0x73baff),
                    tableHeaderBackground: MarkdownColor(hex: 0x4ca8ff, opacity: 0.14),
                    evenRowBackground: MarkdownColor(hex: 0xffffff, opacity: 0.03)
                )
            )
        case .oxocarbonDark:
            return AppThemePalette(
                background: ThemeRGB(hex: 0x161616),
                panel: ThemeRGB(hex: 0x0c0c0c),
                panel2: ThemeRGB(hex: 0x262626),
                line: ThemeRGB(hex: 0x393939),
                lineBright: ThemeRGB(hex: 0x78a9ff),
                text: ThemeRGB(hex: 0xf2f4f8),
                secondaryText: ThemeRGB(hex: 0xdde1e6),
                muted: ThemeRGB(hex: 0xa2a9b0),
                accent: ThemeRGB(hex: 0x78a9ff),
                danger: ThemeRGB(hex: 0xff7eb6),
                good: ThemeRGB(hex: 0x42be65),
                userRow: ThemeRGB(hex: 0x262626),
                codeText: ThemeRGB(hex: 0xbe95ff),
                codeBackground: ThemeRGB(hex: 0x0c0c0c),
                markdown: MarkdownThemePalette(
                    userForeground: MarkdownColor(hex: 0xf2f4f8),
                    assistantForeground: MarkdownColor(hex: 0xdde1e6),
                    strong: MarkdownColor(hex: 0xf2f4f8),
                    emphasis: MarkdownColor(hex: 0xbe95ff),
                    deleted: MarkdownColor(hex: 0xa2a9b0),
                    codeBackground: MarkdownColor(hex: 0xbe95ff, opacity: 0.12),
                    codeBorder: MarkdownColor(hex: 0x78a9ff, opacity: 0.26),
                    quoteForeground: MarkdownColor(hex: 0xa2a9b0),
                    link: MarkdownColor(hex: 0x78a9ff),
                    tableHeaderBackground: MarkdownColor(hex: 0x78a9ff, opacity: 0.14),
                    evenRowBackground: MarkdownColor(hex: 0xffffff, opacity: 0.03)
                )
            )
        case .seoul256:
            return AppThemePalette(
                background: ThemeRGB(red: 0.227, green: 0.227, blue: 0.227), // #3a3a3a
                panel: ThemeRGB(red: 0.188, green: 0.188, blue: 0.188),      // #303030
                panel2: ThemeRGB(red: 0.306, green: 0.306, blue: 0.306),     // #4e4e4e
                line: ThemeRGB(red: 0.384, green: 0.384, blue: 0.384),       // #626262
                lineBright: ThemeRGB(red: 0.847, green: 0.686, blue: 0.373), // #d8af5f
                text: ThemeRGB(red: 0.816, green: 0.816, blue: 0.816),       // #d0d0d0
                secondaryText: ThemeRGB(red: 0.776, green: 0.776, blue: 0.776),
                muted: ThemeRGB(red: 0.627, green: 0.627, blue: 0.627),
                accent: ThemeRGB(red: 0.522, green: 0.678, blue: 0.831),     // #85add4
                danger: ThemeRGB(red: 0.839, green: 0.529, blue: 0.529),     // #d68787
                good: ThemeRGB(red: 0.373, green: 0.525, blue: 0.373),       // #5f865f
                userRow: ThemeRGB(red: 0.267, green: 0.267, blue: 0.267),
                codeText: ThemeRGB(red: 0.847, green: 0.686, blue: 0.373),
                codeBackground: ThemeRGB(red: 0.188, green: 0.188, blue: 0.188),
                markdown: MarkdownThemePalette(
                    userForeground: MarkdownColor(hex: 0xdadada),
                    assistantForeground: MarkdownColor(hex: 0xd0d0d0),
                    strong: MarkdownColor(hex: 0xdadada),
                    emphasis: MarkdownColor(hex: 0xd7afaf),
                    deleted: MarkdownColor(hex: 0x9e9e9e),
                    codeBackground: MarkdownColor(hex: 0xd8af5f, opacity: 0.12),
                    codeBorder: MarkdownColor(hex: 0xd8af5f, opacity: 0.24),
                    quoteForeground: MarkdownColor(hex: 0xbcbcbc),
                    link: MarkdownColor(hex: 0x85add4),
                    tableHeaderBackground: MarkdownColor(hex: 0x85add4, opacity: 0.14),
                    evenRowBackground: MarkdownColor(hex: 0xffffff, opacity: 0.035)
                )
            )
        case .nord:
            return AppThemePalette(
                background: ThemeRGB(red: 0.180, green: 0.204, blue: 0.251),   // #2e3440
                panel: ThemeRGB(red: 0.169, green: 0.188, blue: 0.231),        // #2b303b
                panel2: ThemeRGB(red: 0.231, green: 0.259, blue: 0.322),       // #3b4252
                line: ThemeRGB(red: 0.263, green: 0.298, blue: 0.369),         // #434c5e
                lineBright: ThemeRGB(red: 0.369, green: 0.506, blue: 0.675),   // #5e81ac
                text: ThemeRGB(red: 0.925, green: 0.937, blue: 0.957),         // #eceff4
                secondaryText: ThemeRGB(red: 0.847, green: 0.871, blue: 0.914),// #d8dee9
                muted: ThemeRGB(red: 0.482, green: 0.518, blue: 0.580),        // #7b8494
                accent: ThemeRGB(red: 0.533, green: 0.753, blue: 0.816),       // #88c0d0
                danger: ThemeRGB(red: 0.749, green: 0.380, blue: 0.416),       // #bf616a
                good: ThemeRGB(red: 0.639, green: 0.745, blue: 0.549),         // #a3be8c
                userRow: ThemeRGB(red: 0.231, green: 0.259, blue: 0.322),
                codeText: ThemeRGB(red: 0.561, green: 0.737, blue: 0.733),     // #8fbcbb
                codeBackground: ThemeRGB(red: 0.153, green: 0.173, blue: 0.212),// #272c36
                markdown: MarkdownThemePalette(
                    userForeground: MarkdownColor(hex: 0xeceff4),
                    assistantForeground: MarkdownColor(hex: 0xd8dee9),
                    strong: MarkdownColor(hex: 0xeceff4),
                    emphasis: MarkdownColor(hex: 0xb48ead),
                    deleted: MarkdownColor(hex: 0x7b8494),
                    codeBackground: MarkdownColor(hex: 0x88c0d0, opacity: 0.12),
                    codeBorder: MarkdownColor(hex: 0x88c0d0, opacity: 0.26),
                    quoteForeground: MarkdownColor(hex: 0x9aa4b5),
                    link: MarkdownColor(hex: 0x81a1c1),
                    tableHeaderBackground: MarkdownColor(hex: 0x88c0d0, opacity: 0.14),
                    evenRowBackground: MarkdownColor(hex: 0xffffff, opacity: 0.03)
                )
            )
        case .rosePine:
            return AppThemePalette(
                background: ThemeRGB(red: 0.098, green: 0.090, blue: 0.141),   // #191724
                panel: ThemeRGB(red: 0.122, green: 0.114, blue: 0.180),        // #1f1d2e
                panel2: ThemeRGB(red: 0.149, green: 0.137, blue: 0.227),       // #26233a
                line: ThemeRGB(red: 0.192, green: 0.180, blue: 0.271),         // #312e45
                lineBright: ThemeRGB(red: 0.769, green: 0.655, blue: 0.906),   // #c4a7e7
                text: ThemeRGB(red: 0.878, green: 0.871, blue: 0.957),         // #e0def4
                secondaryText: ThemeRGB(red: 0.784, green: 0.773, blue: 0.867),// #c8c5dd
                muted: ThemeRGB(red: 0.431, green: 0.416, blue: 0.525),        // #6e6a86
                accent: ThemeRGB(red: 0.769, green: 0.655, blue: 0.906),       // #c4a7e7
                danger: ThemeRGB(red: 0.922, green: 0.435, blue: 0.573),       // #eb6f92
                good: ThemeRGB(red: 0.612, green: 0.812, blue: 0.847),         // #9ccfd8
                userRow: ThemeRGB(red: 0.149, green: 0.137, blue: 0.227),
                codeText: ThemeRGB(red: 0.965, green: 0.757, blue: 0.467),     // #f6c177
                codeBackground: ThemeRGB(red: 0.086, green: 0.078, blue: 0.129),// #161421
                markdown: MarkdownThemePalette(
                    userForeground: MarkdownColor(hex: 0xe0def4),
                    assistantForeground: MarkdownColor(hex: 0xe0def4),
                    strong: MarkdownColor(hex: 0xe0def4),
                    emphasis: MarkdownColor(hex: 0xebbcba),
                    deleted: MarkdownColor(hex: 0x6e6a86),
                    codeBackground: MarkdownColor(hex: 0xf6c177, opacity: 0.12),
                    codeBorder: MarkdownColor(hex: 0xf6c177, opacity: 0.26),
                    quoteForeground: MarkdownColor(hex: 0x908caa),
                    link: MarkdownColor(hex: 0xebbcba),
                    tableHeaderBackground: MarkdownColor(hex: 0xc4a7e7, opacity: 0.14),
                    evenRowBackground: MarkdownColor(hex: 0xffffff, opacity: 0.03)
                )
            )
        case .aura:
            return AppThemePalette(
                background: ThemeRGB(red: 0.082, green: 0.078, blue: 0.106),   // #15141b
                panel: ThemeRGB(red: 0.122, green: 0.114, blue: 0.169),        // #1f1d2b
                panel2: ThemeRGB(red: 0.165, green: 0.149, blue: 0.220),       // #2a2638
                line: ThemeRGB(red: 0.231, green: 0.200, blue: 0.302),         // #3b334d
                lineBright: ThemeRGB(red: 0.635, green: 0.467, blue: 1.000),   // #a277ff
                text: ThemeRGB(red: 0.929, green: 0.925, blue: 0.933),         // #edecee
                secondaryText: ThemeRGB(red: 0.776, green: 0.765, blue: 0.808),// #c6c3ce
                muted: ThemeRGB(red: 0.427, green: 0.427, blue: 0.486),        // #6d6d7c
                accent: ThemeRGB(red: 0.635, green: 0.467, blue: 1.000),       // #a277ff
                danger: ThemeRGB(red: 1.000, green: 0.404, blue: 0.404),       // #ff6767
                good: ThemeRGB(red: 0.380, green: 1.000, blue: 0.792),         // #61ffca
                userRow: ThemeRGB(red: 0.133, green: 0.106, blue: 0.200),      // #221b33
                codeText: ThemeRGB(red: 1.000, green: 0.792, blue: 0.522),     // #ffca85
                codeBackground: ThemeRGB(red: 0.067, green: 0.059, blue: 0.094),// #110f18
                markdown: MarkdownThemePalette(
                    userForeground: MarkdownColor(hex: 0xedecee),
                    assistantForeground: MarkdownColor(hex: 0xedecee),
                    strong: MarkdownColor(hex: 0xffffff),
                    emphasis: MarkdownColor(hex: 0xa277ff),
                    deleted: MarkdownColor(hex: 0x6d6d7c),
                    codeBackground: MarkdownColor(hex: 0xffca85, opacity: 0.12),
                    codeBorder: MarkdownColor(hex: 0xa277ff, opacity: 0.28),
                    quoteForeground: MarkdownColor(hex: 0xc6c3ce),
                    link: MarkdownColor(hex: 0x61ffca),
                    tableHeaderBackground: MarkdownColor(hex: 0xa277ff, opacity: 0.16),
                    evenRowBackground: MarkdownColor(hex: 0xffffff, opacity: 0.035)
                )
            )
        case .atomOneDark:
            return AppThemePalette(
                background: ThemeRGB(red: 0.157, green: 0.173, blue: 0.204),   // #282c34
                panel: ThemeRGB(red: 0.129, green: 0.145, blue: 0.169),        // #21252b
                panel2: ThemeRGB(red: 0.173, green: 0.192, blue: 0.227),       // #2c313a
                line: ThemeRGB(red: 0.243, green: 0.267, blue: 0.318),         // #3e4451
                lineBright: ThemeRGB(red: 0.380, green: 0.686, blue: 0.937),   // #61afef
                text: ThemeRGB(red: 0.671, green: 0.698, blue: 0.749),         // #abb2bf
                secondaryText: ThemeRGB(red: 0.784, green: 0.800, blue: 0.831),// #c8ccd4
                muted: ThemeRGB(red: 0.361, green: 0.388, blue: 0.439),        // #5c6370
                accent: ThemeRGB(red: 0.380, green: 0.686, blue: 0.937),       // #61afef
                danger: ThemeRGB(red: 0.878, green: 0.424, blue: 0.459),       // #e06c75
                good: ThemeRGB(red: 0.596, green: 0.765, blue: 0.475),         // #98c379
                userRow: ThemeRGB(red: 0.184, green: 0.204, blue: 0.243),      // #2f343e
                codeText: ThemeRGB(red: 0.820, green: 0.604, blue: 0.400),     // #d19a66
                codeBackground: ThemeRGB(red: 0.118, green: 0.133, blue: 0.153),// #1e2227
                markdown: MarkdownThemePalette(
                    userForeground: MarkdownColor(hex: 0xc8ccd4),
                    assistantForeground: MarkdownColor(hex: 0xabb2bf),
                    strong: MarkdownColor(hex: 0xd7dae0),
                    emphasis: MarkdownColor(hex: 0xc678dd),
                    deleted: MarkdownColor(hex: 0x5c6370),
                    codeBackground: MarkdownColor(hex: 0xd19a66, opacity: 0.12),
                    codeBorder: MarkdownColor(hex: 0x61afef, opacity: 0.24),
                    quoteForeground: MarkdownColor(hex: 0x9da5b4),
                    link: MarkdownColor(hex: 0x56b6c2),
                    tableHeaderBackground: MarkdownColor(hex: 0x61afef, opacity: 0.14),
                    evenRowBackground: MarkdownColor(hex: 0xffffff, opacity: 0.03)
                )
            )
        case .monokaiProSpectrum:
            return AppThemePalette(
                background: ThemeRGB(hex: 0x222222),
                panel: ThemeRGB(hex: 0x191919),
                panel2: ThemeRGB(hex: 0x2c2c2c),
                line: ThemeRGB(hex: 0x3a3a3a),
                lineBright: ThemeRGB(hex: 0xfc618d),
                text: ThemeRGB(hex: 0xf7f1ff),
                secondaryText: ThemeRGB(hex: 0xd8d2df),
                muted: ThemeRGB(hex: 0x8f8997),
                accent: ThemeRGB(hex: 0xfc618d),
                danger: ThemeRGB(hex: 0xfc618d),
                good: ThemeRGB(hex: 0x7bd88f),
                userRow: ThemeRGB(hex: 0x2c2c2c),
                codeText: ThemeRGB(hex: 0xfce566),
                codeBackground: ThemeRGB(hex: 0x131313),
                markdown: MarkdownThemePalette(
                    userForeground: MarkdownColor(hex: 0xf7f1ff),
                    assistantForeground: MarkdownColor(hex: 0xf7f1ff),
                    strong: MarkdownColor(hex: 0xffffff),
                    emphasis: MarkdownColor(hex: 0xfd9353),
                    deleted: MarkdownColor(hex: 0x8f8997),
                    codeBackground: MarkdownColor(hex: 0xfce566, opacity: 0.12),
                    codeBorder: MarkdownColor(hex: 0xfc618d, opacity: 0.26),
                    quoteForeground: MarkdownColor(hex: 0xd8d2df),
                    link: MarkdownColor(hex: 0x5ad4e6),
                    tableHeaderBackground: MarkdownColor(hex: 0xfc618d, opacity: 0.14),
                    evenRowBackground: MarkdownColor(hex: 0xffffff, opacity: 0.03)
                )
            )
        case .ayuLight:
            return AppThemePalette(
                background: ThemeRGB(hex: 0xfafafa),
                panel: ThemeRGB(hex: 0xf0f0f0),
                panel2: ThemeRGB(hex: 0xffffff),
                line: ThemeRGB(hex: 0xdedede),
                lineBright: ThemeRGB(hex: 0xa65c00),
                text: ThemeRGB(hex: 0x575f66),
                secondaryText: ThemeRGB(hex: 0x5c6773),
                muted: ThemeRGB(hex: 0x737d85),
                accent: ThemeRGB(hex: 0xa65c00),
                danger: ThemeRGB(hex: 0xb73232),
                good: ThemeRGB(hex: 0x557400),
                userRow: ThemeRGB(hex: 0xf0eee4),
                codeText: ThemeRGB(hex: 0x874b00),
                codeBackground: ThemeRGB(hex: 0xf0f0f0),
                markdown: MarkdownThemePalette(
                    userForeground: MarkdownColor(hex: 0x575f66),
                    assistantForeground: MarkdownColor(hex: 0x575f66),
                    strong: MarkdownColor(hex: 0x3e4b59),
                    emphasis: MarkdownColor(hex: 0xa65c00),
                    deleted: MarkdownColor(hex: 0x737d85),
                    codeBackground: MarkdownColor(hex: 0xa65c00, opacity: 0.10),
                    codeBorder: MarkdownColor(hex: 0xa65c00, opacity: 0.24),
                    quoteForeground: MarkdownColor(hex: 0x5c6773),
                    link: MarkdownColor(hex: 0x286e9d),
                    tableHeaderBackground: MarkdownColor(hex: 0xa65c00, opacity: 0.10),
                    evenRowBackground: MarkdownColor(hex: 0x000000, opacity: 0.025)
                )
            )
        case .githubLight:
            return AppThemePalette(
                background: ThemeRGB(hex: 0xffffff),
                panel: ThemeRGB(hex: 0xf6f8fa),
                panel2: ThemeRGB(hex: 0xeaeef2),
                line: ThemeRGB(hex: 0xd1d9e0),
                lineBright: ThemeRGB(hex: 0x0969da),
                text: ThemeRGB(hex: 0x1f2328),
                secondaryText: ThemeRGB(hex: 0x424a53),
                muted: ThemeRGB(hex: 0x59636e),
                accent: ThemeRGB(hex: 0x0969da),
                danger: ThemeRGB(hex: 0xb42318),
                good: ThemeRGB(hex: 0x1a7f37),
                userRow: ThemeRGB(hex: 0xf6f8fa),
                codeText: ThemeRGB(hex: 0x8250df),
                codeBackground: ThemeRGB(hex: 0xf6f8fa),
                markdown: MarkdownThemePalette(
                    userForeground: MarkdownColor(hex: 0x1f2328),
                    assistantForeground: MarkdownColor(hex: 0x1f2328),
                    strong: MarkdownColor(hex: 0x1f2328),
                    emphasis: MarkdownColor(hex: 0x8250df),
                    deleted: MarkdownColor(hex: 0x59636e),
                    codeBackground: MarkdownColor(hex: 0x8250df, opacity: 0.10),
                    codeBorder: MarkdownColor(hex: 0x0969da, opacity: 0.22),
                    quoteForeground: MarkdownColor(hex: 0x59636e),
                    link: MarkdownColor(hex: 0x0969da),
                    tableHeaderBackground: MarkdownColor(hex: 0x0969da, opacity: 0.10),
                    evenRowBackground: MarkdownColor(hex: 0x000000, opacity: 0.025)
                )
            )
        case .everforestDark:
            return AppThemePalette(
                background: ThemeRGB(hex: 0x2d353b),
                panel: ThemeRGB(hex: 0x232a2e),
                panel2: ThemeRGB(hex: 0x3d484d),
                line: ThemeRGB(hex: 0x4f585e),
                lineBright: ThemeRGB(hex: 0xa7c080),
                text: ThemeRGB(hex: 0xd3c6aa),
                secondaryText: ThemeRGB(hex: 0xc1b89f),
                muted: ThemeRGB(hex: 0x9da9a0),
                accent: ThemeRGB(hex: 0xa7c080),
                danger: ThemeRGB(hex: 0xe67e80),
                good: ThemeRGB(hex: 0x83c092),
                userRow: ThemeRGB(hex: 0x343f44),
                codeText: ThemeRGB(hex: 0xdbbc7f),
                codeBackground: ThemeRGB(hex: 0x232a2e),
                markdown: MarkdownThemePalette(
                    userForeground: MarkdownColor(hex: 0xd3c6aa),
                    assistantForeground: MarkdownColor(hex: 0xd3c6aa),
                    strong: MarkdownColor(hex: 0xe5d8bb),
                    emphasis: MarkdownColor(hex: 0xd699b6),
                    deleted: MarkdownColor(hex: 0x9da9a0),
                    codeBackground: MarkdownColor(hex: 0xdbbc7f, opacity: 0.12),
                    codeBorder: MarkdownColor(hex: 0xa7c080, opacity: 0.25),
                    quoteForeground: MarkdownColor(hex: 0xa7b7a7),
                    link: MarkdownColor(hex: 0x7fbbb3),
                    tableHeaderBackground: MarkdownColor(hex: 0xa7c080, opacity: 0.14),
                    evenRowBackground: MarkdownColor(hex: 0xffffff, opacity: 0.03)
                )
            )
        case .dracula:
            return AppThemePalette(
                background: ThemeRGB(hex: 0x282a36),
                panel: ThemeRGB(hex: 0x21222c),
                panel2: ThemeRGB(hex: 0x44475a),
                line: ThemeRGB(hex: 0x54576b),
                lineBright: ThemeRGB(hex: 0xbd93f9),
                text: ThemeRGB(hex: 0xf8f8f2),
                secondaryText: ThemeRGB(hex: 0xdbdbe3),
                muted: ThemeRGB(hex: 0xa7aec4),
                accent: ThemeRGB(hex: 0xbd93f9),
                danger: ThemeRGB(hex: 0xff5555),
                good: ThemeRGB(hex: 0x50fa7b),
                userRow: ThemeRGB(hex: 0x44475a),
                codeText: ThemeRGB(hex: 0xf1fa8c),
                codeBackground: ThemeRGB(hex: 0x21222c),
                markdown: MarkdownThemePalette(
                    userForeground: MarkdownColor(hex: 0xf8f8f2),
                    assistantForeground: MarkdownColor(hex: 0xf8f8f2),
                    strong: MarkdownColor(hex: 0xffffff),
                    emphasis: MarkdownColor(hex: 0xff79c6),
                    deleted: MarkdownColor(hex: 0xa7aec4),
                    codeBackground: MarkdownColor(hex: 0xf1fa8c, opacity: 0.12),
                    codeBorder: MarkdownColor(hex: 0xbd93f9, opacity: 0.26),
                    quoteForeground: MarkdownColor(hex: 0xc6c9db),
                    link: MarkdownColor(hex: 0x8be9fd),
                    tableHeaderBackground: MarkdownColor(hex: 0xbd93f9, opacity: 0.14),
                    evenRowBackground: MarkdownColor(hex: 0xffffff, opacity: 0.03)
                )
            )
        case .tokyoNightStorm:
            return AppThemePalette(
                background: ThemeRGB(hex: 0x24283b),
                panel: ThemeRGB(hex: 0x1f2335),
                panel2: ThemeRGB(hex: 0x292e42),
                line: ThemeRGB(hex: 0x3b4261),
                lineBright: ThemeRGB(hex: 0x7aa2f7),
                text: ThemeRGB(hex: 0xc0caf5),
                secondaryText: ThemeRGB(hex: 0xa9b1d6),
                muted: ThemeRGB(hex: 0x8992b0),
                accent: ThemeRGB(hex: 0x7aa2f7),
                danger: ThemeRGB(hex: 0xf7768e),
                good: ThemeRGB(hex: 0x9ece6a),
                userRow: ThemeRGB(hex: 0x292e42),
                codeText: ThemeRGB(hex: 0xe0af68),
                codeBackground: ThemeRGB(hex: 0x1b1e2d),
                markdown: MarkdownThemePalette(
                    userForeground: MarkdownColor(hex: 0xc0caf5),
                    assistantForeground: MarkdownColor(hex: 0xc0caf5),
                    strong: MarkdownColor(hex: 0xd7ddff),
                    emphasis: MarkdownColor(hex: 0xbb9af7),
                    deleted: MarkdownColor(hex: 0x8992b0),
                    codeBackground: MarkdownColor(hex: 0xe0af68, opacity: 0.12),
                    codeBorder: MarkdownColor(hex: 0x7aa2f7, opacity: 0.26),
                    quoteForeground: MarkdownColor(hex: 0xa9b1d6),
                    link: MarkdownColor(hex: 0x7dcfff),
                    tableHeaderBackground: MarkdownColor(hex: 0x7aa2f7, opacity: 0.14),
                    evenRowBackground: MarkdownColor(hex: 0xffffff, opacity: 0.03)
                )
            )
        }
    }
}

enum AppFonts {
    static let codeFamilies = ["Hack Nerd Font", "Hack Nerd Font Mono"]
    static func scaled(_ size: CGFloat) -> CGFloat { size * TextSizePreference.scale }

    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: scaled(size), weight: weight, design: .default)
    }

    static func heading(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: scaled(size), weight: weight, design: .rounded)
    }

    static func code(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let size = scaled(size)
        if let family = installedCodeFamily(size: size) {
            return .custom(family, size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }

    static func nsUI(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: scaled(size), weight: weight)
    }

    static func nsHeading(_ size: CGFloat, weight: NSFont.Weight = .semibold) -> NSFont {
        let size = scaled(size)
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = font.fontDescriptor.withDesign(.rounded),
           let rounded = NSFont(descriptor: descriptor, size: size) {
            return rounded
        }
        return font
    }

    static func nsCode(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let size = scaled(size)
        if let family = installedCodeFamily(size: size), let font = NSFont(name: family, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    private static func installedCodeFamily(size: CGFloat) -> String? {
        codeFamilies.first { NSFont(name: $0, size: size) != nil }
    }
}

struct AppTheme: Hashable {
    let choice: AppThemeChoice
    let palette: AppThemePalette
    let textSizeStep: Int

    init(choice: AppThemeChoice, textSizeStep: Int = TextSizePreference.step) {
        self.choice = choice
        self.palette = choice.palette
        self.textSizeStep = textSizeStep
    }

    var background: Color { palette.background.color }
    var panel: Color { palette.panel.color }
    var panel2: Color { palette.panel2.color }
    var line: Color { palette.line.color }
    var lineBright: Color { palette.lineBright.color }
    var text: Color { palette.text.color }
    var secondaryText: Color { palette.secondaryText.color }
    var muted: Color { palette.muted.color }
    var brass: Color { palette.accent.color }
    var accentForeground: Color { palette.accent.contrastingForeground }
    var dangerForeground: Color { palette.danger.contrastingForeground }
    var toolRunning: Color {
        choice == .monokaiProSpectrum ? ThemeRGB(hex: 0xfce566).color : palette.accent.color
    }
    var danger: Color { palette.danger.color }
    var good: Color { palette.good.color }
    var userRow: Color { palette.userRow.color }
    var codeText: Color { palette.codeText.color }
    var codeBackground: Color { palette.codeBackground.color }

}

private struct AppThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppTheme(choice: .defaultTheme)
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeEnvironmentKey.self] }
        set { self[AppThemeEnvironmentKey.self] = newValue }
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
