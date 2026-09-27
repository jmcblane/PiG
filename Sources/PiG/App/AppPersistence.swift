import Foundation

private final class OrderedSnapshotWriter: @unchecked Sendable {
    private let queue: DispatchQueue
    private let directory: URL
    private let destination: URL

    init(directory: URL, destination: URL, label: String) {
        self.queue = DispatchQueue(label: label, qos: .utility)
        self.directory = directory
        self.destination = destination
    }

    func submit(_ encodeSnapshot: @escaping @Sendable () throws -> Data, onError: @escaping @MainActor (Error) -> Void) {
        let directory = directory
        let destination = destination
        queue.async {
            do {
                let snapshot = try encodeSnapshot()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try snapshot.write(to: destination, options: [.atomic])
            } catch {
                Task { @MainActor in onError(error) }
            }
        }
    }

}

enum ProjectRegistryStore {
    private static let writer = OrderedSnapshotWriter(
        directory: PiPaths.appSupport,
        destination: PiPaths.registryFile,
        label: "PiG.persistence.registry"
    )

    static func load() async -> [ProjectInfo] {
        await Task.detached(priority: .utility) {
            do {
                let data = try Data(contentsOf: PiPaths.registryFile)
                let projects = try JSONDecoder().decode([ProjectInfo].self, from: data)
                var seenPaths = Set<String>()
                return projects.filter { seenPaths.insert($0.path).inserted }
            } catch {
                return []
            }
        }.value
    }

    @MainActor
    static func save(_ projects: [ProjectInfo], onError: @escaping @MainActor (Error) -> Void) {
        writer.submit({ try JSONEncoder().encode(projects) }, onError: onError)
    }
}

enum CustomActionStore {
    private static let writer = OrderedSnapshotWriter(
        directory: PiPaths.appSupport,
        destination: PiPaths.customActionsFile,
        label: "PiG.persistence.custom-actions"
    )

    static func load() async -> [String: ProjectCustomActions] {
        await Task.detached(priority: .utility) {
            do {
                let data = try Data(contentsOf: PiPaths.customActionsFile)
                return try JSONDecoder().decode([String: ProjectCustomActions].self, from: data)
            } catch {
                return [:]
            }
        }.value
    }

    @MainActor
    static func save(_ actions: [String: ProjectCustomActions], onError: @escaping @MainActor (Error) -> Void) {
        writer.submit({ try JSONEncoder().encode(actions) }, onError: onError)
    }
}
