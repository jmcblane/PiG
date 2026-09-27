import Foundation
import Darwin

private actor PiShellEnvironmentCache {
    static let shared = PiShellEnvironmentCache()
    private var cached: [String: String]?
    private var loading: Task<[String: String], Never>?

    func environment() async -> [String: String] {
        if let cached { return cached }
        if loading == nil {
            loading = Task.detached(priority: .utility) { PiEnvironment.loadZshEnvironment() }
        }
        let loaded = await loading!.value
        cached = loaded
        loading = nil
        PiEnvironment.cacheShellEnvironment(loaded)
        return loaded
    }
}

enum PiEnvironment {
    private static let lock = NSLock()
    private static var shellCache: [String: String] = [:]

    static func cacheShellEnvironment(_ environment: [String: String]) {
        lock.lock()
        shellCache = environment
        lock.unlock()
    }

    private static var cachedShellEnvironment: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return shellCache
    }

    static var current: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.merge(cachedShellEnvironment) { _, shell in shell }
        environment["PATH"] = mergedPath(existing: environment["PATH"])
        return environment
    }

    static var userShell: URL {
        let candidates = [ProcessInfo.processInfo.environment["SHELL"],
                          getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) },
                          "/bin/zsh"]
        let path = candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/bin/zsh"
        return URL(fileURLWithPath: path)
    }

    static func executable(named name: String, environment: [String: String]? = nil) -> URL? {
        let path = (environment ?? current)["PATH"] ?? ""
        return path.split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static let pathAdditions = [
        PiPaths.home.appendingPathComponent(".local/bin").path,
        PiPaths.home.appendingPathComponent(".bin").path,
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin"
    ]

    static func merged(extra: [String: String] = [:]) -> [String: String] {
        merged(shellEnvironment: cachedShellEnvironment, extra: extra)
    }

    static func mergedAsync(extra: [String: String] = [:]) async -> [String: String] {
        let shellEnvironment = await PiShellEnvironmentCache.shared.environment()
        return merged(shellEnvironment: shellEnvironment, extra: extra)
    }

    private static func merged(shellEnvironment: [String: String], extra: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.merge(shellEnvironment) { _, shell in shell }
        env["PATH"] = mergedPath(existing: env["PATH"])
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        env.merge(extra) { _, new in new }
        return env
    }

    private static func mergedPath(existing: String?) -> String {
        var seen = Set<String>()
        return (pathAdditions + [(existing ?? "")])
            .flatMap { $0.split(separator: ":", omittingEmptySubsequences: true).map(String.init) }
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
    }

    fileprivate static func loadZshEnvironment() -> [String: String] {
        let marker = "__PIG_ENV_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"
        // printf is a builtin in zsh, bash and fish; use NUL boundaries to isolate rc-file output.
        let command = "printf '\\n\(marker)\\0'; /usr/bin/env -0; printf '\(marker)\\0'"
        do {
            let result = try ProcessRunner.capture(
                executable: userShell, arguments: ["-l", "-i", "-c", command],
                environment: ProcessInfo.processInfo.environment, timeout: 8
            )
            guard result.status == 0 else { return [:] }
            let start = Data("\n\(marker)\0".utf8)
            let end = Data("\(marker)\0".utf8)
            guard let begin = result.stdout.range(of: start),
                  let finish = result.stdout.range(of: end, in: begin.upperBound..<result.stdout.endIndex) else { return [:] }
            return parseEnv(result.stdout.subdata(in: begin.upperBound..<finish.lowerBound))
        } catch {
            return [:]
        }
    }

    private static func parseEnv(_ data: Data) -> [String: String] {
        var env: [String: String] = [:]
        for entry in data.split(separator: 0) {
            guard let equals = entry.firstIndex(of: UInt8(ascii: "=")), equals > entry.startIndex else { continue }
            let keyData = entry[..<equals]
            guard isValidEnvKey(keyData),
                  let key = String(data: Data(keyData), encoding: .utf8),
                  let value = String(data: Data(entry[entry.index(after: equals)...]), encoding: .utf8) else { continue }
            env[key] = value
        }
        return env
    }

    private static func isValidEnvKey(_ data: Data.SubSequence) -> Bool {
        guard let first = data.first, isAlphaOrUnderscore(first) else { return false }
        return data.dropFirst().allSatisfy { isAlphaOrUnderscore($0) || isDigit($0) }
    }

    private static func isAlphaOrUnderscore(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "_") ||
        (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")) ||
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }
}
