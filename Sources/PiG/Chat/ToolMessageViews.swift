import SwiftUI
import AppKit
import ImageIO

enum ToolActivityState: Hashable {
    case new
    case working
    case done
    case error
}

struct ToolActivityIndicator: View {
    @Environment(\.appTheme) private var appTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: ToolActivityState

    var body: some View {
        ZStack {
            if state == .working && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 1.2) / 1.2
                    Circle()
                        .stroke(color.opacity(0.72 * (1 - phase)), lineWidth: 1.2)
                        .scaleEffect(0.72 + phase * 0.95)
                }
            }

            switch state {
            case .new:
                Circle()
                    .stroke(color, lineWidth: 1.3)
                    .frame(width: 8, height: 8)
            case .working:
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
            case .done:
                EmptyView()
            case .error:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(AppFonts.ui(12, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }

    private var color: Color {
        switch state {
        case .new: return appTheme.muted
        case .working: return appTheme.toolRunning
        case .done: return appTheme.good
        case .error: return appTheme.danger
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .new: return "New"
        case .working: return "Working"
        case .done: return "Done"
        case .error: return "Failed"
        }
    }
}

struct ToolActivityView: View {
    @Environment(\.appTheme) private var appTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let group: ToolPresentationGroup
    let projectPath: String?
    let activityText: String
    let theme: AppThemeChoice
    let textSizeStep: Int
    let showThinkingTraces: Bool
    let highlightedMessageID: String?
    @State private var expanded = false
    @State private var observedActiveTurn = false
    @State private var hoveringSummary = false

    private var failedCount: Int {
        group.tools.filter { $0.status == .failed || $0.isError }.count
    }

    private var unfinishedCount: Int {
        group.tools.filter { $0.status == .pending || $0.status == .running }.count
    }

    private var summaryIsHighlighted: Bool {
        highlightedMessageID.map(group.messageIDs.contains) ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if group.isActive || expanded {
                if !group.isActive {
                    disclosureButton
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                }
                orderedContent
                    .padding(.leading, group.isActive ? 0 : 12)
                    .overlay(alignment: .leading) {
                        if !group.isActive {
                            Rectangle()
                                .fill(appTheme.muted.opacity(0.25))
                                .frame(width: 1)
                                .padding(.leading, 18)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .transition(.opacity)
            } else {
                disclosureButton
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
            }
        }
        .onAppear { observedActiveTurn = group.isActive }
        .onChange(of: group.isActive) { wasActive, isActive in
            if wasActive && !isActive && observedActiveTurn {
                withAnimation(.easeInOut(duration: 0.12)) { expanded = false }
            }
            observedActiveTurn = observedActiveTurn || isActive
        }
    }

    private var orderedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(group.content) { content in
                switch content {
                case .message(let message):
                    ChatMessageRow(
                        message: message,
                        projectPath: projectPath,
                        activityText: activityText,
                        theme: theme,
                        textSizeStep: textSizeStep,
                        showThinkingTraces: showThinkingTraces,
                        isHighlighted: highlightedMessageID == message.id,
                        showsActivityIndicator: false
                    )
                    .equatable()
                    .background {
                        ChatMessageScrollAnchor(messageID: message.id)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .tools(_, let tools):
                    ToolGroupView(tools: tools, projectPath: projectPath)
                        .padding(.leading, 36)
                        .padding(.trailing, 18)
                        .padding(.vertical, 6)
                case .anchor(let messageID):
                    ChatMessageScrollAnchor(messageID: messageID)
                        .frame(height: 0)
                }
            }
            if group.isActive {
                InlineActivityIndicator(text: activityText)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
            }
        }
    }

    private var disclosureButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { expanded.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(AppFonts.ui(12, weight: .medium))
                    .foregroundStyle(hoveringSummary ? appTheme.secondaryText : appTheme.muted)
                    .frame(width: 18, height: 18)

                Text("Tool activity")
                    .font(AppFonts.ui(13, weight: .medium))
                    .foregroundStyle(appTheme.secondaryText)
                    .lineLimit(1)

                Text("\(group.tools.count)")
                    .font(AppFonts.code(11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(appTheme.muted)

                Rectangle()
                    .fill(summaryIsHighlighted ? appTheme.brass : appTheme.muted.opacity(hoveringSummary ? 0.4 : 0.25))
                    .frame(minWidth: 4, maxWidth: .infinity)
                    .frame(height: 1)
                    .padding(.horizontal, 7)
                    .accessibilityHidden(true)

                if failedCount > 0 || unfinishedCount > 0 {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            if failedCount > 0 {
                                Label("\(failedCount) failed", systemImage: "exclamationmark.circle.fill")
                                    .foregroundStyle(appTheme.danger)
                            }
                            if unfinishedCount > 0 {
                                Label("\(unfinishedCount) unfinished", systemImage: "circle.dashed")
                                    .foregroundStyle(appTheme.toolRunning)
                            }
                        }
                        Image(systemName: failedCount > 0 ? "exclamationmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(summaryColor)
                    }
                    .font(AppFonts.ui(11.5, weight: .medium))
                }

                Image(systemName: "chevron.down")
                    .font(AppFonts.ui(10, weight: .medium))
                    .foregroundStyle(hoveringSummary ? appTheme.secondaryText : appTheme.muted)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .frame(width: 16)
            }
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveringSummary = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: hoveringSummary)
        .help("\(summary) — \(expanded ? "Hide tools" : "Show tools")")
        .accessibilityLabel(summary)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .background {
            if !expanded && !group.isActive {
                ZStack {
                    ForEach(group.messageIDs, id: \.self) { messageID in
                        ChatMessageScrollAnchor(messageID: messageID)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
    }

    private var summary: String {
        let count = group.tools.count
        var parts = ["\(count) tool\(count == 1 ? "" : "s")"]
        if failedCount > 0 { parts.append("\(failedCount) failed") }
        if unfinishedCount > 0 { parts.append("\(unfinishedCount) unfinished") }
        return parts.joined(separator: " · ")
    }

    private var summaryColor: Color {
        failedCount > 0 ? appTheme.danger : appTheme.toolRunning
    }
}

struct ToolGroupView: View {
    let tools: [ToolDisplay]
    let projectPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(tools) { tool in
                ToolRow(tool: tool, projectPath: projectPath)
                    .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum ToolExpansion: String, Sendable {
    case collapsed, partial, full

    var next: Self {
        switch self {
        case .partial: return .full
        case .full: return .collapsed
        case .collapsed: return .partial
        }
    }

    var actionLabel: String {
        switch self {
        case .partial: return "Show all output"
        case .full: return "Hide tool details"
        case .collapsed: return "Show last 10 lines"
        }
    }
}

private struct PreparedToolRow: @unchecked Sendable {
    var title: String
    var imagePath: String?
    var writePreview: CodePreviewSummary?
    var editDiff: EditDiffSummary?
    var bashPreview: CodePreviewSummary?

    init(tool: ToolDisplay, projectPath: String?, expansion: ToolExpansion) {
        title = tool.displayTitle
        guard expansion != .collapsed else {
            imagePath = nil
            writePreview = nil
            editDiff = nil
            bashPreview = nil
            return
        }
        imagePath = tool.readImagePath(projectPath: projectPath)
        writePreview = tool.writePreview()
        editDiff = tool.editDiff(projectPath: projectPath)
        bashPreview = tool.bashOutputPreview(maxLines: expansion == .partial ? 10 : nil)
    }
}

struct ToolRow: View {
    @Environment(\.appTheme) private var appTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tool: ToolDisplay
    let projectPath: String?
    @State private var expansion: ToolExpansion = .collapsed
    @State private var prepared: PreparedToolRow?

    private var expanded: Bool { expansion != .collapsed }
    @State private var showingCommand = false
    @State private var hovering = false

    init(tool: ToolDisplay, projectPath: String?) {
        self.tool = tool
        self.projectPath = projectPath
        _expansion = State(initialValue: tool.userLabel != nil ? .partial : (Self.isSubagent(tool) && tool.status == .running ? .full : .collapsed))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Button {
                    guard tool.hasExpandableDetails else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) {
                        expansion = tool.userLabel != nil ? expansion.next : (expanded ? .collapsed : .full)
                    }
                } label: {
                    HStack(spacing: 7) {
                        if let label = customActionLabel {
                            Text(label)
                                .font(AppFonts.code(12, weight: .bold))
                                .foregroundStyle(appTheme.secondaryText)
                                .lineLimit(1)
                        }
                        toolTitle
                    }
                    .frame(minHeight: 22, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tool.hasExpandableDetails ? (tool.userLabel != nil ? expansion.actionLabel : (expanded ? "Hide tool details" : "Show tool details")) : (prepared?.title ?? tool.shortName.capitalized))
                .accessibilityValue(expansion == .partial ? "Last 10 lines" : (expanded ? "Expanded" : "Collapsed"))
                .frame(minWidth: 0)

                if let command = tool.bashCommand {
                    bashCommandButton(command)
                        .opacity(hovering || showingCommand ? 1 : 0)
                        .allowsHitTesting(hovering || showingCommand)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: hovering)
                }

                Spacer(minLength: 0)
            }
            .onHover { hovering = $0 }

            if expanded {
                if let imagePath = prepared?.imagePath {
                    ImagePreviewView(path: imagePath)
                        .padding(.leading, 12)
                }

                if !tool.images.isEmpty {
                    MessageImagesView(images: tool.images)
                        .padding(.leading, 12)
                }

                if let preview = prepared?.writePreview {
                    CodePreviewView(preview: preview)
                        .padding(.leading, 12)
                }

                if let diff = prepared?.editDiff {
                    EditDiffView(diff: diff)
                        .padding(.leading, 12)
                }

                if let preview = prepared?.bashPreview {
                    CodePreviewView(preview: preview)
                        .padding(.leading, 12)
                }

                if showsRawDetails {
                    ToolDetailsView(tool: tool)
                        .padding(.leading, 12)
                        .transition(.opacity)
                }
            }
        }
        .task(id: preparationTaskID) {
            let tool = tool
            let projectPath = projectPath
            let expansion = expansion
            let value = await Task.detached(priority: .utility) {
                PreparedToolRow(tool: tool, projectPath: projectPath, expansion: expansion)
            }.value
            guard !Task.isCancelled else { return }
            prepared = value
        }
        .onChange(of: tool.status) { _, status in
            if status == .running, Self.isSubagent(tool) {
                expansion = .full
            }
        }
    }

    private static func isSubagent(_ tool: ToolDisplay) -> Bool {
        tool.shortName == "subagent" || tool.shortName == "delegate_agent"
    }

    private var customActionLabel: String? {
        guard let label = tool.userLabel?.nonEmptyTrimmed else { return nil }
        if label == "you" || label == "you · hidden" { return nil }
        return label.hasPrefix("you · ") ? String(label.dropFirst(6)) : label
    }

    private var showsRawDetails: Bool {
        guard tool.shortName != "bash" else { return false }
        if tool.shortName == "write" || tool.shortName == "edit" {
            return tool.status == .failed || tool.isError
        }
        return tool.hasExpandableDetails
    }

    private var preparationTaskID: String {
        "\(tool.id)|\(tool.status.rawValue)|\(tool.arguments.count)|\(tool.result.count)|\(tool.details?.count ?? 0)|\(expansion.rawValue)|\(projectPath ?? "")"
    }

    @ViewBuilder
    private var toolTitle: some View {
        if tool.status == .running && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.6) / 1.6
                let opacity = 0.72 + 0.28 * (0.5 + 0.5 * sin(phase * 2 * .pi))
                titleText.opacity(opacity)
            }
        } else {
            titleText
        }
    }

    private var titleText: some View {
        Text(tool.displayTitle)
            .font(AppFonts.code(12, weight: .regular))
            .foregroundStyle(titleColor)
            .lineLimit(1)
    }

    private var titleColor: Color {
        switch tool.status {
        case .failed: return appTheme.danger
        case .running: return appTheme.toolRunning
        case .pending: return appTheme.muted
        case .succeeded: return appTheme.secondaryText
        }
    }

    private func bashCommandButton(_ command: String) -> some View {
        Button {
            showingCommand.toggle()
        } label: {
            Image(systemName: "terminal")
                .font(AppFonts.ui(11, weight: .semibold))
                .foregroundStyle(showingCommand ? appTheme.brass : appTheme.muted)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show command")
        .accessibilityLabel("Show command")
        .popover(isPresented: $showingCommand, arrowEdge: .bottom) {
            BashCommandPopover(command: command)
        }
    }
}

struct BashCommandPopover: View {
    @Environment(\.appTheme) private var appTheme
    let command: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer(minLength: 0)
                Button(action: copyCommand) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(InlineIconButtonStyle())
                .help(copied ? "Copied" : "Copy command")
                .accessibilityLabel("Copy command")
            }
            ScrollView {
                Text(command)
                    .font(AppFonts.code(12.5))
                    .foregroundStyle(appTheme.codeText.opacity(0.92))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
        }
        .padding(12)
        .frame(width: 420)
    }

    private func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            copied = false
        }
    }
}

struct ToolDetailsView: View {
    @Environment(\.appTheme) private var appTheme
    let tool: ToolDisplay

    var body: some View {
        switch tool.shortName {
        case "bash": BashToolDetailsView(tool: tool)
        case "subagent", "delegate_agent": SubagentToolDetailsView(tool: tool)
        default: FallbackToolDetailsView(tool: tool)
        }
    }
}

struct BashToolDetailsView: View {
    @Environment(\.appTheme) private var appTheme
    let tool: ToolDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DetailLine(label: "Command", value: stringArg("command") ?? tool.displayTitle)
            if let timeout = numberArg("timeout") { DetailLine(label: "Timeout", value: "\(timeout)s") }
            if let exit = exitStatus { DetailLine(label: "Exit status", value: exit) }
        }
        .padding(10)
        .background(appTheme.panel2.opacity(0.36))
    }

    private var exitStatus: String? {
        guard let obj = tool.resultObject else { return nil }
        if let value = obj["exitCode"] ?? obj["exit_status"] ?? obj["status"] { return String(describing: value) }
        return nil
    }

    private func stringArg(_ key: String) -> String? { tool.argumentsObject?[key] as? String }
    private func numberArg(_ key: String) -> String? {
        guard let value = tool.argumentsObject?[key] else { return nil }
        return String(describing: value)
    }
}

struct FallbackToolDetailsView: View {
    @Environment(\.appTheme) private var appTheme
    let tool: ToolDisplay
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !tool.arguments.isEmpty { DetailSection(title: "Inputs", maxHeight: nil) { tool.readableCall } }
            if !tool.result.isEmpty { DetailSection(title: "Output", maxHeight: 520) { tool.result } }
            if let details = tool.details, !details.isEmpty { DetailSection(title: "Details", maxHeight: 520) { details } }
        }
    }
}

struct DetailSection: View {
    @Environment(\.appTheme) private var appTheme
    let title: String
    let maxHeight: CGFloat?
    let text: () -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(AppFonts.ui(11.5, weight: .semibold)).foregroundStyle(appTheme.muted)
                Spacer()
                Button { copy(text()) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(InlineIconButtonStyle())
            }
            if let maxHeight {
                ScrollView(.vertical) { codeText }
                    .frame(height: min(AppFonts.scaled(maxHeight), estimatedHeight(text())))
                    .background(codeBlockBackground)
            } else {
                codeText.background(codeBlockBackground)
            }
        }
    }

    private var codeText: some View {
        Text(text())
            .font(AppFonts.code(12.5))
            .foregroundStyle(appTheme.codeText.opacity(0.92))
            .lineLimit(nil)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(9)
    }

    private var codeBlockBackground: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(appTheme.codeBackground.opacity(0.24))
    }

    private func estimatedHeight(_ text: String) -> CGFloat {
        let visualLines = text.components(separatedBy: "\n").reduce(0) { total, line in
            total + max(1, Int(ceil(Double(max(line.count, 1)) / 68.0)))
        }
        return max(42, AppFonts.scaled(CGFloat(visualLines) * 18.5 + 18))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct DetailLine: View {
    @Environment(\.appTheme) private var appTheme
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(AppFonts.ui(11.5, weight: .semibold)).foregroundStyle(appTheme.muted).frame(width: 76, alignment: .trailing)
            Text(value).font(AppFonts.code(12.5)).foregroundStyle(appTheme.secondaryText).textSelection(.enabled)
        }
    }
}
