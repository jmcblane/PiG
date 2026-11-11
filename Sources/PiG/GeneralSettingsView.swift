import SwiftUI
import AppKit
import UserNotifications

struct GeneralSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appTheme) private var appTheme
    @State private var notificationsDenied = false
    @AppStorage(QuickChatsFolderPreference.key) private var quickChatsFolder = ""
    @AppStorage(TerminalPaneMode.buttonDefaultKey) private var terminalButtonMode = TerminalPaneMode.full
    @AppStorage(OpenInTerminalTarget.key) private var openInTerminalTarget = OpenInTerminalTarget.pig
    @AppStorage(HTMLRenderPreference.key) private var htmlRenderEnabled = true
    @AppStorage(ResponseStreamingPreference.key) private var responseStreaming = ResponseStreamingPreference.live

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                appearanceSection
                sessionsSection
                terminalSection
                quickChatsSection
                notificationsSection
            }
            .padding(20)
        }
        .task { await refreshNotificationStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshNotificationStatus() }
        }
    }

    private var appearanceSection: some View {
        GlowSection("Appearance") {
            GlowRow("Theme") {
                GlowDropdown(selection: $model.selectedTheme, options: AppThemeChoice.allCases, label: { $0.displayName })
            }

            FontChoicePicker(title: "Interface font", selection: $model.interfaceFont)
            FontChoicePicker(
                title: "Code font",
                hint: model.codeFont.displayName.localizedCaseInsensitiveContains("Nerd Font")
                    ? nil : "Terminal prompt icons need a Nerd Font.",
                selection: $model.codeFont
            )

            GlowRow("Text size") {
                HStack(spacing: 10) {
                    Slider(value: textSizeBinding, in: 0...Double(TextSizePreference.steps.count - 1), step: 1)
                        .tint(appTheme.brass)
                        .frame(width: 170)
                        .accessibilityValue("\(textSizePercent)%")
                    Text("\(textSizePercent)%")
                        .font(AppFonts.ui(12))
                        .foregroundStyle(appTheme.secondaryText)
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                    Button("Reset") { model.textSizeStep = TextSizePreference.actualSizeStep }
                        .buttonStyle(GlowButtonStyle())
                        .disabled(model.textSizeStep == TextSizePreference.actualSizeStep)
                }
            }
        }
    }

    private var sessionsSection: some View {
        GlowSection("Chats") {
            GlowRow("Runtime") {
                GlowSegmented(selection: $model.sessionRuntimePolicy, options: SessionRuntimePolicy.allCases, label: { $0.displayName })
            }
            .help(model.sessionRuntimePolicy.helpText)

            GlowRow("Response streaming") {
                GlowSegmented(selection: $responseStreaming, options: ResponseStreamingPreference.allCases, label: { $0.displayName })
            }
            .help("Finished paragraphs shows each paragraph, list item, or code block once it is complete.")

            SettingsToggleRow(title: "Show thinking traces", isOn: $model.showThinkingTraces)
            SettingsToggleRow(title: "Accent composer on focus", isOn: $model.composerFocusAccent)
            SettingsToggleRow(
                title: "Interactive HTML in replies",
                subtitle: "Lets the agent add small interactive controls to chat. Applies to chats started after you change it.",
                isOn: $htmlRenderEnabled
            )
        }
    }

    private var terminalSection: some View {
        GlowSection("Terminal") {
            GlowRow("Terminal button opens") {
                GlowSegmented(selection: $terminalButtonMode, options: TerminalPaneMode.buttonChoices, label: { $0.displayName })
            }
            GlowRow("Open in Terminal uses") {
                GlowSegmented(selection: $openInTerminalTarget, options: OpenInTerminalTarget.allCases, label: { $0.displayName })
            }
        }
    }

    private var quickChatsSection: some View {
        GlowSection("Quick Chats") {
            GlowBlockRow {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Folder")
                        .font(AppFonts.ui(13))
                        .foregroundStyle(appTheme.text)
                    Text(PiPaths.quickChatsProject.path)
                        .font(AppFonts.code(12))
                        .foregroundStyle(appTheme.secondaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            GlowBlockRow {
                HStack(spacing: 8) {
                    Button("Choose…") { chooseQuickChatsFolder() }
                    Button("Show in Finder") {
                        let folder = PiPaths.quickChatsProject
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                    Button("Reset to Default") { quickChatsFolder = "" }
                        .disabled(quickChatsFolder.isEmpty)
                }
                .buttonStyle(GlowButtonStyle())
            }
        }
    }

    private var notificationsSection: some View {
        GlowSection("Notifications") {
            SettingsToggleRow(title: "Enable notifications", isOn: $model.notificationsEnabled)
            if notificationsDenied {
                GlowBlockRow {
                    HStack {
                        Label("Notifications are turned off for PiG in System Settings.", systemImage: "exclamationmark.triangle.fill")
                            .font(AppFonts.ui(12))
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(GlowButtonStyle())
                    }
                }
            }
            GlowBlockRow {
                Button("Send test notification in 10 seconds") {
                    model.scheduleTestNotification()
                }
                .buttonStyle(GlowButtonStyle())
                .disabled(!model.notificationsEnabled)
            }
        }
    }

    private var textSizePercent: Int {
        Int((TextSizePreference.steps[model.textSizeStep] * 100).rounded())
    }

    private var textSizeBinding: Binding<Double> {
        Binding {
            Double(model.textSizeStep)
        } set: { value in
            let step = Int(value.rounded())
            if step != model.textSizeStep { model.textSizeStep = step }
        }
    }

    private func refreshNotificationStatus() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationsDenied = status == .denied
    }

    private func chooseQuickChatsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.fileExists(atPath: PiPaths.quickChatsProject.path)
            ? PiPaths.quickChatsProject : PiPaths.appSupport
        panel.prompt = "Choose"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                quickChatsFolder = url.standardizedFileURL.path
            }
        }
    }
}

/// Labeled glow switch row, with an optional muted line under the title.
struct SettingsToggleRow: View {
    @Environment(\.appTheme) private var appTheme
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        GlowBlockRow {
            Toggle(isOn: $isOn) {
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
            }
            .toggleStyle(.glow)
        }
    }
}

/// A dropdown whose popover lists the presets, then every installed family
/// in its own face, filtered by a search field.
private struct FontChoicePicker<Choice: FontChoice>: View {
    @Environment(\.appTheme) private var appTheme
    let title: String
    var hint: String? = nil
    @Binding var selection: Choice
    @State private var open = false
    @State private var search = ""

    var body: some View {
        GlowRow(title, subtitle: hint) {
            GlowDropdownButton(title: selection.displayName, open: $open)
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    menu
                        .glowPresentationBackground()
                        .environment(\.appTheme, appTheme)
                }
                .onChange(of: open) { _, isOpen in
                    if isOpen { search = "" }
                }
        }
    }

    private var menu: some View {
        VStack(spacing: 6) {
            GlowTextField("Search fonts", text: $search)
                .padding([.horizontal, .top], 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !presets.isEmpty {
                        header("Presets")
                        ForEach(presets, id: \.self) { choice in
                            row(choice.displayName, font: AppFonts.ui(12.5), choice: choice)
                        }
                    }
                    if !families.isEmpty {
                        header("Installed fonts")
                        ForEach(families, id: \.self) { family in
                            row(family, font: .custom(family, size: 12.5), choice: .family(family))
                        }
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .frame(width: 260, height: 340)
    }

    private func header(_ text: String) -> some View {
        Text(text.uppercased())
            .font(AppFonts.ui(10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(appTheme.muted)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }

    private func row(_ title: String, font: Font, choice: Choice) -> some View {
        FontMenuRow(title: title, font: font, isSelected: choice == selection) {
            selection = choice
            open = false
        }
    }

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    private var presets: [Choice] {
        query.isEmpty ? Choice.presets : Choice.presets.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    private var families: [String] {
        query.isEmpty ? Choice.installedFamilies : Choice.installedFamilies.filter { $0.localizedCaseInsensitiveContains(query) }
    }
}

private struct FontMenuRow: View {
    @Environment(\.appTheme) private var appTheme
    let title: String
    let font: Font
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(AppFonts.ui(10, weight: .bold))
                    .foregroundStyle(appTheme.brass)
                    .opacity(isSelected ? 1 : 0)
                Text(title)
                    .font(font)
                    .foregroundStyle(appTheme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(hovering ? appTheme.brass.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
