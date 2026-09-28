import SwiftUI
import AppKit

private struct ThemedRootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        RootView()
            .environment(\.appTheme, AppTheme(choice: model.selectedTheme, textSizeStep: model.textSizeStep))
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

    var body: some Scene {
        Window("PiG", id: "main") {
            ThemedRootView()
                .environmentObject(model)
                .preferredColorScheme(model.selectedTheme.isLight ? .light : .dark)
                .frame(minWidth: WindowLaunchDefaults.minimumSize.width, idealWidth: WindowLaunchDefaults.defaultSize.width, minHeight: WindowLaunchDefaults.minimumSize.height, idealHeight: WindowLaunchDefaults.defaultSize.height)
                .background {
                    TitlebarCustomActionsInstaller(model: model).frame(width: 0, height: 0)
                    MainWindowCloseGuard(appDelegate: appDelegate, model: model).frame(width: 0, height: 0)
                }
        }
        .windowStyle(.titleBar)
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
                    model.showNewChatHome()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Toggle("Show Sidebar", isOn: $model.sidebarVisible)
                    .keyboardShortcut("s", modifiers: .command)
                Button("New Quick Chat") {
                    model.showNewChatHome(quickChat: true)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Search Sessions") {
                    NotificationCenter.default.post(name: .pigRevealSidebarSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
                Divider()
                ForEach(Array(quickModels.enumerated()), id: \.offset) { slot, id in
                    Button("Quick Model \(slot + 1)") {
                        model.activeComposerController?.setModel(id)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(slot + 1))), modifiers: .command)
                    .disabled(id.isEmpty || model.activeComposerController?.models.contains(where: { $0.id == id }) != true)
                }
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
                Button("Pi Updates…") {
                    model.piMaintenance.presentUpdates(
                        cwd: model.selectedController?.projectPath ?? model.selectedProjectPath ?? PiPaths.home.path,
                        projectName: model.selectedProject?.displayName
                    )
                }
                Button("What’s New in Pi…") {
                    model.piMaintenance.openChangelog()
                }
                Divider()
                Button("Unload Other Idle Sessions") {
                    model.unloadOtherSessions(keeping: model.selectedController)
                }
                Button("Unload All Idle Sessions") {
                    model.unloadAllIdleSessions()
                }
            }
        }

        Settings {
            TabView {
                GeneralSettingsView()
                    .tabItem { Label("General", systemImage: "gearshape") }
                ModelsSettingsView()
                    .tabItem { Label("Models", systemImage: "cpu") }
            }
            .frame(width: 600, height: 680)
            .environmentObject(model)
            .preferredColorScheme(model.selectedTheme.isLight ? .light : .dark)
        }
    }

    private var quickModels: [String] {
        [quickModel1, quickModel2, quickModel3, quickModel4, quickModel5]
    }
}
