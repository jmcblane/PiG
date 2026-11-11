import SwiftUI

struct AgentsSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appTheme) private var appTheme
    @State private var removalDialog: GlowDialogRequest?
    @State private var addMenuOpen = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                GlowSection(footer: "Agents start ordinary chats. Removing an agent keeps its chats.") {
                    if model.agents.isEmpty {
                        GlowBlockRow {
                            Text("No agents yet.")
                                .font(AppFonts.ui(12.5))
                                .foregroundStyle(appTheme.muted)
                        }
                    }
                    ForEach(Array(model.agents.enumerated()), id: \.element.id) { index, agent in
                        agentRow(agent, index: index)
                    }
                }
            }
            .padding(20)
        }
        // Settings is its own window, so it hosts its own dialog instead of RootView's.
        .glowDialog($removalDialog)
    }

    private func requestRemoval(_ agent: Agent) {
        let model = model
        removalDialog = GlowDialogRequest(
            title: "Remove \(agent.name)?",
            message: "The agent will be removed. Chats are kept.",
            confirmTitle: "Remove",
            role: .destructive,
            onConfirm: { _ in model.removeAgent(agent.id) }
        )
    }

    private var header: some View {
        HStack {
            Text("Agents")
                .font(AppFonts.heading(17))
                .foregroundStyle(appTheme.text)
            Spacer()
            Button("Add Agent") { addMenuOpen.toggle() }
                .buttonStyle(GlowButtonStyle(kind: .primary))
                .popover(isPresented: $addMenuOpen, arrowEdge: .bottom) {
                    addMenu
                }
        }
        .padding(.horizontal, 4)
    }

    private var addMenu: some View {
        VStack(spacing: 0) {
            PopoverPickerRow(title: "New Pi Agent…", icon: "person.badge.plus", checkmarkColumn: false) {
                addMenuOpen = false
                model.requestNewAgent(backend: .pi, fromSettings: true)
            }
            PopoverPickerRow(title: "New Hermes Agent…", icon: "antenna.radiowaves.left.and.right", checkmarkColumn: false) {
                addMenuOpen = false
                model.requestNewAgent(backend: .hermes, fromSettings: true)
            }
        }
        .padding(.vertical, 6)
        .frame(minWidth: 220)
        .fixedSize()
        .glowPresentationBackground()
        .environment(\.appTheme, appTheme)
    }

    private func agentRow(_ agent: Agent, index: Int) -> some View {
        GlowBlockRow {
            HStack(spacing: 10) {
                AgentAvatar(look: agent.look, size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(agent.name)
                        .font(AppFonts.ui(13, weight: .semibold))
                        .foregroundStyle(appTheme.text)
                    Text(agent.role)
                        .font(AppFonts.ui(12))
                        .foregroundStyle(appTheme.muted)
                }
                Spacer()
                Button {
                    model.moveAgent(agent.id, relativeTo: model.agents[index - 1].id, after: false)
                } label: { MoveIcon(symbol: "arrow.up") }
                .buttonStyle(.plain)
                .disabled(index == 0)
                .help("Move up")
                .accessibilityLabel("Move up")
                Button {
                    model.moveAgent(agent.id, relativeTo: model.agents[index + 1].id, after: true)
                } label: { MoveIcon(symbol: "arrow.down") }
                .buttonStyle(.plain)
                .disabled(index == model.agents.count - 1)
                .help("Move down")
                .accessibilityLabel("Move down")
                Button("Edit…") { model.requestEditAgent(agent.id, fromSettings: true) }
                    .buttonStyle(GlowButtonStyle())
                Button("Remove…") { requestRemoval(agent) }
                    .buttonStyle(GlowButtonStyle(kind: .destructive))
            }
            .padding(.vertical, 2)
        }
    }
}

/// Up/down arrow for reordering, dimmed when its button is disabled.
private struct MoveIcon: View {
    @Environment(\.appTheme) private var appTheme
    @Environment(\.isEnabled) private var isEnabled
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(AppFonts.ui(11, weight: .semibold))
            .foregroundStyle(appTheme.secondaryText)
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(appTheme.panel))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(appTheme.line, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(Rectangle())
    }
}
