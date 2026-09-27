import Foundation

enum AsyncFileSystem {
    static func createDirectory(at url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }.value
    }

    static func itemExists(at url: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            FileManager.default.fileExists(atPath: url.path)
        }.value
    }

    static func moveToTrash(_ url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }.value
    }
}
