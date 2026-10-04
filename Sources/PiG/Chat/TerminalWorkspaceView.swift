import SwiftUI
import AppKit
import ImageIO

struct TerminalWorkspaceState {
    var mode: TerminalPaneMode = .hidden
    var verticalSplitFraction: CGFloat = 0.5
    var horizontalSplitFraction: CGFloat = 0.75
    var tabs: [TerminalTabState] = []
    var activeTabID: UUID?

    mutating func ensureTab(workingDirectoryPath: String?) {
        if tabs.isEmpty { addTab(workingDirectoryPath: workingDirectoryPath) }
    }

    mutating func addTab(workingDirectoryPath: String?) {
        let name = Self.tabName(for: workingDirectoryPath)
        // Reuse the lowest number no open tab with this name holds.
        let used = Set(tabs.filter { $0.name == name }.map(\.number))
        let number = (1...).first { !used.contains($0) }!
        let tab = TerminalTabState(
            id: UUID(),
            name: name,
            number: number,
            workingDirectoryPath: workingDirectoryPath
        )
        tabs.append(tab)
        activeTabID = tab.id
    }

    mutating func closeTab(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let wasActive = activeTabID == tabID
        tabs.remove(at: index)
        if tabs.isEmpty {
            activeTabID = nil
            mode = .hidden
        } else if wasActive {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    mutating func updateTitle(_ title: String, for tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }
        tabs[index].shellTitle = String(cleanTitle.prefix(80))
    }

    /// The project folder's name, or "~" for the home folder or a missing directory.
    private static func tabName(for path: String?) -> String {
        var isDirectory: ObjCBool = false
        guard let path, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "~"
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if url.path == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path { return "~" }
        return url.lastPathComponent
    }
}

struct TerminalTabState: Identifiable, Equatable {
    let id: UUID
    /// Default label: the project folder name.
    let name: String
    /// Distinguishes tabs that share a name; shown only when above 1.
    let number: Int
    var workingDirectoryPath: String?
    /// Title set by the shell, which replaces the default label.
    var shellTitle: String?
}

enum TerminalPaneMode: String, Equatable {
    case hidden
    case full
    case verticalSplit
    case horizontalSplit

    var terminalVisible: Bool { self != .hidden }
    var isSplit: Bool { self == .verticalSplit || self == .horizontalSplit }

    /// Layouts the titlebar terminal button can open.
    static let buttonChoices: [TerminalPaneMode] = [.full, .verticalSplit, .horizontalSplit]
    static let buttonDefaultKey = "PiG.terminal.buttonDefaultMode"

    /// The layout the titlebar terminal button opens (Settings → General → Terminal).
    static var buttonDefault: TerminalPaneMode {
        let mode = TerminalPaneMode(rawValue: UserDefaults.standard.string(forKey: buttonDefaultKey) ?? "") ?? .full
        return buttonChoices.contains(mode) ? mode : .full
    }

    var displayName: String {
        switch self {
        case .hidden: return "Hidden"
        case .full: return "Full"
        case .verticalSplit: return "Vertical split"
        case .horizontalSplit: return "Horizontal split"
        }
    }
}

/// Where the file tree's "Open in Terminal" opens a folder (Settings → General → Terminal).
enum OpenInTerminalTarget: String, CaseIterable, Identifiable {
    case pig
    case system

    static let key = "PiG.terminal.openInTerminalTarget"

    static var current: OpenInTerminalTarget {
        OpenInTerminalTarget(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .pig
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pig: return "Inside PiG"
        case .system: return "Default terminal app"
        }
    }
}

enum TerminalSplitAxis {
    case vertical
    case horizontal
}

struct TerminalSplitResizeHandle: View {
    @Environment(\.appTheme) private var appTheme
    let axis: TerminalSplitAxis
    @Binding var fraction: CGFloat
    let total: CGFloat
    let thickness: CGFloat
    let minPaneSize: CGFloat
    @State private var startingFraction: CGFloat?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering ? appTheme.brass.opacity(0.55) : appTheme.line.opacity(0.45))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let start = startingFraction ?? fraction
                        startingFraction = start
                        let available = max(1, total - thickness)
                        let delta = axis == .vertical ? value.translation.width : value.translation.height
                        fraction = Self.clamped(start + delta / available, available: available, minPaneSize: minPaneSize)
                    }
                    .onEnded { _ in startingFraction = nil }
            )
    }

    private static func clamped(_ value: CGFloat, available: CGFloat, minPaneSize: CGFloat) -> CGFloat {
        let minPane = min(minPaneSize, max(1, available / 2))
        let minFraction = minPane / available
        let maxFraction = 1 - minFraction
        guard minFraction <= maxFraction else { return 0.5 }
        return min(max(value, minFraction), maxFraction)
    }
}

struct TerminalWorkspaceView: View {
    @Environment(\.appTheme) private var appTheme
    let tabs: [TerminalTabState]
    let activeTabID: UUID?
    let selectTab: (UUID) -> Void
    let closeTab: (UUID) -> Void
    let newTab: () -> Void
    let onExit: (UUID) -> Void
    let onTitleChange: (UUID, String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !tabs.isEmpty {
                TerminalTabStrip(
                    tabs: tabs,
                    activeTabID: activeTabID,
                    selectTab: selectTab,
                    closeTab: closeTab,
                    newTab: newTab
                )
            }

            ZStack(alignment: .topLeading) {
                ForEach(tabs) { tab in
                    EmbeddedTerminalView(
                        workingDirectoryPath: tab.workingDirectoryPath,
                        onExit: { onExit(tab.id) },
                        onTitleChange: { onTitleChange(tab.id, $0) }
                    )
                    .id(tab.id)
                    .opacity(tab.id == activeTabID ? 1 : 0)
                    .allowsHitTesting(tab.id == activeTabID)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(appTheme.background)
    }
}

private struct TerminalTabStrip: View {
    @Environment(\.appTheme) private var appTheme
    let tabs: [TerminalTabState]
    let activeTabID: UUID?
    let selectTab: (UUID) -> Void
    let closeTab: (UUID) -> Void
    let newTab: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                HStack(spacing: 0) {
                    Button(action: { selectTab(tab.id) }) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(tab.shellTitle ?? tab.name)
                                .font(AppFonts.ui(12, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if tab.shellTitle == nil, tab.number > 1 {
                                // A quiet number, not "(2)": it reads as a secondary label.
                                Text("\(tab.number)")
                                    .font(AppFonts.ui(11, weight: .regular).monospacedDigit())
                                    .foregroundStyle(appTheme.muted)
                                    .layoutPriority(1)
                            }
                        }
                            .padding(.leading, 10)
                            .padding(.trailing, 6)
                            .frame(maxWidth: 110, minHeight: 24, maxHeight: 24, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help(tab.workingDirectoryPath ?? "~")

                    Button(action: { closeTab(tab.id) }) {
                        Image(systemName: "xmark")
                            .font(AppFonts.ui(9, weight: .bold))
                            .frame(width: 20, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(appTheme.muted)
                }
                .foregroundStyle(tab.id == activeTabID ? appTheme.text : appTheme.secondaryText)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tab.id == activeTabID ? appTheme.panel : appTheme.panel.opacity(0.45))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(tab.id == activeTabID ? appTheme.brass.opacity(0.45) : appTheme.line.opacity(0.55), lineWidth: 1)
                )
            }

            Button(action: newTab) {
                Image(systemName: "plus")
                    .font(AppFonts.ui(11, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(appTheme.secondaryText)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(appTheme.panel.opacity(0.96))
        .overlay(alignment: .bottom) {
            Rectangle().fill(appTheme.line.opacity(0.7)).frame(height: 1)
        }
    }
}

extension CGSize {
    var nonZero: CGSize {
        CGSize(width: max(1, width), height: max(1, height))
    }
}
