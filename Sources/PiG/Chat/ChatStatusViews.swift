import SwiftUI
import AppKit
import ImageIO

struct UsageLimitIndicator: View {
    @Environment(\.appTheme) private var appTheme
    let snapshot: UsageLimitSnapshot?
    let refresh: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: refresh) {
            VStack(spacing: 3) {
                SegmentMeter(
                    percent: snapshot?.primary.map { Double($0.remainingPercent) },
                    fill: usageColor(snapshot?.primary?.remainingPercent, fallback: appTheme.brass),
                    empty: emptyTrack(for: snapshot?.primary?.remainingPercent)
                )
                SegmentMeter(
                    percent: snapshot?.weekly.map { Double($0.remainingPercent) },
                    fill: usageColor(snapshot?.weekly?.remainingPercent, fallback: appTheme.good),
                    empty: emptyTrack(for: snapshot?.weekly?.remainingPercent)
                )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottomTrailing) {
            if hovering {
                UsageLimitPopup(snapshot: snapshot)
                    .offset(y: -16)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .zIndex(hovering ? 10 : 0)
        .onHover { hovering = $0 }
    }

    private func usageColor(_ percent: Int?, fallback: Color) -> Color {
        guard let percent else { return snapshot?.error == nil ? appTheme.muted : appTheme.danger }
        if percent <= 10 { return appTheme.danger }
        if percent <= 25 { return appTheme.brass }
        return fallback
    }

    private func emptyTrack(for percent: Int?) -> Color {
        if percent == nil, snapshot?.error != nil { return appTheme.danger.opacity(0.35) }
        return appTheme.line
    }
}

struct UsageLimitPopup: View {
    @Environment(\.appTheme) private var appTheme
    let snapshot: UsageLimitSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(snapshot?.serviceName ?? "Usage") usage")
                .font(AppFonts.ui(11.5, weight: .semibold))
                .foregroundStyle(appTheme.text)
            if let snapshot, snapshot.error == nil {
                ForEach(snapshot.details, id: \.self) { window in
                    popupRow(window)
                }
            } else {
                Text(snapshot?.error ?? "Loading…")
                    .font(AppFonts.ui(11.5))
                    .foregroundStyle(appTheme.danger)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .fixedSize(horizontal: true, vertical: true)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(appTheme.panel.opacity(0.98)))
        .shadow(color: Color.black.opacity(0.32), radius: 12, y: 6)
    }

    private func popupRow(_ window: UsageLimitWindow) -> some View {
        HStack(spacing: 8) {
            Text(window.label)
                .font(AppFonts.ui(11.5, weight: .semibold))
                .foregroundStyle(appTheme.muted)
                .frame(width: 86, alignment: .leading)
            Text("\(window.remainingPercent)%")
                .font(AppFonts.ui(11.5, weight: .semibold))
                .foregroundStyle(window.remainingPercent <= 10 ? appTheme.danger : window.remainingPercent <= 25 ? appTheme.brass : appTheme.good)
            Text("resets \(window.resetText)")
                .font(AppFonts.ui(11.5))
                .foregroundStyle(appTheme.secondaryText)
        }
    }
}

struct ContextUsageBar: View {
    @Environment(\.appTheme) private var appTheme
    let percent: Double?
    let tokens: Int?
    let window: Int?

    var body: some View {
        SegmentMeter(percent: percent, fill: color, empty: appTheme.line)
            .help(help)
    }

    private var color: Color {
        guard let percent else { return appTheme.muted }
        if percent >= 85 { return appTheme.danger }
        if percent >= 65 { return appTheme.brass }
        return appTheme.good
    }

    private var help: String {
        if let percent, let tokens, let window { return "Context: \(Int(percent))% · \(tokens) / \(window) tokens" }
        if let percent { return "Context: \(Int(percent))%" }
        return "Context usage unavailable"
    }
}

/// 10-block meter for usage remaining / context used.
private struct SegmentMeter: View {
    let percent: Double?
    let fill: Color
    var empty: Color
    var segments: Int = 10

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(index < litCount ? fill : empty)
            }
        }
        .frame(height: 4)
    }

    private var litCount: Int {
        guard let percent else { return 0 }
        return Int(round(min(max(percent, 0), 100) / 100 * Double(segments)))
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
    var presentation: Presentation = .standard
    var tone: Tone = .accent

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
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
