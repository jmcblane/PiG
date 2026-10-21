import SwiftUI

struct AgentsSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pendingRemoval: Agent?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Agents").font(.title2)
                Spacer()
                Menu("Add Agent") {
                    Button("New Pi Agent…") { model.requestNewAgent(backend: .pi, fromSettings: true) }
                    Button("New Hermes Agent…") { model.requestNewAgent(backend: .hermes, fromSettings: true) }
                }
            }
            List {
                ForEach(Array(model.agents.enumerated()), id: \.element.id) { index, agent in
                    HStack(spacing: 10) {
                        AgentAvatar(look: agent.look, size: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(agent.name).font(.headline)
                            Text(agent.role).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            model.moveAgent(agent.id, relativeTo: model.agents[index - 1].id, after: false)
                        } label: { Image(systemName: "arrow.up") }
                        .disabled(index == 0)
                        .help("Move up")
                        Button {
                            model.moveAgent(agent.id, relativeTo: model.agents[index + 1].id, after: true)
                        } label: { Image(systemName: "arrow.down") }
                        .disabled(index == model.agents.count - 1)
                        .help("Move down")
                        Button("Edit…") { model.requestEditAgent(agent.id, fromSettings: true) }
                        Button("Remove…") { pendingRemoval = agent }
                    }
                    .padding(.vertical, 5)
                }
            }
            Text("Agents start ordinary chats. Removing an agent keeps its chats.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .alert("Remove \(pendingRemoval?.name ?? "Agent")?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), presenting: pendingRemoval) { agent in
            Button("Remove", role: .destructive) { model.removeAgent(agent.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("The agent will be removed. Chats are kept.") }
    }
}
