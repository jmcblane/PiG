import SwiftUI

/// Compact transient notification. Callers own identity and dismissal state.
struct AutoDismissToast<Content: View>: View {
    @Environment(\.appTheme) private var appTheme
    let id: String
    let accent: Color
    let duration: TimeInterval
    let dismiss: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false
    private enum FocusTarget: Hashable { case body, dismiss }
    @FocusState private var focused: FocusTarget?

    var body: some View {
        content
            .padding(.leading, 12)
            .padding(.trailing, 36)
            .padding(.vertical, 10)
            .frame(width: 340, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(appTheme.panel.opacity(0.98)))
            .overlay(alignment: .leading) { Rectangle().fill(accent).frame(width: 2) }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(appTheme.line, lineWidth: 1))
            .focusable()
            .focused($focused, equals: .body)
            .overlay(alignment: .topTrailing) {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(AppFonts.ui(9, weight: .bold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss notification")
                .foregroundStyle(appTheme.muted)
                .padding(4)
                .focused($focused, equals: .dismiss)
            }
            .shadow(color: Color.black.opacity(0.18), radius: 8, y: 3)
            .focusSection()
            .onHover { hovering = $0 }
            .task(id: id) {
                var remaining = duration
                while remaining > 0 {
                    do { try await Task.sleep(nanoseconds: 200_000_000) }
                    catch { return }
                    if !hovering && focused == nil { remaining -= 0.2 }
                }
                guard !Task.isCancelled else { return }
                dismiss()
            }
    }
}
