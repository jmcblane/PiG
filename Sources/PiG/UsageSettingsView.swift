import SwiftUI

struct UsageSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        UsageSettingsContent(store: model.usageLimitStore)
    }
}

private struct UsageSettingsContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appTheme) private var appTheme
    @ObservedObject var store: UsageLimitStore
    @State private var accounts: [UsageLimitProvider] = []
    @State private var hasLoadedAccounts = false

    private var isRefreshingAny: Bool {
        accounts.contains { store.refreshing.contains($0) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                headerBar
                if hasLoadedAccounts && accounts.isEmpty {
                    emptySection
                } else {
                    ForEach(accounts, id: \.self) { provider in
                        accountSection(for: provider)
                    }
                }
            }
            .padding(20)
        }
        .task {
            _ = await PiEnvironment.mergedAsync()
            accounts = model.configuredUsageAccounts
            hasLoadedAccounts = true
            await model.refreshAllConfiguredUsageLimits(force: false)
        }
    }

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(summaryText)
                .font(AppFonts.ui(12.5, weight: .medium))
                .foregroundStyle(appTheme.secondaryText)
            Spacer(minLength: 8)
            Button {
                Task {
                    _ = await PiEnvironment.mergedAsync()
                    accounts = model.configuredUsageAccounts
                    await model.refreshAllConfiguredUsageLimits(force: true)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    Text("Refresh All")
                }
            }
            .buttonStyle(GlowButtonStyle())
            .disabled(isRefreshingAny || accounts.allSatisfy { $0 == .claudeBridge })
        }
        .padding(.horizontal, 4)
    }

    private var summaryText: String {
        guard hasLoadedAccounts else { return "Checking configured accounts…" }
        if accounts.isEmpty { return "No subscription accounts detected" }
        let count = accounts.count
        return "\(count) configured account\(count == 1 ? "" : "s")"
    }

    private var emptySection: some View {
        GlowSection("Accounts") {
            GlowBlockRow {
                VStack(alignment: .leading, spacing: 5) {
                    Text("No usage-enabled accounts found")
                        .font(AppFonts.ui(13, weight: .semibold))
                        .foregroundStyle(appTheme.text)
                    Text("Accounts appear automatically when you sign in with OAuth for Codex or Grok in ~/.pi/agent/auth.json, or when the Claude Code (claude) or Antigravity (agy) CLI is installed.")
                        .font(AppFonts.ui(12))
                        .foregroundStyle(appTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func accountSection(for provider: UsageLimitProvider) -> some View {
        let snapshot = model.usageLimit(for: provider)
        let isRefreshing = store.refreshing.contains(provider)
        let fetchDate = store.fetchDates[provider]
        let groups = groupedWindows(in: snapshot?.details ?? [])

        return GlowSection {
            GlowBlockRow {
                HStack(spacing: 10) {
                    Circle()
                        .fill(TabStripPickerLabel.color(for: provider.colorKey))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.serviceName)
                            .font(AppFonts.ui(13.5, weight: .semibold))
                            .foregroundStyle(appTheme.text)
                        if let subtitle = accountSubtitle(for: provider, groupCount: groups.count) {
                            Text(subtitle)
                                .font(AppFonts.ui(11.5))
                                .foregroundStyle(appTheme.muted)
                        }
                    }
                    Spacer(minLength: 8)
                    if isRefreshing {
                        SignalMarch(presentation: .compact, tone: .muted)
                    } else if let fetchDate {
                        UpdatedTimestampLabel(date: fetchDate)
                    }
                    if provider != .claudeBridge {
                        Button {
                            model.refreshUsageLimit(for: provider, force: true)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(GlowButtonStyle())
                        .disabled(isRefreshing)
                        .help("Refresh \(provider.serviceName) usage")
                        .accessibilityLabel("Refresh \(provider.serviceName) usage")
                    }
                }
            }

            if let snapshot, let error = snapshot.error {
                GlowBlockRow {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(AppFonts.ui(12))
                            .foregroundStyle(appTheme.danger)
                            .padding(.top, 1)
                        Text(error)
                            .font(AppFonts.ui(12))
                            .foregroundStyle(appTheme.danger)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if let snapshot, !snapshot.details.isEmpty {
                if !groups.isEmpty {
                    ForEach(groups, id: \.name) { group in
                        GlowBlockRow {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.name)
                                    .font(AppFonts.ui(12.5, weight: .semibold))
                                    .foregroundStyle(appTheme.text)
                                VStack(spacing: 8) {
                                    ForEach(Array(group.windows.enumerated()), id: \.offset) { _, window in
                                        windowMeterRow(
                                            window,
                                            labelOverride: shortLabel(for: window, strippingGroup: group.name)
                                        )
                                    }
                                }
                            }
                        }
                    }
                } else {
                    GlowBlockRow {
                        VStack(spacing: 10) {
                            ForEach(Array(snapshot.details.enumerated()), id: \.offset) { _, window in
                                windowMeterRow(window)
                            }
                        }
                    }
                }
            } else if isRefreshing {
                GlowBlockRow {
                    SignalMarchLoadingLabel(text: "Loading usage…")
                }
            } else {
                GlowBlockRow {
                    Text(provider == .claudeBridge
                        ? "Waiting for Claude Code quota data from an active chat…"
                        : "No usage limits reported yet.")
                        .font(AppFonts.ui(12))
                        .foregroundStyle(appTheme.muted)
                }
            }
        }
    }

    private func windowMeterRow(_ window: UsageLimitWindow, labelOverride: String? = nil) -> some View {
        let color = UsageLimitStyle.meterColor(percent: window.remainingPercent, role: window.role, theme: appTheme)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(color)
                        .frame(width: 10, height: 4)
                    Text(labelOverride ?? window.label)
                        .font(AppFonts.ui(12.5, weight: .medium))
                        .foregroundStyle(appTheme.text)
                }
                Spacer(minLength: 8)
                Text("\(window.remainingPercent)%")
                    .font(AppFonts.ui(12.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(color)
                if let resetText = window.resetText, !resetText.isEmpty {
                    Text("resets \(resetText)")
                        .font(AppFonts.ui(11.5))
                        .foregroundStyle(appTheme.muted)
                }
            }
            SegmentMeter(
                percent: Double(window.remainingPercent),
                fill: color,
                empty: appTheme.line,
                segments: 20,
                height: 6
            )
        }
    }

    private struct WindowGroup {
        let name: String
        let subtitle: String?
        var windows: [UsageLimitWindow]
    }

    private func groupedWindows(in details: [UsageLimitWindow]) -> [WindowGroup] {
        guard details.contains(where: { $0.groupName != nil }) else { return [] }
        var groups: [WindowGroup] = []
        for window in details {
            let name = window.groupName ?? "Other"
            if let idx = groups.firstIndex(where: { $0.name == name }) {
                groups[idx].windows.append(window)
            } else {
                groups.append(WindowGroup(name: name, subtitle: window.groupSubtitle, windows: [window]))
            }
        }
        return groups
    }

    private func shortLabel(for window: UsageLimitWindow, strippingGroup groupName: String) -> String {
        let prefix = "\(groupName) · "
        if window.label.hasPrefix(prefix) {
            return String(window.label.dropFirst(prefix.count))
        }
        return window.label
    }

    private func accountSubtitle(for provider: UsageLimitProvider, groupCount: Int) -> String? {
        if case .antigravity = provider, groupCount > 0 {
            return "\(groupCount) model group\(groupCount == 1 ? "" : "s")"
        }
        return provider.accountSubtitle
    }
}

private struct UpdatedTimestampLabel: View {
    @Environment(\.appTheme) private var appTheme
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(label(relativeTo: context.date))
                .font(AppFonts.ui(11.5))
                .foregroundStyle(appTheme.muted)
        }
    }

    private func label(relativeTo now: Date) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 45 { return "Updated just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Updated \(formatter.localizedString(for: date, relativeTo: now))"
    }
}
