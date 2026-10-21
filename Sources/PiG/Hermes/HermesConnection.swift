import Foundation

extension HermesConnection {
    func validate() throws {
        // No shell is involved. Restrict destinations further to prevent SSH option/URI injection.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@:")
        guard !host.isEmpty, !host.hasPrefix("-"), !host.hasPrefix("@"),
              host.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              host.filter({ $0 == "@" }).count <= 1,
              !host.split(separator: "@", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0.hasPrefix("-") }),
              (1...65535).contains(port) else {
            throw HermesError.message("Enter an SSH host alias or user@hostname and an API port from 1 to 65535. SSH options and whitespace are not allowed.")
        }
        guard !profile.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              profile != ".", profile != ".." else {
            throw HermesError.message("The Hermes profile cannot contain control characters or be a path component '.' or '..'.")
        }
    }

    var pathPrefix: String {
        guard !profile.isEmpty else { return "" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return "/p/" + (profile.addingPercentEncoding(withAllowedCharacters: safe) ?? "")
    }
}

enum HermesError: LocalizedError {
    case message(String)
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .http(401), .http(403): return "Hermes rejected the API key. Check the saved key and selected profile."
        case .http(404): return "Hermes API endpoint was not found. Check the profile and native API version."
        case .http(let code): return "Hermes API returned HTTP \(code)."
        }
    }
}

/// API keys live in an owner-only JSON file keyed by credential ID.
enum HermesCredentials {
    private static let lock = NSLock()

    static func read(_ id: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return try load()[id]
    }
    static func save(_ key: String, for id: String) throws {
        try validateKey(key)
        lock.lock(); defer { lock.unlock() }
        var keys = try load()
        keys[id] = key
        try store(keys)
    }
    static func delete(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        var keys = try load()
        guard keys.removeValue(forKey: id) != nil else { return }
        try store(keys)
    }
    static func validateKey(_ key: String) throws {
        guard !key.isEmpty, !key.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else {
            throw HermesError.message("Enter an API key without whitespace or control characters.")
        }
    }

    private static func load() throws -> [String: String] {
        let url = PiPaths.hermesAuthFile
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        // An unreadable existing file must not be mistaken for an empty credential store.
        let data = try Data(contentsOf: url)
        do { return try JSONDecoder().decode([String: String].self, from: data) } catch {
            throw HermesError.message("\(PiPaths.hermesAuthFile.path) is not valid JSON. Fix or delete it, then save the API key again.")
        }
    }
    private static func store(_ keys: [String: String]) throws {
        let fm = FileManager.default
        let url = PiPaths.hermesAuthFile
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(keys)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try data.write(to: url)
    }
}

struct HermesConnectionInfo: Codable {
    var models: [String]
    var features: [String: Bool]
    var version: String?
}

enum HermesOnboarding {
    static func check(_ connection: HermesConnection, apiKey: String? = nil) async throws -> HermesConnectionInfo {
        let client = HermesAPI(connection: connection, keyOverride: apiKey)
        let capabilities = try await client.request("GET", "/v1/capabilities")
        let modelResponse = try await client.request("GET", "/v1/models")
        let root = HermesJSON.object(capabilities)
        let body = (root["capabilities"] as? [String: Any]) ?? root
        var features: [String: Bool] = [:]
        for (key, value) in body { if let value = value as? Bool { features[key] = value } }
        if let nested = body["features"] as? [String: Any] {
            for (key, value) in nested { if let value = value as? Bool { features[key] = value } }
        }
        var models = HermesJSON.models(modelResponse)
        if features["model_options"] == true {
            do {
                let options = try await client.request("GET", "/api/model/options")
                models = Array(Set(models + HermesJSON.authenticatedModels(options))).sorted()
            } catch {
                // Optional catalog: route aliases and gateway defaults still work without it.
                try Task.checkCancellation()
            }
        }
        return HermesConnectionInfo(models: models, features: features,
                                    version: root["version"] as? String ?? body["version"] as? String)
    }
}

// Runtime JSON parsing deliberately tolerates extra fields and common response envelopes.
enum HermesJSON {
    static func object(_ value: Any) -> [String: Any] { value as? [String: Any] ?? [:] }
    static func models(_ value: Any) -> [String] {
        let root = object(value)
        let entries = (value as? [Any]) ?? (root["data"] as? [Any]) ?? (root["models"] as? [Any]) ?? []
        return Array(Set(entries.compactMap { entry -> String? in
            if let id = entry as? String { return id }
            let row = object(entry)
            return row["id"] as? String ?? row["model"] as? String ?? row["model_id"] as? String
        })).sorted()
    }
    static func authenticatedModels(_ value: Any) -> [String] {
        let providers = object(value)["providers"] as? [[String: Any]] ?? []
        return providers.flatMap { provider -> [String] in
            guard provider["authenticated"] as? Bool == true,
                  let slug = provider["slug"] as? String, !slug.isEmpty,
                  let models = provider["models"] as? [String] else { return [] }
            return models.filter { !$0.isEmpty }.map { slug + "/" + $0 }
        }
    }

    /// Route aliases take precedence even if an alias itself contains a slash.
    static func modelFields(_ selection: String?, aliases: [String]) -> [String: Any] {
        guard let selection, !selection.isEmpty, selection != "hermes-agent" else { return [:] }
        if !aliases.contains(selection), let slash = selection.firstIndex(of: "/") {
            let provider = String(selection[..<slash])
            let model = String(selection[selection.index(after: slash)...])
            if !provider.isEmpty, !model.isEmpty { return ["provider": provider, "model": model] }
        }
        return ["model": selection]
    }

    static func messageID(_ value: Any?) -> String? {
        if let id = value as? String { return id }
        if let id = value as? Int64 { return String(id) }
        return nil
    }

    static func text(_ value: Any?) -> String {
        if let string = value as? String { return string }
        guard let parts = value as? [[String: Any]] else { return "" }
        return parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func identifier(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? ""
    }
}
