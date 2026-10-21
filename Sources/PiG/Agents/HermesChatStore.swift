import Foundation

/// Sidebar metadata only; transcripts and remote run state remain in HermesCache.
struct HermesChatRecord: Codable, Identifiable {
    let id: String
    let agentID: String
    var title: String
    let created: Date
    var lastActivity: Date
}

enum HermesChatStore {
    private static let url = PiPaths.appSupport.appendingPathComponent("hermes-chats.json")

    static func load() -> [HermesChatRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let records = try JSONDecoder().decode([HermesChatRecord].self, from: Data(contentsOf: url))
            var seen = Set<String>()
            return records.filter { seen.insert($0.id).inserted }
        } catch {
            NSLog("PiG: could not read hermes-chats.json: \(error)")
            return []
        }
    }

    static func save(_ records: [HermesChatRecord]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: PiPaths.appSupport, withIntermediateDirectories: true)
        try encoder.encode(records).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
