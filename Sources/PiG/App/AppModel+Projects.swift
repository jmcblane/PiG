import Foundation
import SwiftUI

extension AppModel {
    var selectedProject: ProjectInfo? {
        guard let selectedProjectPath else { return nil }
        return projects.first { $0.path == selectedProjectPath }
    }

    func projectDisplayName(for path: String) -> String {
        projects.first { $0.path == path }?.displayName ?? URL(fileURLWithPath: path).lastPathComponent
    }

    func expandedDirectories(forProjectPath path: String) -> Set<String> {
        fileTreeExpandedByProject[path] ?? []
    }

    func setExpandedDirectories(_ expanded: Set<String>, forProjectPath path: String) {
        if expanded.isEmpty {
            fileTreeExpandedByProject.removeValue(forKey: path)
        } else {
            fileTreeExpandedByProject[path] = expanded
        }
    }

    func refreshSessions() {
        syncAgentSessionRecords()
        sessionRefreshGeneration += 1
        let generation = sessionRefreshGeneration
        Task { [weak self] in
            guard let self else { return }
            let grouped = await SessionScanner.scan(maxAgeDays: SessionHistoryWindow.defaultDays)
            guard self.sessionRefreshGeneration == generation else { return }
            self.sessionsByProject = grouped
            self.syncOpenControllerTitles(from: grouped)

            var known = Dictionary(self.projects.map { ($0.path, $0) }, uniquingKeysWith: { existing, duplicate in
                existing.lastOpened >= duplicate.lastOpened ? existing : duplicate
            })
            let childOnlyProjectPaths = Set(grouped.compactMap { path, sessions in
                !sessions.isEmpty && sessions.allSatisfy(\.isChildSession) ? path : nil
            })
            for path in childOnlyProjectPaths {
                known.removeValue(forKey: path)
            }
            for path in grouped.keys where !childOnlyProjectPaths.contains(path) && known[path] == nil {
                known[path] = ProjectInfo(path: path, lastOpened: grouped[path]?.first?.timestamp ?? Date.distantPast)
            }
            self.projects = self.sortedProjects(Array(known.values), grouped: grouped)
            self.pruneFileTreeExpanded()
            self.saveRegistry()
        }
    }

    func loadSessionArchive() {
        guard sessionArchiveLoadState != .loading else { return }
        sessionArchiveLoadGeneration += 1
        let generation = sessionArchiveLoadGeneration
        sessionArchiveLoadState = .loading
        Task { [weak self] in
            guard let self else { return }
            let grouped = await SessionScanner.scanAll()
            guard self.sessionArchiveLoadGeneration == generation else { return }
            self.archivedSessionsByProject = grouped
            self.sessionArchiveLoadState = .loaded
            self.syncOpenControllerTitles(from: grouped)
        }
    }

    func addExistingProject() {
        Task { [weak self] in
            let urls = await ProjectDialogs.chooseProjectDirectories()
            guard let self else { return }
            let paths = urls.map { ProjectInfo(path: $0.path).path }
            guard let lastPath = paths.last else { return }

            let trustTasks = paths.map { (path: $0, task: self.addProject(path: $0)) }
            var lastProjectTrustFailed = false
            for item in trustTasks {
                do {
                    try await item.task.value
                    self.projectTrustTasks.removeValue(forKey: item.path)
                } catch {
                    if item.path == lastPath { lastProjectTrustFailed = true }
                    self.reportProjectTrustFailure(path: item.path, error: error)
                }
            }
            if !lastProjectTrustFailed {
                self.showNewChatHome(projectPath: lastPath)
            }
        }
    }

    func createProject() {
        Task { [weak self] in
            guard let self, let url = await ProjectDialogs.createProjectDirectoryURL() else { return }
            do {
                try await AsyncFileSystem.createDirectory(at: url)
                let path = ProjectInfo(path: url.path).path
                let trustTask = self.addProject(path: path)
                try await trustTask.value
                self.projectTrustTasks.removeValue(forKey: path)
                self.showNewChatHome(projectPath: path)
            } catch {
                if error is PiTrustService.ServiceError {
                    self.reportProjectTrustFailure(path: url.path, error: error)
                } else {
                    self.statusLine = "Could not create directory: \(error.localizedDescription)"
                }
            }
        }
    }

    @discardableResult
    func addProject(path: String) -> Task<Void, Error> {
        let project = ProjectInfo(path: path)
        if !projects.contains(where: { $0.path == project.path }) {
            projects.insert(project, at: 0)
        }
        touchProject(project.path)
        refreshSessions()
        let trustTask = Task { try await PiTrustService.trust(projectPath: project.path) }
        projectTrustTasks[project.path] = trustTask
        return trustTask
    }

    func toggleProjectPinned(_ path: String) {
        guard let index = projects.firstIndex(where: { $0.path == path }) else { return }
        projects[index].isPinned.toggle()
        if projects[index].isPinned {
            projects[index].pinnedSortIndex = (projects.filter(\.isPinned).map(\.pinnedSortIndex).max() ?? -1) + 1
        } else {
            projects[index].pinnedSortIndex = 0
        }
        normalizePinnedSortIndexes()
        sortProjectsInPlace()
        saveRegistry()
    }

    func selectProject(_ path: String) {
        showNewChatHome(projectPath: path)
    }

    func recentSessions(forProjectPath projectPath: String, limit: Int) -> [SessionSummary] {
        let sessions = sessionsByProject[projectPath] ?? []
        let byPath = Dictionary(uniqueKeysWithValues: sessions.map { ($0.filePath, $0) })
        var result: [SessionSummary] = []
        var seen = Set<String>()
        for session in sessions {
            let candidate: SessionSummary
            if session.isChildSession, let parentPath = session.parentSessionPath, let parent = byPath[parentPath] {
                candidate = parent
            } else {
                candidate = session
            }
            guard !seen.contains(candidate.filePath) else { continue }
            seen.insert(candidate.filePath)
            result.append(candidate)
            if result.count >= limit { break }
        }
        return result
    }

    func reportProjectTrustFailure(path: String, error: Error) {
        let name = URL(fileURLWithPath: path).lastPathComponent
        statusLine = "Could not automatically trust project “\(name)”: \(error.localizedDescription). The project remains registered, but project-local resources were not loaded."
    }

    func touchProject(_ path: String) {
        if let index = projects.firstIndex(where: { $0.path == path }) {
            projects[index].lastOpened = Date()
        } else {
            projects.append(ProjectInfo(path: path))
        }
        sortProjectsInPlace()
        saveRegistry()
    }

    private func sortProjectsInPlace() {
        projects = sortedProjects(projects, grouped: sessionsByProject)
    }

    private func pruneFileTreeExpanded() {
        var keep = Set(projects.map(\.path))
        if let selectedProjectPath { keep.insert(selectedProjectPath) }
        fileTreeExpandedByProject = fileTreeExpandedByProject.filter { keep.contains($0.key) }
    }

    func sortedProjects(_ projects: [ProjectInfo], grouped: [String: [SessionSummary]]) -> [ProjectInfo] {
        projects.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            if lhs.isPinned { return lhs.pinnedSortIndex < rhs.pinnedSortIndex }
            let lhsDate = max(lhs.lastOpened, grouped[lhs.path]?.first?.timestamp ?? Date.distantPast)
            let rhsDate = max(rhs.lastOpened, grouped[rhs.path]?.first?.timestamp ?? Date.distantPast)
            return lhsDate > rhsDate
        }
    }

    private func normalizePinnedSortIndexes() {
        let pinned = projects.filter(\.isPinned).sorted { $0.pinnedSortIndex < $1.pinnedSortIndex }
        for (order, project) in pinned.enumerated() {
            if let index = projects.firstIndex(where: { $0.path == project.path }) {
                projects[index].pinnedSortIndex = order
            }
        }
    }

    func loadRegistry() async {
        let stored = await ProjectRegistryStore.load()
        projects = sortedProjects(stored, grouped: sessionsByProject)
    }

    private func saveRegistry() {
        let snapshot = projects
        ProjectRegistryStore.save(snapshot) { [weak self] error in
            self?.statusLine = "Could not save registry: \(error.localizedDescription)"
        }
    }
}
