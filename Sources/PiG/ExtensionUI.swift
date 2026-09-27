import SwiftUI
import AppKit

struct ExtensionUIPrompt: Identifiable, Equatable {
    enum Kind: Equatable {
        case select([String])
        case confirm(message: String?)
        case input(placeholder: String?)
        case editor
    }

    let id: String
    let title: String
    let kind: Kind
    let initialValue: String
    let timeout: TimeInterval?
}

struct ExtensionUINotification: Identifiable, Equatable {
    /// Cap per controller so hidden items cannot accumulate indefinitely.
    static let maxPending = 5

    enum Kind: String {
        case info
        case warning
        case error
    }

    let id: String
    let message: String
    let kind: Kind
}

struct ExtensionUIWidget: Identifiable, Equatable {
    enum Placement: String {
        case aboveEditor
        case belowEditor
    }

    var id: String { key }
    let key: String
    let lines: [String]
    let placement: Placement
}

enum ExtensionStatusVisibilityPreference {
    private static let key = "PiG.hiddenExtensionStatusKeys"

    static var hiddenKeys: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: key) }
    }
}

struct ExtensionUINotificationPresentation: Identifiable {
    var id: String { "\(controller.id):\(notification.id)" }
    let controller: SessionController
    let notification: ExtensionUINotification
}

struct ExtensionUIPromptView: View {
    @Environment(\.appTheme) private var appTheme
    @ObservedObject var controller: SessionController
    let prompt: ExtensionUIPrompt
    @State private var value: String
    @FocusState private var fieldFocused: Bool

    init(controller: SessionController, prompt: ExtensionUIPrompt) {
        self.controller = controller
        self.prompt = prompt
        _value = State(initialValue: prompt.initialValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(prompt.title)
                    .font(AppFonts.heading(20, weight: .semibold))
                    .foregroundStyle(appTheme.text)
                Spacer(minLength: 12)
                Text(controller.projectName)
                    .font(AppFonts.ui(12, weight: .semibold))
                    .foregroundStyle(appTheme.muted)
                    .lineLimit(1)
            }

            switch prompt.kind {
            case .select(let options):
                VStack(spacing: 1) {
                    ForEach(options, id: \.self) { option in
                        Button {
                            controller.respondToExtensionPrompt(prompt.id, value: option)
                        } label: {
                            HStack(spacing: 10) {
                                Text(option)
                                    .font(AppFonts.ui(14))
                                    .foregroundStyle(appTheme.text)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 8)
                                Image(systemName: "arrow.right")
                                    .font(AppFonts.ui(11, weight: .semibold))
                                    .foregroundStyle(appTheme.muted)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(appTheme.panel2.opacity(0.72))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                HStack {
                    Spacer()
                    Button("Cancel") { controller.cancelExtensionPrompt(prompt.id) }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(ExtensionPromptButtonStyle())
                }

            case .confirm(let message):
                if let message, !message.isEmpty {
                    Text(message)
                        .font(AppFonts.ui(14))
                        .foregroundStyle(appTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actionRow(confirm: true)

            case .input(let placeholder):
                TextField(placeholder ?? "", text: $value)
                    .textFieldStyle(.plain)
                    .font(AppFonts.ui(14))
                    .foregroundStyle(appTheme.text)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(appTheme.codeBackground.opacity(0.55)))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(appTheme.line, lineWidth: 1))
                    .focused($fieldFocused)
                    .onSubmit { submitValue() }
                actionRow(confirm: false)

            case .editor:
                TextEditor(text: $value)
                    .font(AppFonts.code(13))
                    .foregroundStyle(appTheme.text)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 180, maxHeight: 360)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(appTheme.codeBackground.opacity(0.55)))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(appTheme.line, lineWidth: 1))
                    .focused($fieldFocused)
                actionRow(confirm: false)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(appTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(appTheme.brass.opacity(0.5), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.42), radius: 30, y: 12)
        .onAppear {
            if case .input = prompt.kind { fieldFocused = true }
            if case .editor = prompt.kind { fieldFocused = true }
        }
        .onExitCommand { controller.cancelExtensionPrompt(prompt.id) }
    }

    @ViewBuilder
    private func actionRow(confirm: Bool) -> some View {
        HStack(spacing: 10) {
            Spacer()
            Button(confirm ? "No" : "Cancel") {
                if confirm {
                    controller.respondToExtensionConfirmation(prompt.id, confirmed: false)
                } else {
                    controller.cancelExtensionPrompt(prompt.id)
                }
            }
            .keyboardShortcut(.cancelAction)
            Button(confirm ? "Yes" : "Submit") {
                if confirm {
                    controller.respondToExtensionConfirmation(prompt.id, confirmed: true)
                } else {
                    submitValue()
                }
            }
            .keyboardShortcut(.defaultAction)
        }
        .buttonStyle(ExtensionPromptButtonStyle())
    }

    private func submitValue() {
        controller.respondToExtensionPrompt(prompt.id, value: value)
    }
}

private struct ExtensionPromptButtonStyle: ButtonStyle {
    @Environment(\.appTheme) private var appTheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFonts.ui(13, weight: .semibold))
            .foregroundStyle(appTheme.text)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(configuration.isPressed ? appTheme.brass.opacity(0.38) : appTheme.panel2))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(appTheme.line, lineWidth: 1))
    }
}

struct ExtensionWidgetsView: View {
    @Environment(\.appTheme) private var appTheme
    let widgets: [ExtensionUIWidget]

    var body: some View {
        if !widgets.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(widgets) { widget in
                    Text(widget.lines.joined(separator: "\n"))
                        .font(AppFonts.code(12.5))
                        .foregroundStyle(appTheme.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(appTheme.panel2.opacity(0.58))
            .overlay(alignment: .top) { Rectangle().fill(appTheme.line.opacity(0.65)).frame(height: 1) }
        }
    }
}

struct ExtensionStatusView: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    let statuses: [String: String]

    private var visibleKeys: [String] {
        statuses.keys.filter { !model.hiddenExtensionStatusKeys.contains($0) }.sorted()
    }

    var body: some View {
        if !visibleKeys.isEmpty {
            HStack(spacing: 14) {
                ForEach(visibleKeys, id: \.self) { key in
                    if let text = statuses[key] {
                        HStack(spacing: 5) {
                            Circle().fill(appTheme.brass).frame(width: 5, height: 5)
                            Text(text).lineLimit(1)
                        }
                        .contextMenu {
                            Button("Hide Status Item") {
                                model.setExtensionStatusHidden(key, hidden: true)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .font(AppFonts.ui(11.5))
            .foregroundStyle(appTheme.muted)
            .padding(.horizontal, 18)
            .padding(.vertical, 5)
        }
    }
}

struct ExtensionNotificationsView: View {
    @Environment(\.appTheme) private var appTheme
    let items: [ExtensionUINotificationPresentation]

    /// One visible toast at a time (errors first); the next appears after
    /// the current one expires or is dismissed. Expiry lives here so
    /// hovering/keyboard focus can pause it.
    private var topItem: ExtensionUINotificationPresentation? {
        items.sorted { rank($0.notification.kind) < rank($1.notification.kind) }.first
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let item = topItem {
                AutoDismissToast(
                    id: item.id,
                    accent: color(for: item.notification.kind),
                    duration: duration(for: item.notification.kind),
                    dismiss: { item.controller.dismissExtensionNotification(item.notification.id) }
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.notification.message)
                            .font(AppFonts.ui(13))
                            .foregroundStyle(appTheme.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(item.notification.message)
                        if items.contains(where: { $0.controller.id != item.controller.id }) {
                            Text(item.controller.projectName)
                                .font(AppFonts.ui(11.5))
                                .foregroundStyle(appTheme.muted)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private func rank(_ kind: ExtensionUINotification.Kind) -> Int {
        switch kind {
        case .error: return 0
        case .warning: return 1
        case .info: return 2
        }
    }

    private func duration(for kind: ExtensionUINotification.Kind) -> TimeInterval {
        switch kind {
        case .info: return 3
        case .warning, .error: return 5
        }
    }

    private func color(for kind: ExtensionUINotification.Kind) -> Color {
        switch kind {
        case .info: return appTheme.brass
        case .warning: return .orange
        case .error: return appTheme.danger
        }
    }
}

extension String {
    /// Removes ANSI/ECMA-48 terminal formatting and non-printing control characters
    /// before extension-provided text reaches native SwiftUI controls.
    var strippingTerminalControlSequences: String {
        let scalars = Array(unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0

        func isSequenceTerminator(_ value: UInt32) -> Bool {
            (0x40...0x7E).contains(value)
        }

        while index < scalars.count {
            let value = scalars[index].value

            if value == 0x1B { // ESC
                index += 1
                guard index < scalars.count else { break }
                let introducer = scalars[index].value
                if introducer == 0x5B { // CSI: ESC [ ... final byte
                    index += 1
                    while index < scalars.count {
                        let current = scalars[index].value
                        index += 1
                        if isSequenceTerminator(current) { break }
                    }
                } else if introducer == 0x5D { // OSC: ESC ] ... BEL or ST
                    index += 1
                    while index < scalars.count {
                        if scalars[index].value == 0x07 {
                            index += 1
                            break
                        }
                        if scalars[index].value == 0x1B,
                           index + 1 < scalars.count,
                           scalars[index + 1].value == 0x5C {
                            index += 2
                            break
                        }
                        index += 1
                    }
                } else {
                    // Other two-byte escape sequence.
                    index += 1
                }
                continue
            }

            if value == 0x9B { // Single-byte CSI
                index += 1
                while index < scalars.count {
                    let current = scalars[index].value
                    index += 1
                    if isSequenceTerminator(current) { break }
                }
                continue
            }

            if (value < 0x20 && value != 0x09 && value != 0x0A) || value == 0x7F {
                index += 1
                continue
            }

            result.append(scalars[index])
            index += 1
        }

        return String(result)
    }
}

struct ExtensionWindowTitleView: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        update(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        update(nsView)
    }

    private func update(_ view: NSView) {
        DispatchQueue.main.async { view.window?.title = title }
    }
}
