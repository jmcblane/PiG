import Foundation

enum SessionScanner {
    private struct FileKey: Equatable, Codable {
        var modified: Date
        var size: UInt64
    }

    private struct CachedSummary: Codable {
        var key: FileKey
        var summary: SessionSummary
    }

    private struct CachePayload: Codable {
        var version: Int
        var summaries: [String: CachedSummary]
    }

    private static let cacheVersion = 1
    private static let cacheLock = NSLock()
    private static let cacheWriteLock = NSLock()
    nonisolated(unsafe) private static var cacheLoaded = false
    nonisolated(unsafe) private static var summaryCache: [String: CachedSummary] = [:]

    static func cachedSummaries(forPaths paths: [String]) async -> [String: [SessionSummary]] {
        await Task.detached(priority: .userInitiated) {
            ensureCacheLoaded()
            let manager = FileManager.default
            var grouped: [String: [SessionSummary]] = [:]
            for path in paths where path.hasSuffix(".jsonl") {
                let url = URL(fileURLWithPath: path)
                guard let key = fileKey(for: url, manager: manager),
                      let summary = cachedSummary(for: url, key: key) else { continue }
                grouped[summary.projectPath, default: []].append(summary)
            }
            sort(&grouped)
            persistCache()
            return grouped
        }.value
    }

    static func scan(maxAgeDays: Int) async -> [String: [SessionSummary]] {
        await Task.detached(priority: .utility) {
            scanSync(maxAgeDays: maxAgeDays)
        }.value
    }

    static func scanAll() async -> [String: [SessionSummary]] {
        await Task.detached(priority: .utility) {
            scanSync(maxAgeDays: nil)
        }.value
    }

    private static func scanSync(maxAgeDays: Int?) -> [String: [SessionSummary]] {
        ensureCacheLoaded()
        var grouped: [String: [SessionSummary]] = [:]
        let manager = FileManager.default
        let cutoff = maxAgeDays.map { Date().addingTimeInterval(-Double($0) * 24 * 60 * 60) }
        guard let enumerator = manager.enumerator(
            at: PiPaths.piSessions,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return grouped }

        var existingPaths = Set<String>()
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            existingPaths.insert(url.path)
            guard let key = fileKey(for: url, manager: manager) else { continue }
            if let cutoff, key.modified < cutoff { continue }
            guard let summary = cachedSummary(for: url, key: key) else { continue }
            grouped[summary.projectPath, default: []].append(summary)
        }
        cacheLock.lock()
        summaryCache = summaryCache.filter { existingPaths.contains($0.key) }
        cacheLock.unlock()
        sort(&grouped)
        persistCache()
        return grouped
    }

    private static func cachedSummary(for url: URL, key: FileKey) -> SessionSummary? {
        cacheLock.lock()
        if let cached = summaryCache[url.path], cached.key == key {
            cacheLock.unlock()
            return cached.summary
        }
        cacheLock.unlock()

        guard let summary = SessionParser.parseSummaryFile(url) else { return nil }
        cacheLock.lock()
        summaryCache[url.path] = CachedSummary(key: key, summary: summary)
        cacheLock.unlock()
        return summary
    }

    private static func ensureCacheLoaded() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard !cacheLoaded else { return }
        cacheLoaded = true
        guard let data = try? Data(contentsOf: PiPaths.sessionSummaryCacheFile),
              let payload = try? JSONDecoder().decode(CachePayload.self, from: data),
              payload.version == cacheVersion else { return }
        summaryCache = payload.summaries
    }

    private static func persistCache() {
        cacheWriteLock.lock()
        defer { cacheWriteLock.unlock() }
        cacheLock.lock()
        let snapshot = summaryCache
        cacheLock.unlock()
        let payload = CachePayload(version: cacheVersion, summaries: snapshot)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(at: PiPaths.appSupport, withIntermediateDirectories: true)
        try? data.write(to: PiPaths.sessionSummaryCacheFile, options: [.atomic])
    }

    private static func sort(_ grouped: inout [String: [SessionSummary]]) {
        for key in grouped.keys {
            grouped[key] = grouped[key]?.sorted { $0.timestamp > $1.timestamp }
        }
    }

    private static func fileKey(for url: URL, manager: FileManager) -> FileKey? {
        guard let attributes = try? manager.attributesOfItem(atPath: url.path) else { return nil }
        let modified = attributes[.modificationDate] as? Date ?? Date.distantPast
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        return FileKey(modified: modified, size: size)
    }
}

enum SessionHistoryWindow {
    static let defaultDays = 7
}
