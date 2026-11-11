import SwiftUI
import AppKit

private struct ThemedRootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        RootView()
            .environment(\.appTheme, AppTheme(choice: model.selectedTheme, textStyle: model.textStyle))
    }
}

@main
struct PiGApp: App {
    @NSApplicationDelegateAdaptor(PiGAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @AppStorage(QuickModelSlots.key(1)) private var quickModel1 = ""
    @AppStorage(QuickModelSlots.key(2)) private var quickModel2 = ""
    @AppStorage(QuickModelSlots.key(3)) private var quickModel3 = ""
    @AppStorage(QuickModelSlots.key(4)) private var quickModel4 = ""
    @AppStorage(QuickModelSlots.key(5)) private var quickModel5 = ""
    @AppStorage(InboxColumn.visibilityKey) private var inboxVisible = true

    var body: some Scene {
        Window("PiG", id: "main") {
            ThemedRootView()
                .environmentObject(model)
                .preferredColorScheme(model.selectedTheme.isLight ? .light : .dark)
                .frame(minWidth: WindowLaunchDefaults.minimumSize.width, idealWidth: WindowLaunchDefaults.defaultSize.width, minHeight: WindowLaunchDefaults.minimumSize.height, idealHeight: WindowLaunchDefaults.defaultSize.height)
                .background {
                    MainWindowCloseGuard(appDelegate: appDelegate, model: model).frame(width: 0, height: 0)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: WindowLaunchDefaults.defaultSize.width, height: WindowLaunchDefaults.defaultSize.height)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await model.appUpdates.check(manual: true) }
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    if let agent = model.selectedAgent {
                        model.selectAgent(agent.id)
                    } else {
                        model.showNewChatHome()
                    }
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("New Quick Chat") {
                    model.showNewChatHome(quickChat: true)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Reopen Last Done Chat") { model.undoLastInboxDismissal() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(!model.canUndoInboxDismissal)
            }
            CommandGroup(after: .textEditing) {
                Divider()
                Button("Find in Chat") {
                    NotificationCenter.default.post(name: .pigFindInChat, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
                Button("Find Next") {
                    NotificationCenter.default.post(name: .pigFindNext, object: nil)
                }
                .keyboardShortcut("g", modifiers: .command)
                Button("Find Previous") {
                    NotificationCenter.default.post(name: .pigFindPrevious, object: nil)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Toggle("Expand Open Chats", isOn: $inboxVisible.animation(.smooth(duration: 0.22)))
                    .keyboardShortcut("s", modifiers: .command)
                Divider()
                Button("Bigger Text") { model.textSizeStep += 1 }
                    .keyboardShortcut("=", modifiers: .command)
                    .disabled(model.textSizeStep >= TextSizePreference.steps.count - 1)
                Button("Smaller Text") { model.textSizeStep -= 1 }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(model.textSizeStep <= 0)
                Button("Actual Size") { model.textSizeStep = TextSizePreference.actualSizeStep }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(model.textSizeStep == TextSizePreference.actualSizeStep)
                Divider()
                Button("Toggle Fullscreen Terminal") {
                    NotificationCenter.default.post(name: .pigToggleFullscreenTerminal, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Open Vertical Terminal Split") {
                    NotificationCenter.default.post(name: .pigOpenVerticalTerminalSplit, object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)
                Button("Open Horizontal Terminal Split") {
                    NotificationCenter.default.post(name: .pigOpenHorizontalTerminalSplit, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            CommandMenu("Go") {
                Button("Go to Anything…") {
                    NotificationCenter.default.post(name: .pigOpenPalette, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
                Button("Search Chats…") {
                    NotificationCenter.default.post(name: .pigOpenPalette, object: PaletteScope.sessions.rawValue)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
            CommandMenu("Chat") {
                ForEach(Array(quickModels.enumerated()), id: \.offset) { slot, id in
                    let quickModel = id.isEmpty ? nil : model.activeComposerController?.models.first(where: { $0.id == id })
                    Button(quickModel?.name ?? "Quick Model \(slot + 1)") {
                        model.activeComposerController?.setModel(id)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(slot + 1))), modifiers: .command)
                    .disabled(quickModel == nil)
                }
                Divider()
                Button("Unload Other Idle Chats") {
                    model.unloadOtherSessions(keeping: model.selectedController)
                }
                Button("Unload All Idle Chats") {
                    model.unloadAllIdleSessions()
                }
            }
        }

        Settings {
            SettingsWindowView()
                .frame(width: 600, height: 800)
                .environmentObject(model)
                .environment(\.appTheme, AppTheme(choice: model.selectedTheme, textStyle: model.textStyle))
                .preferredColorScheme(model.selectedTheme.isLight ? .light : .dark)
                .sheet(item: Binding(
                    get: { model.agentEditorInSettings ? model.agentEditorRequest : nil },
                    set: { model.agentEditorRequest = $0 }
                )) { request in
                    AgentEditorView(request: request)
                        .environmentObject(model)
                        .environment(\.appTheme, AppTheme(choice: model.selectedTheme, textStyle: model.textStyle))
                }
        }
    }

    private var quickModels: [String] {
        [quickModel1, quickModel2, quickModel3, quickModel4, quickModel5]
    }
}
