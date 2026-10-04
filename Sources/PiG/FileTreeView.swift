import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Row model

enum GitFileStatus {
    case modified
    case untracked
    case added
    case deleted
    case renamed
    case conflicted
}

struct FileRow: Identifiable {
    enum Kind {
        case node(FileNode)
        case placeholder(String)
    }

    let id: String
    let kind: Kind
    let depth: Int
    var detail: String? = nil

    var node: FileNode? {
        if case .node(let node) = kind { return node }
        return nil
    }
}

// MARK: - Directory watcher

final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(path: String, onChange: @escaping () -> Void) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    func cancel() { source.cancel() }
    deinit { if !source.isCancelled { source.cancel() } }
}

// MARK: - Tree model

@MainActor
final class FileTreeModel: ObservableObject {
    let rootURL: URL

    @Published private(set) var rows: [FileRow] = []
    @Published var selection: String?
    @Published var filter = "" { didSet { if filter != oldValue { filterDidChange() } } }
    @Published var showHidden = false { didSet { if showHidden != oldValue { refreshAll() } } }
    @Published private(set) var gitStatus: [String: GitFileStatus] = [:]
    @Published private(set) var gitDirsWithChanges: Set<String> = []

    private var expanded: Set<String> {
        didSet {
            if expanded != oldValue { onExpandedChange?(expanded) }
        }
    }
    private let onExpandedChange: ((Set<String>) -> Void)?
    private var childrenByDir: [String: [FileNode]] = [:]
    private var failedDirs: Set<String> = []
    private var watchers: [String: DirectoryWatcher] = [:]
    private var pendingRefresh: Task<Void, Never>?
    private var directoryRefreshTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var gitStatusTask: Task<Void, Never>?
    private var directoryRefreshGeneration = 0
    private var gitStatusGeneration = 0

    init(rootURL: URL, expanded: Set<String> = [], onExpandedChange: ((Set<String>) -> Void)? = nil) {
        self.rootURL = rootURL
        self.expanded = expanded
        self.onExpandedChange = onExpandedChange
    }

    deinit {
        pendingRefresh?.cancel()
        directoryRefreshTask?.cancel()
        searchTask?.cancel()
        gitStatusTask?.cancel()
        for watcher in watchers.values { watcher.cancel() }
    }

    func start() {
        watch(rootURL.path)
        for path in expanded { watch(path) }
        refreshAll()
    }

    func isExpanded(_ path: String) -> Bool { expanded.contains(path) }

    private var filterQuery: String { filter.trimmingCharacters(in: .whitespaces) }
    var isFiltering: Bool { !filterQuery.isEmpty }

    func relativePath(of url: URL) -> String {
        let path = url.path
        let rootPath = rootURL.path
        if path == rootPath { return "." }
        if path.hasPrefix(rootPath + "/") { return String(path.dropFirst(rootPath.count + 1)) }
        return path
    }

    // MARK: Expansion

    func toggleDir(_ node: FileNode) {
        let path = node.url.path
        if expanded.contains(path) {
            let prefix = path + "/"
            expanded = expanded.filter { $0 != path && !$0.hasPrefix(prefix) }
            unwatchSubtree(of: path)
            rebuildRows()
        } else {
            expanded.insert(path)
            watch(path)
            rebuildRows()
            Task {
                await loadChildren(of: path)
                rebuildRows()
            }
        }
    }

    /// Expands ancestors of `url` (and `url` itself when it is a directory and
    /// `expandIfDirectory`), clears any filter, and selects it.
    func revealInTree(_ url: URL, expandIfDirectory: Bool = false) {
        if !filter.isEmpty { filter = "" }
        var ancestors: [String] = []
        if expandIfDirectory, url.path != rootURL.path {
            ancestors.append(url.path)
        }
        var dir = url.deletingLastPathComponent()
        while dir.path.hasPrefix(rootURL.path + "/") {
            ancestors.append(dir.path)
            dir.deleteLastPathComponent()
        }
        for path in ancestors {
            expanded.insert(path)
            watch(path)
        }
        selection = url.path
        Task {
            await loadChildren(of: rootURL.path)
            for path in ancestors.reversed() {
                await loadChildren(of: path)
            }
            rebuildRows()
        }
    }

    // MARK: Refresh

    func refreshAll() {
        refreshGitStatus()
        directoryRefreshTask?.cancel()
        directoryRefreshGeneration += 1
        let generation = directoryRefreshGeneration
        if isFiltering {
            runSearch(debounce: false)
            return
        }
        let dirs = [rootURL.path] + expanded.sorted()
        directoryRefreshTask = Task {
            var stale: Set<String> = []
            for dir in dirs {
                guard !Task.isCancelled, directoryRefreshGeneration == generation else { return }
                let exists = await Task.detached(priority: .utility) {
                    FileManager.default.fileExists(atPath: dir)
                }.value
                guard !Task.isCancelled, directoryRefreshGeneration == generation else { return }
                if exists {
                    await loadChildren(of: dir, refreshGeneration: generation)
                } else {
                    stale.insert(dir)
                }
            }
            guard !Task.isCancelled, directoryRefreshGeneration == generation else { return }
            if !stale.isEmpty {
                expanded.subtract(stale)
                for dir in stale { unwatchSubtree(of: dir) }
            }
            rebuildRows()
        }
    }

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            refreshAll()
        }
    }

    private func loadChildren(of dirPath: String, refreshGeneration: Int? = nil) async {
        let url = URL(fileURLWithPath: dirPath, isDirectory: true)
        let hidden = showHidden
        let worker = Task.detached(priority: .userInitiated) {
            FileTreeLoader.children(of: url, showHidden: hidden)
        }
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled else { return }
        if let refreshGeneration, refreshGeneration != directoryRefreshGeneration { return }
        if let result {
            childrenByDir[dirPath] = result
            failedDirs.remove(dirPath)
        } else {
            childrenByDir[dirPath] = []
            failedDirs.insert(dirPath)
        }
    }

    // MARK: Rows

    private func rebuildRows() {
        guard !isFiltering else { return }
        var out: [FileRow] = []
        appendRows(for: rootURL.path, depth: 0, into: &out)
        rows = out
        if let selection, !out.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
    }

    private func appendRows(for dirPath: String, depth: Int, into out: inout [FileRow]) {
        if failedDirs.contains(dirPath) {
            out.append(FileRow(id: dirPath + "/#error", kind: .placeholder("Can't read folder"), depth: depth))
            return
        }
        guard let kids = childrenByDir[dirPath] else {
            out.append(FileRow(id: dirPath + "/#loading", kind: .placeholder("Loading…"), depth: depth))
            return
        }
        if kids.isEmpty {
            out.append(FileRow(id: dirPath + "/#empty", kind: .placeholder("Empty"), depth: depth))
            return
        }
        for kid in kids {
            out.append(FileRow(id: kid.id, kind: .node(kid), depth: depth))
            if kid.isDirectory, expanded.contains(kid.url.path) {
                appendRows(for: kid.url.path, depth: depth + 1, into: &out)
            }
        }
    }

    // MARK: Filter search

    private func filterDidChange() {
        searchTask?.cancel()
        if isFiltering {
            runSearch(debounce: true)
        } else {
            rebuildRows()
        }
    }

    private func runSearch(debounce: Bool) {
        searchTask?.cancel()
        let query = filterQuery
        let root = rootURL
        let hidden = showHidden
        searchTask = Task {
            if debounce { try? await Task.sleep(nanoseconds: 180_000_000) }
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                FileTreeLoader.search(root: root, query: query, showHidden: hidden)
            }
            let matches = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, self.filterQuery == query else { return }
            self.rows = matches.map { node in
                let parent = node.url.deletingLastPathComponent()
                let detail = self.relativePath(of: parent)
                return FileRow(id: node.id, kind: .node(node), depth: 0, detail: detail)
            }
            if let selection = self.selection, !self.rows.contains(where: { $0.id == selection }) {
                self.selection = nil
            }
        }
    }

    // MARK: Git

    private func refreshGitStatus() {
        gitStatusTask?.cancel()
        gitStatusGeneration += 1
        let generation = gitStatusGeneration
        let root = rootURL
        gitStatusTask = Task {
            let worker = Task.detached(priority: .utility) {
                GitStatusLoader.status(for: root)
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, gitStatusGeneration == generation else { return }
            gitStatus = result.files
            gitDirsWithChanges = result.dirs
            if let top = result.topLevel {
                watch(top + "/.git")
            }
        }
    }

    // MARK: Watchers

    private func watch(_ path: String) {
        guard watchers[path] == nil else { return }
        watchers[path] = DirectoryWatcher(path: path) { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
    }

    private func unwatchSubtree(of path: String) {
        let prefix = path + "/"
        for key in watchers.keys where key == path || key.hasPrefix(prefix) {
            watchers[key]?.cancel()
            watchers[key] = nil
        }
    }
}

// MARK: - View

struct FileTreeView: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var model: FileTreeModel
    @FocusState private var treeFocused: Bool
    @FocusState private var filterFocused: Bool

    @State private var namingAction: NamingAction?
    @State private var namingVisible = false
    @State private var namingText = ""

    enum NamingAction {
        case newFile(URL)
        case newFolder(URL)
        case rename(URL)
    }

    init(rootURL: URL, expanded: Set<String> = [], onExpandedChange: @escaping (Set<String>) -> Void = { _ in }) {
        _model = StateObject(wrappedValue: FileTreeModel(
            rootURL: rootURL,
            expanded: expanded,
            onExpandedChange: onExpandedChange
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            filterField
            tree
        }
        .task { model.start() }
        .alert(namingTitle, isPresented: $namingVisible) {
            TextField("Name", text: $namingText)
            Button("Cancel", role: .cancel) { namingAction = nil }
            Button(namingConfirmLabel) { performNaming() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(appTheme.brass)
            Text(model.rootURL.lastPathComponent)
                .font(AppFonts.ui(14.5, weight: .semibold))
                .foregroundStyle(appTheme.text)
                .lineLimit(1)
            Spacer()
            Button { model.showHidden.toggle() } label: {
                Image(systemName: model.showHidden ? "eye" : "eye.slash")
            }
            .buttonStyle(InlineIconButtonStyle())
            .foregroundStyle(model.showHidden ? appTheme.brass : appTheme.muted)
            .help(model.showHidden ? "Hide hidden files" : "Show hidden files")

            Button { model.refreshAll() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(InlineIconButtonStyle())
                .help("Refresh")

            Button { NSWorkspace.shared.open(model.rootURL) } label: { Image(systemName: "arrow.up.forward.square") }
                .buttonStyle(InlineIconButtonStyle())
                .help("Open in Finder")
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var filterField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(AppFonts.ui(11, weight: .semibold))
                .foregroundStyle(appTheme.muted)
            TextField("Filter files", text: $model.filter)
                .textFieldStyle(.plain)
                .foregroundStyle(appTheme.text)
                .focused($filterFocused)
                .onExitCommand { model.filter = "" }
            if !model.filter.isEmpty {
                Button { model.filter = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(appTheme.muted)
                .accessibilityLabel("Clear search")
            }
        }
        .modifier(SearchFieldSurface(isFocused: filterFocused))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    // MARK: Tree

    private var tree: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows) { row in
                        rowView(row)
                            .id(row.id)
                    }
                    if model.isFiltering && model.rows.isEmpty {
                        EmptyState(text: "No matches", icon: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: model.selection) { _, selection in
                if let selection { proxy.scrollTo(selection) }
            }
        }
        .contextMenu {
            Button("New File…") { beginNaming(.newFile(model.rootURL)) }
            Button("New Folder…") { beginNaming(.newFolder(model.rootURL)) }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($treeFocused)
        .onMoveCommand(perform: handleMove)
        .onKeyPress(.return) {
            if let row = selectedRow() { open(row) }
            return .handled
        }
    }

    @ViewBuilder
    private func rowView(_ row: FileRow) -> some View {
        switch row.kind {
        case .placeholder(let text):
            HStack(spacing: 6) {
                Color.clear.frame(width: CGFloat(row.depth) * 14 + 12, height: 1)
                Text(text)
                    .font(AppFonts.ui(12.5))
                    .italic()
                    .foregroundStyle(appTheme.muted)
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 12)
        case .node(let node):
            FileTreeRowView(
                row: row,
                node: node,
                selected: model.selection == row.id,
                expanded: node.isDirectory && model.isExpanded(node.url.path),
                gitStatus: model.gitStatus[node.url.path],
                dirHasChanges: node.isDirectory && model.gitDirsWithChanges.contains(node.url.path),
                model: model,
                onSelect: {
                    model.selection = row.id
                    treeFocused = true
                },
                onOpen: { open(row) },
                onNaming: { beginNaming($0) }
            )
        }
    }

    // MARK: Actions

    private func open(_ row: FileRow) {
        guard let node = row.node else { return }
        if node.isDirectory {
            if row.detail != nil {
                model.revealInTree(node.url, expandIfDirectory: true)
            } else {
                model.toggleDir(node)
            }
        } else {
            NSWorkspace.shared.open(node.url)
        }
    }

    // MARK: Keyboard

    private func selectedRow() -> FileRow? {
        model.rows.first { $0.id == model.selection }
    }

    private func handleMove(_ direction: MoveCommandDirection) {
        switch direction {
        case .down: moveSelection(1)
        case .up: moveSelection(-1)
        case .right:
            guard let row = selectedRow(), let node = row.node else { return }
            if node.isDirectory, row.detail == nil {
                if model.isExpanded(node.url.path) {
                    moveSelection(1)
                } else {
                    model.toggleDir(node)
                }
            }
        case .left:
            guard let row = selectedRow(), let node = row.node, row.detail == nil else { return }
            if node.isDirectory, model.isExpanded(node.url.path) {
                model.toggleDir(node)
            } else {
                let parent = node.url.deletingLastPathComponent().path
                if model.rows.contains(where: { $0.id == parent }) {
                    model.selection = parent
                }
            }
        @unknown default:
            break
        }
    }

    private func moveSelection(_ delta: Int) {
        let nodeRows = model.rows.filter { $0.node != nil }
        guard !nodeRows.isEmpty else { return }
        guard let selection = model.selection,
              let index = nodeRows.firstIndex(where: { $0.id == selection }) else {
            model.selection = (delta > 0 ? nodeRows.first : nodeRows.last)?.id
            return
        }
        model.selection = nodeRows[min(max(index + delta, 0), nodeRows.count - 1)].id
    }

    // MARK: Naming (new file / new folder / rename)

    private func beginNaming(_ action: NamingAction) {
        if case .rename(let url) = action {
            namingText = url.lastPathComponent
        } else {
            namingText = ""
        }
        namingAction = action
        namingVisible = true
    }

    private var namingTitle: String {
        switch namingAction {
        case .newFile: return "New File"
        case .newFolder: return "New Folder"
        case .rename(let url): return "Rename \(url.lastPathComponent)"
        case nil: return ""
        }
    }

    private var namingConfirmLabel: String {
        if case .rename = namingAction { return "Rename" }
        return "Create"
    }

    private func performNaming() {
        let name = namingText.trimmingCharacters(in: .whitespaces)
        guard let action = namingAction, !name.isEmpty, !name.contains("/") else {
            namingAction = nil
            NSSound.beep()
            return
        }
        namingAction = nil

        Task {
            let target = await Task.detached(priority: .userInitiated) { () -> URL? in
                let fm = FileManager.default
                do {
                    switch action {
                    case .newFile(let dir):
                        let target = dir.appendingPathComponent(name)
                        guard !fm.fileExists(atPath: target.path),
                              fm.createFile(atPath: target.path, contents: Data()) else { return nil }
                        return target
                    case .newFolder(let dir):
                        let target = dir.appendingPathComponent(name, isDirectory: true)
                        guard !fm.fileExists(atPath: target.path) else { return nil }
                        try fm.createDirectory(at: target, withIntermediateDirectories: false)
                        return target
                    case .rename(let url):
                        let target = url.deletingLastPathComponent().appendingPathComponent(name)
                        guard target.path != url.path else { return url }
                        try fm.moveItem(at: url, to: target)
                        return target
                    }
                } catch {
                    return nil
                }
            }.value
            guard let target else {
                NSSound.beep()
                return
            }
            model.revealInTree(target)
            model.refreshAll()
        }
    }
}

// MARK: - Row view

private struct FileTreeRowView: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var appModel: AppModel
    let row: FileRow
    let node: FileNode
    let selected: Bool
    let expanded: Bool
    let gitStatus: GitFileStatus?
    let dirHasChanges: Bool
    let model: FileTreeModel
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onNaming: (FileTreeView.NamingAction) -> Void

    @State private var hovering = false

    private var isSearchResult: Bool { row.detail != nil }

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)
            if node.isDirectory, !isSearchResult {
                Button { model.toggleDir(node) } label: {
                    Image(systemName: "chevron.right")
                        .font(AppFonts.ui(9, weight: .bold))
                        .foregroundStyle(appTheme.muted)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.13), value: expanded)
                        .frame(width: 12, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 12, height: 1)
            }

            Image(nsImage: FileIconCache.icon(for: node.url, isDirectory: node.isDirectory))
                .resizable()
                .frame(width: 15, height: 15)

            VStack(alignment: .leading, spacing: 1) {
                Text(node.url.lastPathComponent)
                    .font(AppFonts.ui(13.5))
                    .foregroundStyle(nameColor)
                    .lineLimit(1)
                if let detail = row.detail {
                    Text(detail)
                        .font(AppFonts.ui(11))
                        .foregroundStyle(appTheme.muted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if gitStatus != nil {
                Text(gitStatusLabel)
                    .font(AppFonts.ui(10, weight: .bold))
                    .foregroundStyle(gitStatusColor)
            } else if dirHasChanges {
                Circle()
                    .fill(appTheme.brass.opacity(0.8))
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? appTheme.brass.opacity(0.18) : (hovering ? appTheme.panel2.opacity(0.55) : Color.clear))
        )
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded { onOpen() })
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(object: node.url as NSURL) }
        .contextMenu { contextMenu }
        .help(isSearchResult ? model.relativePath(of: node.url) : node.url.lastPathComponent)
    }

    private var gitStatusLabel: String {
        switch gitStatus {
        case .modified: return "M"
        case .untracked: return "U"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .conflicted: return "!"
        case nil: return ""
        }
    }

    private var gitStatusColor: Color {
        switch gitStatus {
        case .untracked, .added: return appTheme.good
        case .deleted, .conflicted: return appTheme.danger
        case .modified, .renamed: return appTheme.brass
        case nil: return appTheme.secondaryText
        }
    }

    private var nameColor: Color {
        gitStatus == nil ? (node.isDirectory ? appTheme.text : appTheme.secondaryText) : gitStatusColor
    }

    private var mentionPath: String? {
        guard let controller = appModel.activeComposerController else { return nil }
        let root = URL(fileURLWithPath: controller.projectPath, isDirectory: true).standardizedFileURL.path
        let path = node.url.standardizedFileURL.path
        // File references resolve only within the composer's project; absolute paths are not supported.
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button {
            guard let controller = appModel.activeComposerController, let path = mentionPath else { return }
            let suggestion = ComposerFileSuggestion(
                relativePath: path,
                isDirectory: node.isDirectory,
                replacementRange: NSRange(location: 0, length: 0),
                replacementText: ""
            )
            controller.composerPrefillRequest = ComposerPrefillRequest(
                text: ComposerCompletion.replacingFileSuggestion(suggestion, in: ""),
                insertsAtEnd: true
            )
        } label: {
            Label("Mention in Chat", systemImage: "at")
        }
        .disabled(mentionPath == nil)
        .help(appModel.activeComposerController == nil
              ? "No chat composer available"
              : mentionPath == nil
                ? "Only files within the chat's project can be mentioned"
                : "Insert file reference into chat")
        Button("Open") { NSWorkspace.shared.open(node.url) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
        if isSearchResult {
            Button("Reveal in Tree") { model.revealInTree(node.url, expandIfDirectory: node.isDirectory) }
        }
        Button("Open in Terminal") { openInTerminal() }
        Divider()
        Button("Copy Path") { copyToClipboard(node.url.path) }
        Button("Copy Relative Path") { copyToClipboard(model.relativePath(of: node.url)) }
        Divider()
        Button("New File…") { onNaming(.newFile(containingDirectory)) }
        Button("New Folder…") { onNaming(.newFolder(containingDirectory)) }
        Button("Rename…") { onNaming(.rename(node.url)) }
        Divider()
        Button("Move to Trash", role: .destructive) {
            let url = node.url
            Task {
                let removed = await Task.detached(priority: .userInitiated) {
                    do {
                        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                        return true
                    } catch {
                        return false
                    }
                }.value
                if removed {
                    model.refreshAll()
                } else {
                    NSSound.beep()
                }
            }
        }
    }

    private var containingDirectory: URL {
        node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    }

    private func openInTerminal() {
        let dir = containingDirectory
        switch OpenInTerminalTarget.current {
        case .pig:
            NotificationCenter.default.post(name: .pigOpenTerminalAtPath, object: dir.path)
        case .system:
            // macOS has no default-terminal setting; the app that opens shell
            // executables is the closest equivalent (Terminal unless changed).
            let app = NSWorkspace.shared.urlForApplication(toOpen: .unixExecutable)
                ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([dir], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Icons

@MainActor
enum FileIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for url: URL, isDirectory: Bool) -> NSImage {
        let fileType = UTType(filenameExtension: url.pathExtension) ?? .data
        let key = isDirectory ? "\0dir" : fileType.identifier
        if let hit = cache[key] { return hit }
        let image = NSWorkspace.shared.icon(for: isDirectory ? .folder : fileType)
        image.size = NSSize(width: 16, height: 16)
        cache[key] = image
        return image
    }
}

// MARK: - Loading

enum FileTreeLoader {
    /// Returns nil when the directory can't be read.
    static func children(of url: URL, showHidden: Bool) -> [FileNode]? {
        let fm = FileManager.default
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        guard let urls = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: options) else { return nil }
        return urls
            .map { child in
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
                return FileNode(url: child, isDirectory: values?.isDirectory == true)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
            }
    }

    private static let searchSkipNames: Set<String> = [".git", "node_modules", ".build", "DerivedData", ".venv"]

    static func search(root: URL, query: String, showHidden: Bool) -> [FileNode] {
        let fm = FileManager.default
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showHidden { options.insert(.skipsHiddenFiles) }
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: options) else { return [] }
        let needle = query.lowercased()
        var matches: [FileNode] = []
        var scanned = 0
        for case let url as URL in enumerator {
            scanned += 1
            if scanned.isMultiple(of: 128), Task.isCancelled { break }
            if scanned > 60_000 || matches.count >= 400 { break }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory, searchSkipNames.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            if url.lastPathComponent.lowercased().contains(needle) {
                matches.append(FileNode(url: url, isDirectory: isDirectory))
            }
        }
        return matches.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }
}

// MARK: - Git status

enum GitStatusLoader {
    struct Result {
        var files: [String: GitFileStatus] = [:]
        var dirs: Set<String> = []
        var topLevel: String?
    }

    static func status(for root: URL) -> Result {
        guard !Task.isCancelled,
              let topData = run(["rev-parse", "--show-toplevel"], in: root),
              let top = lineOutput(topData), !top.isEmpty,
              !Task.isCancelled,
              let output = run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: root),
              !Task.isCancelled else {
            return Result()
        }
        var result = Result(topLevel: top)
        let rootPath = root.path
        let records = output.split(separator: 0, omittingEmptySubsequences: true)
        var recordIndex = 0

        func absolutePath(for relativePath: String) -> String? {
            let absolute = (top as NSString).appendingPathComponent(relativePath)
            guard absolute == rootPath || absolute.hasPrefix(rootPath + "/") else { return nil }
            return absolute
        }

        func recordDirectories(for absolute: String) {
            var dir = (absolute as NSString).deletingLastPathComponent
            while dir.count >= rootPath.count, dir.hasPrefix(rootPath) {
                result.dirs.insert(dir)
                if dir == rootPath { break }
                dir = (dir as NSString).deletingLastPathComponent
            }
        }

        while recordIndex < records.count {
            if recordIndex.isMultiple(of: 128), Task.isCancelled { return Result() }
            let record = records[recordIndex]
            recordIndex += 1
            guard record.count >= 4 else { continue }
            let flags = String(decoding: record.prefix(2), as: UTF8.self)
            guard flags != "!!" else { continue }

            let path = String(decoding: record.dropFirst(3), as: UTF8.self)
            let isRenameOrCopy = flags.contains("R") || flags.contains("C")
            var sourcePath: String?
            if isRenameOrCopy, recordIndex < records.count {
                sourcePath = String(decoding: records[recordIndex], as: UTF8.self)
                recordIndex += 1
            }

            guard let absolute = absolutePath(for: path) else {
                if let sourcePath, let sourceAbsolute = absolutePath(for: sourcePath) {
                    recordDirectories(for: sourceAbsolute)
                }
                continue
            }
            result.files[absolute] = fileStatus(for: flags)
            recordDirectories(for: absolute)
            if let sourcePath, let sourceAbsolute = absolutePath(for: sourcePath) {
                recordDirectories(for: sourceAbsolute)
            }
        }
        return result
    }

    private static func fileStatus(for flags: String) -> GitFileStatus {
        switch flags {
        case "??":
            return .untracked
        case "DD", "AU", "UD", "UA", "DU", "AA", "UU":
            return .conflicted
        default:
            if flags.contains("U") { return .conflicted }
            if flags.contains("R") { return .renamed }
            if flags.contains("D") { return .deleted }
            if flags.contains("A") || flags.contains("C") { return .added }
            return .modified
        }
    }

    private static func lineOutput(_ data: Data) -> String? {
        var data = data
        if data.last == 0x0A { data.removeLast() }
        if data.last == 0x0D { data.removeLast() }
        return String(data: data, encoding: .utf8)
    }

    private static func run(_ arguments: [String], in directory: URL) -> Data? {
        guard let result = try? ProcessRunner.capture(
            executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments, cwd: directory
        ), result.status == 0 else { return nil }
        return result.stdout
    }
}
