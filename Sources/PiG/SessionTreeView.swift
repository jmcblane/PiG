import SwiftUI

struct SessionTreeToolbarButton: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button {
            model.showingSessionTree.toggle()
        } label: {
            Image(systemName: "arrow.triangle.branch")
                .font(AppFonts.ui(12.5, weight: .semibold))
                .foregroundStyle(model.showingSessionTree ? appTheme.brass : appTheme.text)
                .frame(width: 24, height: 20)
                .background(model.showingSessionTree ? appTheme.panel2.opacity(0.9) : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.selectedController == nil)
        .help("Fork session")
        .popover(isPresented: $model.showingSessionTree, arrowEdge: .bottom) {
            if let controller = model.selectedController {
                SessionTreeLensView(controller: controller)
                    .environmentObject(model)
                    .environment(\.appTheme, AppTheme(choice: model.selectedTheme))
            }
        }
        .onChange(of: model.selectedControllerID) { _, _ in
            model.showingSessionTree = false
        }
    }
}

private struct SessionTreeMarkdownPreview: View {
    let source: String
    @State private var renderedSource = ""
    @State private var rendered = AttributedString()

    var body: some View {
        Text(renderedSource == source ? rendered : AttributedString(source))
            .task(id: source) {
                let source = source
                let value = await Task.detached(priority: .utility) {
                    Self.render(source)
                }.value
                guard !Task.isCancelled else { return }
                rendered = value
                renderedSource = source
            }
    }

    nonisolated private static func render(_ source: String) -> AttributedString {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result = AttributedString()

        for (index, line) in lines.enumerated() {
            let heading = headingContent(in: line)
            let content = heading ?? line
            var rendered = (try? AttributedString(
                markdown: content,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(content)

            if heading != nil {
                let runs = rendered.runs.map { ($0.range, $0.inlinePresentationIntent) }
                for (range, existingIntent) in runs {
                    var intent = existingIntent ?? []
                    intent.insert(.stronglyEmphasized)
                    rendered[range].inlinePresentationIntent = intent
                }
            }

            result.append(rendered)
            if index < lines.count - 1 { result.append(AttributedString("\n")) }
        }
        return result
    }

    nonisolated private static func headingContent(in line: String) -> String? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        let markerCount = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(markerCount) else { return nil }
        let remainder = trimmed.dropFirst(markerCount)
        guard remainder.first?.isWhitespace == true else { return nil }
        return remainder.drop(while: \.isWhitespace).trimmingCharacters(in: .whitespaces)
    }
}

private struct SessionTreeLensView: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    @ObservedObject var controller: SessionController
    @State private var expandedAlternativeNodeIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 440, height: 520)
        .background(appTheme.panel2)
        .task(id: controller.id) {
            await controller.loadSessionTree()
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.triangle.branch")
                .font(AppFonts.ui(13, weight: .semibold))
                .foregroundStyle(appTheme.brass)
            Text("Session Tree")
                .font(AppFonts.heading(14, weight: .semibold))
                .foregroundStyle(appTheme.text)
            Spacer()
            Button {
                Task { await controller.loadSessionTree(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(AppFonts.ui(11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(appTheme.muted)
            .disabled(controller.sessionTreeLoadState == .loading)
            .help("Refresh session tree")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .background(appTheme.brass.opacity(0.05))
    }

    @ViewBuilder
    private var content: some View {
        switch controller.sessionTreeLoadState {
        case .idle, .loading:
            SignalMarchLoadingLabel(text: "Loading tree…")
                .frame(maxWidth: .infinity, minHeight: 150)
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(appTheme.danger)
                Text(message)
                    .font(AppFonts.ui(12.5))
                    .foregroundStyle(appTheme.muted)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Button("Retry") {
                    Task { await controller.loadSessionTree(force: true) }
                }
                .buttonStyle(.plain)
                .font(AppFonts.ui(12.5, weight: .semibold))
                .foregroundStyle(appTheme.brass)
            }
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: 150)
        case .loaded:
            if let tree = controller.sessionTree {
                let turns = conversationTurns(from: tree.activePath)
                if !turns.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                                spineTurn(
                                    turn,
                                    in: tree,
                                    isCurrent: index == turns.count - 1,
                                    isLast: index == turns.count - 1
                                )
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                } else {
                    Text("No conversation messages")
                        .font(AppFonts.ui(12.5))
                        .foregroundStyle(appTheme.muted)
                        .frame(maxWidth: .infinity, minHeight: 150)
                }
            } else {
                Text("No session entries")
                    .font(AppFonts.ui(12.5))
                    .foregroundStyle(appTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 150)
            }
        }
    }

    private func alternateRoots(for turn: SessionTreeTurn, in tree: SessionTreeSnapshot) -> [SessionTreeNode] {
        let fromUser = turn.user.children.filter { !tree.activePathIDs.contains($0.id) }
        let fromAssistant = turn.assistant?.children.filter { !tree.activePathIDs.contains($0.id) } ?? []
        return fromUser + fromAssistant
    }

    private func conversationTurns(from nodes: [SessionTreeNode]) -> [SessionTreeTurn] {
        var turns: [SessionTreeTurn] = []
        var currentUser: SessionTreeNode?
        var currentAssistant: SessionTreeNode?

        func flush() {
            guard let user = currentUser else { return }
            turns.append(SessionTreeTurn(user: user, assistant: currentAssistant))
            currentUser = nil
            currentAssistant = nil
        }

        for node in nodes {
            if node.isForkable {
                flush()
                currentUser = node
            } else if currentUser != nil, node.kind == .assistant, node.hasDisplayableText {
                currentAssistant = node
            }
        }
        flush()
        return turns
    }

    @ViewBuilder
    private func spineTurn(
        _ turn: SessionTreeTurn,
        in tree: SessionTreeSnapshot,
        isCurrent: Bool,
        isLast: Bool
    ) -> some View {
        let roots = alternateRoots(for: turn, in: tree)
        let alternatives = roots.flatMap { alternativeItems(root: $0) }
        let expanded = expandedAlternativeNodeIDs.contains(turn.user.id)

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Button {
                    Task { await controller.revealMessage(entryID: turn.user.id) }
                } label: {
                    turnUserSummary(turn.user, isCurrent: isCurrent)
                }
                .buttonStyle(.plain)
                .help("Show this message in chat")
                .accessibilityLabel("Show in chat: \(turn.user.preview.oneLine(max: 80))")

                forkButton(for: turn.user)
            }
            .padding(.leading, 13)
            .padding(.trailing, 5)
            .padding(.top, 9)
            .padding(.bottom, alternatives.isEmpty && turn.assistant == nil ? 9 : 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isCurrent ? appTheme.brass.opacity(0.05) : Color.clear)

            if !alternatives.isEmpty {
                Button {
                    if expanded {
                        expandedAlternativeNodeIDs.remove(turn.user.id)
                    } else {
                        expandedAlternativeNodeIDs.insert(turn.user.id)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(AppFonts.ui(8.5, weight: .bold))
                            .frame(width: 10)
                        Text("\(roots.count) alternate\(roots.count == 1 ? "" : "s")")
                            .font(AppFonts.ui(11.5, weight: .semibold))
                    }
                    .foregroundStyle(appTheme.muted)
                    .padding(.leading, 13)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Collapse alternatives" : "Show alternatives")

                if expanded {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(alternatives) { item in
                            alternativeRow(item)
                        }
                    }
                    .padding(.leading, 13)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(appTheme.line)
                            .frame(width: 1)
                            .padding(.leading, 4)
                    }
                }
            }

            if let assistant = turn.assistant {
                assistantPair(assistant)
                    .padding(.bottom, isLast ? 4 : 8)
            }
        }
        .padding(.leading, 18)
        .overlay(alignment: .leading) {
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(appTheme.brass.opacity(isCurrent ? 1 : 0.35))
                    .frame(width: 2)
                    .padding(.bottom, isLast ? 14 : 0)
                SessionTreeNodePoint(kind: turn.user.kind)
                    .padding(.top, 14)
            }
            .frame(width: 12)
        }
    }

    private func turnUserSummary(_ node: SessionTreeNode, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                SessionTreeKindIcon(kind: node.kind)
                Text(node.label ?? node.kind.displayName)
                    .font(AppFonts.ui(9.5, weight: .bold))
                    .tracking(1.0)
                    .textCase(.uppercase)
                    .foregroundStyle(appTheme.muted)
                    .lineLimit(1)
                Spacer()
                if isCurrent {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(appTheme.brass)
                            .frame(width: 6, height: 6)
                        Text("CURRENT")
                            .font(AppFonts.ui(9, weight: .bold))
                            .tracking(0.8)
                    }
                    .foregroundStyle(appTheme.brass)
                }
            }

            previewText(for: node)
                .font(AppFonts.ui(12.5, weight: .semibold))
                .foregroundStyle(appTheme.text)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private func assistantPair(_ node: SessionTreeNode) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                SessionTreeKindIcon(kind: node.kind)
                Text(node.label ?? node.kind.displayName)
                    .font(AppFonts.ui(9.5, weight: .bold))
                    .tracking(1.0)
                    .textCase(.uppercase)
                    .foregroundStyle(appTheme.muted)
                    .lineLimit(1)
            }

            previewText(for: node)
                .font(AppFonts.ui(12))
                .foregroundStyle(appTheme.secondaryText)
                .lineLimit(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 13)
        .padding(.trailing, 5)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(appTheme.line.opacity(0.7))
                .frame(width: 1)
                .padding(.leading, 4)
        }
    }

    private func alternativeRow(_ item: SessionTreeAlternativeItem) -> some View {
        HStack(alignment: .top, spacing: 7) {
            SessionTreeNodePoint(kind: item.node.kind)
            SessionTreeKindIcon(kind: item.node.kind)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.node.label ?? item.node.kind.displayName)
                    .font(AppFonts.ui(9, weight: .bold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(appTheme.muted)
                previewText(for: item.node)
                    .font(AppFonts.ui(11.5, weight: item.node.kind == .user ? .semibold : .regular))
                    .foregroundStyle(appTheme.secondaryText)
                    .lineLimit(item.node.kind == .assistant ? 12 : 2)
            }
            Spacer(minLength: 4)
            if item.node.isForkable {
                forkButton(for: item.node, compact: true)
            }
        }
        .padding(.leading, CGFloat(item.depth) * 14)
        .padding(.vertical, 6)
        .padding(.trailing, 5)
        .overlay(alignment: .bottom) {
            Rectangle().fill(appTheme.line.opacity(0.45)).frame(height: 1)
        }
    }

    @ViewBuilder
    private func previewText(for node: SessionTreeNode) -> some View {
        if node.kind == .assistant {
            SessionTreeMarkdownPreview(source: node.preview)
        } else {
            Text(node.preview)
        }
    }

    private func forkButton(for node: SessionTreeNode, compact: Bool = false) -> some View {
        Button {
            model.showingSessionTree = false
            Task { await controller.forkFromTree(entryID: node.id) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(AppFonts.ui(10, weight: .semibold))
                if !compact { Text("Fork") }
            }
            .font(AppFonts.ui(10.5, weight: .bold))
            .foregroundStyle(appTheme.brass)
            .padding(.horizontal, compact ? 5 : 8)
            .frame(height: 24)
            .background(appTheme.brass.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(appTheme.brass.opacity(0.55), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(controller.isForking || !controller.isAgentSettled || controller.showsActivityIndicator)
        .help("Fork a new session from this prompt")
        .accessibilityLabel("Fork from: \(node.preview.oneLine(max: 80))")
    }

    private func alternativeItems(root: SessionTreeNode) -> [SessionTreeAlternativeItem] {
        let flattened = flattenedAlternativeItems(root: root)
        var visible: [SessionTreeAlternativeItem] = []
        var pendingAssistant: SessionTreeAlternativeItem?

        for item in flattened {
            if item.node.isForkable {
                if let pendingAssistant { visible.append(pendingAssistant) }
                pendingAssistant = nil
                visible.append(item)
            } else if item.node.kind == .assistant, item.node.hasDisplayableText {
                pendingAssistant = item
            }
        }
        if let pendingAssistant { visible.append(pendingAssistant) }
        return visible
    }

    private func flattenedAlternativeItems(root: SessionTreeNode, depth: Int = 0) -> [SessionTreeAlternativeItem] {
        [SessionTreeAlternativeItem(node: root, depth: depth)]
            + root.children.flatMap { flattenedAlternativeItems(root: $0, depth: depth + 1) }
    }
}

private struct SessionTreeTurn: Identifiable {
    let user: SessionTreeNode
    let assistant: SessionTreeNode?
    var id: String { user.id }
}

private struct SessionTreeAlternativeItem: Identifiable {
    let node: SessionTreeNode
    let depth: Int
    var id: String { node.id }
}

private struct SessionTreeNodePoint: View {
    @Environment(\.appTheme) private var appTheme
    let kind: SessionTreeEntryKind

    var body: some View {
        Group {
            if kind == .user {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(appTheme.brass)
                    .frame(width: 8, height: 8)
                    .rotationEffect(.degrees(45))
            } else {
                Circle()
                    .fill(appTheme.panel2)
                    .overlay(Circle().stroke(appTheme.brass, lineWidth: 1.5))
                    .frame(width: 7, height: 7)
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}

private struct SessionTreeKindIcon: View {
    @Environment(\.appTheme) private var appTheme
    let kind: SessionTreeEntryKind

    var body: some View {
        Image(systemName: kind.symbolName)
            .font(AppFonts.ui(10.5, weight: .semibold))
            .foregroundStyle(kind == .user ? appTheme.brass : appTheme.muted)
            .frame(width: 14, height: 14)
    }
}

private extension SessionTreeEntryKind {
    var displayName: String {
        switch self {
        case .user: return "User"
        case .assistant: return "Assistant"
        case .tool: return "Tool"
        case .message: return "Message"
        case .model: return "Model"
        case .thinking: return "Thinking"
        case .compaction: return "Compaction"
        case .branchSummary: return "Branch summary"
        case .label: return "Label"
        case .custom: return "Custom"
        case .sessionInfo: return "Session info"
        case .unknown: return "Entry"
        }
    }

    var symbolName: String {
        switch self {
        case .user: return "person"
        case .assistant: return "sparkles"
        case .tool: return "wrench.and.screwdriver"
        case .message: return "text.bubble"
        case .model: return "cpu"
        case .thinking: return "brain"
        case .compaction: return "arrow.down.right.and.arrow.up.left"
        case .branchSummary: return "arrow.triangle.branch"
        case .label: return "tag"
        case .custom: return "puzzlepiece.extension"
        case .sessionInfo: return "info.circle"
        case .unknown: return "circle"
        }
    }
}
