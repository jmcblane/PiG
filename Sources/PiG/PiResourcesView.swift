import SwiftUI
import Foundation
import UniformTypeIdentifiers

struct PiResourceItem: Identifiable, Hashable, Decodable, Sendable {
    var id: String
    var type: String
    var path: String
    var enabled: Bool
    var displayName: String
    var source: String
    var origin: String
    var groupLabel: String
}

private struct PiResourceListResponse: Decodable, Sendable {
    var resources: [PiResourceItem]
}

private struct PiResourcePayload: @unchecked Sendable {
    var value: [String: Any]
}

enum PiTrustService {
    enum ServiceError: Error, LocalizedError {
        case missingPiModule
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingPiModule:
                return "Could not locate the installed pi module."
            case .commandFailed(let message):
                return message
            }
        }
    }

    static func trust(projectPath: String) async throws {
        let canonicalPath = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        _ = await PiEnvironment.mergedAsync()
        try await Task.detached(priority: .userInitiated) {
            guard let piIndex = PiPaths.piDistIndex else { throw ServiceError.missingPiModule }

            let result: ProcessRunner.Result
            do {
                result = try ProcessRunner.capture(
                    executable: URL(fileURLWithPath: "/usr/bin/env"),
                    arguments: ["node", "--input-type=module", "--eval", trustHelperScript, piIndex.path, canonicalPath],
                    environment: PiEnvironment.merged(extra: [
                        "PIG_PI_DIST_INDEX": piIndex.path,
                        "PIG_PI_AGENT_DIR": PiPaths.agentDir.path
                    ]),
                    cwd: URL(fileURLWithPath: canonicalPath, isDirectory: true)
                )
            } catch {
                throw ServiceError.commandFailed(error.localizedDescription)
            }
            let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            guard result.status == 0 else {
                throw ServiceError.commandFailed(
                    stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stdout : stderr
                )
            }
        }.value
    }
}

enum PiResourceService {
    enum ServiceError: Error, LocalizedError {
        case missingPiModule
        case invalidOutput(String)
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingPiModule:
                return "Could not locate the installed pi module."
            case .invalidOutput(let output):
                return "Invalid pi resource output: \(output)"
            case .commandFailed(let message):
                return message
            }
        }
    }

    static func list() async throws -> [PiResourceItem] {
        let response: PiResourceListResponse = try await run(action: "list", payload: [:])
        return response.resources
    }

    static func setEnabled(_ item: PiResourceItem, enabled: Bool) async throws -> [PiResourceItem] {
        let response: PiResourceListResponse = try await run(action: "set", payload: [
            "type": item.type,
            "path": item.path,
            "enabled": enabled
        ])
        return response.resources
    }

    private static func run<T: Decodable & Sendable>(action: String, payload: [String: Any]) async throws -> T {
        let payload = PiResourcePayload(value: payload)
        _ = await PiEnvironment.mergedAsync()
        return try await Task.detached(priority: .userInitiated) {
            guard let piIndex = PiPaths.piDistIndex else { throw ServiceError.missingPiModule }

            let payloadData = try JSONSerialization.data(withJSONObject: payload.value)
            let payloadText = String(data: payloadData, encoding: .utf8) ?? "{}"
            let result: ProcessRunner.Result
            do {
                try FileManager.default.createDirectory(at: PiPaths.appSupport.appendingPathComponent("GlobalPiResources", isDirectory: true), withIntermediateDirectories: true)
                result = try ProcessRunner.capture(
                    executable: URL(fileURLWithPath: "/usr/bin/env"),
                    arguments: ["node", "-e", helperScript, action, payloadText],
                    environment: PiEnvironment.merged(extra: [
                        "PIG_PI_DIST_INDEX": piIndex.path,
                        "PIG_PI_AGENT_DIR": PiPaths.agentDir.path,
                        "PIG_PI_GLOBAL_CWD": PiPaths.appSupport.appendingPathComponent("GlobalPiResources", isDirectory: true).path
                    ]),
                    cwd: PiPaths.home
                )
            } catch {
                throw ServiceError.commandFailed(error.localizedDescription)
            }
            let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            guard result.status == 0 else {
                throw ServiceError.commandFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stdout : stderr)
            }
            guard let data = stdout.data(using: .utf8) else { throw ServiceError.invalidOutput(stdout) }
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw ServiceError.invalidOutput(stdout.oneLine(max: 600))
            }
        }.value
    }
}

struct PiResourcesPopoverView: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var resources: [PiResourceItem] = []
    @State private var query = ""
    @FocusState private var queryFocused: Bool
    @State private var loading = false
    @State private var errorText: String?

    private let typeOrder = ["extensions", "skills", "prompts", "themes"]
    private let typeLabels = [
        "extensions": "Extensions",
        "skills": "Skills",
        "prompts": "Prompts",
        "themes": "Themes"
    ]

    private var filteredResources: [PiResourceItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return resources }
        return resources.filter { item in
            item.displayName.lowercased().contains(trimmed) ||
            item.path.lowercased().contains(trimmed) ||
            item.groupLabel.lowercased().contains(trimmed) ||
            item.type.lowercased().contains(trimmed)
        }
    }

    private var pinnedResources: [PiResourceItem] {
        let byID = Dictionary(uniqueKeysWithValues: filteredResources.map { ($0.id, $0) })
        return model.pinnedResourceIDs.compactMap { byID[$0] }
    }

    private var groupedResources: [(String, [PiResourceItem])] {
        Dictionary(grouping: filteredResources, by: \.groupLabel)
            .map { group, items in
                (group, items.sorted { lhs, rhs in
                    let lhsType = typeOrder.firstIndex(of: lhs.type) ?? Int.max
                    let rhsType = typeOrder.firstIndex(of: rhs.type) ?? Int.max
                    if lhsType != rhsType { return lhsType < rhsType }
                    return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
                })
            }
            .sorted { lhs, rhs in
                if lhs.0.hasPrefix("npm:") != rhs.0.hasPrefix("npm:") { return lhs.0.hasPrefix("npm:") }
                return lhs.0.localizedStandardCompare(rhs.0) == .orderedAscending
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Pi Resources")
                    .font(AppFonts.heading(18, weight: .semibold))
                    .foregroundStyle(appTheme.text)
                Spacer()
                Button { model.reloadCurrentSessionRuntime() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(InlineIconButtonStyle())
                .disabled(!model.canReloadCurrentSessionRuntime)
                .help("Reload current session runtime")
                Button { model.reloadAllIdleSessionRuntimes() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(InlineIconButtonStyle())
                .disabled(!model.canReloadAnyIdleSessionRuntime)
                .help("Reload all idle session runtimes")
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(InlineIconButtonStyle())
                .help("Close")
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(appTheme.muted)
                TextField("Search resources", text: $query)
                    .textFieldStyle(.plain)
                    .foregroundStyle(appTheme.text)
                    .focused($queryFocused)
                    .onExitCommand { query = "" }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(appTheme.muted)
                    .accessibilityLabel("Clear search")
                }
            }
            .modifier(SearchFieldSurface(isFocused: queryFocused))

            if loading && resources.isEmpty {
                SignalMarchLoadingLabel(text: "Loading resources…")
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else if let errorText {
                Text(errorText)
                    .font(AppFonts.ui(13))
                    .foregroundStyle(appTheme.danger)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
            } else if filteredResources.isEmpty {
                EmptyState(text: resources.isEmpty ? "No global resources" : "No matches", icon: resources.isEmpty ? "puzzlepiece.extension" : "magnifyingglass")
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if !pinnedResources.isEmpty {
                            PinnedResourcesSection(items: pinnedResources, toggle: toggle)
                        }
                        ForEach(groupedResources, id: \.0) { group, items in
                            PiResourceSourceSection(
                                title: group,
                                items: items,
                                typeOrder: typeOrder,
                                typeLabels: typeLabels,
                                toggle: toggle
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 430)
            }
        }
        .padding(14)
        .frame(width: 460)
        .background(appTheme.panel)
        .task { await load() }
    }

    private func load() async {
        loading = true
        errorText = nil
        do {
            resources = try await PiResourceService.list()
            model.updateSessionLaunchExtensions(from: resources)
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }

    private func toggle(_ item: PiResourceItem) {
        guard let index = resources.firstIndex(where: { $0.id == item.id }) else { return }
        let next = !resources[index].enabled
        resources[index].enabled = next
        Task {
            do {
                resources = try await PiResourceService.setEnabled(item, enabled: next)
                model.updateSessionLaunchExtensions(from: resources)
                model.invalidateSlashCommandCatalog()
                errorText = nil
            } catch {
                errorText = error.localizedDescription
                await load()
            }
        }
    }
}

private struct PiResourceSourceSection: View {
    @Environment(\.appTheme) private var appTheme
    let title: String
    let items: [PiResourceItem]
    let typeOrder: [String]
    let typeLabels: [String: String]
    let toggle: (PiResourceItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(AppFonts.ui(13.5, weight: .semibold))
                .foregroundStyle(appTheme.text)
                .lineLimit(1)
                .padding(.horizontal, 2)

            ForEach(typeOrder, id: \.self) { type in
                let typeItems = items.filter { $0.type == type }
                if !typeItems.isEmpty {
                    Text((typeLabels[type] ?? type.capitalized).uppercased())
                        .font(AppFonts.heading(11, weight: .semibold))
                        .tracking(0.9)
                        .foregroundStyle(appTheme.brass)
                        .padding(.top, 3)
                        .padding(.horizontal, 2)
                    ForEach(typeItems) { item in
                        PiResourceRow(item: item) { toggle(item) }
                    }
                }
            }
        }
        .padding(.bottom, 2)
    }
}

private struct PinnedResourcesSection: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    let items: [PiResourceItem]
    let toggle: (PiResourceItem) -> Void
    var showsTitle = true
    var allowsPinning = true
    @State private var draggingID: String?
    @State private var dropTargetID: String?
    @State private var dropAfter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsTitle {
                HStack(spacing: 6) {
                    Image(systemName: "pin.fill")
                        .font(AppFonts.ui(9.5, weight: .semibold))
                        .foregroundStyle(appTheme.brass)
                    Text("PINNED")
                        .font(AppFonts.heading(11, weight: .semibold))
                        .tracking(0.9)
                        .foregroundStyle(appTheme.brass)
                }
                .padding(.horizontal, 2)
            }

            ForEach(items) { item in
                PiResourceRow(
                    item: item,
                    subtitle: "\(item.type.dropLast(item.type.hasSuffix("s") ? 1 : 0).uppercased()) · \(item.groupLabel)",
                    allowsPinning: allowsPinning
                ) { toggle(item) }
                .opacity(draggingID == item.id ? 0.5 : 1)
                .overlay(alignment: dropAfter ? .bottom : .top) {
                    if dropTargetID == item.id, draggingID != item.id {
                        Rectangle()
                            .fill(appTheme.brass)
                            .frame(height: 2)
                            .padding(.horizontal, 8)
                    }
                }
                .onDrag {
                    draggingID = item.id
                    dropTargetID = nil
                    return NSItemProvider(object: item.id as NSString)
                }
                .onDrop(
                    of: [UTType.plainText],
                    delegate: PinnedResourceDropDelegate(
                        targetID: item.id,
                        draggingID: $draggingID,
                        dropTargetID: $dropTargetID,
                        dropAfter: $dropAfter,
                        model: model
                    )
                )
            }
        }
        .padding(.bottom, 4)
    }
}

private struct PinnedResourceDropDelegate: DropDelegate {
    let targetID: String
    @Binding var draggingID: String?
    @Binding var dropTargetID: String?
    @Binding var dropAfter: Bool
    let model: AppModel

    func dropEntered(info: DropInfo) { update(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dropTargetID == targetID { dropTargetID = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggingID, draggingID != targetID else {
            clear()
            return false
        }
        model.movePinnedResource(draggingID, relativeTo: targetID, after: dropAfter)
        clear()
        return true
    }

    private func update(_ info: DropInfo) {
        guard let draggingID, draggingID != targetID else { return }
        dropTargetID = targetID
        dropAfter = info.location.y > 24
    }

    private func clear() {
        draggingID = nil
        dropTargetID = nil
        dropAfter = false
    }
}

private struct PiResourceRow: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    let item: PiResourceItem
    var subtitle: String? = nil
    var allowsPinning = true
    let action: () -> Void
    @State private var hovering = false

    private var pinned: Bool { model.isResourcePinned(item.id) }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: action) {
                HStack(spacing: 9) {
                    Image(systemName: item.enabled ? "checkmark.square.fill" : "square")
                        .font(AppFonts.ui(14, weight: .semibold))
                        .foregroundStyle(item.enabled ? appTheme.brass : appTheme.muted)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayName)
                            .font(AppFonts.ui(13.5, weight: .semibold))
                            .foregroundStyle(appTheme.text)
                            .lineLimit(1)
                        Text(subtitle ?? abbreviatedPath(item.path))
                            .font(AppFonts.ui(11))
                            .foregroundStyle(appTheme.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 8)
                .padding(.trailing, allowsPinning && (hovering || pinned) ? 34 : 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? appTheme.panel2.opacity(0.7) : Color.clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if allowsPinning {
                Button { model.toggleResourcePinned(item.id) } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .font(AppFonts.ui(10.5, weight: .semibold))
                        .foregroundStyle(pinned ? appTheme.brass : appTheme.muted)
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovering || pinned ? 1 : 0)
                .allowsHitTesting(hovering || pinned)
                .padding(.trailing, 5)
                .help(pinned ? "Unpin resource" : "Pin resource")
            }
        }
        .onHover { hovering = $0 }
        .help(item.path)
        .contextMenu {
            if allowsPinning {
                Button(pinned ? "Unpin Resource" : "Pin Resource") {
                    model.toggleResourcePinned(item.id)
                }
            }
            if item.type == "extensions" && !item.enabled {
                if allowsPinning { Divider() }
                Button {
                    if let path = model.selectedProject?.path {
                        model.newSession(projectPath: path, extensionPaths: [item.path])
                    }
                } label: {
                    Label("New Chat with This Extension", systemImage: "square.and.pencil")
                }
                .disabled(model.selectedProject == nil)

                Button {
                    model.newQuickChat(extensionPaths: [item.path])
                } label: {
                    Label("New Quick Chat with This Extension", systemImage: "bolt.fill")
                }
            }
        }
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

private let trustHelperScript = #"""
(async () => {
  const { pathToFileURL } = await import('node:url');
  const piIndex = process.env.PIG_PI_DIST_INDEX || process.argv[1];
  const projectPath = process.argv[2];
  if (!piIndex) throw new Error('PIG_PI_DIST_INDEX is not set');
  if (!projectPath) throw new Error('Project path is not set');
  const pi = await import(pathToFileURL(piIndex).href);
  const agentDir = process.env.PIG_PI_AGENT_DIR || pi.getAgentDir();
  new pi.ProjectTrustStore(agentDir).set(projectPath, true);
  process.stdout.write(projectPath);
})().catch((error) => {
  console.error(error && error.stack ? error.stack : String(error));
  process.exit(1);
});
"""#

private let helperScript = #"""
(async () => {
  const path = await import('node:path');
  const { pathToFileURL } = await import('node:url');
  const piIndex = process.env.PIG_PI_DIST_INDEX;
  if (!piIndex) throw new Error('PIG_PI_DIST_INDEX is not set');
  const pi = await import(pathToFileURL(piIndex).href);
  const { DefaultPackageManager, SettingsManager } = pi;
  const cwd = process.env.PIG_PI_GLOBAL_CWD || process.env.HOME || process.cwd();
  const agentDir = process.env.PIG_PI_AGENT_DIR || path.join(process.env.HOME || '', '.pi', 'agent');
  const action = process.argv[1] || 'list';
  const payload = process.argv[2] ? JSON.parse(process.argv[2]) : {};
  const RESOURCE_TYPES = ['extensions', 'skills', 'prompts', 'themes'];

  function settingsManager() {
    return SettingsManager.create(cwd, agentDir, { projectTrusted: false });
  }

  async function resolvedResources(manager) {
    const packageManager = new DefaultPackageManager({ cwd, agentDir, settingsManager: manager });
    const resolved = await packageManager.resolve(async () => 'skip');
    const resources = [];
    for (const type of RESOURCE_TYPES) {
      for (const item of resolved[type] || []) {
        if (item.metadata?.scope !== 'user') continue;
        resources.push(formatItem(type, item));
      }
    }
    resources.sort((a, b) => {
      const ta = RESOURCE_TYPES.indexOf(a.type), tb = RESOURCE_TYPES.indexOf(b.type);
      if (ta !== tb) return ta - tb;
      const ga = a.groupLabel.localeCompare(b.groupLabel);
      return ga || a.displayName.localeCompare(b.displayName);
    });
    return { resources };
  }

  function formatItem(type, item) {
    const metadata = item.metadata || {};
    return {
      id: `${type}:${item.path}`,
      type,
      path: item.path,
      enabled: !!item.enabled,
      displayName: displayName(type, item.path),
      source: metadata.source || '',
      origin: metadata.origin || '',
      groupLabel: groupLabel(metadata),
    };
  }

  function displayName(type, filePath) {
    const fileName = path.basename(filePath);
    const parentFolder = path.basename(path.dirname(filePath));
    if (type === 'extensions' && parentFolder !== 'extensions') return `${parentFolder}/${fileName}`;
    if (type === 'skills' && fileName === 'SKILL.md') return parentFolder;
    return fileName;
  }

  function groupLabel(metadata) {
    if (metadata.origin === 'package') return metadata.source || 'Package';
    if (metadata.source === 'auto') return `User (${formatBaseDir(metadata.baseDir || agentDir)})`;
    return 'User settings';
  }

  function formatBaseDir(baseDir) {
    const home = process.env.HOME || '';
    let display = baseDir;
    if (home && baseDir === home) display = '~';
    else if (home && baseDir.startsWith(home)) display = `~${baseDir.slice(home.length)}`;
    return display.endsWith('/') ? display : `${display}/`;
  }

  function strippedPattern(pattern) {
    return pattern.startsWith('!') || pattern.startsWith('+') || pattern.startsWith('-') ? pattern.slice(1) : pattern;
  }

  async function toggleResource() {
    const manager = settingsManager();
    const packageManager = new DefaultPackageManager({ cwd, agentDir, settingsManager: manager });
    const resolved = await packageManager.resolve(async () => 'skip');
    const type = payload.type;
    const target = (resolved[type] || []).find((item) => item.path === payload.path && item.metadata?.scope === 'user');
    if (!target) throw new Error(`Resource not found: ${payload.path}`);
    const enabled = !!payload.enabled;
    if (target.metadata.origin === 'package') togglePackage(manager, target, type, enabled);
    else toggleTopLevel(manager, target, type, enabled);
    await manager.flush();
    return resolvedResources(settingsManager());
  }

  function toggleTopLevel(manager, item, type, enabled) {
    const settings = manager.getGlobalSettings();
    const current = settings[type] || [];
    const baseDir = item.metadata.baseDir || agentDir;
    const pattern = path.relative(baseDir, item.path);
    const updated = current.filter((entry) => strippedPattern(entry) !== pattern);
    updated.push(`${enabled ? '+' : '-'}${pattern}`);
    setGlobalResourcePaths(manager, type, updated);
  }

  function togglePackage(manager, item, type, enabled) {
    const settings = manager.getGlobalSettings();
    const packages = [...(settings.packages || [])];
    const index = packages.findIndex((pkg) => (typeof pkg === 'string' ? pkg : pkg.source) === item.metadata.source);
    if (index < 0) throw new Error(`Package not found: ${item.metadata.source}`);
    let pkg = packages[index];
    if (typeof pkg === 'string') {
      pkg = { source: pkg };
      packages[index] = pkg;
    }
    const baseDir = item.metadata.baseDir || path.dirname(item.path);
    const pattern = path.relative(baseDir, item.path);
    const current = pkg[type] || [];
    const updated = current.filter((entry) => strippedPattern(entry) !== pattern);
    updated.push(`${enabled ? '+' : '-'}${pattern}`);
    pkg[type] = updated;
    manager.setPackages(packages);
  }

  function setGlobalResourcePaths(manager, type, paths) {
    if (type === 'extensions') manager.setExtensionPaths(paths);
    else if (type === 'skills') manager.setSkillPaths(paths);
    else if (type === 'prompts') manager.setPromptTemplatePaths(paths);
    else if (type === 'themes') manager.setThemePaths(paths);
    else throw new Error(`Unknown resource type: ${type}`);
  }

  const result = action === 'set' ? await toggleResource() : await resolvedResources(settingsManager());
  process.stdout.write(JSON.stringify(result));
})().catch((error) => {
  console.error(error && error.stack ? error.stack : String(error));
  process.exit(1);
});
"""#
