import SwiftUI

struct PiMaintenanceHost: View {
    @ObservedObject var controller: PiMaintenanceController
    let theme: AppThemeChoice

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .piChangelogSheet(controller: controller, window: .main, theme: theme)
    }
}

extension View {
    func piChangelogSheet(controller: PiMaintenanceController, window: PiChangelogWindow, theme: AppThemeChoice) -> some View {
        modifier(PiChangelogSheetModifier(controller: controller, window: window, theme: theme))
    }
}

private struct PiChangelogSheetModifier: ViewModifier {
    @Environment(\.appTheme) private var appTheme
    @ObservedObject var controller: PiMaintenanceController
    let window: PiChangelogWindow
    let theme: AppThemeChoice

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { controller.changelogWindow == window },
            set: { if !$0, controller.changelogWindow == window { controller.changelogWindow = nil } }
        )) {
            ChangelogView(controller: controller, theme: theme)
                .background(GlowPanelFill())
                .glowPresentationBackground()
                .environment(\.appTheme, appTheme)
        }
    }
}

private struct ChangelogView: View {
    @Environment(\.appTheme) private var appTheme
    @ObservedObject var controller: PiMaintenanceController
    let theme: AppThemeChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(controller.changelogTitle)
                    .font(AppFonts.heading(22, weight: .semibold))
                    .foregroundStyle(appTheme.text)
                Spacer()
                Button { controller.changelogWindow = nil } label: {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(appTheme.muted)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 24)
            .frame(height: 66)
            Divider().overlay(appTheme.line)
            ScrollView {
                NativeMarkdownView(
                    markdown: controller.changelogMarkdown,
                    role: .assistant,
                    theme: theme,
                    projectPath: PiMaintenancePaths.packageRootPath
                )
                .padding(28)
            }
        }
        .frame(width: 560, height: 660)
    }
}

enum PiMaintenancePaths {
    static var packageRootPath: String? {
        PiPaths.piDistIndex?.deletingLastPathComponent().deletingLastPathComponent().path
    }
}
