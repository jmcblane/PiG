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
    @ObservedObject private var occlusion = AppOcclusion.shared
    let state: ToolActivityState

    var body: some View {
        ZStack {
            if state == .working && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !occlusion.isVisible)) { context in
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
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
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
    let textStyle: TextStyle
    let showThinkingTraces: Bool
    let highlightedMessageID: String?
    var htmlArtifacts: [String: HTMLArtifact] = [:]
    var htmlActionTarget: SessionController? = nil
    @State private var expanded = false
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
            disclosureButton
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            if expanded {
                orderedContent
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(appTheme.muted.opacity(0.25))
                            .frame(width: 1)
                            .padding(.leading, 18)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .transition(.opacity)
            } else {
                // Running background jobs stay in view as one line each while the turn is folded.
                let runningJobs = group.tools.filter { $0.backgroundJob != nil && $0.status == .running }
                if !runningJobs.isEmpty {
                    ToolGroupView(tools: runningJobs, projectPath: projectPath)
                        .padding(.leading, 12)
                        .padding(.bottom, 6)
                        .overlay(alignment: .leading) {
                            VerticalLine()
                                .stroke(appTheme.toolRunning.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .frame(width: 1)
                                .padding(.leading, 18)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                }
            }
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
                        textStyle: textStyle,
                        showThinkingTraces: showThinkingTraces,
                        isHighlighted: highlightedMessageID == message.id,
                        showsActivityIndicator: false,
                        htmlArtifacts: HTMLArtifact.selected(from: htmlArtifacts, in: message.text),
                        htmlActionTarget: htmlActionTarget
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

                HStack(spacing: 5) {
                    Text(activitySentence)
                        .font(AppFonts.ui(13, weight: .medium))
                        .foregroundStyle(appTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if failedCount > 0 {
                        Text("· \(failedCount) failed")
                            .font(AppFonts.ui(13, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(appTheme.danger)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .layoutPriority(1)

                Rectangle()
                    .fill(summaryIsHighlighted ? appTheme.brass : appTheme.muted.opacity(hoveringSummary ? 0.4 : 0.25))
                    .frame(minWidth: 4, maxWidth: .infinity)
                    .frame(height: 1)
                    .padding(.horizontal, 7)
                    .accessibilityHidden(true)

                if unfinishedCount > 0 {
                    ViewThatFits(in: .horizontal) {
                        Label("\(unfinishedCount) unfinished", systemImage: "circle.dashed")
                        Image(systemName: "circle.dashed")
                    }
                    .font(AppFonts.ui(11.5, weight: .medium))
                    .foregroundStyle(appTheme.toolRunning)
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
            if !expanded {
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
        var parts = [activitySentence]
        if failedCount > 0 { parts.append("\(failedCount) failed") }
        if unfinishedCount > 0 { parts.append("\(unfinishedCount) unfinished") }
        return parts.joined(separator: ", ")
    }

    private var activitySentence: String {
        var order: [ToolActivityKind] = []
        var counts: [ToolActivityKind: Int] = [:]
        for tool in group.tools {
            let kind = ToolActivityKind(tool.shortName)
            if counts[kind] == nil { order.append(kind) }
            counts[kind, default: 0] += 1
        }
        let phrases = order.map { $0.phrase(count: counts[$0, default: 0], isOnlyKind: order.count == 1) }
        guard let first = phrases.first else { return "No tools" }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + phrases.dropFirst()).joined(separator: ", ")
    }
}

private enum ToolActivityKind: Hashable {
    case read, write, edit, command, search, subagent, script, background, other

    init(_ shortName: String) {
        switch shortName {
        case "read": self = .read
        case "write": self = .write
        case "edit": self = .edit
        case "bash": self = .command
        case "grep", "find", "ls", "search", "web_search", "websearch": self = .search
        case "subagent", "delegate_agent": self = .subagent
        case "codemode": self = .script
        case "background": self = .background
        default: self = .other
        }
    }

    func phrase(count: Int, isOnlyKind: Bool) -> String {
        func counted(_ noun: String, _ plural: String? = nil) -> String {
            "\(count) \(count == 1 ? noun : plural ?? noun + "s")"
        }
        switch self {
        case .read: return "read \(counted("file"))"
        case .write: return "wrote \(counted("file"))"
        case .edit: return "edited \(counted("file"))"
        case .command: return "ran \(counted("command"))"
        case .search: return count == 1 ? "searched" : "searched \(count) times"
        case .subagent: return count == 1 ? "delegated to subagents" : "delegated to subagents \(count) times"
        case .script: return "ran \(counted("script"))"
        case .background: return "started \(counted("background job"))"
        case .other: return "used \(count) \(isOnlyKind ? "" : "other ")tool\(count == 1 ? "" : "s")"
        }
    }
}

private struct VerticalLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

/// A finished `background` job, shown where a prompt would start the turn it woke.
struct BackgroundJobResultView: View {
    @Environment(\.appTheme) private var appTheme
    let message: ChatMessage
    let projectPath: String?
    let isHighlighted: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expandedJobs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(message.tools) { tool in
                divider(for: tool)
                if expandedJobs.contains(tool.id) {
                    ToolRow(tool: tool, projectPath: projectPath, startsExpanded: true)
                        .padding(.leading, 36)
                        .padding(.trailing, 18)
                        .transition(.opacity)
                }
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Arriving from the launching row's "Show result" means the output is wanted.
        .onChange(of: isHighlighted) { _, highlighted in
            if highlighted { expandedJobs.formUnion(message.tools.map(\.id)) }
        }
    }

    /// A centered pill on a hairline: an event that starts a turn, not a message.
    private func divider(for tool: ToolDisplay) -> some View {
        let failed = tool.status == .failed || tool.isError
        let expanded = expandedJobs.contains(tool.id)
        let jobID = tool.backgroundJob?.id ?? 0
        return HStack(spacing: 10) {
            hairline
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) {
                    if expanded { expandedJobs.remove(tool.id) } else { expandedJobs.insert(tool.id) }
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(failed ? appTheme.danger : appTheme.good)
                        .frame(width: 7, height: 7)
                    Text(jobID > 0 ? "Job \(jobID) \(failed ? "failed" : "finished")" : (failed ? "Job failed" : "Job finished"))
                        .font(AppFonts.ui(12, weight: .medium))
                        .foregroundStyle(appTheme.secondaryText)
                    Text(tool.displayTitle)
                        .font(AppFonts.code(12))
                        .foregroundStyle(appTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let duration = tool.backgroundJob?.duration {
                        Text(TurnTiming.format(duration))
                            .font(AppFonts.code(11.5))
                            .monospacedDigit()
                            .foregroundStyle(appTheme.muted)
                    }
                    Image(systemName: "chevron.right")
                        .font(AppFonts.ui(9, weight: .bold))
                        .foregroundStyle(appTheme.muted)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background(Capsule().fill(isHighlighted ? appTheme.brass.opacity(0.16) : appTheme.panel))
                .overlay(Capsule().stroke(isHighlighted ? appTheme.brass : appTheme.line, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .help(expanded ? "Hide output" : "Show output")
            .accessibilityLabel("Background job \(jobID) \(failed ? "failed" : "finished"), \(tool.displayTitle)")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            hairline
        }
        .padding(.horizontal, 18)
        .animation(.easeOut(duration: 0.22), value: isHighlighted)
    }

    private var hairline: some View {
        Rectangle()
            .fill(appTheme.line)
            .frame(minWidth: 16, maxWidth: .infinity)
            .frame(height: 1)
    }
}

/// Elapsed time of a running background job, or the run time of a finished one.
private struct BackgroundJobTime: View {
    @Environment(\.appTheme) private var appTheme
    let job: BackgroundJobInfo
    let isRunning: Bool

    var body: some View {
        if isRunning, let start = job.startedAt {
            TimelineView(.periodic(from: start, by: 1)) { context in
                label(context.date.timeIntervalSince(start))
            }
        } else if let duration = job.duration {
            label(duration)
        }
    }

    private func label(_ seconds: TimeInterval) -> some View {
        Text(TurnTiming.format(seconds))
            .font(AppFonts.code(11.5))
            .monospacedDigit()
            .foregroundStyle(appTheme.muted)
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

private struct PreparedToolRow: @unchecked Sendable {
    var summary: ToolRowSummary?
    var imagePath: String?
    var writePreview: CodePreviewSummary?
    var editDiff: EditDiffSummary?
    var bashPreview: CodePreviewSummary?
    var bashLineCount = 0

    init(tool: ToolDisplay, projectPath: String?, expanded: Bool, showsAllOutput: Bool) {
        summary = tool.rowSummary
        guard expanded else { return }
        imagePath = tool.readImagePath(projectPath: projectPath)
        writePreview = tool.writePreview()
        editDiff = tool.editDiff(projectPath: projectPath)
        bashPreview = tool.bashOutputPreview(maxLines: showsAllOutput ? nil : ToolRow.bashTailLines)
        bashLineCount = bashPreview.map { $0.lines.count + $0.hiddenLineCount } ?? 0
    }
}

struct ToolRow: View {
    static let bashTailLines = 10
    @Environment(\.appTheme) private var appTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var occlusion = AppOcclusion.shared
    @Environment(\.revealMessage) private var revealMessage
    let tool: ToolDisplay
    let projectPath: String?
    @State private var expanded: Bool
    @State private var userToggled = false
    @State private var showsAllOutput = false
    @State private var prepared: PreparedToolRow?

    init(tool: ToolDisplay, projectPath: String?, startsExpanded: Bool = false) {
        self.tool = tool
        self.projectPath = projectPath
        _expanded = State(initialValue: startsExpanded || (tool.backgroundJob == nil
            && (tool.userLabel != nil || (Self.isSubagent(tool) && tool.status == .running))))
    }

    var body: some View {
        let title = bashActionLabel.map { ToolRowTitle(verb: $0, subject: "") } ?? tool.rowTitle(projectPath: projectPath)
        let isExpandable = tool.hasExpandableDetails
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 4) {
                if isExpandable {
                    Button {
                        userToggled = true
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) { expanded.toggle() }
                    } label: {
                        header(title, isExpandable: true)
                    }
                    .buttonStyle(.plain)
                    .help(helpText(title))
                    .accessibilityLabel(accessibilityTitle(title))
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                    .accessibilityHint(expanded ? "Hides tool details" : "Shows tool details")
                } else {
                    header(title, isExpandable: false)
                        .help(helpText(title))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(accessibilityTitle(title))
                }

                if let job = tool.backgroundJob {
                    BackgroundJobTime(job: job, isRunning: tool.status == .running)
                        .frame(minHeight: 22)
                    if let target = job.resultMessageID {
                        Button { revealMessage?(target) } label: {
                            Image(systemName: "arrow.down")
                                .font(AppFonts.ui(11, weight: .semibold))
                                .foregroundStyle(appTheme.brass)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show result")
                        .accessibilityLabel("Show result")
                    }
                }
            }

            if expanded && isExpandable {
                details
                    .padding(.leading, 23)
                    .transition(.opacity)
            }
        }
        .task(id: preparationTaskID) {
            let tool = tool
            let projectPath = projectPath
            let expanded = expanded
            let showsAllOutput = showsAllOutput
            let value = await Task.detached(priority: .utility) {
                PreparedToolRow(tool: tool, projectPath: projectPath, expanded: expanded, showsAllOutput: showsAllOutput)
            }.value
            guard !Task.isCancelled else { return }
            prepared = value
        }
        .onChange(of: tool.status) { _, status in
            if status == .running, Self.isSubagent(tool), tool.backgroundJob == nil, !userToggled {
                expanded = true
            }
        }
    }

    private func header(_ title: ToolRowTitle, isExpandable: Bool) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: tool.rowSymbolName)
                .font(AppFonts.ui(11, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 16, height: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    if let job = tool.backgroundJob, job.id > 0 {
                        Text("job \(job.id)")
                            .font(AppFonts.code(12, weight: .bold))
                            .foregroundStyle(appTheme.secondaryText)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    if bashActionLabel == nil, let label = customActionLabel {
                        Text(label)
                            .font(AppFonts.code(12, weight: .bold))
                            .foregroundStyle(appTheme.secondaryText)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    pulsingTitle(title)
                    Spacer(minLength: 8)
                    summaryView
                    if isExpandable {
                        Image(systemName: "chevron.right")
                            .font(AppFonts.ui(9, weight: .bold))
                            .foregroundStyle(appTheme.muted)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 12)
                            .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: 22)

                if let errorLine = tool.errorLine {
                    Text(errorLine)
                        .font(AppFonts.ui(11.5))
                        .foregroundStyle(appTheme.danger)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.bottom, 3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func pulsingTitle(_ title: ToolRowTitle) -> some View {
        if tool.status == .running && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !occlusion.isVisible)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.6) / 1.6
                let opacity = 0.72 + 0.28 * (0.5 + 0.5 * sin(phase * 2 * .pi))
                titleText(title).opacity(opacity)
            }
        } else {
            titleText(title)
        }
    }

    private func titleText(_ title: ToolRowTitle) -> some View {
        HStack(spacing: 6) {
            Text(title.verb)
                .font(AppFonts.ui(12.5, weight: .medium))
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .layoutPriority(1)
            if !title.subject.isEmpty {
                Text(title.subject)
                    .font(AppFonts.code(12))
                    .foregroundStyle(tool.status == .running ? appTheme.toolRunning.opacity(0.8) : appTheme.muted)
                    .lineLimit(1)
                    .truncationMode(subjectIsPath ? .middle : .tail)
            }
        }
    }

    @ViewBuilder
    private var summaryView: some View {
        Group {
            switch prepared?.summary {
            case .text(let text)?:
                Text(text)
            case .lineDelta(let added, let removed)?:
                Text("+\(added)").foregroundStyle(appTheme.good) + Text(" -\(removed)").foregroundStyle(appTheme.danger)
            case nil:
                EmptyView()
            }
        }
        .font(AppFonts.ui(11.5))
        .monospacedDigit()
        .foregroundStyle(appTheme.muted)
        .lineLimit(1)
        .fixedSize()
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let imagePath = prepared?.imagePath {
                ImagePreviewView(path: imagePath)
            }

            if !tool.images.isEmpty {
                MessageImagesView(images: tool.images)
            }

            if let preview = prepared?.writePreview {
                CodePreviewView(preview: preview)
            }

            if let diff = prepared?.editDiff {
                EditDiffView(diff: diff)
            }

            if tool.shortName == "bash", tool.bashCommand != nil || prepared?.bashPreview != nil {
                BashOutputView(
                    command: tool.bashCommand,
                    preview: prepared?.bashPreview,
                    lineCount: prepared?.bashLineCount ?? 0,
                    showsAll: $showsAllOutput
                )
            }

            if showsRawDetails {
                ToolDetailsView(tool: tool, projectPath: projectPath)
            }
        }
    }

    private static func isSubagent(_ tool: ToolDisplay) -> Bool {
        tool.shortName == "subagent" || tool.shortName == "delegate_agent"
    }

    private var subjectIsPath: Bool {
        ["read", "write", "edit", "ls"].contains(tool.shortName)
    }

    private var customActionLabel: String? {
        guard let label = tool.userLabel?.nonEmptyTrimmed else { return nil }
        if label == "you" || label == "you · hidden" { return nil }
        return label.hasPrefix("you · ") ? String(label.dropFirst(6)) : label
    }

    private var bashActionLabel: String? {
        tool.bashCommand == nil ? nil : customActionLabel
    }

    private var showsRawDetails: Bool {
        guard tool.shortName != "bash" else { return false }
        if tool.shortName == "write" || tool.shortName == "edit" {
            return tool.status == .failed || tool.isError
        }
        return tool.hasExpandableDetails
    }

    private var preparationTaskID: String {
        "\(tool.id)|\(tool.status.rawValue)|\(tool.arguments.count)|\(tool.result.count)|\(tool.details?.count ?? 0)|\(expanded)|\(showsAllOutput)|\(projectPath ?? "")"
    }

    private func helpText(_ title: ToolRowTitle) -> String {
        title.subject.isEmpty ? title.verb : "\(title.verb) \(title.subject)"
    }

    private func accessibilityTitle(_ title: ToolRowTitle) -> String {
        var parts = [helpText(title)]
        switch tool.status {
        case .failed: parts.append("failed")
        case .running: parts.append("running")
        case .pending: parts.append("pending")
        case .succeeded: break
        }
        if case .text(let text)? = prepared?.summary { parts.append(text) }
        if case .lineDelta(let added, let removed)? = prepared?.summary {
            parts.append("\(added) lines added, \(removed) removed")
        }
        if let errorLine = tool.errorLine { parts.append(errorLine) }
        return parts.joined(separator: ", ")
    }

    private var iconColor: Color {
        switch tool.status {
        case .failed: return appTheme.danger
        case .running: return appTheme.toolRunning
        case .pending, .succeeded: return appTheme.muted
        }
    }

    private var titleColor: Color {
        switch tool.status {
        case .failed: return appTheme.danger
        case .running: return appTheme.toolRunning
        case .pending: return appTheme.muted
        case .succeeded: return appTheme.secondaryText
        }
    }
}

private struct BashOutputView: View {
    @Environment(\.appTheme) private var appTheme
    let command: String?
    let preview: CodePreviewSummary?
    let lineCount: Int
    @Binding var showsAll: Bool
    @State private var showsFullCommand = false

    private static let commandLineLimit = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let command {
                HStack(alignment: .top, spacing: 6) {
                    (Text("$ ").foregroundStyle(appTheme.muted) + Text(command).foregroundStyle(appTheme.codeText.opacity(0.92)))
                        .font(AppFonts.code(12.5))
                        .lineLimit(showsFullCommand ? nil : Self.commandLineLimit)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    CopyButton(label: "Copy command") { command }
                }
                if command.split(separator: "\n", omittingEmptySubsequences: false).count > Self.commandLineLimit {
                    ToolLinkButton(title: showsFullCommand ? "Show less of command" : "Show full command") {
                        showsFullCommand.toggle()
                    }
                }
            }

            if let preview, hasOutput(preview) {
                if command != nil {
                    Rectangle()
                        .fill(appTheme.line.opacity(0.5))
                        .frame(height: 1)
                        .accessibilityHidden(true)
                }
                if lineCount > ToolRow.bashTailLines {
                    ToolLinkButton(title: showsAll ? "Show last \(ToolRow.bashTailLines) lines" : "Show all \(lineCount) lines") {
                        showsAll.toggle()
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(preview.lines) { line in
                        CodePreviewLineView(line: line)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .toolBodyStyle()
    }

    private func hasOutput(_ preview: CodePreviewSummary) -> Bool {
        !(preview.lines.count == 1 && preview.lines[0].text.isEmpty)
    }
}

struct ToolDetailsView: View {
    let tool: ToolDisplay
    let projectPath: String?

    var body: some View {
        switch tool.shortName {
        case "subagent", "delegate_agent": SubagentToolDetailsView(tool: tool, projectPath: projectPath)
        case "codemode": CodemodeToolDetailsView(tool: tool)
        default: FallbackToolDetailsView(tool: tool)
        }
    }
}

/// The calls a codemode script made, one aligned line each, then its output.
struct CodemodeToolDetailsView: View {
    @Environment(\.appTheme) private var appTheme
    let tool: ToolDisplay

    var body: some View {
        let calls = tool.codemodeCalls
        let output = tool.codemodeOutput
        VStack(alignment: .leading, spacing: 8) {
            if !calls.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    ForEach(calls) { call in
                        GridRow {
                            Text(call.name)
                                .foregroundStyle(call.failed ? appTheme.danger : appTheme.secondaryText)
                            Text(call.subject)
                                .foregroundStyle(call.failed ? appTheme.danger : appTheme.muted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(call.durationMs.map(Self.duration) ?? "")
                                .foregroundStyle(appTheme.muted)
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
                .font(AppFonts.code(12))
                .textSelection(.enabled)
                .toolBodyStyle()
            }
            if !output.isEmpty {
                DetailSection(title: "Output", maxHeight: 520) { output }
            }
        }
    }

    private static func duration(_ ms: Double) -> String {
        ms < 1000 ? "\(Int(ms.rounded()))ms" : String(format: "%.1fs", ms / 1000)
    }
}

struct FallbackToolDetailsView: View {
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
        let value = text()
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(AppFonts.ui(11.5, weight: .semibold)).foregroundStyle(appTheme.muted)
                Spacer()
                CopyButton(label: "Copy \(title.lowercased())") { value }
            }
            Group {
                if let maxHeight {
                    CappedHeight(maxHeight: AppFonts.scaled(maxHeight)) {
                        ScrollView(.vertical) { codeText(value) }
                    }
                } else {
                    codeText(value)
                }
            }
            .toolBodyStyle(padding: 0)
        }
    }

    private func codeText(_ value: String) -> some View {
        Text(value)
            .font(AppFonts.code(12.5))
            .foregroundStyle(appTheme.codeText.opacity(0.92))
            .lineLimit(nil)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(9)
    }
}
