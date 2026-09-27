import SwiftUI
import AppKit
import ImageIO

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
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(appTheme.panel2.opacity(0.36)))
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
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(appTheme.panel2.opacity(0.36)))
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
