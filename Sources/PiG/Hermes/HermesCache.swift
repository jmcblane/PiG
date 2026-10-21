import Foundation

/// A write-ahead record: input and key survive even if admission's HTTP response is lost.
struct HermesAdmission: Codable {
    let key: String
    let input: String
    let sessionID: String
    let model: String?
    var provider: String? = nil
    /// Nil in older caches: never guess whether the server still retains this key.
    var createdAt: Date? = nil

    var recoveryNotice: String? {
        guard let createdAt else {
            return "This saved Hermes admission has no timestamp. Automatic retry is disabled because its idempotency key may have expired. Verify acceptance on the server before resolving the saved admission; its input and key are retained."
        }
        let age = Date().timeIntervalSince(createdAt)
        guard age >= 0, age < 86_400 else {
            return "This saved Hermes admission is outside the 24-hour idempotency window (or the clock changed). Automatic retry is disabled to avoid duplicate work. Verify acceptance on the server before resolving the saved admission; its input and key are retained."
        }
        return nil
    }
}

struct HermesJournal: Codable {
    var sessionID = UUID().uuidString
    var sessionReady = false
    var runID: String?
    var pending: HermesAdmission?
    var messages: [ChatMessage] = []
    var historyKeys: [String] = []
    /// Earlier session transcript retained when remote compression rotates the session ID.
    var historyPrefix: [ChatMessage]?
    // Retain the completed run until its final history has been recovered successfully.
    var terminalStatus: String?
    var recoveredRunID: String?
}

enum HermesCache {
    private static var directory: URL { PiPaths.hermesCacheDirectory }
    static func journalURL(_ id: String) -> URL { directory.appendingPathComponent(HermesJSON.identifier(id) + ".json") }
    static func load(_ id: String) throws -> HermesJournal {
        let url = journalURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return HermesJournal() }
        do { return try JSONDecoder().decode(HermesJournal.self, from: Data(contentsOf: url)) }
        catch { throw HermesError.message("The cached Hermes conversation cannot be read. Preserve its cache file before repairing it; sending is disabled to avoid duplicate work.") }
    }
    static func save(_ journal: HermesJournal, for id: String) throws {
        do {
            try prepareDirectory()
            try JSONEncoder().encode(journal).write(to: journalURL(id), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL(id).path)
        } catch { throw HermesError.message("Cannot save Hermes run state. Check disk space and Application Support permissions before sending.") }
    }
    private static func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
    // Models/capabilities are nonsecret and keyed by endpoint, not employee name.
    private struct Catalog: Codable { let connection: HermesConnection; let info: HermesConnectionInfo }
    static func info(for connection: HermesConnection) -> HermesConnectionInfo? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("models.json")),
              let entries = try? JSONDecoder().decode([Catalog].self, from: data) else { return nil }
        return entries.first { $0.connection == connection }?.info
    }
    static func save(_ info: HermesConnectionInfo, for connection: HermesConnection) throws {
        let url = directory.appendingPathComponent("models.json")
        var entries = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Catalog].self, from: $0) } ?? []
        entries.removeAll { $0.connection == connection }
        entries.append(Catalog(connection: connection, info: info))
        try prepareDirectory()
        try JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }
}
