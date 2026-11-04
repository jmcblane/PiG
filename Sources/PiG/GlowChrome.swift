import SwiftUI
import AppKit

// Shared chrome for panels, dialogs, popovers and forms, so they match the
// command palette and the window's glow instead of stock AppKit surfaces.

// MARK: - Panel

/// Panel fill with the theme's glow tinting the top edge. Flat themes get the plain panel.
struct GlowPanelFill: View {
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        ZStack(alignment: .top) {
            appTheme.panel
            if let glow = appTheme.choice.glow {
                LinearGradient(colors: [glow.top.color.opacity(0.08), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 90)
            }
        }
    }
}

private struct GlowPanelModifier: ViewModifier {
    @Environment(\.appTheme) private var appTheme
    let cornerRadius: CGFloat
    let shadow: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(GlowPanelFill())
            .clipShape(shape)
            .overlay(shape.stroke(appTheme.line.opacity(0.8), lineWidth: 1))
            .shadow(color: .black.opacity(shadow ? (appTheme.choice.isLight ? 0.18 : 0.45) : 0), radius: 40, y: 20)
    }
}

extension View {
    /// Floating panel: themed fill, top glow, hairline stroke and a deep shadow.
    func glowPanel(cornerRadius: CGFloat = 16, shadow: Bool = true) -> some View {
        modifier(GlowPanelModifier(cornerRadius: cornerRadius, shadow: shadow))
    }

    /// Replaces the system popover or sheet material with the themed panel fill.
    func glowPresentationBackground() -> some View {
        presentationBackground { GlowPanelFill() }
    }
}

// MARK: - Buttons

struct GlowButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }

    @Environment(\.appTheme) private var appTheme
    @Environment(\.isEnabled) private var isEnabled
    var kind: Kind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .font(AppFonts.ui(12.5, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .foregroundStyle(foreground)
            .background(shape.fill(fill))
            .overlay(shape.stroke(stroke, lineWidth: 1))
            .shadow(color: kind == .primary && isEnabled ? appTheme.brass.opacity(0.35) : .clear, radius: 9)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(shape)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return appTheme.accentForeground
        case .secondary: return appTheme.secondaryText
        case .destructive: return appTheme.danger
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: return appTheme.brass
        case .secondary: return appTheme.panel2
        case .destructive: return appTheme.danger.opacity(0.14)
        }
    }

    private var stroke: Color {
        switch kind {
        case .primary: return .clear
        case .secondary: return appTheme.line
        case .destructive: return appTheme.danger.opacity(0.4)
        }
    }
}

// MARK: - Dialog

/// In-window replacement for `.alert`: a title, optional message, optional text field,
/// a cancel button (Esc) and a confirm button (Return).
struct GlowDialogRequest: Identifiable {
    enum Role { case normal, destructive }

    struct TextInput {
        var placeholder: String
        var initialText: String = ""
        /// Disable the confirm button while the trimmed text is empty.
        var requiresText: Bool = true
    }

    let id = UUID()
    var title: String
    var message: String? = nil
    var textInput: TextInput? = nil
    var confirmTitle: String
    var role: Role = .normal
    var cancelTitle: String = "Cancel"
    /// Receives the text field's value, or "" when there is no text field.
    var onConfirm: (String) -> Void
    var onCancel: () -> Void = {}
}

extension View {
    /// Shows `request` as a centered dialog over this view with a dimmed backdrop.
    func glowDialog(_ request: Binding<GlowDialogRequest?>) -> some View {
        overlay {
            if let value = request.wrappedValue {
                GlowDialogView(request: value) { request.wrappedValue = nil }
                    .id(value.id)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: request.wrappedValue?.id)
    }
}

struct GlowDialogView: View {
    @Environment(\.appTheme) private var appTheme
    let request: GlowDialogRequest
    let close: () -> Void
    @State private var text = ""
    @State private var handled = false
    @FocusState private var fieldFocused: Bool

    private var confirmDisabled: Bool {
        guard let input = request.textInput, input.requiresText else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .contentShape(Rectangle())
                .onTapGesture(perform: cancel)
            VStack(alignment: .leading, spacing: 0) {
                Text(request.title)
                    .font(AppFonts.heading(15))
                    .foregroundStyle(request.role == .destructive ? appTheme.danger : appTheme.text)
                if let message = request.message {
                    Text(message)
                        .font(AppFonts.ui(12.5))
                        .foregroundStyle(appTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
                if let input = request.textInput {
                    GlowTextField(input.placeholder, text: $text)
                        .focused($fieldFocused)
                        .onSubmit { if !confirmDisabled { confirm() } }
                        .padding(.top, 14)
                }
                HStack(spacing: 8) {
                    Spacer()
                    Button(request.cancelTitle, action: cancel)
                        .buttonStyle(GlowButtonStyle(kind: .secondary))
                        .keyboardShortcut(.cancelAction)
                    Button(request.confirmTitle, action: confirm)
                        .buttonStyle(GlowButtonStyle(kind: request.role == .destructive ? .destructive : .primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(confirmDisabled)
                }
                .padding(.top, 18)
            }
            .padding(20)
            .frame(width: 380)
            .glowPanel()
        }
        .onAppear {
            text = request.textInput?.initialText ?? ""
            guard request.textInput != nil else { return }
            // The composer is an AppKit text view; SwiftUI focus won't take first
            // responder from it, so clear it first and focus on the next pass.
            NSApp.keyWindow?.makeFirstResponder(nil)
            DispatchQueue.main.async { fieldFocused = true }
        }
        // A newer request replaced this one before it was answered.
        .onDisappear { if !handled { request.onCancel() } }
    }

    private func confirm() {
        handled = true
        let value = text
        close()
        request.onConfirm(value)
    }

    private func cancel() {
        handled = true
        close()
        request.onCancel()
    }
}

// MARK: - Fields

private struct GlowFieldModifier: ViewModifier {
    @Environment(\.appTheme) private var appTheme
    let focused: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        content
            .background(shape.fill(appTheme.panel2))
            .overlay(shape.stroke(focused ? appTheme.lineBright.opacity(0.7) : appTheme.line, lineWidth: 1))
            .background(shape.stroke(appTheme.lineBright.opacity(focused ? 0.15 : 0), lineWidth: 6))
    }
}

extension View {
    /// Field chrome for custom inputs (TextEditor, search rows): panel2 fill, stroke, accent focus ring.
    func glowField(focused: Bool) -> some View {
        modifier(GlowFieldModifier(focused: focused))
    }
}

struct GlowTextField: View {
    @Environment(\.appTheme) private var appTheme
    let placeholder: String
    @Binding var text: String
    var monospaced = false
    @FocusState private var focused: Bool

    init(_ placeholder: String, text: Binding<String>, monospaced: Bool = false) {
        self.placeholder = placeholder
        self._text = text
        self.monospaced = monospaced
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(monospaced ? AppFonts.code(12.5) : AppFonts.ui(13))
            .foregroundStyle(appTheme.text)
            .focused($focused)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .glowField(focused: focused)
    }
}

// MARK: - Toggle

/// Switch drawn after the label. Put a labeled `Toggle` in a `GlowBlockRow` so the switch sits on the right.
struct GlowToggleStyle: ToggleStyle {
    @Environment(\.appTheme) private var appTheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.label
            Spacer(minLength: 0)
            Capsule()
                .fill(configuration.isOn ? appTheme.brass : appTheme.line)
                .frame(width: 30, height: 17)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 13, height: 13).padding(2)
                }
                .shadow(color: configuration.isOn ? appTheme.brass.opacity(0.4) : .clear, radius: 5)
                .animation(.easeOut(duration: 0.12), value: configuration.isOn)
                .onTapGesture { configuration.isOn.toggle() }
        }
        .opacity(isEnabled ? 1 : 0.45)
    }
}

extension ToggleStyle where Self == GlowToggleStyle {
    static var glow: GlowToggleStyle { GlowToggleStyle() }
}

// MARK: - Segmented

/// Segmented control for two to four options.
struct GlowSegmented<Value: Hashable>: View {
    @Environment(\.appTheme) private var appTheme
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    Text(label(option))
                        .font(AppFonts.ui(12, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? appTheme.text : appTheme.muted)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selected ? appTheme.panel2 : .clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(selected ? appTheme.lineBright.opacity(0.45) : .clear, lineWidth: 1)
                                )
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(appTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(appTheme.line, lineWidth: 1))
        .fixedSize()
    }
}

// MARK: - Dropdown

/// Replacement for a menu-style `Picker`: a compact button that opens a themed popover list.
struct GlowDropdown<Value: Hashable>: View {
    @Environment(\.appTheme) private var appTheme
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    var icon: ((Value) -> String?)? = nil
    @State private var open = false

    var body: some View {
        GlowDropdownButton(title: label(selection), icon: icon?(selection), open: $open)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(options, id: \.self) { option in
                            PopoverPickerRow(title: label(option), icon: icon?(option), isSelected: option == selection) {
                                selection = option
                                open = false
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(minWidth: 220, maxHeight: 340)
                .fixedSize(horizontal: false, vertical: options.count <= 12)
                .glowPresentationBackground()
                .environment(\.appTheme, appTheme)
            }
    }
}

/// The closed state of a dropdown: current value and a chevron. Tapping toggles `open`.
struct GlowDropdownButton: View {
    @Environment(\.appTheme) private var appTheme
    let title: String
    var icon: String? = nil
    @Binding var open: Bool
    @State private var hovering = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(AppFonts.ui(11))
                        .foregroundStyle(appTheme.muted)
                }
                Text(title)
                    .font(AppFonts.ui(12))
                    .foregroundStyle(appTheme.text)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(AppFonts.ui(8.5, weight: .bold))
                    .foregroundStyle(appTheme.muted)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering || open ? appTheme.panel2 : appTheme.panel)
            )
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(appTheme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
    }
}

// MARK: - Form

/// Grouped form section: small uppercase header, rows in a rounded panel2 group, optional footer.
struct GlowSection<Content: View>: View {
    @Environment(\.appTheme) private var appTheme
    let title: String?
    var footer: String? = nil
    @ViewBuilder let content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title.uppercased())
                    .font(AppFonts.ui(10.5, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(appTheme.muted)
                    .padding(.horizontal, 4)
            }
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(appTheme.panel2.opacity(0.7)))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(appTheme.line, lineWidth: 1))
            if let footer {
                Text(footer)
                    .font(AppFonts.ui(11.5))
                    .foregroundStyle(appTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// Free-form row inside a `GlowSection`. Rows draw a hairline on top; the first one sits on the group's stroke.
struct GlowBlockRow<Content: View>: View {
    @Environment(\.appTheme) private var appTheme
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .overlay(alignment: .top) {
                Rectangle().fill(appTheme.line.opacity(0.6)).frame(height: 1)
            }
    }
}

/// Labeled row inside a `GlowSection`: title and optional subtitle on the left, a control on the right.
struct GlowRow<Trailing: View>: View {
    @Environment(\.appTheme) private var appTheme
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        GlowBlockRow {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AppFonts.ui(13))
                        .foregroundStyle(appTheme.text)
                    if let subtitle {
                        Text(subtitle)
                            .font(AppFonts.ui(11.5))
                            .foregroundStyle(appTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
        }
    }
}
