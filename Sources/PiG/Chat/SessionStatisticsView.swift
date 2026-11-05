import SwiftUI

struct SessionStatisticsToolbarButton: View {
    @EnvironmentObject private var model: AppModel
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "chart.bar.xaxis")
        }
        .buttonStyle(TitlebarIconButtonStyle(active: showing))
        .help("Session statistics")
        .accessibilityLabel("Session statistics")
        .disabled(model.selectedController == nil && model.selectedHermesController == nil)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            Group {
                if let controller = model.selectedController {
                    SessionStatisticsView(controller: controller)
                        .id(controller.id + (controller.sessionPath ?? ""))
                } else {
                    Text("Session statistics are unavailable for Hermes chats.")
                        .font(AppFonts.ui(12.5))
                        .padding(16)
                        .frame(width: 300)
                }
            }
            .glowPresentationBackground()
        }
        .onChange(of: model.selectedControllerID) { _, _ in showing = false }
        .onChange(of: model.selectedHermesChatID) { _, _ in showing = false }
    }
}

private struct SessionStatisticsView: View {
    @Environment(\.appTheme) private var appTheme
    @ObservedObject var controller: SessionController
    @State private var statistics: SessionStatistics?
    @State private var error: String?
    @State private var loading = true
    @State private var updatedAt: Date?
    @State private var refreshID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let statistics {
                content(statistics)
            } else if loading {
                SignalMarchLoadingLabel(text: "Loading statistics…")
                    .padding(.vertical, 12)
            }
            if let error {
                Text(error)
                    .font(AppFonts.ui(12))
                    .foregroundStyle(appTheme.danger)
                    .textSelection(.enabled)
            }
            HStack {
                if loading {
                    Text("Refreshing…")
                } else if let updatedAt, error == nil {
                    Text("Updated \(updatedAt.formatted(date: .omitted, time: .standard))")
                }
                Spacer()
                Button { refreshID = UUID() } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(error == nil ? "Refresh statistics" : "Retry")
                .accessibilityLabel(error == nil ? "Refresh statistics" : "Retry loading statistics")
                .disabled(loading)
            }
            .font(AppFonts.ui(11))
            .foregroundStyle(appTheme.muted)
        }
        .padding(16)
        .frame(width: 320)
        .font(AppFonts.ui(13))
        .foregroundStyle(appTheme.text)
        .monospacedDigit()
        .task(id: refreshID) { await refresh() }
    }

    @ViewBuilder private func content(_ stats: SessionStatistics) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Context used")
                Spacer()
                if let percent = stats.contextPercent {
                    Text("\(percent, specifier: "%.1f")%")
                        .font(AppFonts.ui(25, weight: .semibold))
                } else {
                    Text("Unavailable").foregroundStyle(appTheme.muted)
                }
            }
            if let percent = stats.contextPercent {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(appTheme.line)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(percent >= 85 ? appTheme.danger : percent >= 65 ? appTheme.brass : appTheme.good)
                            .frame(width: geometry.size.width * min(1, max(0, percent / 100)))
                    }
                }
                .frame(height: 5)
                .accessibilityHidden(true)
            }
            HStack {
                Text(stats.contextTokens.map { "\($0.formatted()) tokens" } ?? "Tokens unavailable")
                Spacer()
                Text(stats.contextWindow.map { "\($0.formatted()) limit" } ?? "Limit unavailable")
            }
            .font(AppFonts.ui(11.5))
            .foregroundStyle(appTheme.muted)
        }
        divider
        VStack(spacing: 9) {
            row("Input tokens", stats.inputTokens)
            row("Output tokens", stats.outputTokens)
            if let count = stats.cacheReadTokens, count > 0 { row("Cache read", count) }
            if let count = stats.cacheWriteTokens, count > 0 { row("Cache written", count) }
            row("Total tokens", stats.totalTokens, emphasized: true)
                .help("Cumulative session usage, including cached tokens; not the current context size.")
        }
        divider
        VStack(alignment: .leading, spacing: 5) {
            row("Messages", stats.totalMessages)
            Text(messageBreakdown(stats))
                .font(AppFonts.ui(11))
                .foregroundStyle(appTheme.muted)
            row("Tool calls", stats.toolCalls).padding(.top, 6)
        }
    }

    private var divider: some View {
        Rectangle().fill(appTheme.line.opacity(0.6)).frame(height: 1)
    }

    private func row(_ title: String, _ value: Int?, emphasized: Bool = false) -> some View {
        HStack {
            Text(title).foregroundStyle(emphasized ? appTheme.text : appTheme.secondaryText)
            Spacer()
            Text(SessionStatistics.display(value))
        }
        .font(AppFonts.ui(13, weight: emphasized ? .semibold : .regular))
    }

    private func messageBreakdown(_ stats: SessionStatistics) -> String {
        var parts: [String] = []
        if let count = stats.userMessages { parts.append("\(count.formatted()) user") }
        if let count = stats.assistantMessages { parts.append("\(count.formatted()) assistant") }
        if let count = stats.toolResults, count > 0 { parts.append("\(count.formatted()) tool results") }
        return parts.joined(separator: " / ")
    }

    @MainActor private func refresh() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let result = try await controller.fetchSessionStatistics()
            try Task.checkCancellation()
            statistics = result
            updatedAt = Date()
        } catch is CancellationError {
            // Closing the popover or switching sessions discards the request.
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
