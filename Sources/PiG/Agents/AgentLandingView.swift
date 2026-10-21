import SwiftUI

/// Agent home uses the same bottom-aligned header/composer/recents layout as project home.
struct AgentLandingView: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    let agent: Agent
    @State private var projectMenuOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent")
                        .font(AppFonts.heading(15, weight: .semibold))
                        .foregroundStyle(appTheme.text)
                    if agent.backend == .pi {
                        let sessions = model.recentSessions(forAgentID: agent.id)
                        if sessions.isEmpty {
                            EmptyState(text: "No recent sessions", icon: "clock")
                                .frame(maxWidth: .infinity, minHeight: 110)
                        }
                        ForEach(sessions) { session in SessionRow(summary: session) }
                    } else {
                        let chats = model.recentHermesChats(forAgentID: agent.id)
                        if chats.isEmpty {
                            EmptyState(text: "No recent chats", icon: "clock")
                                .frame(maxWidth: .infinity, minHeight: 110)
                        }
                        ForEach(chats) { chat in
                            Button {
                                model.selectHermesChat(agentID: agent.id, chatID: chat.id)
                            } label: {
                                Text(chat.title)
                                    .font(AppFonts.ui(13.5))
                                    .foregroundStyle(appTheme.secondaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .frame(maxHeight: 290)
            HStack(spacing: 12) {
                AgentAvatar(look: agent.look, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Button { projectMenuOpen.toggle() } label: {
                        HStack(spacing: 8) {
                            Text(agent.name)
                                .font(AppFonts.heading(26, weight: .semibold))
                                .foregroundStyle(appTheme.text)
                            Image(systemName: "chevron.down")
                                .font(AppFonts.ui(9, weight: .bold))
                                .foregroundStyle(appTheme.muted)
                        }
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $projectMenuOpen, arrowEdge: .bottom) {
                        ProjectPickerMenu(width: 620, showsQuickChat: true,
                                          isSelected: { _ in false },
                                          selectProject: { model.showNewChatHome(projectPath: $0) },
                                          selectQuickChat: { model.showNewChatHome(quickChat: true) },
                                          dismiss: { projectMenuOpen = false })
                    }
                    Text(agent.role)
                        .font(AppFonts.ui(12.5))
                        .foregroundStyle(appTheme.muted)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 18)
            .layoutPriority(1)
            if agent.backend == .pi, let controller = model.landingDraftController {
                ComposerView(controller: controller,
                             draft: $model.landingDraftText,
                             imageAttachments: $model.landingDraftImages,
                             beforeSubmit: { model.activateLandingDraft(controller) },
                             focusOnAppear: true)
                    .layoutPriority(1)
            } else if let controller = model.hermesLandingDraftController {
                HermesComposerView(controller: controller, draft: $model.landingDraftText,
                                   beforeSubmit: { model.activateHermesLandingDraft(controller) })
                    .layoutPriority(1)
            }
        }
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}
