import SwiftUI
import AppKit
import ImageIO

private enum SubagentRunStatus: Hashable {
    case queued
    case running
    case succeeded
    case failed
}

private enum SubagentOutputKind: Hashable {
    case text
    case tool
}

private struct SubagentOutputItem: Identifiable, Hashable {
    let id: Int
    let kind: SubagentOutputKind
    let text: String
    var bashCommand: String? = nil
}

private struct SubagentRun: Identifiable, Hashable {
    let id: String
    let name: String
    let prompt: String
    let parameters: [String]
    let output: [SubagentOutputItem]
    let status: SubagentRunStatus

    var outputSignature: Int {
        var hasher = Hasher()
        hasher.combine(output)
        hasher.combine(status)
        return hasher.finalize()
    }
}

private struct SubagentLane: Identifiable, Hashable {
    let id: Int
    let runs: [SubagentRun]
}

private struct SubagentPresentation: @unchecked Sendable {
    enum Mode {
        case single
        case parallel
        case chain
    }

    let mode: Mode
    let lanes: [SubagentLane]

    var runs: [SubagentRun] { lanes.flatMap(\.runs) }
    var hasNestedChain: Bool { mode == .parallel && lanes.contains { $0.runs.count > 1 } }

    var preferredRunID: String? {
        runs.first(where: { $0.status == .running })?.id ?? runs.first?.id
    }

    var progressSignature: String {
        lanes.map { lane in
            lane.runs.map { "\($0.id):\($0.status)" }.joined(separator: ",")
        }.joined(separator: "|")
    }

    init(tool: ToolDisplay) {
        let args = tool.argumentsObject ?? [:]
        let details = Self.jsonObject(tool.details)
        let flatResults = details?["results"] as? [[String: Any]] ?? []
        let detailLanes = details?["lanes"] as? [[String: Any]]

        let resolvedMode: Mode
        let specLanes: [[[String: Any]]]
        if let chain = args["chain"] as? [[String: Any]], !chain.isEmpty {
            resolvedMode = .chain
            specLanes = [chain]
        } else if let tasks = args["tasks"] as? [[String: Any]], !tasks.isEmpty {
            resolvedMode = .parallel
            specLanes = tasks.map { item in
                if let nested = item["chain"] as? [[String: Any]], !nested.isEmpty { return nested }
                return [item]
            }
        } else if details?["mode"] as? String == "chain" {
            resolvedMode = .chain
            specLanes = [[]]
        } else if details?["mode"] as? String == "parallel" {
            resolvedMode = .parallel
            specLanes = []
        } else {
            resolvedMode = .single
            specLanes = tool.shortName == "subagent"
                && (args["task"] as? String)?.nonEmptyTrimmed != nil
                && (details == nil || details?["mode"] as? String == "single") ? [[args]] : []
        }
        mode = resolvedMode

        let resultLanes: [[[String: Any]]]
        if let detailLanes, !detailLanes.isEmpty {
            resultLanes = detailLanes.map { ($0["results"] as? [[String: Any]]) ?? [] }
        } else if resolvedMode == .parallel, specLanes.contains(where: { $0.count > 1 }) {
            resultLanes = specLanes.map { _ in [] }
        } else if resolvedMode == .parallel {
            resultLanes = flatResults.map { [$0] }
        } else {
            resultLanes = [flatResults]
        }

        let fallbackToToolResult = resolvedMode == .single && details == nil && !tool.result.isEmpty
        let laneCount = max(specLanes.count, resultLanes.count)
        lanes = (0..<laneCount).compactMap { laneIndex in
            let specs = laneIndex < specLanes.count ? specLanes[laneIndex] : []
            let results = laneIndex < resultLanes.count ? resultLanes[laneIndex] : []
            let count = max(specs.count, results.count)
            guard count > 0 else { return nil }
            let nested = resolvedMode == .parallel && count > 1
            let runs = (0..<count).map { stepIndex in
                let spec = stepIndex < specs.count ? specs[stepIndex] : [:]
                let result = stepIndex < results.count ? results[stepIndex] : nil
                let fallbackName = nested || resolvedMode == .chain ? "step-\(stepIndex + 1)" : "subagent"
                let name = (result?["agent"] as? String)?.nonEmptyTrimmed
                    ?? (spec["agent"] as? String)?.nonEmptyTrimmed
                    ?? fallbackName
                let output = Self.outputItems(result?["messages"])
                return SubagentRun(
                    id: "\(laneIndex).\(stepIndex)",
                    name: name,
                    prompt: (result?["task"] as? String) ?? (spec["task"] as? String) ?? "",
                    parameters: Self.parameters(spec),
                    output: output.isEmpty && fallbackToToolResult
                        ? [SubagentOutputItem(id: 0, kind: .text, text: tool.result)]
                        : output,
                    status: Self.status(
                        mode: resolvedMode,
                        index: stepIndex,
                        resultCount: results.count,
                        result: result,
                        toolStatus: tool.status
                    )
                )
            }
            return SubagentLane(id: laneIndex, runs: runs)
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
                    if let text = block["text"] as? String, !text.isEmpty {
                        items.append(SubagentOutputItem(id: items.count, kind: .text, text: text))
                    }
                case "toolCall":
                    let name = block["name"] as? String ?? "tool"
                    let args = block["arguments"] as? [String: Any] ?? [:]
                    let command = name.split(separator: ".").last == "bash"
                        ? (args["command"] as? String)?.nonEmptyTrimmed
                        : nil
                    items.append(SubagentOutputItem(
                        id: items.count,
                        kind: .tool,
                        text: toolTitle(name: name, args: args),
                        bashCommand: command
                    ))
                default:
                    continue
                }
            }
        }
        return items
    }

    private static func toolTitle(name: String, args: [String: Any]) -> String {
        let shortName = name.split(separator: ".").last.map(String.init) ?? name
        switch shortName {
        case "bash":
            return (args["description"] as? String)?.nonEmptyTrimmed
                ?? (args["command"] as? String)?.nonEmptyTrimmed
                ?? "Run shell command"
        case "read":
            return "read \((args["path"] as? String) ?? (args["file_path"] as? String) ?? "file")"
        case "write":
            return "write \((args["path"] as? String) ?? (args["file_path"] as? String) ?? "file")"
        case "edit":
            return "edit \((args["path"] as? String) ?? (args["file_path"] as? String) ?? "file")"
        default:
            return ToolDisplay.genericTitle(name: shortName, args: args)
        }
    }
}

/// Renders the task/tasks/chain arguments and mode/results/lanes details from
/// ~/.pi/agent/extensions/subagent/index.ts; other tool shapes use the fallback view.
struct SubagentToolDetailsView: View {
    @Environment(\.appTheme) private var appTheme
    let tool: ToolDisplay
    @State private var selectedRunID: String?

    private var presentation: SubagentPresentation { SubagentPresentation(tool: tool) }

    var body: some View {
        let presentation = presentation
        let selected = presentation.runs.first(where: { $0.id == selectedRunID })
            ?? presentation.runs.first(where: { $0.id == presentation.preferredRunID })
            ?? presentation.runs.first

        Group {
            if let selected {
                HStack(alignment: .top, spacing: 0) {
                    if presentation.runs.count > 1 {
                        rail(selected: selected, presentation: presentation)
                    }
                    runDetails(selected)
                }
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(appTheme.panel2.opacity(0.36))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(appTheme.line.opacity(0.58), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                FallbackToolDetailsView(tool: tool)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .onAppear { syncSelection(in: presentation) }
        .onChange(of: presentationTaskID) { _, _ in syncSelection(in: presentation) }
        .onChange(of: presentation.progressSignature) { _, _ in followSelectedLane(in: presentation) }
    }

    private var presentationTaskID: String {
        "\(tool.id)|\(tool.status.rawValue)|\(tool.arguments.count)|\(tool.result.count)|\(tool.details?.count ?? 0)"
    }

    private func syncSelection(in presentation: SubagentPresentation) {
        if selectedRunID.map({ id in presentation.runs.contains(where: { $0.id == id }) }) != true {
            selectedRunID = presentation.preferredRunID
        }
        followSelectedLane(in: presentation)
    }

    private func followSelectedLane(in presentation: SubagentPresentation) {
        guard let selectedRunID,
              let lane = presentation.lanes.first(where: { $0.runs.contains { $0.id == selectedRunID } }),
              lane.runs.count > 1,
              let running = lane.runs.first(where: { $0.status == .running })
        else { return }
        self.selectedRunID = running.id
    }

    private func rail(selected: SubagentRun, presentation: SubagentPresentation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(presentation.lanes) { lane in
                if presentation.mode == .parallel && lane.runs.count > 1 {
                    chainLane(lane, selected: selected)
                } else {
                    ForEach(lane.runs) { run in
                        railButton(run, selected: selected, stepLabel: nil, indented: false)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: presentation.hasNestedChain ? 158 : 128)
        .background(appTheme.panel.opacity(0.3))
        .overlay(alignment: .trailing) {
            Rectangle().fill(appTheme.line.opacity(0.58)).frame(width: 1)
        }
    }

    private func chainLane(_ lane: SubagentLane, selected: SubagentRun) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lane.runs.enumerated()), id: \.element.id) { index, run in
                railButton(
                    run,
                    selected: selected,
                    stepLabel: "\(index + 1)/\(lane.runs.count)",
                    indented: index > 0
                )
            }
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(appTheme.line.opacity(0.7))
                .frame(width: 1)
                .padding(.leading, 16)
                .padding(.top, 22)
                .padding(.bottom, 14)
                .allowsHitTesting(false)
        }
    }

    private func railButton(
        _ run: SubagentRun,
        selected: SubagentRun,
        stepLabel: String?,
        indented: Bool
    ) -> some View {
        Button {
            selectedRunID = run.id
        } label: {
            HStack(spacing: 8) {
                ToolActivityIndicator(state: activityState(run.status))
                Text(run.name)
                    .font(AppFonts.ui(11.5, weight: .semibold))
                    .foregroundStyle(run.id == selected.id ? appTheme.text : appTheme.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let stepLabel {
                    Text(stepLabel)
                        .font(AppFonts.code(10))
                        .foregroundStyle(appTheme.muted)
                }
            }
            .padding(.leading, indented ? 22 : 10)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(run.id == selected.id ? appTheme.brass.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(stepLabel.map { "\(run.name), step \($0)" } ?? run.name)
    }

    private func runDetails(_ run: SubagentRun) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.vertical) {
                    Text(run.prompt.isEmpty ? "(no prompt)" : run.prompt)
                        .font(AppFonts.code(12))
                        .foregroundStyle(appTheme.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(height: promptHeight(run.prompt))

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
            .padding(10)

            Rectangle()
                .fill(appTheme.line.opacity(0.58))
                .frame(height: 1)

            SubagentStreamView(run: run)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activityState(_ status: SubagentRunStatus) -> ToolActivityState {
        switch status {
        case .queued: return .new
        case .running: return .working
        case .succeeded: return .done
        case .failed: return .error
        }
    }

    private func promptHeight(_ prompt: String) -> CGFloat {
        let visualLines = prompt.components(separatedBy: "\n").reduce(0) { total, line in
            total + max(1, Int(ceil(Double(max(line.count, 1)) / 76.0)))
        }
        return min(96, max(18, CGFloat(visualLines) * 17))
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

private struct SubagentOutputRow: View {
    @Environment(\.appTheme) private var appTheme
    let item: SubagentOutputItem
    @State private var showingCommand = false

    var body: some View {
        Text(item.text)
            .font(AppFonts.code(item.kind == .tool ? 11.5 : 12))
            .foregroundStyle(item.kind == .tool ? appTheme.muted : appTheme.codeText.opacity(0.92))
            .textSelection(.enabled)
            .padding(.trailing, item.bashCommand == nil ? 0 : 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .topTrailing) {
                if let command = item.bashCommand {
                    Button { showingCommand.toggle() } label: {
                        Image(systemName: "terminal")
                            .font(AppFonts.ui(10, weight: .semibold))
                            .foregroundStyle(showingCommand ? appTheme.brass : appTheme.muted)
                            .frame(width: 20, height: 20)
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
    }
}

private struct SubagentStreamView: View {
    @Environment(\.appTheme) private var appTheme
    let run: SubagentRun

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if run.output.isEmpty {
                        Text(emptyText)
                            .font(AppFonts.code(11.5))
                            .foregroundStyle(appTheme.muted)
                    } else {
                        ForEach(run.output) { item in
                            SubagentOutputRow(item: item)
                        }
                    }
                    Color.clear.frame(height: 1).id("subagent-stream-bottom")
                }
                .padding(10)
            }
            .frame(height: 184)
            .background(appTheme.codeBackground.opacity(0.24))
            .onAppear { scrollToBottom(proxy) }
            .onChange(of: run.outputSignature) { _, _ in scrollToBottom(proxy) }
        }
    }

    private var emptyText: String {
        switch run.status {
        case .queued: return "(queued)"
        case .running: return "(waiting for output…)"
        case .succeeded, .failed: return "(no output)"
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo("subagent-stream-bottom", anchor: .bottom)
        }
    }
}
