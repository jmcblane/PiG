import SwiftUI
import AppKit

protocol FontChoice: Hashable {
    static var presets: [Self] { get }
    static var installedFamilies: [String] { get }
    static func family(_ name: String) -> Self
    var displayName: String { get }
    /// The family picked from the installed fonts, or nil for a preset.
    var customFamily: String? { get }
}

enum InterfaceFont: FontChoice {
    case system, rounded, serif
    case family(String)

    static let presets: [InterfaceFont] = [.system, .rounded, .serif]
    static var installedFamilies: [String] { FontFamilies.all }

    init(storedValue: String?) {
        switch storedValue {
        case "rounded": self = .rounded
        case "serif": self = .serif
        default:
            if let name = FontFamilies.installedFamily(fromStoredValue: storedValue) { self = .family(name) }
            else { self = .system }
        }
    }

    var storedValue: String {
        switch self {
        case .system: "system"
        case .rounded: "rounded"
        case .serif: "serif"
        case .family(let name): FontFamilies.storedValue(for: name)
        }
    }

    var displayName: String {
        switch self {
        case .system: "System"
        case .rounded: "Rounded"
        case .serif: "Serif"
        case .family(let name): name
        }
    }

    var customFamily: String? {
        if case .family(let name) = self { return name }
        return nil
    }

    /// Headings stay rounded with the system font, as before this setting
    /// existed; every other choice uses one face for headings and body.
    /// Families are loaded by name, so their design is unused.
    func design(heading: Bool) -> Font.Design {
        switch self {
        case .system: heading ? .rounded : .default
        case .family: .default
        case .rounded: .rounded
        case .serif: .serif
        }
    }

    func nsDesign(heading: Bool) -> NSFontDescriptor.SystemDesign {
        switch design(heading: heading) {
        case .rounded: .rounded
        case .serif: .serif
        default: .default
        }
    }
}

enum CodeFont: FontChoice {
    /// Hack Nerd Font when installed, otherwise SF Mono.
    case standard
    case sfMono, menlo
    case family(String)

    static var presets: [CodeFont] {
        AppFonts.installedHackFamily == nil ? [.standard, .menlo] : [.standard, .sfMono, .menlo]
    }

    static var installedFamilies: [String] { FontFamilies.monospaced }

    init(storedValue: String?) {
        switch storedValue {
        case "sfMono": self = .sfMono
        case "menlo": self = .menlo
        default:
            if let name = FontFamilies.installedFamily(fromStoredValue: storedValue) { self = .family(name) }
            else { self = .standard }
        }
    }

    var storedValue: String {
        switch self {
        case .standard: "standard"
        case .sfMono: "sfMono"
        case .menlo: "menlo"
        case .family(let name): FontFamilies.storedValue(for: name)
        }
    }

    var displayName: String {
        switch self {
        case .standard: AppFonts.installedHackFamily ?? "SF Mono"
        case .sfMono: "SF Mono"
        case .menlo: "Menlo"
        case .family(let name): name
        }
    }

    var customFamily: String? {
        if case .family(let name) = self { return name }
        return nil
    }

    /// The family to load, or nil for the system monospaced font.
    var fontFamily: String? {
        switch self {
        case .standard: AppFonts.installedHackFamily
        case .sfMono: nil
        case .menlo: "Menlo"
        case .family(let name): name
        }
    }
}

enum FontPreference {
    private static let interfaceKey = "PiG.view.interfaceFont"
    private static let codeKey = "PiG.view.codeFont"

    // Held in memory because AppFonts reads these on every font it builds.
    static var interface = InterfaceFont(storedValue: UserDefaults.standard.string(forKey: interfaceKey)) {
        didSet { UserDefaults.standard.set(interface.storedValue, forKey: interfaceKey) }
    }

    static var code = CodeFont(storedValue: UserDefaults.standard.string(forKey: codeKey)) {
        didSet { UserDefaults.standard.set(code.storedValue, forKey: codeKey) }
    }
}

/// Everything that changes how text is measured. Rendered-text caches and
/// layout passes key on this so a size or font change redraws them.
struct TextStyle: Hashable {
    var sizeStep: Int
    var interfaceFont: InterfaceFont
    var codeFont: CodeFont

    static var current: TextStyle {
        TextStyle(sizeStep: TextSizePreference.step, interfaceFont: FontPreference.interface, codeFont: FontPreference.code)
    }

    var scale: CGFloat {
        TextSizePreference.steps[min(max(sizeStep, 0), TextSizePreference.steps.count - 1)]
    }
}

enum FontFamilies {
    private static let familyPrefix = "family:"

    static let all: [String] = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }

    static let monospaced: [String] = all.filter {
        NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: $0]), size: 12)?.isFixedPitch == true
    }

    static func isInstalled(_ family: String) -> Bool {
        NSFontManager.shared.availableMembers(ofFontFamily: family) != nil
    }

    static func storedValue(for family: String) -> String { familyPrefix + family }

    /// A stored family that has since been uninstalled falls back to the default.
    static func installedFamily(fromStoredValue value: String?) -> String? {
        guard let value, value.hasPrefix(familyPrefix) else { return nil }
        let name = String(value.dropFirst(familyPrefix.count))
        return isInstalled(name) ? name : nil
    }
}
