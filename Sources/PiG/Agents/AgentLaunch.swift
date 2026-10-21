import Foundation

extension PiLaunchResources {
    /// Agent skills are always-on context, not pi's on-demand skill catalog.
    init(agent: Agent) {
        let firstName = NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()
        let persona = "## Who you are\nYou are \(agent.name) (role: \(agent.role)). \(firstName) talks with you in PiG and can start a fresh chat with /new."
        self.init(extensions: agent.extensions ?? [],
                  appendedSystemPrompts: [persona] + agent.skills,
                  noExtensions: agent.extensions != nil)
    }
}

/// Ownership is metadata, never a visibility rule. Deleted agents leave their chats intact.
enum AgentSessionStore {
    static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: PiPaths.agentSessionsFile),
              let records = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return Dictionary(records.map { (standardizedPath($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    static func save(_ records: [String: String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: PiPaths.appSupport, withIntermediateDirectories: true)
        try encoder.encode(records).write(to: PiPaths.agentSessionsFile, options: .atomic)
    }
}
