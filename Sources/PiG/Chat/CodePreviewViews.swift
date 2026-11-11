import SwiftUI
import AppKit
import ImageIO

struct ToolBodyStyle: ViewModifier {
    @Environment(\.appTheme) private var appTheme
    var padding: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(appTheme.panel2.opacity(0.36)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(appTheme.line.opacity(0.5), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

extension View {
    func toolBodyStyle(padding: CGFloat = 10) -> some View {
        modifier(ToolBodyStyle(padding: padding))
    }
}

struct CopyButton: View {
    let label: String
    let text: () -> String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text(), forType: .string)
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(InlineIconButtonStyle())
        .help(copied ? "Copied" : label)
        .accessibilityLabel(copied ? "Copied" : label)
        .accessibilityValue(copied ? "Copied" : "")
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            copied = false
        }
    }
}

struct ToolLinkButton: View {
    @Environment(\.appTheme) private var appTheme
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(AppFonts.ui(11.5, weight: .medium))
                .foregroundStyle(appTheme.brass)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct CappedHeight: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let natural = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? natural.width, height: min(natural.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

struct EditDiffView: View {
    @Environment(\.appTheme) private var appTheme
    let diff: EditDiffSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(diff.hunks) { hunk in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(hunk.lines) { line in
                        EditDiffLineView(line: line)
                    }
                }
            }
        }
        .toolBodyStyle()
    }
}

struct CodePreviewView: View {
    @Environment(\.appTheme) private var appTheme
    let preview: CodePreviewSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !preview.title.isEmpty {
                Text(preview.title)
                    .font(AppFonts.ui(11.5, weight: .semibold))
                    .foregroundStyle(appTheme.muted)
                    .lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 0) {
                if preview.hiddenLineCount > 0, preview.hiddenLinePosition == .top {
                    CodePreviewLineView(line: hiddenLineText("earlier"))
                }
                ForEach(preview.lines) { line in
                    CodePreviewLineView(line: line)
                }
                if preview.hiddenLineCount > 0, preview.hiddenLinePosition == .bottom {
                    CodePreviewLineView(line: hiddenLineText("more"))
                }
            }
        }
        .toolBodyStyle()
    }

    private func hiddenLineText(_ direction: String) -> CodePreviewLine {
        CodePreviewLine(number: nil, text: "... \(preview.hiddenLineCount) \(direction) line\(preview.hiddenLineCount == 1 ? "" : "s")")
    }
}

struct CodePreviewLineView: View {
    @Environment(\.appTheme) private var appTheme
    let line: CodePreviewLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(line.number.map(String.init) ?? "")
                .font(AppFonts.code(12.5))
                .foregroundStyle(appTheme.muted)
                .frame(width: 46, alignment: .trailing)
                .padding(.trailing, 8)
            Text(line.text.isEmpty ? " " : line.text)
                .font(AppFonts.code(12.5))
                .foregroundStyle(appTheme.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .padding(.trailing, 5)
    }
}

struct EditDiffLineView: View {
    @Environment(\.appTheme) private var appTheme
    let line: EditDiffLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(numberText)
                .font(AppFonts.code(12.5))
                .foregroundStyle(numberColor)
                .frame(width: 46, alignment: .trailing)
                .padding(.trailing, 8)
            Text(line.text.isEmpty ? " " : line.text)
                .font(AppFonts.code(12.5))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .padding(.trailing, 5)
        .background(backgroundColor)
    }

    private var numberText: String {
        switch line.kind {
        case .context: return line.newNumber.map(String.init) ?? ""
        case .delete: return line.oldNumber.map(String.init) ?? ""
        case .insert: return line.newNumber.map(String.init) ?? ""
        case .ellipsis: return ""
        }
    }

    private var backgroundColor: Color {
        switch line.kind {
        case .delete: return appTheme.danger.opacity(0.20)
        case .insert: return appTheme.good.opacity(0.18)
        case .context, .ellipsis: return Color.clear
        }
    }

    private var numberColor: Color {
        switch line.kind {
        case .delete: return appTheme.danger.opacity(0.9)
        case .insert: return appTheme.good.opacity(0.9)
        default: return appTheme.muted
        }
    }

    private var textColor: Color {
        switch line.kind {
        case .delete: return appTheme.danger.opacity(0.95)
        case .insert: return appTheme.good.opacity(0.95)
        default: return appTheme.secondaryText
        }
    }
}
