import Foundation

/// Appearance of a pixel person. Colors are hex strings ("#rrggbb").
/// Same shape as PiAgents' `Look`, so imported agents keep their appearance.
struct Look: Codable, Hashable {
    enum Hair: String, Codable, CaseIterable { case short, bob, long, bun, curly, ponytail, spiky, buzz }
    enum Top: String, Codable, CaseIterable { case tee, collar, hoodie }
    enum Accessory: String, Codable, CaseIterable { case none, glasses, beard }

    var skin: String
    var hair: String
    var shirt: String
    var pants: String
    var shoes: String
    var hairStyle: Hair
    var top: Top
    var accessory: Accessory
    var accentColor: String
    var tie: String?
    var happy: Bool

    static let skins = ["#fbd9bf", "#f1c09a", "#dca47a", "#b77b52", "#8d5a3b", "#5e3b26"]
    static let hairs = ["#2b1d14", "#4a2c1a", "#7a4424", "#b5652f", "#d9a441", "#efe0b9", "#1c1a22", "#a33b2e", "#6d4c9e", "#3f7fbf", "#e27aa6", "#9aa3ad"]
    static let shirts = ["#e76f51", "#3a86ff", "#2a9d8f", "#9b5de5", "#f4a261", "#06a77d", "#ef476f", "#457b9d", "#ffb703", "#8ab17d", "#5c5f7a", "#d6d2c4"]
    static let pantsColors = ["#2c3e50", "#34495e", "#5d4037", "#1f2a44", "#4a4a4a", "#6b5b3e", "#3d5a80", "#7a6f5a"]
    static let shoeColors = ["#2d2d2d", "#5b3a29", "#e8e4dc", "#7a1f1f", "#2f4a6d"]
    static let accents = ["#e76f51", "#3a86ff", "#ffb703", "#06a77d", "#ef476f", "#9b5de5", "#2a2a36"]

    static func random() -> Look {
        let accessories: [Accessory] = [.none, .none, .none, .glasses, .glasses, .beard]
        let tops: [Top] = [.tee, .tee, .collar, .hoodie]
        return Look(
            skin: skins.randomElement()!, hair: hairs.randomElement()!,
            shirt: shirts.randomElement()!, pants: pantsColors.randomElement()!,
            shoes: shoeColors.randomElement()!, hairStyle: Hair.allCases.randomElement()!,
            top: tops.randomElement()!, accessory: accessories.randomElement()!,
            accentColor: accents.randomElement()!, tie: nil, happy: Bool.random()
        )
    }
}

enum AgentBackend: String, Codable, CaseIterable {
    case pi
    case hermes
}

/// Where a Hermes agent lives. The API key is stored separately under `credentialID`
/// (see `HermesCredentials`), never in agents.json.
struct HermesConnection: Codable, Hashable {
    var host: String
    var profile: String
    var port: Int
    var credentialID: String

    init(host: String = "", profile: String = "", port: Int = 8642, credentialID: String = UUID().uuidString) {
        self.host = host
        self.profile = profile
        self.port = port
        self.credentialID = credentialID
    }
}

/// A launch configuration and identity for any number of ordinary chats.
struct Agent: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var role: String
    var look: Look
    var backend: AgentBackend

    // Pi
    /// Project folder. nil uses PiG's Quick Chats folder, with saved sessions.
    var projectPath: String?
    /// "provider/modelId". Pi: nil means PiG's default model. Hermes: nil means the server default.
    var modelID: String?
    /// Pi thinking level; nil means PiG's default. Unused for Hermes.
    var thinking: String?
    /// Absolute SKILL.md paths. Their contents are appended to the system prompt.
    var skills: [String]
    /// nil: pi's default extensions. Non-nil: launch with `--no-extensions` and load only these
    /// (absolute file/package paths or `builtin:<name>`).
    var extensions: [String]?

    // Hermes
    var hermes: HermesConnection?

    init(
        id: String = String(UUID().uuidString.prefix(8)).lowercased(),
        name: String,
        role: String,
        look: Look = .random(),
        backend: AgentBackend = .pi,
        projectPath: String? = nil,
        modelID: String? = nil,
        thinking: String? = nil,
        skills: [String] = [],
        extensions: [String]? = nil,
        hermes: HermesConnection? = nil
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.look = look
        self.backend = backend
        self.projectPath = projectPath
        self.modelID = modelID
        self.thinking = thinking
        self.skills = skills
        self.extensions = extensions
        self.hermes = hermes
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, role, look, backend, projectPath, modelID, thinking, skills, extensions, hermes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        look = try c.decodeIfPresent(Look.self, forKey: .look) ?? .random()
        backend = try c.decodeIfPresent(AgentBackend.self, forKey: .backend) ?? .pi
        projectPath = try c.decodeIfPresent(String.self, forKey: .projectPath)
        modelID = try c.decodeIfPresent(String.self, forKey: .modelID)
        thinking = try c.decodeIfPresent(String.self, forKey: .thinking)
        skills = try c.decodeIfPresent([String].self, forKey: .skills) ?? []
        extensions = try c.decodeIfPresent([String].self, forKey: .extensions)
        hermes = try c.decodeIfPresent(HermesConnection.self, forKey: .hermes)
    }

    /// Working directory for pi agents.
    var workingDirectory: String { projectPath ?? PiPaths.quickChatsProject.path }

    /// Short location label: folder name, "Quick Chats", or the Hermes host.
    var placeLabel: String {
        if backend == .hermes { return hermes?.host ?? "Hermes" }
        guard let projectPath else { return "Quick Chats" }
        return URL(fileURLWithPath: projectPath).lastPathComponent
    }

    static let names = ["Ada", "Bea", "Cal", "Dex", "Eve", "Fitz", "Gus", "Ivy", "Jax", "Kit", "Lou", "Moe", "Nia", "Oli", "Pip", "Quinn", "Rex", "Sol", "Tess", "Uma",
                        "Vic", "Wes", "Yuki", "Zed", "Mabel", "Arlo", "Hazel", "Otto", "Ruby", "Iris", "Milo", "June", "Ezra", "Nora", "Bram", "Cleo", "Elsie", "Flo"]

    static func new(backend: AgentBackend = .pi) -> Agent {
        Agent(name: names.randomElement()!, role: "Assistant", backend: backend,
              hermes: backend == .hermes ? HermesConnection() : nil)
    }
}

extension PiPaths {
    static let agentsFile = appSupport.appendingPathComponent("agents.json")
    /// Owner-only (0600) JSON map of credentialID → Hermes API key.
    static let hermesAuthFile = appSupport.appendingPathComponent("hermes-auth.json")
    /// Hermes transcript caches, run journals, and model catalogs.
    static let hermesCacheDirectory = appSupport.appendingPathComponent("Hermes", isDirectory: true)
    static let agentSessionsFile = appSupport.appendingPathComponent("agent-sessions.json")
}

enum AgentStore {
    static func load() -> [Agent] {
        guard let data = try? Data(contentsOf: PiPaths.agentsFile) else { return [] }
        let decoder = JSONDecoder()
        do {
            return try decoder.decode([Agent].self, from: data)
        } catch {
            NSLog("PiG: could not decode agents.json: \(error)")
            return []
        }
    }

    static func save(_ agents: [Agent]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(agents)
        try FileManager.default.createDirectory(at: PiPaths.appSupport, withIntermediateDirectories: true)
        try data.write(to: PiPaths.agentsFile, options: .atomic)
    }
}
