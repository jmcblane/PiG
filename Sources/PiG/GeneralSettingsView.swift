import SwiftUI
import AppKit

struct GeneralSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var piExecutablePath = PiExecutablePreference.path ?? ""
    @State private var detectedPiPath = PiPaths.detectedPiExecutable.path
    @AppStorage(QuickChatsFolderPreference.key) private var quickChatsFolder = ""

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $model.selectedTheme) {
                    ForEach(AppThemeChoice.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }

                HStack {
                    Text("Text size")
                    Spacer()
                    Button { model.textSizeStep -= 1 } label: { Image(systemName: "minus") }
                        .disabled(model.textSizeStep == 0)
                    Text("\(Int(TextSizePreference.steps[model.textSizeStep] * 100))%")
                        .frame(width: 52)
                    Button { model.textSizeStep += 1 } label: { Image(systemName: "plus") }
                        .disabled(model.textSizeStep == TextSizePreference.steps.count - 1)
                    Button("Actual Size") { model.textSizeStep = TextSizePreference.actualSizeStep }
                        .disabled(model.textSizeStep == TextSizePreference.actualSizeStep)
                }

                Picker("Project headers", selection: $model.projectHeaderStyle) {
                    ForEach(ProjectHeaderStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
            }

            Section("Pi executable") {
                TextField("Override path", text: $piExecutablePath)
                    .onChange(of: piExecutablePath) { _, value in PiExecutablePreference.path = value }
                Text("Auto-detected: \(detectedPiPath == "/usr/bin/env" ? "pi not found" : detectedPiPath)")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section("Sessions") {
                Picker("Runtime", selection: $model.sessionRuntimePolicy) {
                    ForEach(SessionRuntimePolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }

                Toggle("Show thinking traces", isOn: $model.showThinkingTraces)
                Toggle("Accent composer on focus", isOn: $model.composerFocusAccent)
            }

            Section("Quick Chats") {
                LabeledContent("Folder") {
                    Text(quickChatsFolder.isEmpty ? PiPaths.defaultQuickChatsProject.path : PiPaths.quickChatsProject.path)
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
                Button("Send test notification in 10 seconds") {
                    model.scheduleTestNotification()
                }
                .disabled(!model.notificationsEnabled)
            }

            Section("Extension status items") {
                if model.extensionStatusKeys.isEmpty {
                    Text("No extension status items are available.")
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
        .padding(12)
        .task {
            _ = await PiEnvironment.mergedAsync()
            detectedPiPath = PiPaths.detectedPiExecutable.path
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
