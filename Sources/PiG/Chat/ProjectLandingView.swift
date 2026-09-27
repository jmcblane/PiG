import SwiftUI
import AppKit
import ImageIO

struct ChatTabContent: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    let controller: SessionController?
    let selectedProjectPath: String?
    let theme: AppThemeChoice
    @Binding var draft: String
    @Binding var imageAttachments: [ImageAttachment]

    var body: some View {
        VStack(spacing: 0) {
            if let controller {
                ChatScrollView(controller: controller, theme: theme)
                    .id(controller.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Chat errors surface via the single arbitrated toast in
                // RootView plus the 'Last error' affordance near the composer.
                ExtensionWidgetsView(widgets: widgets(for: controller, placement: .aboveEditor))
                ExtensionStatusView(statuses: controller.extensionUIStatuses)
                if !controller.chatResources.isEmpty {
                    ChatResourceChips(items: controller.chatResources)
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                }
                ComposerView(controller: controller, draft: $draft, imageAttachments: $imageAttachments)
                ExtensionWidgetsView(widgets: widgets(for: controller, placement: .belowEditor))
                    .padding(.top, -10)
            } else if let selectedProjectPath {
                ProjectLandingView(projectPath: selectedProjectPath)
                    .id("\(selectedProjectPath)|\(model.newChatHomeRequestID)")
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "terminal")
                        .font(AppFonts.ui(42, weight: .light))
                        .foregroundStyle(appTheme.brass)
                    Text("Select or create a session")
                        .font(AppFonts.heading(24, weight: .semibold))
                        .foregroundStyle(appTheme.text)
                    Text("Open a project from the sidebar, or start here.")
                        .font(AppFonts.ui(13.5))
                        .foregroundStyle(appTheme.muted)
                    HStack(spacing: 10) {
                        Button {
                            model.showNewChatHome(quickChat: true)
                        } label: {
                            Label("New Quick Chat", systemImage: "bubble.left.and.bubble.right")
                        }
                        .buttonStyle(ProjectLandingPrimaryButtonStyle())
                        Button {
                            model.addExistingProject()
                        } label: {
                            Label("Add Project", systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(ProjectLandingSecondaryButtonStyle())
                    }
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            ExtensionWindowTitleView(title: controller?.extensionWindowTitle ?? controller?.title ?? "PiG")
                .frame(width: 0, height: 0)
        }
    }

    private func widgets(for controller: SessionController, placement: ExtensionUIWidget.Placement) -> [ExtensionUIWidget] {
        controller.extensionUIWidgets.values
            .filter { $0.placement == placement }
            .sorted { $0.key < $1.key }
    }
}

private struct ProjectLandingView: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    let projectPath: String
    @State private var projectMenuOpen = false

    private var projectName: String {
        if model.composingQuickChat { return "Quick Chat" }
        return model.projectDisplayName(for: projectPath)
    }

    private var recentSessions: [SessionSummary] {
        model.recentSessions(forProjectPath: projectPath, limit: 5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            if !model.composingQuickChat {
                ScrollView {
                    recentSessionsSection
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
                .frame(maxHeight: 290)
            }
            projectHeader
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 18)
                .layoutPriority(1)
            projectComposer
                .layoutPriority(1)
        }
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onAppear { model.prepareLandingDraft() }
    }

    private var projectHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: model.composingQuickChat ? "bolt.fill" : "folder.fill")
                .font(AppFonts.ui(28, weight: .semibold))
                .foregroundStyle(model.composingQuickChat ? Color.yellow.opacity(0.88) : appTheme.brass)
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    projectMenuOpen.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Text(projectName)
                            .font(AppFonts.heading(26, weight: .semibold))
                            .foregroundStyle(appTheme.text)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(AppFonts.ui(9, weight: .bold))
                            .foregroundStyle(appTheme.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $projectMenuOpen, arrowEdge: .bottom) {
                    ProjectPickerMenu(
                        width: 300,
                        showsQuickChat: true,
                        isSelected: { !model.composingQuickChat && $0.path == projectPath },
                        selectProject: { model.showNewChatHome(projectPath: $0) },
                        quickChatSelected: model.composingQuickChat,
                        selectQuickChat: { model.showNewChatHome(quickChat: true) },
                        dismiss: { projectMenuOpen = false }
                    )
                }
                Text(model.composingQuickChat ? "Temporary conversation" : projectPath.abbreviatingHomeDirectory())
                    .font(AppFonts.ui(12.5))
                    .foregroundStyle(appTheme.muted)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    @ViewBuilder private var projectComposer: some View {
        if let controller = model.landingDraftController {
            ComposerView(
                controller: controller,
                draft: $model.landingDraftText,
                imageAttachments: $model.landingDraftImages,
                beforeSubmit: { model.activateLandingDraft(controller) },
                focusOnAppear: true,
                showsLandingResources: true
            )
        } else {
            SignalMarchLoadingLabel(text: "Loading composer…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        }
    }

    private var recentSessionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent")
                    .font(AppFonts.heading(15, weight: .semibold))
                    .foregroundStyle(appTheme.text)
                Spacer()
                Button {
                    NotificationCenter.default.post(name: .pigRevealSidebarSearch, object: nil)
                } label: {
                    Text("Search all ⌘F")
                }
                .buttonStyle(.plain)
                .font(AppFonts.ui(12.5))
                .foregroundStyle(appTheme.brass)
            }
            if recentSessions.isEmpty {
                EmptyState(text: "No recent sessions", icon: "clock")
                    .frame(maxWidth: .infinity, minHeight: 110)
            } else {
                VStack(spacing: 2) {
                    ForEach(recentSessions) { session in
                        SessionRow(summary: session)
                    }
                }
            }
        }
    }
}

private struct ProjectLandingPrimaryButtonStyle: ButtonStyle {
    @Environment(\.appTheme) private var appTheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFonts.ui(13.5, weight: .semibold))
            .foregroundStyle(appTheme.accentForeground)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(appTheme.brass.opacity(configuration.isPressed ? 0.82 : 1)))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct ProjectLandingSecondaryButtonStyle: ButtonStyle {
    @Environment(\.appTheme) private var appTheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFonts.ui(13.5, weight: .semibold))
            .foregroundStyle(appTheme.text)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(appTheme.panel2.opacity(configuration.isPressed ? 0.7 : 1)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(appTheme.line.opacity(0.8), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
