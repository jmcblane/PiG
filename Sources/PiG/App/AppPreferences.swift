import Foundation

extension UserDefaults {
    func bool(forKey key: String, default fallback: Bool) -> Bool {
        object(forKey: key) == nil ? fallback : bool(forKey: key)
    }

    func integer(forKey key: String, default fallback: Int) -> Int {
        object(forKey: key) == nil ? fallback : integer(forKey: key)
    }

    func string(forKey key: String, default fallback: String) -> String {
        string(forKey: key) ?? fallback
    }

    func stringArray(forKey key: String, default fallback: [String]) -> [String] {
        stringArray(forKey: key) ?? fallback
    }

    func storedEnum<Value: RawRepresentable>(forKey key: String, default fallback: Value) -> Value where Value.RawValue == String {
        string(forKey: key).flatMap(Value.init(rawValue:)) ?? fallback
    }

    func trimmedString(forKey key: String) -> String? {
        string(forKey: key)?.nonEmptyTrimmed
    }

    func setTrimmedString(_ value: String?, forKey key: String) {
        if let value = value?.nonEmptyTrimmed { set(value, forKey: key) }
        else { removeObject(forKey: key) }
    }
}

enum PiExecutablePreference {
    private static let key = "PiG.piExecutablePath"

    static var path: String? {
        get { UserDefaults.standard.trimmedString(forKey: key) }
        set { UserDefaults.standard.setTrimmedString(newValue, forKey: key) }
    }
}

enum TextSizePreference {
    static let steps: [CGFloat] = [0.85, 0.92, 1, 1.08, 1.16, 1.25, 1.35, 1.5]
    static let actualSizeStep = 2
    private static let key = "PiG.view.textSizeStep"

    static var step: Int {
        get { min(max(UserDefaults.standard.integer(forKey: key, default: actualSizeStep), 0), steps.count - 1) }
        set { UserDefaults.standard.set(min(max(newValue, 0), steps.count - 1), forKey: key) }
    }

    static var scale: CGFloat { steps[step] }
}

enum NotificationPreference {
    private static let key = "PiG.notificationsEnabled"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

enum SidebarPreference {
    private static let visibilityKey = "PiG.sidebar.visible"
    private static let widthKey = "PiG.sidebar.width"

    static var visible: Bool {
        get { UserDefaults.standard.bool(forKey: visibilityKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: visibilityKey) }
    }

    static var width: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: widthKey)
            return stored > 0 ? CGFloat(stored) : 238
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: widthKey) }
    }
}

enum QuickChatsFolderPreference {
    static let key = "PiG.quickChats.folderPath"

    static var path: String? {
        UserDefaults.standard.trimmedString(forKey: key)
    }
}

enum TitleGenerationExtensionsPreference {
    static let key = "PiG.sessionNaming.titleExtensions"

    static var paths: [String] {
        UserDefaults.standard.string(forKey: key, default: "")
            .components(separatedBy: .newlines)
            .compactMap(\.nonEmptyTrimmed)
            .map { ($0 as NSString).expandingTildeInPath }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }
}

enum SessionInboxStore {
    private static let key = "PiG.sidebar.sessionInbox"
    private static let sessionPrefix = "session:"

    static var ids: [String] {
        let stored = UserDefaults.standard.stringArray(forKey: key) ?? []
        var seen = Set<String>()
        return stored
            .filter { $0.hasPrefix(sessionPrefix) }
            .filter { seen.insert($0).inserted }
    }

    static func save(_ ids: [String]) {
        UserDefaults.standard.set(ids.filter { $0.hasPrefix(sessionPrefix) }, forKey: key)
    }
}

enum PinnedResourceStore {
    private static let key = "PiG.resources.pinnedIDs"

    static var ids: [String] {
        var seen = Set<String>()
        return (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .filter { seen.insert($0).inserted }
    }

    static func save(_ ids: [String]) {
        UserDefaults.standard.set(ids, forKey: key)
    }
}

enum ThinkingTracePreference {
    private static let key = "PiG.view.showThinkingTraces"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

enum ComposerFocusAccentPreference {
    private static let key = "PiG.composer.focusAccent"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

enum ProjectHeaderStyle: String, CaseIterable, Identifiable, Hashable {
    case nameOnly = "nameOnly"
    case band = "band"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nameOnly: return "Name Only"
        case .band: return "Band"
        }
    }

    private static let storageKey = "PiG.sidebar.projectHeaderStyle"

    static var stored: ProjectHeaderStyle {
        get { UserDefaults.standard.storedEnum(forKey: storageKey, default: .nameOnly) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }
}
