import SwiftUI
import AppKit
import ImageIO

extension Notification.Name {
    static let pigToggleTerminal = Notification.Name("pigToggleTerminal")
    /// Opens a new terminal tab; the notification's object is the directory path.
    static let pigOpenTerminalAtPath = Notification.Name("pigOpenTerminalAtPath")
    static let pigToggleFullscreenTerminal = Notification.Name("pigToggleFullscreenTerminal")
    static let pigOpenVerticalTerminalSplit = Notification.Name("pigOpenVerticalTerminalSplit")
    static let pigOpenHorizontalTerminalSplit = Notification.Name("pigOpenHorizontalTerminalSplit")
    static let pigShowTerminal = Notification.Name("pigShowTerminal")
    static let pigShowVerticalTerminalSplit = Notification.Name("pigShowVerticalTerminalSplit")
    static let pigShowHorizontalTerminalSplit = Notification.Name("pigShowHorizontalTerminalSplit")
    static let pigNewTerminalTab = Notification.Name("pigNewTerminalTab")
    static let pigCloseTerminalSplit = Notification.Name("pigCloseTerminalSplit")
    static let pigTerminalSplitActiveChanged = Notification.Name("pigTerminalSplitActiveChanged")
}

struct ChatPaneView: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    let controller: SessionController?
    @State private var drafts: [String: String] = [:]
    @State private var imageDrafts: [String: [ImageAttachment]] = [:]
    @State private var terminalWorkspace = TerminalWorkspacePreference.restoredState

    private let splitHandleThickness: CGFloat = 3
    private let minSplitPaneSize: CGFloat = 240

    var body: some View {
        let workspace = terminalWorkspace

        GeometryReader { geometry in
                let size = geometry.size.nonZero
                let chat = chatRect(in: size, workspace: workspace)
                let terminal = terminalRect(in: size, workspace: workspace)

                ZStack(alignment: .topLeading) {
                    ChatTabContent(
                        controller: controller,
                        selectedProjectPath: model.selectedProjectPath,
                        theme: model.selectedTheme,
                        draft: draftBinding(forKey: controller?.id ?? "__none__"),
                        imageAttachments: imageDraftBinding(forKey: controller?.id ?? "__none__")
                    )
                        .frame(width: chat.width, height: chat.height, alignment: .topLeading)
                        .offset(x: chat.minX, y: chat.minY)
                        .opacity(workspace.mode == .full ? 0 : 1)
                        .allowsHitTesting(workspace.mode != .full)
                        .zIndex(workspace.mode == .full ? 0 : 1)

                    TerminalWorkspaceView(
                        tabs: workspace.tabs,
                        activeTabID: workspace.activeTabID,
                        selectTab: selectTerminalTab,
                        closeTab: closeTerminalTab,
                        newTab: { addTerminalTab(show: true) },
                        onExit: closeTerminalTab,
                        onTitleChange: updateTerminalTabTitle
                    )
                    .frame(width: terminal.width, height: terminal.height, alignment: .topLeading)
                    .offset(x: terminal.minX, y: terminal.minY)
                    .opacity(workspace.mode.terminalVisible ? 1 : 0)
                    .allowsHitTesting(workspace.mode.terminalVisible)
                    .zIndex(workspace.mode.terminalVisible ? 2 : 0)

                    splitHandle(in: size, workspace: workspace)
                        .zIndex(3)
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .clipped()
        }
        .background(appTheme.background)
        .onAppear {
            if terminalWorkspace.mode.terminalVisible {
                terminalWorkspace.ensureTab(workingDirectoryPath: currentTerminalWorkingDirectory)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pigToggleTerminal)) { _ in
            toggleTerminal()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pigOpenTerminalAtPath)) { notification in
            guard let path = notification.object as? String else { return }
            terminalWorkspace.addTab(workingDirectoryPath: path)
            if !terminalWorkspace.mode.terminalVisible {
                terminalWorkspace.mode = TerminalPaneMode.buttonDefault
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pigToggleFullscreenTerminal)) { _ in
            toggleFullscreenTerminal()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pigOpenVerticalTerminalSplit)) { _ in
            terminalWorkspace.mode == .verticalSplit ? closeTerminal() : openVerticalSplit()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pigOpenHorizontalTerminalSplit)) { _ in
            terminalWorkspace.mode == .horizontalSplit ? closeTerminal() : openHorizontalSplit()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pigShowTerminal)) { _ in
            showTerminal()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pigShowVerticalTerminalSplit)) { _ in
            openVerticalSplit()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pigShowHorizontalTerminalSplit)) { _ in
            openHorizontalSplit()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pigNewTerminalTab)) { _ in
            addTerminalTab(show: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pigCloseTerminalSplit)) { _ in
            closeSplit()
        }
        .onChange(of: terminalWorkspace.mode, initial: true) { _, mode in
            TerminalWorkspacePreference.save(mode: mode)
            NotificationCenter.default.post(name: .pigTerminalSplitActiveChanged, object: mode.isSplit)
        }
        .onChange(of: terminalWorkspace.verticalSplitFraction) { _, fraction in
            TerminalWorkspacePreference.save(verticalSplitFraction: fraction)
        }
        .onChange(of: terminalWorkspace.horizontalSplitFraction) { _, fraction in
            TerminalWorkspacePreference.save(horizontalSplitFraction: fraction)
        }
    }

    // Drafts are stored per session so a half-typed message never follows
    // the user into a different session.
    private func draftBinding(forKey key: String) -> Binding<String> {
        Binding(
            get: { drafts[key] ?? "" },
            set: { drafts[key] = $0 }
        )
    }

    private func imageDraftBinding(forKey key: String) -> Binding<[ImageAttachment]> {
        Binding(
            get: { imageDrafts[key] ?? [] },
            set: { imageDrafts[key] = $0 }
        )
    }

    private var currentTerminalWorkingDirectory: String? {
        controller?.projectPath ?? model.selectedProjectPath
    }

    private func toggleTerminal() {
        terminalWorkspace.mode.terminalVisible ? closeTerminal() : openTerminal(mode: TerminalPaneMode.buttonDefault)
    }

    private func showTerminal() {
        openTerminal(mode: .full)
    }

    private func toggleFullscreenTerminal() {
        terminalWorkspace.mode == .full ? closeTerminal() : showTerminal()
    }

    private func openVerticalSplit() {
        openTerminal(mode: .verticalSplit)
    }

    private func openHorizontalSplit() {
        openTerminal(mode: .horizontalSplit)
    }

    private func openTerminal(mode: TerminalPaneMode) {
        terminalWorkspace.ensureTab(workingDirectoryPath: currentTerminalWorkingDirectory)
        terminalWorkspace.mode = mode
    }

    private func closeTerminal() {
        terminalWorkspace.mode = .hidden
    }

    private func closeSplit() {
        guard terminalWorkspace.mode.isSplit else { return }
        terminalWorkspace.mode = .hidden
    }

    private func addTerminalTab(show: Bool) {
        terminalWorkspace.addTab(workingDirectoryPath: currentTerminalWorkingDirectory)
        if show, !terminalWorkspace.mode.terminalVisible {
            terminalWorkspace.mode = .horizontalSplit
        }
    }

    private func selectTerminalTab(_ tabID: UUID) {
        guard terminalWorkspace.tabs.contains(where: { $0.id == tabID }) else { return }
        terminalWorkspace.activeTabID = tabID
    }

    private func closeTerminalTab(_ tabID: UUID) {
        terminalWorkspace.closeTab(tabID)
    }

    private func updateTerminalTabTitle(_ tabID: UUID, title: String) {
        terminalWorkspace.updateTitle(title, for: tabID)
    }

    private func chatRect(in size: CGSize, workspace: TerminalWorkspaceState) -> CGRect {
        switch workspace.mode {
        case .hidden, .full:
            return CGRect(origin: .zero, size: size)
        case .verticalSplit:
            let available = max(1, size.width - splitHandleThickness)
            let chatWidth = available * clampedSplitFraction(workspace.verticalSplitFraction, available: available)
            return CGRect(x: 0, y: 0, width: chatWidth, height: size.height)
        case .horizontalSplit:
            let available = max(1, size.height - splitHandleThickness)
            let chatHeight = available * clampedSplitFraction(workspace.horizontalSplitFraction, available: available)
            return CGRect(x: 0, y: 0, width: size.width, height: chatHeight)
        }
    }

    private func terminalRect(in size: CGSize, workspace: TerminalWorkspaceState) -> CGRect {
        switch workspace.mode {
        case .hidden, .full:
            return CGRect(origin: .zero, size: size)
        case .verticalSplit:
            let available = max(1, size.width - splitHandleThickness)
            let chatWidth = available * clampedSplitFraction(workspace.verticalSplitFraction, available: available)
            return CGRect(x: chatWidth + splitHandleThickness, y: 0, width: available - chatWidth, height: size.height)
        case .horizontalSplit:
            let available = max(1, size.height - splitHandleThickness)
            let chatHeight = available * clampedSplitFraction(workspace.horizontalSplitFraction, available: available)
            return CGRect(x: 0, y: chatHeight + splitHandleThickness, width: size.width, height: available - chatHeight)
        }
    }

    @ViewBuilder private func splitHandle(in size: CGSize, workspace: TerminalWorkspaceState) -> some View {
        switch workspace.mode {
        case .verticalSplit:
            let available = max(1, size.width - splitHandleThickness)
            let chatWidth = available * clampedSplitFraction(workspace.verticalSplitFraction, available: available)
            TerminalSplitResizeHandle(
                axis: .vertical,
                fraction: splitFractionBinding(axis: .vertical),
                total: size.width,
                thickness: splitHandleThickness,
                minPaneSize: minSplitPaneSize
            )
            .frame(width: splitHandleThickness, height: size.height)
            .offset(x: chatWidth, y: 0)
        case .horizontalSplit:
            let available = max(1, size.height - splitHandleThickness)
            let chatHeight = available * clampedSplitFraction(workspace.horizontalSplitFraction, available: available)
            TerminalSplitResizeHandle(
                axis: .horizontal,
                fraction: splitFractionBinding(axis: .horizontal),
                total: size.height,
                thickness: splitHandleThickness,
                minPaneSize: minSplitPaneSize
            )
            .frame(width: size.width, height: splitHandleThickness)
            .offset(x: 0, y: chatHeight)
        case .hidden, .full:
            EmptyView()
        }
    }

    private func splitFractionBinding(axis: TerminalSplitAxis) -> Binding<CGFloat> {
        Binding(
            get: {
                axis == .vertical ? terminalWorkspace.verticalSplitFraction : terminalWorkspace.horizontalSplitFraction
            },
            set: { value in
                if axis == .vertical {
                    terminalWorkspace.verticalSplitFraction = value
                } else {
                    terminalWorkspace.horizontalSplitFraction = value
                }
            }
        )
    }

    private func clampedSplitFraction(_ value: CGFloat, available: CGFloat) -> CGFloat {
        let minPane = min(minSplitPaneSize, max(1, available / 2))
        let minFraction = minPane / available
        let maxFraction = 1 - minFraction
        guard minFraction <= maxFraction else { return 0.5 }
        return min(max(value, minFraction), maxFraction)
    }
}

private enum TerminalWorkspacePreference {
    private static let modeKey = "PiG.terminal.mode"
    private static let verticalSplitFractionKey = "PiG.terminal.verticalSplitFraction"
    private static let horizontalSplitFractionKey = "PiG.terminal.horizontalSplitFraction"

    static var restoredState: TerminalWorkspaceState {
        TerminalWorkspaceState(
            mode: TerminalPaneMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .hidden,
            verticalSplitFraction: fraction(forKey: verticalSplitFractionKey, defaultValue: 0.5),
            horizontalSplitFraction: fraction(forKey: horizontalSplitFractionKey, defaultValue: 0.75)
        )
    }

    static func save(mode: TerminalPaneMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: modeKey)
    }

    static func save(verticalSplitFraction: CGFloat) {
        UserDefaults.standard.set(Double(verticalSplitFraction), forKey: verticalSplitFractionKey)
    }

    static func save(horizontalSplitFraction: CGFloat) {
        UserDefaults.standard.set(Double(horizontalSplitFraction), forKey: horizontalSplitFractionKey)
    }

    private static func fraction(forKey key: String, defaultValue: CGFloat) -> CGFloat {
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        let stored = UserDefaults.standard.double(forKey: key)
        return stored > 0 && stored < 1 ? CGFloat(stored) : defaultValue
    }
}
