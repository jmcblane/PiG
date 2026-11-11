import SwiftUI
import AppKit

private enum SubagentRunStatus: Hashable {
    case queued
    case running
    case succeeded
    case failed

    var isFinished: Bool { self == .succeeded || self == .failed }
}

private enum SubagentOutputKind: Hashable {
    case text
    case tool
}

private struct SubagentOutputItem: Identifiable, Hashable {
    let id: Int
    let kind: SubagentOutputKind
    let text: String
    var toolName: String? = nil
    var detail: String? = nil
}

private struct SubagentUsage: Hashable {
    let input: Int
    let output: Int

    var label: String { "↑\(Self.tokens(input)) ↓\(Self.tokens(output))" }

    private static func tokens(_ value: Int) -> String {
        if value < 1000 { return "\(value)" }
        if value < 10_000 { return String(format: "%.1fk", Double(value) / 1000) }
        if value < 1_000_000 { return "\(value / 1000)k" }
        return String(format: "%.1fM", Double(value) / 1_000_000)
    }
}

private struct SubagentRun: Identifiable, Hashable {
    let id: String
    let name: String
    let model: String?
    let prompt: String
    let parameters: [String]
    let activity: [SubagentOutputItem]
    let result: String?
    let error: String?
    let usage: SubagentUsage?
    let status: SubagentRunStatus
    let liveText: String
}

private struct SubagentPresentation: @unchecked Sendable {
    enum Mode {
        case single
        case parallel
        case chain
    }

    let mode: Mode
    let runs: [SubagentRun]

    init(tool: ToolDisplay) {
        let args = tool.argumentsObject ?? [:]
        let details = Self.jsonObject(tool.details)
        let results = details?["results"] as? [[String: Any]] ?? []

        let resolvedMode: Mode
        let specs: [[String: Any]]
        if let chain = args["chain"] as? [[String: Any]], !chain.isEmpty {
            resolvedMode = .chain
            specs = chain
        } else if let tasks = args["tasks"] as? [[String: Any]], !tasks.isEmpty {
            resolvedMode = .parallel
            specs = tasks
        } else if details?["mode"] as? String == "chain" {
            resolvedMode = .chain
            specs = []
        } else if details?["mode"] as? String == "parallel" {
            resolvedMode = .parallel
            specs = []
        } else {
            resolvedMode = .single
            specs = tool.shortName == "subagent"
                && (args["task"] as? String)?.nonEmptyTrimmed != nil
                && (details == nil || details?["mode"] as? String == "single") ? [args] : []
        }
        mode = resolvedMode

        let fallbackToToolResult = resolvedMode == .single && details == nil && !tool.result.isEmpty
        let count = resolvedMode == .single ? min(1, max(specs.count, results.count)) : max(specs.count, results.count)
        runs = (0..<count).map { index in
            let spec = index < specs.count ? specs[index] : [:]
            let result = index < results.count ? results[index] : nil
            let fallbackName = resolvedMode == .chain ? "step-\(index + 1)" : "subagent"
            let name = (result?["agent"] as? String)?.nonEmptyTrimmed
                ?? (spec["agent"] as? String)?.nonEmptyTrimmed
                ?? fallbackName
            let status = Self.status(
                mode: resolvedMode,
                index: index,
                resultCount: results.count,
                result: result,
                toolStatus: tool.status
            )
            var activity = Self.outputItems(result?["messages"])
            var finalText: String?
            if status == .succeeded, let last = activity.last, last.kind == .text {
                finalText = last.text
                activity.removeLast()
            }
            var error: String?
            if status == .failed {
                error = (result?["errorMessage"] as? String)?.nonEmptyTrimmed
                    ?? (result?["stderr"] as? String)?.nonEmptyTrimmed
            }
            if activity.isEmpty && finalText == nil && fallbackToToolResult {
                if status == .failed { error = error ?? tool.result.nonEmptyTrimmed } else { finalText = tool.result }
            }
            return SubagentRun(
                id: resolvedMode == .parallel ? "\(index).0" : "0.\(index)",
                name: name,
                model: (result?["model"] as? String)?.nonEmptyTrimmed ?? (spec["model"] as? String)?.nonEmptyTrimmed,
                prompt: (result?["task"] as? String) ?? (spec["task"] as? String) ?? "",
                parameters: Self.parameters(spec),
                activity: activity,
                result: finalText,
                error: error,
                usage: Self.usage(result?["usage"]),
                status: status,
                liveText: Self.liveText(status: status, activity: activity, result: finalText, error: error)
            )
        }
    }

    private static func jsonObject(_ json: String?) -> [String: Any]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func parameters(_ spec: [String: Any]) -> [String] {
        var values: [String] = []
        appendParameter("provider", spec["provider"], to: &values)
        appendParameter("model", spec["model"], to: &values)
        appendParameter("thinking", spec["thinkingLevel"], to: &values)
        if let tools = spec["tools"] as? [String], !tools.isEmpty {
            values.append("tools \(tools.joined(separator: ", "))")
        }
        appendParameter("cwd", spec["cwd"], to: &values)
        return values
    }

    private static func appendParameter(_ label: String, _ value: Any?, to values: inout [String]) {
        guard let value else { return }
        values.append("\(label) \(String(describing: value))")
    }

    private static func usage(_ value: Any?) -> SubagentUsage? {
        guard let usage = value as? [String: Any] else { return nil }
        let input = (usage["input"] as? NSNumber)?.intValue ?? 0
        let output = (usage["output"] as? NSNumber)?.intValue ?? 0
        guard input > 0 || output > 0 else { return nil }
        return SubagentUsage(input: input, output: output)
    }

    private static func liveText(
        status: SubagentRunStatus,
        activity: [SubagentOutputItem],
        result: String?,
        error: String?
    ) -> String {
        switch status {
        case .queued:
            return "Queued"
        case .running:
            guard let latest = activity.last else { return "Starting" }
            if latest.kind == .tool { return latest.text.oneLine(max: 160) }
            let line = latest.text.split(whereSeparator: \.isNewline).last { !$0.allSatisfy(\.isWhitespace) }
            return line.map { String($0).oneLine(max: 160) } ?? "Working"
        case .succeeded:
            guard let result else { return "Finished with no output" }
            let plain = MarkdownPlainText.render(String(result.prefix(800)))
            let line = plain.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) }
            return line.map { String($0).oneLine(max: 160) } ?? "Finished with no output"
        case .failed:
            let line = error?.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) }
            return line.map { String($0).oneLine(max: 160) } ?? "Failed"
        }
    }

    private static func status(
        mode: Mode,
        index: Int,
        resultCount: Int,
        result: [String: Any]?,
        toolStatus: ToolStatus
    ) -> SubagentRunStatus {
        if mode == .single {
            if toolStatus == .failed { return .failed }
            if toolStatus == .running { return .running }
            guard let result else { return .queued }
            return isFailed(result) ? .failed : .succeeded
        }

        if mode == .parallel {
            guard let result else { return .queued }
            if isFailed(result) { return .failed }
            if (result["exitCode"] as? Int) == -1 {
                if toolStatus == .failed { return .failed }
                return toolStatus == .running ? .running : .succeeded
            }
            return .succeeded
        }

        if toolStatus == .running {
            if index >= resultCount { return .queued }
            if index == resultCount - 1 { return isFailed(result) ? .failed : .running }
            return isFailed(result) ? .failed : .succeeded
        }

        guard let result else {
            return toolStatus == .failed && index == resultCount ? .failed : .queued
        }
        return isFailed(result) ? .failed : .succeeded
    }

    private static func isFailed(_ result: [String: Any]?) -> Bool {
        guard let result else { return false }
        if let exitCode = result["exitCode"] as? Int, exitCode != 0 && exitCode != -1 { return true }
        if let stopReason = result["stopReason"] as? String, ["error", "aborted"].contains(stopReason) { return true }
        return false
    }

    private static func outputItems(_ messagesValue: Any?) -> [SubagentOutputItem] {
        guard let messages = messagesValue as? [[String: Any]] else { return [] }
        var items: [SubagentOutputItem] = []
        for message in messages where message["role"] as? String == "assistant" {
            if let text = message["content"] as? String, !text.isEmpty {
                items.append(SubagentOutputItem(id: items.count, kind: .text, text: text))
                continue
            }
            guard let blocks = message["content"] as? [[String: Any]] else { continue }
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String, text.nonEmptyTrimmed != nil {
                        items.append(SubagentOutputItem(id: items.count, kind: .text, text: text))
                    }
                case "toolCall":
                    let name = block["name"] as? String ?? "tool"
                    let shortName = name.split(separator: ".").last.map(String.init) ?? name
                    let args = block["arguments"] as? [String: Any] ?? [:]
                    let command = shortName == "bash" ? (args["command"] as? String)?.nonEmptyTrimmed : nil
                    items.append(SubagentOutputItem(
                        id: items.count,
                        kind: .tool,
                        text: toolTitle(name: shortName, args: args),
                        toolName: shortName,
                        detail: command
                    ))
                default:
                    continue
                }
            }
        }
        return items
    }

    private static func toolTitle(name: String, args: [String: Any]) -> String {
        let path = (args["path"] as? String) ?? (args["file_path"] as? String) ?? "file"
        switch name {
        case "bash":
            return (args["description"] as? String)?.nonEmptyTrimmed
                ?? (args["command"] as? String)?.nonEmptyTrimmed?.oneLine(max: 200)
                ?? "Run shell command"
        case "read":
            return "Read \(path)"
        case "write":
            return "Write \(path)"
        case "edit":
            return "Edit \(path)"
        default:
            return ToolDisplay.genericTitle(name: name, args: args)
        }
    }
}

@MainActor
private enum SubagentRunClock {
    private static var starts: [String: Date] = [:]
    private static var ends: [String: Date] = [:]

    static func observe(_ key: String, status: SubagentRunStatus) {
        switch status {
        case .running:
            if starts[key] == nil { starts[key] = Date() }
        case .succeeded, .failed:
            if starts[key] != nil, ends[key] == nil { ends[key] = Date() }
        case .queued:
            break
        }
    }

    static func start(_ key: String) -> Date? { starts[key] }
    static func end(_ key: String) -> Date? { ends[key] }
}

/// Renders the task/tasks/chain arguments and mode/results details from
/// ~/.pi/agent/extensions/subagent/index.ts; other tool shapes use the fallback view.
struct SubagentToolDetailsView: View {
    @Environment(\.appTheme) private var appTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tool: ToolDisplay
    let projectPath: String?
    @State private var presentation: SubagentPresentation?
    @State private var cardOverrides: [String: Bool] = [:]
    @State private var finishedWhileShown: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let presentation {
                if presentation.runs.isEmpty {
                    FallbackToolDetailsView(tool: tool)
                } else {
                    cards(presentation)
                }
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .task(id: presentationTaskID) {
            let tool = tool
            let value = await Task.detached(priority: .utility) {
                SubagentPresentation(tool: tool)
            }.value
            guard !Task.isCancelled else { return }
            observe(value)
            presentation = value
        }
    }

    private var presentationTaskID: String {
        "\(tool.id)|\(tool.status.rawValue)|\(tool.arguments.count)|\(tool.result.count)|\(tool.details?.count ?? 0)"
    }

    private func clockKey(_ run: SubagentRun) -> String { "\(tool.id)#\(run.id)" }

    private func observe(_ next: SubagentPresentation) {
        let previous = Dictionary((presentation?.runs ?? []).map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
        for run in next.runs {
            SubagentRunClock.observe(clockKey(run), status: run.status)
            if let before = previous[run.id], !before.isFinished, run.status.isFinished {
                finishedWhileShown.insert(run.id)
            }
        }
    }

    private func isExpanded(_ run: SubagentRun, in presentation: SubagentPresentation) -> Bool {
        if let override = cardOverrides[run.id] { return override }
        return presentation.runs.count == 1 && run.status != .queued && !finishedWhileShown.contains(run.id)
    }

    private func cards(_ presentation: SubagentPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if presentation.mode == .chain && presentation.runs.count > 1 {
                chain(presentation)
            } else {
                ForEach(presentation.runs) { run in
                    card(run, step: nil, in: presentation)
                }
            }
        }
    }

    private func chain(_ presentation: SubagentPresentation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(presentation.runs.enumerated()), id: \.element.id) { index, run in
                if index > 0 {
                    Rectangle()
                        .fill(presentation.runs[index - 1].status == .succeeded ? appTheme.good.opacity(0.6) : appTheme.line)
                        .frame(width: 1.5, height: 10)
                        .padding(.leading, 16.25)
                        .accessibilityHidden(true)
                }
                card(run, step: (index + 1, presentation.runs.count), in: presentation)
            }
        }
    }

    private func card(_ run: SubagentRun, step: (index: Int, count: Int)?, in presentation: SubagentPresentation) -> some View {
        let expanded = isExpanded(run, in: presentation)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.14)) {
                    cardOverrides[run.id] = !expanded
                }
            } label: {
                cardLine(run, in: presentation, expanded: expanded)
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide run details" : "Show run details")
            .accessibilityLabel(cardAccessibilityLabel(run, step: step))
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded {
                Rectangle()
                    .fill(appTheme.line.opacity(0.5))
                    .frame(height: 1)
                    .accessibilityHidden(true)
                SubagentRunBody(run: run, projectPath: projectPath)
                    .padding(.leading, 32)
                    .padding(.trailing, 14)
                    .padding(.vertical, 12)
                    .transition(.opacity)
            }
        }
        .toolBodyStyle(padding: 0)
    }

    private func cardLine(_ run: SubagentRun, in presentation: SubagentPresentation, expanded: Bool) -> some View {
        let showsToolCall = run.status == .running && run.activity.last?.kind == .tool
        return HStack(spacing: 8) {
            ToolActivityIndicator(state: activityState(run.status))
            ZStack(alignment: .leading) {
                ForEach(presentation.runs) { other in
                    nameText(other.name).hidden()
                }
                nameText(run.name)
            }
            .frame(maxWidth: 220, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)
            Text(run.liveText)
                .font(showsToolCall ? AppFonts.code(11.5) : AppFonts.ui(12))
                .foregroundStyle(run.status == .failed ? appTheme.danger : appTheme.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            modelChip(run.model)
                .frame(maxWidth: 170, alignment: .trailing)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .help(run.model ?? "")
            if let start = SubagentRunClock.start(clockKey(run)) {
                SubagentElapsedText(start: start, end: SubagentRunClock.end(clockKey(run)), isRunning: run.status == .running)
                    .font(AppFonts.ui(11))
                    .monospacedDigit()
                    .foregroundStyle(appTheme.muted)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: AppFonts.scaled(30), alignment: .trailing)
                    .layoutPriority(3)
            }
            Image(systemName: "chevron.right")
                .font(AppFonts.ui(9, weight: .bold))
                .foregroundStyle(appTheme.muted)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 12)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func nameText(_ name: String) -> some View {
        Text(name)
            .font(AppFonts.ui(12.5, weight: .semibold))
            .foregroundStyle(appTheme.text)
            .lineLimit(1)
    }

    @ViewBuilder
    private func modelChip(_ model: String?) -> some View {
        if let model {
            Text(model.split(separator: "/").last.map(String.init) ?? model)
                .font(AppFonts.ui(10.5, weight: .medium))
                .foregroundStyle(appTheme.muted)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(appTheme.panel.opacity(0.7)))
                .overlay(Capsule().stroke(appTheme.line.opacity(0.6), lineWidth: 1))
        }
    }

    private func cardAccessibilityLabel(_ run: SubagentRun, step: (index: Int, count: Int)?) -> String {
        var parts = [step.map { "Step \($0.index) of \($0.count), \(run.name)" } ?? run.name]
        switch run.status {
        case .queued: parts.append("queued")
        case .running: parts.append("running")
        case .succeeded: parts.append("done")
        case .failed: parts.append("failed")
        }
        if run.status != .queued { parts.append(run.liveText) }
        return parts.joined(separator: ", ")
    }

    private func activityState(_ status: SubagentRunStatus) -> ToolActivityState {
        switch status {
        case .queued: return .new
        case .running: return .working
        case .succeeded: return .done
        case .failed: return .error
        }
    }

}

private struct SubagentElapsedText: View {
    let start: Date
    let end: Date?
    let isRunning: Bool

    var body: some View {
        if let end {
            Text(TurnTiming.format(end.timeIntervalSince(start)))
        } else if isRunning {
            TimelineView(.periodic(from: start, by: 1)) { context in
                Text(TurnTiming.format(context.date.timeIntervalSince(start)))
            }
        }
    }
}

private struct SubagentRunBody: View {
    @Environment(\.appTheme) private var appTheme
    let run: SubagentRun
    let projectPath: String?
    @State private var showsAllActivity = false
    @State private var panel: Panel?

    private enum Panel {
        case task
        case activity
    }

    private static let visibleToolCalls = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let result = run.result {
                NativeMarkdownView(
                    markdown: result,
                    role: .assistant,
                    theme: appTheme.choice,
                    projectPath: projectPath,
                    textStyle: appTheme.textStyle
                )
            } else if let error = run.error {
                Text(error)
                    .font(AppFonts.code(12))
                    .foregroundStyle(appTheme.danger)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                activityList
            }

            HStack(spacing: 14) {
                if let usage = run.usage {
                    Text(usage.label)
                        .font(AppFonts.ui(11))
                        .monospacedDigit()
                        .foregroundStyle(appTheme.muted)
                        .lineLimit(1)
                        .help("\(usage.input) input tokens, \(usage.output) output tokens")
                }
                Spacer(minLength: 8)
                ToolLinkButton(title: "Task") { toggle(.task) }
                if showsActivityLink {
                    ToolLinkButton(title: "\(toolCallCount) tool call\(toolCallCount == 1 ? "" : "s")") { toggle(.activity) }
                }
            }

            if panel == .task {
                taskPanel
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(appTheme.panel.opacity(0.7)))
            } else if panel == .activity, showsActivityLink {
                activityList
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(appTheme.panel.opacity(0.7)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var toolCallCount: Int {
        run.activity.filter { $0.kind == .tool }.count
    }

    private var showsActivityLink: Bool {
        (run.result != nil || run.error != nil) && toolCallCount > 0
    }

    private func toggle(_ target: Panel) {
        panel = panel == target ? nil : target
    }

    private var taskPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(run.prompt.isEmpty ? "No task text" : run.prompt)
                .font(AppFonts.ui(12.5))
                .foregroundStyle(run.prompt.isEmpty ? appTheme.muted : appTheme.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !run.parameters.isEmpty {
                SubagentMetadataLayout(spacing: 0) {
                    ForEach(run.parameters.indices, id: \.self) { index in
                        if index > run.parameters.startIndex {
                            Text("  ·  ")
                                .layoutValue(key: MetadataSeparatorKey.self, value: true)
                        }
                        Text(run.parameters[index])
                    }
                }
                .font(AppFonts.code(10.5))
                .foregroundStyle(appTheme.muted)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var activityList: some View {
        let toolIDs = run.activity.filter { $0.kind == .tool }.map(\.id)
        let hiddenCount = showsAllActivity ? 0 : max(0, toolIDs.count - Self.visibleToolCalls)
        let hidden = Set(toolIDs.prefix(hiddenCount))
        VStack(alignment: .leading, spacing: 5) {
            if hiddenCount > 0 {
                ToolLinkButton(title: "\(hiddenCount) more tool call\(hiddenCount == 1 ? "" : "s")") {
                    showsAllActivity = true
                }
            }
            if run.activity.isEmpty {
                Text("Waiting for output")
                    .font(AppFonts.ui(12))
                    .foregroundStyle(appTheme.muted)
            }
            ForEach(run.activity.filter { !hidden.contains($0.id) }) { item in
                SubagentActivityRow(item: item)
            }
        }
    }
}

private struct SubagentActivityRow: View {
    @Environment(\.appTheme) private var appTheme
    let item: SubagentOutputItem

    var body: some View {
        switch item.kind {
        case .tool:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: ToolDisplay.symbolName(forTool: item.toolName ?? ""))
                    .font(AppFonts.ui(10, weight: .medium))
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text(item.text)
                    .font(AppFonts.code(11.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(appTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(item.detail ?? item.text)
        case .text:
            Text(item.text)
                .font(AppFonts.ui(12.5))
                .foregroundStyle(appTheme.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MetadataSeparatorKey: LayoutValueKey {
    static let defaultValue = false
}

private struct SubagentMetadataLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(
            proposal: ProposedViewSize(width: bounds.width, height: proposal.height),
            subviews: subviews
        )
        for (index, point) in result.points.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                proposal: .unspecified
            )
        }
    }

    private func arrangement(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> (size: CGSize, points: [CGPoint]) {
        let proposedWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let availableWidth = proposedWidth ?? .greatestFiniteMagnitude
        var points = Array(repeating: CGPoint.zero, count: subviews.count)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maximumOccupiedWidth: CGFloat = 0
        var index = 0

        while index < subviews.count {
            let hasSeparator = subviews[index][MetadataSeparatorKey.self]
            let separatorIndex = hasSeparator ? index : nil
            let fieldIndex = hasSeparator ? index + 1 : index
            guard fieldIndex < subviews.count else { break }

            let separatorSize = separatorIndex.map { subviews[$0].sizeThatFits(.unspecified) } ?? .zero
            let fieldSize = subviews[fieldIndex].sizeThatFits(.unspecified)
            let combinedWidth = separatorSize.width + fieldSize.width
            let wraps = x > 0 && x + combinedWidth > availableWidth

            if wraps {
                maximumOccupiedWidth = max(maximumOccupiedWidth, x)
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }

            if let separatorIndex {
                if wraps {
                    // The separator belongs between fields, never at the start of a row.
                    points[separatorIndex] = CGPoint(x: -10_000, y: y)
                } else {
                    points[separatorIndex] = CGPoint(x: x, y: y)
                    x += separatorSize.width
                }
                rowHeight = max(rowHeight, separatorSize.height)
            }

            points[fieldIndex] = CGPoint(x: x, y: y)
            x += fieldSize.width
            rowHeight = max(rowHeight, fieldSize.height)
            index = fieldIndex + 1
        }

        maximumOccupiedWidth = max(maximumOccupiedWidth, x)
        let width = proposedWidth ?? maximumOccupiedWidth
        return (CGSize(width: width, height: y + rowHeight), points)
    }
}

