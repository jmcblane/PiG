import SwiftUI
import AppKit
import ImageIO

struct ChatScrollView: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    @ObservedObject var controller: SessionController
    let theme: AppThemeChoice
    @State private var isAtBottom = true
    @State private var forceScrollToken = 0
    @State private var topAnchorToken = 0
    @State private var highlightedMessageID: String?
    @State private var highlightRequestID: UUID?

    private let bottomContentGap: CGFloat = 8

    private var activityText: String {
        if controller.isThinking { return "Thinking" }
        if controller.isCompacting { return "Compacting" }
        if controller.isWorking { return "Working" }
        return "Streaming"
    }

    private var transcriptPresentation: TranscriptToolPresentation {
        TranscriptToolPresentation(
            messages: controller.messages,
            visibleMessages: controller.visibleMessages,
            isAgentActive: controller.isWorking,
            showThinkingTraces: model.showThinkingTraces
        )
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                ReliableBottomScrollView(
                    isAtBottom: $isAtBottom,
                    forceScrollToken: forceScrollToken,
                    streamingFrameToken: controller.streamingFrameToken,
                    textSizeStep: model.textSizeStep,
                    topAnchorToken: topAnchorToken,
                    messageScrollRequest: controller.messageScrollRequest
                ) {
                    VStack(alignment: .leading, spacing: 0) {
                        if controller.hiddenMessageCount > 0 {
                            LoadEarlierMessagesRow(count: controller.hiddenMessageCount) {
                                topAnchorToken += 1
                                controller.loadEarlierMessages()
                            }
                        }
                        ForEach(transcriptPresentation.items) { item in
                            switch item {
                            case .message(let message):
                                ChatMessageRow(
                                    message: message,
                                    projectPath: controller.projectPath,
                                    activityText: activityText,
                                    theme: theme,
                                    textSizeStep: model.textSizeStep,
                                    showThinkingTraces: model.showThinkingTraces,
                                    isHighlighted: highlightedMessageID == message.id
                                )
                                .equatable()
                                .background {
                                    ChatMessageScrollAnchor(messageID: message.id)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            case .toolGroup(let group):
                                ToolActivityView(
                                    group: group,
                                    projectPath: controller.projectPath,
                                    activityText: activityText,
                                    theme: theme,
                                    textSizeStep: model.textSizeStep,
                                    showThinkingTraces: model.showThinkingTraces,
                                    highlightedMessageID: highlightedMessageID
                                )
                            case .userTools(let messageID, let tools):
                                ToolGroupView(tools: tools, projectPath: controller.projectPath)
                                    .padding(.leading, 36)
                                    .padding(.trailing, 18)
                                    .padding(.vertical, 6)
                                    .background {
                                        ChatMessageScrollAnchor(messageID: messageID)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    }
                            case .anchor(let messageID):
                                ChatMessageScrollAnchor(messageID: messageID)
                                    .frame(height: 0)
                            }
                        }
                        // controller.errorText surfaces via the arbitrated root toast
                        // plus the 'Last error' affordance near the composer.
                    }
                    .padding(.top, 6)
                    .padding(.bottom, bottomContentGap)
                    // Size the transcript to its ideal height before the
                    // minHeight floor below. Without this the floor's slack is
                    // proposed down into the stack and any vertically flexible
                    // child (a markdown table cell) swallows it, which is what
                    // produced the giant blank table rows.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: geometry.size.height, alignment: .bottomLeading)
                    // Explicit width so NSHostingView's fittingSize measures the
                    // wrapped (width-constrained) height, not the ideal width.
                    .frame(width: geometry.size.width, alignment: .bottomLeading)
                }
                .onAppear { forceScrollToken += 1 }
                .onChange(of: controller.id) { _, _ in forceScrollToken += 1 }
                .onChange(of: controller.bottomScrollRequest) { _, _ in forceScrollToken += 1 }
                .onChange(of: controller.messageScrollRequest) { _, request in
                    guard let request else { return }
                    highlightedMessageID = request.messageID
                    highlightRequestID = request.id
                    Task {
                        try? await Task.sleep(nanoseconds: 1_300_000_000)
                        guard highlightRequestID == request.id else { return }
                        withAnimation(.easeOut(duration: 0.22)) {
                            highlightedMessageID = nil
                        }
                    }
                }

                Button {
                    forceScrollToken += 1
                    isAtBottom = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down")
                        Text("Jump to Bottom")
                    }
                    .font(AppFonts.ui(13.5, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .buttonStyle(JumpToBottomButtonStyle())
                .padding(.trailing, 18)
                .padding(.bottom, 18)
                .opacity(isAtBottom ? 0 : 1)
                .offset(y: isAtBottom ? 64 : 0)
                .allowsHitTesting(!isAtBottom)
                .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isAtBottom)
            }
        }
    }
}

struct JumpToBottomButtonStyle: ButtonStyle {
    @Environment(\.appTheme) private var appTheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(appTheme.accentForeground)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(appTheme.brass.opacity(configuration.isPressed ? 0.78 : 0.96)))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .shadow(color: Color.black.opacity(0.28), radius: 14, y: 6)
    }
}

struct LoadEarlierMessagesRow: View {
    @Environment(\.appTheme) private var appTheme
    let count: Int
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(action: action) {
                Text("Load earlier messages (\(count) hidden)")
                    .font(AppFonts.ui(13.5, weight: .semibold))
                    .foregroundStyle(appTheme.brass)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(appTheme.panel2.opacity(0.8)))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.vertical, 10)
    }
}

enum ToolPresentationContent: Identifiable, Hashable {
    case message(ChatMessage)
    case tools(id: String, tools: [ToolDisplay])
    case anchor(String)

    var id: String {
        switch self {
        case .message(let message): return "activity-message-\(message.id)"
        case .tools(let id, _): return id
        case .anchor(let messageID): return "activity-anchor-\(messageID)"
        }
    }
}

struct ToolPresentationGroup: Hashable {
    let id: String
    let tools: [ToolDisplay]
    let content: [ToolPresentationContent]
    let messageIDs: [String]
    let isActive: Bool
}

private enum TranscriptPresentationItem: Identifiable {
    case message(ChatMessage)
    case toolGroup(ToolPresentationGroup)
    case userTools(messageID: String, tools: [ToolDisplay])
    case anchor(String)

    var id: String {
        switch self {
        case .message(let message): return "message-\(message.id)"
        case .toolGroup(let group): return group.id
        case .userTools(let messageID, _): return "user-tools-\(messageID)"
        case .anchor(let messageID): return "anchor-\(messageID)"
        }
    }
}

private struct TranscriptToolPresentation {
    var items: [TranscriptPresentationItem] = []

    private struct AccumulatedGroup {
        var id: String
        var messages: [ChatMessage] = []
        var tools: [ToolDisplay] = []
    }

    init(messages: [ChatMessage], visibleMessages: [ChatMessage], isAgentActive: Bool, showThinkingTraces: Bool) {
        let visibleMessageIDs = Set(visibleMessages.map(\.id))
        var groups: [String: AccumulatedGroup] = [:]
        var order: [String] = []
        var segmentByMessageID: [String: String] = [:]
        var currentSegment = "tools-before-first-user"

        for message in messages {
            if message.role == .user {
                currentSegment = "tools-after-\(message.id)"
            }
            segmentByMessageID[message.id] = currentSegment
            if groups[currentSegment] == nil {
                groups[currentSegment] = AccumulatedGroup(id: currentSegment)
                order.append(currentSegment)
            }
            groups[currentSegment]?.messages.append(message)

            let automaticTools = message.tools.filter { $0.userLabel == nil }
            guard message.role != .user, !automaticTools.isEmpty else { continue }
            for tool in automaticTools {
                if let index = groups[currentSegment]?.tools.firstIndex(where: { $0.id == tool.id }) {
                    let old = groups[currentSegment]!.tools[index]
                    groups[currentSegment]!.tools[index] = Self.mergedTool(old, tool)
                } else {
                    groups[currentSegment]?.tools.append(tool)
                }
            }
        }

        let activeSegment = messages.last.map { segmentByMessageID[$0.id] } ?? nil
        var groupByHostMessageID: [String: ToolPresentationGroup] = [:]
        var groupedMessageIDs = Set<String>()

        for key in order {
            guard let group = groups[key], !group.tools.isEmpty else { continue }
            let isActive = isAgentActive && key == activeSegment
            let lastAssistant = group.messages.last(where: { $0.role == .assistant })
            let successfulFinalID = lastAssistant.flatMap {
                $0.stopReason == "stop" && Self.hasAnswerContent($0) ? $0.id : nil
            }
            let fallbackID = successfulFinalID == nil && !isActive
                ? (group.messages.last(where: {
                    $0.role == .assistant && Self.hasAnswerContent($0)
                }) ?? group.messages.last(where: {
                    $0.role == .assistant && Self.hasVisibleContent($0, showThinkingTraces: showThinkingTraces)
                }))?.id
                : nil
            let visibleOutputID = successfulFinalID ?? fallbackID
            let mergedTools = Dictionary(uniqueKeysWithValues: group.tools.map { ($0.id, $0) })
            var emittedToolIDs = Set<String>()
            var content: [ToolPresentationContent] = []
            var lastToolContentIndex: Int?
            var activityMessageIDs: [String] = []

            for message in group.messages where message.role != .user {
                let automaticTools = message.tools.filter { $0.userLabel == nil }
                let isVisibleOutput = message.role == .assistant && message.id == visibleOutputID
                let isIntermediateAssistant = message.role == .assistant && !isVisibleOutput
                let belongsToActivity = !isVisibleOutput && (isIntermediateAssistant
                    || (!automaticTools.isEmpty && !Self.hasVisibleContent(message, showThinkingTraces: showThinkingTraces)))

                if belongsToActivity, visibleMessageIDs.contains(message.id) {
                    activityMessageIDs.append(message.id)
                    if isIntermediateAssistant && (Self.hasAnswerContent(message)
                        || (showThinkingTraces && !message.thinking.isEmpty)) {
                        content.append(.message(message))
                        lastToolContentIndex = nil
                    } else {
                        content.append(.anchor(message.id))
                    }
                }

                let newTools = automaticTools.compactMap { tool -> ToolDisplay? in
                    guard emittedToolIDs.insert(tool.id).inserted else { return nil }
                    return mergedTools[tool.id]
                }
                if !newTools.isEmpty {
                    // Zero-height anchors must not split consecutive tools into
                    // separate padded blocks (or reintroduce thinking gaps).
                    if let index = lastToolContentIndex, case .tools(let id, let tools) = content[index] {
                        content[index] = .tools(id: id, tools: tools + newTools)
                    } else {
                        lastToolContentIndex = content.count
                        content.append(.tools(id: "activity-tools-\(key)-\(message.id)", tools: newTools))
                    }
                }
            }

            guard let hostID = visibleMessages.first(where: {
                segmentByMessageID[$0.id] == key && $0.role != .user
            })?.id else { continue }
            groupedMessageIDs.formUnion(activityMessageIDs)
            groupByHostMessageID[hostID] = ToolPresentationGroup(
                id: group.id,
                tools: group.tools,
                content: content,
                messageIDs: activityMessageIDs,
                isActive: isActive
            )
        }

        for message in visibleMessages {
            if let group = groupByHostMessageID[message.id] {
                items.append(.toolGroup(group))
            }
            let userTools = message.tools.filter { $0.userLabel != nil }
            if !userTools.isEmpty {
                items.append(.userTools(messageID: message.id, tools: userTools))
            }
            if groupedMessageIDs.contains(message.id) { continue }
            if Self.hasVisibleContent(message, showThinkingTraces: showThinkingTraces) {
                items.append(.message(message))
            } else if userTools.isEmpty {
                items.append(.anchor(message.id))
            }
        }
    }

    private static func hasAnswerContent(_ message: ChatMessage) -> Bool {
        !message.text.isEmpty
            || message.canonicalText?.isEmpty == false
            || !message.references.isEmpty
            || !message.images.isEmpty
    }

    private static func hasVisibleContent(_ message: ChatMessage, showThinkingTraces: Bool) -> Bool {
        message.role == .user
            || hasAnswerContent(message)
            || (showThinkingTraces && !message.thinking.isEmpty)
            || message.isStreaming
    }

    private static func mergedTool(_ old: ToolDisplay, _ new: ToolDisplay) -> ToolDisplay {
        ToolDisplay(
            id: old.id,
            name: new.name.isEmpty ? old.name : new.name,
            arguments: new.arguments.isEmpty ? old.arguments : new.arguments,
            result: new.result.isEmpty ? old.result : new.result,
            details: new.details ?? old.details,
            images: new.images.isEmpty ? old.images : new.images,
            status: new.status,
            isError: old.isError || new.isError,
            userLabel: new.userLabel ?? old.userLabel
        )
    }
}

// Equatable so the hosted transcript can skip re-rendering unchanged rows
// on every streaming frame; only the streaming message's row changes.
struct ChatMessageRow: View, Equatable {
    @Environment(\.appTheme) private var appTheme
    let message: ChatMessage
    let projectPath: String?
    let activityText: String
    let theme: AppThemeChoice
    var textSizeStep: Int = TextSizePreference.step
    let showThinkingTraces: Bool
    let isHighlighted: Bool
    var showsActivityIndicator = true
    @State private var hovering = false
    @State private var copied = false

    static func == (lhs: ChatMessageRow, rhs: ChatMessageRow) -> Bool {
        lhs.message == rhs.message &&
        lhs.projectPath == rhs.projectPath &&
        lhs.activityText == rhs.activityText &&
        lhs.theme == rhs.theme &&
        lhs.textSizeStep == rhs.textSizeStep &&
        lhs.showThinkingTraces == rhs.showThinkingTraces &&
        lhs.isHighlighted == rhs.isHighlighted &&
        lhs.showsActivityIndicator == rhs.showsActivityIndicator
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if message.role == .user {
                detachedReferences
                messageText
                messageImages
            } else {
                if showThinkingTraces, !message.thinking.isEmpty {
                    NativeMarkdownView(markdown: message.thinking, role: .system, theme: theme, isStreaming: message.isStreaming, textSizeStep: textSizeStep)
                }
                detachedReferences
                messageImages
                messageText
                if message.isStreaming && showsActivityIndicator {
                    InlineActivityIndicator(text: activityText)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, message.role == .user ? 18 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .overlay {
            if isHighlighted {
                Rectangle()
                    .fill(appTheme.brass.opacity(0.10))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .leading) {
            if isHighlighted {
                Rectangle()
                    .fill(appTheme.brass)
                    .frame(width: 3)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !message.text.isEmpty || !message.references.isEmpty {
                Button(action: copyMessage) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(AppFonts.ui(11, weight: .semibold))
                        .foregroundStyle(copied ? appTheme.good : appTheme.muted)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(appTheme.panel.opacity(0.94))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(appTheme.line.opacity(0.7), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(8)
                .opacity(hovering || copied ? 1 : 0)
                .allowsHitTesting(hovering || copied)
                .animation(.easeInOut(duration: 0.12), value: hovering)
                .help(copied ? "Copied" : "Copy message")
                .accessibilityLabel("Copy message")
                .accessibilityValue(copied ? "Copied" : "")
            }
        }
        .onHover { hovering = $0 }
        .padding(.top, message.role == .user ? 12 : 0)
    }

    @ViewBuilder
    private var detachedReferences: some View {
        // Older envelopes did not retain reference positions, so only
        // those messages use the detached reference row.
        if message.canonicalText == nil, !message.references.isEmpty {
            MessageReferencesView(references: message.references, projectPath: projectPath)
        }
    }

    @ViewBuilder
    private var messageImages: some View {
        if !message.images.isEmpty {
            MessageImagesView(images: message.images)
        }
    }

    @ViewBuilder
    private var messageText: some View {
        if let canonicalText = message.canonicalText {
            NativeMarkdownView(
                markdown: canonicalText,
                role: message.role,
                theme: theme,
                isStreaming: message.isStreaming,
                projectPath: projectPath,
                textSizeStep: textSizeStep
            )
        } else if !message.text.isEmpty {
            NativeMarkdownView(markdown: message.text, role: message.role, theme: theme, isStreaming: message.isStreaming, textSizeStep: textSizeStep)
        }
    }

    private func copyMessage() {
        NSPasteboard.general.clearContents()
        let copiedText: String
        if let canonicalText = message.canonicalText {
            copiedText = ComposerTokenCodec.plainText(from: canonicalText)
        } else {
            let references = message.references.map(\.plainText).joined(separator: " ")
            copiedText = [references, message.text].filter { !$0.isEmpty }.joined(separator: references.isEmpty ? "" : "\n")
        }
        NSPasteboard.general.setString(copiedText, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            copied = false
        }
    }

    private var rowBackground: Color {
        switch message.role {
        case .user:
            return appTheme.userRow
        case .assistant:
            return Color.clear
        case .system, .custom:
            // User-run commands (!, !!, custom actions) render as tool rows and
            // sit flush like agent tool calls; textual notices keep the panel tint.
            if message.text.isEmpty && !message.tools.isEmpty { return Color.clear }
            return appTheme.panel.opacity(0.35)
        }
    }
}

struct MessageReferencesView: View {
    @Environment(\.appTheme) private var appTheme
    let references: [MessageReference]
    let projectPath: String?

    var body: some View {
        FlowLayout(spacing: 7) {
            ForEach(references) { reference in
                referenceView(reference)
            }
        }
    }

    @ViewBuilder private func referenceView(_ reference: MessageReference) -> some View {
        let available = isAvailable(reference)
        HStack(spacing: 7) {
            if reference.kind == .skill {
                Text("$")
                    .font(AppFonts.ui(13.5, weight: .bold))
                    .foregroundStyle(appTheme.brass)
            } else {
                Image(systemName: "doc.text")
                    .font(AppFonts.ui(12, weight: .semibold))
                    .foregroundStyle(appTheme.brass)
            }
            Text(reference.label)
                .font(AppFonts.ui(13.5, weight: .semibold))
                .lineLimit(1)
            if !available {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(AppFonts.ui(10, weight: .semibold))
            }
        }
        .foregroundStyle(available ? appTheme.text : appTheme.danger)
        .padding(.horizontal, 9)
        .frame(height: max(25, AppFonts.scaled(25)))
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(appTheme.codeBackground.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(available ? appTheme.line : appTheme.danger.opacity(0.7), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { open(reference) }
        .help(referenceHelp(reference, available: available))
        .contextMenu {
            if reference.kind == .file {
                Button("Open") { open(reference) }
                Button("Reveal in Finder") { reveal(reference) }
                Divider()
            } else if reference.resourcePath != nil {
                Button("Open Skill") { open(reference) }
                Divider()
            }
            Button("Copy Reference") { copy(reference.plainText) }
            if let path = resolvedPath(reference) {
                Button("Copy Path") { copy(path) }
            }
        }
    }

    private func resolvedPath(_ reference: MessageReference) -> String? {
        switch reference.kind {
        case .skill:
            return reference.resourcePath.map { ($0 as NSString).expandingTildeInPath }
        case .file:
            if reference.value.hasPrefix("/") { return URL(fileURLWithPath: reference.value).standardizedFileURL.path }
            guard let projectPath else { return nil }
            let root = URL(fileURLWithPath: projectPath, isDirectory: true).standardizedFileURL
            let url = root.appendingPathComponent(reference.value).standardizedFileURL
            guard url.path.hasPrefix(root.path + "/") else { return nil }
            return url.path
        }
    }

    private func isAvailable(_ reference: MessageReference) -> Bool {
        guard let path = resolvedPath(reference) else { return reference.isAvailable }
        return FileManager.default.fileExists(atPath: path)
    }

    private func open(_ reference: MessageReference) {
        guard let path = resolvedPath(reference), FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func reveal(_ reference: MessageReference) {
        guard let path = resolvedPath(reference), FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func referenceHelp(_ reference: MessageReference, available: Bool) -> String {
        if !available { return "Unavailable: \(reference.detail ?? reference.value)" }
        return reference.detail ?? resolvedPath(reference) ?? reference.value
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(proposal: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews)
        for (index, point) in arrangement.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let proposedWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let maxWidth = proposedWidth ?? .greatestFiniteMagnitude
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maximumOccupiedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                maximumOccupiedWidth = max(maximumOccupiedWidth, x - spacing)
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        maximumOccupiedWidth = max(maximumOccupiedWidth, max(0, x - spacing))
        let width = proposedWidth ?? maximumOccupiedWidth
        return (CGSize(width: width, height: y + lineHeight), points)
    }
}
