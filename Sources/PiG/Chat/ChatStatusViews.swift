import SwiftUI
import AppKit
import ImageIO

enum UsageLimitStyle {
    static func meterColor(percent: Int?, role: UsageLimitWindowRole, hasError: Bool = false, theme: AppTheme) -> Color {
        guard let percent else { return hasError ? theme.danger : theme.muted }
        if percent <= 10 { return theme.danger }
        if percent <= 25 { return theme.warning }
        return baseColor(for: role, theme: theme)
    }

    static func baseColor(for role: UsageLimitWindowRole, theme: AppTheme) -> Color {
        switch role {
        case .primary: return theme.brass
        case .weekly: return theme.good
        case .extra: return theme.secondaryText
        }
    }
}

struct UsageLimitIndicator: View {
    @Environment(\.appTheme) private var appTheme
    let snapshot: UsageLimitSnapshot?
    var pendingText = "Loading…"
    let refresh: () -> Void
    @State private var indicatorHovering = false
    @State private var popupHovering = false
    @State private var showPopup = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        Button(action: refresh) {
            VStack(spacing: 3) {
                SegmentMeter(
                    percent: snapshot?.primary.map { Double($0.remainingPercent) },
                    fill: UsageLimitStyle.meterColor(
                        percent: snapshot?.primary?.remainingPercent,
                        role: .primary,
                        hasError: snapshot?.error != nil,
                        theme: appTheme
                    ),
                    empty: emptyTrack(for: snapshot?.primary?.remainingPercent)
                )
                SegmentMeter(
                    percent: snapshot?.weekly.map { Double($0.remainingPercent) },
                    fill: UsageLimitStyle.meterColor(
                        percent: snapshot?.weekly?.remainingPercent,
                        role: .weekly,
                        hasError: snapshot?.error != nil,
                        theme: appTheme
                    ),
                    empty: emptyTrack(for: snapshot?.weekly?.remainingPercent)
                )
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Refresh usage limits")
        .accessibilityValue(snapshot?.error ?? snapshot?.details.map { "\($0.label): \($0.remainingPercent)% remaining" }.joined(separator: ", ") ?? pendingText)
        .overlay(alignment: .bottomTrailing) {
            if showPopup {
                VStack(spacing: 0) {
                    UsageLimitPopup(
                        snapshot: snapshot,
                        pendingText: pendingText,
                        openUsageSettings: {
                            dismissPopup()
                            SettingsTab.open(.usage)
                        }
                    )
                    Color.clear
                        .frame(height: 8)
                }
                .contentShape(Rectangle())
                .onHover { inside in
                    popupHovering = inside
                    updateHoverVisibility()
                }
                .offset(y: -15)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .zIndex(showPopup ? 10 : 0)
        .onHover { inside in
            indicatorHovering = inside
            updateHoverVisibility()
        }
        .onDisappear {
            hideTask?.cancel()
            hideTask = nil
        }
    }

    private func updateHoverVisibility() {
        hideTask?.cancel()
        hideTask = nil
        if indicatorHovering || popupHovering {
            if !showPopup {
                withAnimation(.easeOut(duration: 0.12)) { showPopup = true }
            }
        } else if showPopup {
            hideTask = Task {
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                if !indicatorHovering && !popupHovering {
                    withAnimation(.easeOut(duration: 0.12)) { showPopup = false }
                }
            }
        }
    }

    private func dismissPopup() {
        hideTask?.cancel()
        hideTask = nil
        indicatorHovering = false
        popupHovering = false
        showPopup = false
    }

    private func emptyTrack(for percent: Int?) -> Color {
        if percent == nil, snapshot?.error != nil { return appTheme.danger.opacity(0.35) }
        return appTheme.line
    }
}

struct UsageLimitPopup: View {
    @Environment(\.appTheme) private var appTheme
    let snapshot: UsageLimitSnapshot?
    var pendingText = "Loading…"
    var openUsageSettings: (() -> Void)? = nil
    @State private var shortcutHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("\(snapshot?.serviceName ?? "Usage") usage")
                    .font(AppFonts.ui(11.5, weight: .semibold))
                    .foregroundStyle(appTheme.text)
                Spacer(minLength: 8)
                if let openUsageSettings {
                    Button(action: openUsageSettings) {
                        Image(systemName: "arrow.up.right.square")
                            .font(AppFonts.ui(11, weight: .semibold))
                            .foregroundStyle(shortcutHovering ? appTheme.text : appTheme.muted)
                            .frame(width: 20, height: 18)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(shortcutHovering ? appTheme.panel2 : .clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { shortcutHovering = $0 }
                    .help("Open all usage in Settings")
                    .accessibilityLabel("Open all usage in Settings")
                }
            }
            if let snapshot, snapshot.error == nil {
                if snapshot.details.isEmpty {
                    Text(pendingText)
                        .font(AppFonts.ui(11.5))
                        .foregroundStyle(appTheme.muted)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                        ForEach(Array(snapshot.details.enumerated()), id: \.offset) { index, window in
                            if index > 0 && snapshot.details[index - 1].isActiveGroup && !window.isActiveGroup {
                                Divider()
                                    .gridCellUnsizedAxes(.horizontal)
                                    .padding(.vertical, 2)
                            }
                            popupRow(window)
                        }
                    }
                }
            } else {
                Text(snapshot?.error ?? pendingText)
                    .font(AppFonts.ui(11.5))
                    .foregroundStyle(appTheme.danger)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .fixedSize(horizontal: true, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(appTheme.panel.opacity(0.98))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(appTheme.line.opacity(0.75), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.32), radius: 12, y: 6)
    }

    private func popupRow(_ window: UsageLimitWindow) -> some View {
        let color = UsageLimitStyle.meterColor(percent: window.remainingPercent, role: window.role, theme: appTheme)
        return GridRow {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(color)
                    .frame(width: 10, height: 4)
                    .opacity(window.isActiveGroup ? 1 : 0.72)
                Text(window.label)
                    .font(AppFonts.ui(11.5, weight: window.isActiveGroup ? .semibold : .medium))
                    .foregroundStyle(window.isActiveGroup ? appTheme.text : appTheme.muted)
                    .lineLimit(1)
            }
            Text("\(window.remainingPercent)%")
                .font(AppFonts.ui(11.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(color)
                .gridColumnAlignment(.trailing)
            Text(window.resetText.map { "resets \($0)" } ?? "")
                .font(AppFonts.ui(11.5))
                .foregroundStyle(appTheme.secondaryText)
                .lineLimit(1)
        }
    }
}

/// 10-block meter for usage remaining.
struct SegmentMeter: View {
    let percent: Double?
    let fill: Color
    var empty: Color
    var segments: Int = 10
    var height: CGFloat = 4

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(index < litCount ? fill : empty)
            }
        }
        .frame(height: height)
    }

    private var litCount: Int {
        guard let percent else { return 0 }
        return Int(round(min(max(percent, 0), 100) / 100 * Double(segments)))
    }
}

/// Send (or abort) button ringed by the share of the context window in use.
struct ComposerSendButton: View {
    @Environment(\.appTheme) private var appTheme
    let aborting: Bool
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(aborting ? appTheme.danger : appTheme.brass)
                .frame(width: 30, height: 30)
                .overlay(
                    Image(systemName: aborting ? "stop.fill" : "arrow.up")
                        .font(AppFonts.ui(13, weight: .bold))
                        .foregroundStyle(aborting ? appTheme.dangerForeground : appTheme.accentForeground)
                )
                .opacity(disabled ? 0.45 : 1)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(aborting ? "Abort" : "Send")
        .accessibilityLabel(aborting ? "Abort" : "Send")
    }
}

struct ContextRingButton: View {
    @Environment(\.appTheme) private var appTheme
    @ObservedObject var controller: SessionController
    @State private var showingStatistics = false

    private var percent: Double? { controller.contextPercent }

    var body: some View {
        Button { showingStatistics.toggle() } label: {
            ZStack {
                Circle()
                    .stroke(appTheme.line.opacity(0.8), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: min(1, max(0, (percent ?? 0) / 100)))
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: percent)
            }
            .frame(width: 14, height: 14)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(contextHelp)
        .accessibilityLabel("Context")
        .accessibilityValue(contextHelp)
        .popover(isPresented: $showingStatistics, arrowEdge: .top) {
            SessionStatisticsView(controller: controller)
                .id(controller.id + (controller.sessionPath ?? ""))
                .glowPresentationBackground()
        }
    }

    private var ringColor: Color {
        guard let percent else { return appTheme.muted }
        if percent >= 85 { return appTheme.danger }
        if percent >= 65 { return appTheme.brass }
        return appTheme.good
    }

    private var contextHelp: String {
        if let percent, let tokens = controller.contextTokens, let window = controller.contextWindow {
            return "Context \(Int(percent))% used (\(tokens.formatted()) of \(window.formatted()) tokens)"
        }
        if let percent { return "Context \(Int(percent))% used" }
        return "Context usage unavailable"
    }
}

struct SendButtonStyle: ButtonStyle {
    @Environment(\.appTheme) private var appTheme
    let active: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 38, height: 38)
            .foregroundStyle(active ? appTheme.dangerForeground : appTheme.accentForeground)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(active ? appTheme.danger : appTheme.brass)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(active ? appTheme.danger.opacity(0.7) : appTheme.brass.opacity(0.8), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

struct InlineActivityIndicator: View {
    let text: String

    var body: some View {
        SignalMarchIndicator(text: text)
    }
}

struct SignalMarch: View {
    enum Presentation {
        case standard
        case compact
    }

    enum Tone {
        case accent
        case muted
    }

    @Environment(\.appTheme) private var appTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var occlusion = AppOcclusion.shared
    var presentation: Presentation = .standard
    var tone: Tone = .accent

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || !occlusion.isVisible)) { timeline in
            let time = reduceMotion ? 0.0 : timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: presentation == .compact ? 1.5 : 2) {
                ForEach(0..<5, id: \.self) { index in
                    let strength = signalStrength(time, index: index)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color)
                        .frame(
                            width: presentation == .compact ? 1.5 : 2,
                            height: minimumHeight + CGFloat(strength) * heightRange
                        )
                        .opacity(0.25 + strength * 0.75)
                }
            }
            .frame(height: presentation == .compact ? 12 : 14)
            .fixedSize()
        }
        .accessibilityHidden(true)
    }

    private var color: Color {
        switch tone {
        case .accent: return appTheme.brass
        case .muted: return appTheme.muted
        }
    }

    private var minimumHeight: CGFloat {
        presentation == .compact ? 3 : 4
    }

    private var heightRange: CGFloat {
        presentation == .compact ? 8 : 10
    }

    private func signalStrength(_ time: TimeInterval, index: Int) -> Double {
        guard !reduceMotion else {
            return [0.18, 0.48, 0.78, 0.42, 0.22][index]
        }
        let cycle = 1.05
        let delay = Double(index) * 0.11
        let rawPhase = (time - delay).truncatingRemainder(dividingBy: cycle)
        let phase = (rawPhase < 0 ? rawPhase + cycle : rawPhase) / cycle
        let linear = max(0, 1 - abs(phase - 0.45) / 0.20)
        return linear * linear * (3 - 2 * linear)
    }
}

struct SignalMarchLoadingLabel: View {
    @Environment(\.appTheme) private var appTheme
    let text: String

    var body: some View {
        HStack(spacing: 9) {
            SignalMarch(presentation: .compact, tone: .muted)
            Text(text)
                .font(AppFonts.ui(12.5))
                .foregroundStyle(appTheme.muted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

private struct SignalMarchIndicator: View {
    @Environment(\.appTheme) private var appTheme
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Text(text.uppercased())
                .font(AppFonts.heading(12.5, weight: .semibold))
                .tracking(1.2)
            SignalMarch()
        }
        .foregroundStyle(appTheme.brass)
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

// Chat errors now surface through the single arbitrated toast in RootView
// (chat error > extension > status) plus a small 'Last error' affordance near
// the composer. This file keeps only status/activity indicators.
