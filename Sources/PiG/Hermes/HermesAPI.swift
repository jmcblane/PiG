import Foundation
import Darwin
import AppKit

// Also used synchronously by the app's termination path, which cannot await an actor.
enum HermesTunnelLifetime {
    private static let lock = NSLock()
    private static var processes: [Int32: Process] = [:]
    private static let terminationObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: nil
    ) { _ in HermesTunnelLifetime.stopAll() }
    private static let registerExit: Void = {
        _ = terminationObserver
        atexit { HermesTunnelLifetime.stopAll() }
    }()
    static func track(_ process: Process) {
        _ = registerExit
        lock.lock(); defer { lock.unlock() }
        processes[process.processIdentifier] = process
    }
    static func remove(_ id: Int32) {
        lock.lock(); defer { lock.unlock() }
        processes[id] = nil
    }
    static func stopAll() {
        lock.lock()
        let owned = Array(processes.values)
        processes.removeAll()
        lock.unlock()
        for process in owned where process.isRunning { process.terminate() }
    }
}

/// One loopback-only tunnel per SSH destination/API port. Transport loss never stops remote runs.
actor HermesTunnels {
    static let shared = HermesTunnels()
    private struct Endpoint: Hashable { let host: String; let port: Int }
    private struct Tunnel { let process: Process; let port: UInt16; let errors: ErrorBuffer }
    private var tunnels: [Endpoint: Tunnel] = [:]

    private final class ErrorBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            if data.count < 4096 { data.append(chunk.prefix(4096 - data.count)) }
        }
        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    func localPort(for connection: HermesConnection) async throws -> UInt16 {
        try connection.validate()
        let endpoint = Endpoint(host: connection.host, port: connection.port)
        if let tunnel = tunnels[endpoint], tunnel.process.isRunning {
            try await waitUntilReady(tunnel)
            return tunnel.port
        }
        tunnels[endpoint] = nil
        // Binding to port zero allocates an unused port. ssh must acquire it after we close
        // the reservation; ExitOnForwardFailure catches that small race and we try again.
        for attempt in 0..<3 {
            let port = try Self.allocatePort()
            let process = Process()
            let pipe = Pipe()
            let errors = ErrorBuffer()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-N", "-T", "-L", "127.0.0.1:\(port):127.0.0.1:\(connection.port)",
                                 "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                                 "-o", "ExitOnForwardFailure=yes", "-o", "ConnectTimeout=10",
                                 "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "--", connection.host]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { errors.append(data) }
            }
            process.terminationHandler = { process in HermesTunnelLifetime.remove(process.processIdentifier) }
            do {
                try process.run()
                HermesTunnelLifetime.track(process)
                if !process.isRunning { HermesTunnelLifetime.remove(process.processIdentifier) }
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                throw HermesError.message("Could not launch /usr/bin/ssh: \(error.localizedDescription)")
            }
            let tunnel = Tunnel(process: process, port: port, errors: errors)
            tunnels[endpoint] = tunnel
            do {
                try await waitUntilReady(tunnel)
                return port
            } catch {
                if process.isRunning { process.terminate() }
                // Do not remove a replacement installed by another caller.
                if tunnels[endpoint]?.process === process { tunnels[endpoint] = nil }
                if attempt < 2 && errors.text.localizedCaseInsensitiveContains("address already in use") { continue }
                throw error
            }
        }
        throw HermesError.message("Could not allocate a local SSH forwarding port.")
    }

    private func waitUntilReady(_ tunnel: Tunnel) async throws {
        for _ in 0..<120 {
            try Task.checkCancellation()
            if !tunnel.process.isRunning {
                let detail: String
                let text = tunnel.errors.text.lowercased()
                if text.contains("host key") || text.contains("host identification") {
                    detail = "Verify this host's fingerprint and add its key to your SSH known_hosts outside PiG. Host-key checking remains enabled."
                } else if text.contains("permission denied") {
                    detail = "SSH authentication failed. Configure a noninteractive SSH key/agent for this host outside PiG."
                } else {
                    detail = "Check the SSH alias, network, known_hosts, and key/agent authentication in Terminal."
                }
                throw HermesError.message("Hermes SSH tunnel exited. " + detail)
            }
            if Self.canConnect(tunnel.port) {
                // Let ssh report a bind failure before trusting a raced local listener.
                try await Task.sleep(for: .milliseconds(100))
                if tunnel.process.isRunning { return }
                continue
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HermesError.message("Hermes SSH forwarding timed out. Check the host and network in Terminal.")
    }

    func stopAll() {
        for tunnel in tunnels.values where tunnel.process.isRunning { tunnel.process.terminate() }
        tunnels.removeAll()
    }

    private static func address(_ port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return addr
    }
    private static func allocatePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HermesError.message("Cannot allocate a local socket.") }
        defer { close(fd) }
        var addr = address(0)
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard bound == 0, found == 0 else { throw HermesError.message("Cannot reserve a loopback forwarding port.") }
        return UInt16(bigEndian: addr.sin_port)
    }
    private static func canConnect(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = address(port)
        return withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}

private final class HermesHTTPDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward a bearer credential to a redirected host or public listener.
        completionHandler(nil)
    }
}

struct HermesAPI {
    let connection: HermesConnection
    var keyOverride: String? = nil
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config, delegate: HermesHTTPDelegate(), delegateQueue: nil)
    }()

    func urlRequest(_ method: String, _ path: String, body: [String: Any]? = nil,
                    idempotencyKey: String? = nil) async throws -> URLRequest {
        try connection.validate()
        guard let key = try keyOverride ?? HermesCredentials.read(connection.credentialID) else {
            throw HermesError.message("No Hermes API key is saved. Edit the agent and save the API key.")
        }
        try HermesCredentials.validateKey(key)
        let port = try await HermesTunnels.shared.localPort(for: connection)
        guard let url = URL(string: "http://127.0.0.1:\(port)" + connection.pathPrefix + path) else {
            throw HermesError.message("Invalid Hermes API path.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    func events(_ path: String, onEvent: @escaping @MainActor ([String: Any]) -> Void) async throws {
        var request = try await urlRequest("GET", path)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await Self.session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw HermesError.message("Hermes event stream unavailable; using status polling.")
        }
        var eventType = ""
        var payload = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.utf8.count < 1_048_576 else { throw HermesError.message("Hermes event exceeded the stream limit.") }
            if line.isEmpty {
                if let data = payload.data(using: .utf8), var event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    if event["type"] == nil && !eventType.isEmpty { event["type"] = eventType }
                    await onEvent(event)
                }
                eventType = ""; payload = ""
            } else if line.hasPrefix("event:") {
                eventType = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                if !payload.isEmpty { payload += "\n" }
                payload += String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard payload.utf8.count < 1_048_576 else { throw HermesError.message("Hermes event exceeded the stream limit.") }
            }
        }
    }

    /// Stage the entire oldest-first transcript before the caller replaces its offline cache.
    func history(_ sessionID: String) async throws -> (sessionID: String, rows: [[String: Any]]) {
        let limit = 500
        var offset = 0
        var resolvedID: String?
        var rows: [[String: Any]] = []
        var seenIDs = Set<String>()
        while true {
            try Task.checkCancellation()
            let path = "/api/sessions/" + HermesJSON.identifier(sessionID)
                + "/messages?limit=\(limit)&offset=\(offset)&order=oldest"
            let root = HermesJSON.object(try await request("GET", path))
            let pagination = root["pagination"] as? [String: Any] ?? [:]
            guard let page = root["data"] as? [[String: Any]],
                  let id = root["session_id"] as? String, !id.isEmpty,
                  pagination["limit"] as? Int == limit,
                  pagination["offset"] as? Int == offset,
                  pagination["order"] as? String == "oldest",
                  let returned = pagination["returned"] as? Int,
                  returned == page.count, (0...limit).contains(returned) else {
                throw HermesError.message("Hermes history pagination is invalid. Cached history and run ID are retained.")
            }
            guard resolvedID == nil || resolvedID == id else {
                throw HermesError.message("Hermes changed sessions during history pagination. Cached history is retained until a consistent retrieval succeeds.")
            }
            resolvedID = id
            for row in page {
                guard let key = HermesJSON.messageID(row["id"]), !key.isEmpty,
                      seenIDs.insert(key).inserted else {
                    throw HermesError.message("Hermes history contains missing or repeated message IDs. Cached history is retained.")
                }
            }
            rows.append(contentsOf: page)
            if returned < limit {
                try Task.checkCancellation()
                return (id, rows)
            }
            offset += returned
        }
    }

    func request(_ method: String, _ path: String, body: [String: Any]? = nil,
                 idempotencyKey: String? = nil, expiresAt: Date? = nil) async throws -> Any {
        let request = try await urlRequest(method, path, body: body, idempotencyKey: idempotencyKey)
        // Check after tunnel/key preparation too, immediately before sending an admission.
        if let expiresAt, Date() >= expiresAt {
            throw HermesError.message("Hermes admission's 24-hour idempotency window has expired. Automatic retry is disabled; its saved input and key are retained.")
        }
        try Task.checkCancellation()
        let (data, response) = try await Self.session.data(for: request)
        // Keep cancelled controllers from applying late responses after the chat reloads.
        // An accepted admission still has its saved input/key for idempotent recovery.
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw HermesError.message("Hermes returned no HTTP response.") }
        guard (200..<300).contains(response.statusCode) else { throw HermesError.http(response.statusCode) }
        if data.isEmpty { return [String: Any]() }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { throw HermesError.message("Hermes returned invalid JSON.") }
        return json
    }
}
