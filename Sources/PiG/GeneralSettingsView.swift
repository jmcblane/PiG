import SwiftUI
import AppKit
import UserNotifications

struct GeneralSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var piExecutablePath = PiExecutablePreference.path ?? ""
    @State private var detectedPiPath = PiPaths.detectedPiExecutable.path
    @State private var notificationsDenied = false
    @AppStorage(QuickChatsFolderPreference.key) private var quickChatsFolder = ""
    @AppStorage(TerminalPaneMode.buttonDefaultKey) private var terminalButtonMode = TerminalPaneMode.full
    @AppStorage(OpenInTerminalTarget.key) private var openInTerminalTarget = OpenInTerminalTarget.pig
    @AppStorage(HTMLRenderPreference.key) private var htmlRenderEnabled = true

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $model.selectedTheme) {
                    ForEach(AppThemeChoice.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }

                LabeledContent("Text size") {
                    HStack {
                        Slider(value: textSizeBinding, in: 0...Double(TextSizePreference.steps.count - 1), step: 1)
                            .accessibilityValue("\(textSizePercent)%")
                        Text("\(textSizePercent)%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                        Button("Reset") { model.textSizeStep = TextSizePreference.actualSizeStep }
                            .disabled(model.textSizeStep == TextSizePreference.actualSizeStep)
                    }
                }

                Picker("Project headers", selection: $model.projectHeaderStyle) {
                    ForEach(ProjectHeaderStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
            }

            Section("Sessions") {
                Picker("Runtime", selection: $model.sessionRuntimePolicy) {
                    ForEach(SessionRuntimePolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy).help(policy.helpText)
                    }
                }
                .help(model.sessionRuntimePolicy.helpText)

                Toggle("Show thinking traces", isOn: $model.showThinkingTraces)
                Toggle("Accent composer on focus", isOn: $model.composerFocusAccent)
                Toggle(isOn: $htmlRenderEnabled) {
                    Text("Interactive HTML in replies")
                    Text("Lets the agent add small interactive controls to chat. Applies to sessions started after you change it.")
                }
            }

            Section("Terminal") {
                Picker("Terminal button opens", selection: $terminalButtonMode) {
                    ForEach(TerminalPaneMode.buttonChoices, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Picker("Open in Terminal uses", selection: $openInTerminalTarget) {
                    ForEach(OpenInTerminalTarget.allCases) { target in
                        Text(target.displayName).tag(target)
                    }
                }
            }

            Section("Quick Chats") {
                LabeledContent("Folder") {
                    Text(PiPaths.quickChatsProject.path)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Choose…") { chooseQuickChatsFolder() }
                    Button("Show in Finder") {
                        let folder = PiPaths.quickChatsProject
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                    Button("Reset to Default") { quickChatsFolder = "" }
                        .disabled(quickChatsFolder.isEmpty)
                }
            }

            Section("Notifications") {
                Toggle("Enable notifications", isOn: $model.notificationsEnabled)
                if notificationsDenied {
                    HStack {
                        Label("Notifications are turned off for PiG in System Settings.", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                Button("Send test notification in 10 seconds") {
                    model.scheduleTestNotification()
                }
                .disabled(!model.notificationsEnabled)
            }

            Section("Pi executable") {
                TextField("Override path", text: $piExecutablePath, prompt: Text(detectedPiPathLabel))
                    .onChange(of: piExecutablePath) { _, value in PiExecutablePreference.path = value }
                HStack {
                    piExecutableStatus
                    Spacer()
                    Button("Choose…") { choosePiExecutable() }
                    Button("Clear") { piExecutablePath = "" }
                        .disabled(piExecutablePath.isEmpty)
                }
            }

            Section("Extension status items") {
                if model.extensionStatusKeys.isEmpty {
                    Text("Status items appear here after an extension in a loaded session reports one.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.extensionStatusKeys, id: \.self) { key in
                        Toggle(
                            model.extensionStatusLabel(for: key),
                            isOn: Binding(
                                get: { !model.hiddenExtensionStatusKeys.contains(key) },
                                set: { visible in
                                    model.setExtensionStatusHidden(key, hidden: !visible)
                                }
                            )
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await refreshNotificationStatus()
            _ = await PiEnvironment.mergedAsync()
            detectedPiPath = PiPaths.detectedPiExecutable.path
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshNotificationStatus() }
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

    private var detectedPiPathLabel: String {
        detectedPiPath == "/usr/bin/env" ? "pi not found on PATH" : detectedPiPath
    }

    @ViewBuilder
    private var piExecutableStatus: some View {
        if let path = piExecutablePath.nonEmptyTrimmed {
            if FileManager.default.isExecutableFile(atPath: (path as NSString).expandingTildeInPath) {
                Label("Executable found", systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Label("Not found or not executable", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        } else {
            Label("Using auto-detected pi", systemImage: "magnifyingglass")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshNotificationStatus() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationsDenied = status == .denied
    }

    private func choosePiExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        let current = piExecutablePath.nonEmptyTrimmed.map { ($0 as NSString).expandingTildeInPath } ?? detectedPiPath
        panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent()
        panel.prompt = "Choose"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                piExecutablePath = url.path
            }
        }
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
