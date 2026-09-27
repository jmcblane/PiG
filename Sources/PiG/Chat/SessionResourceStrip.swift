import SwiftUI

/// Pinned global defaults are informational; only disabled resources can be added to this draft.
struct SessionResourceStrip: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    @ObservedObject var controller: SessionController
    @State private var resources: [PiResourceItem] = []

    private var pinned: [PiResourceItem] {
        let byID = Dictionary(uniqueKeysWithValues: resources.map { ($0.id, $0) })
        return model.pinnedResourceIDs.compactMap { byID[$0] }.filter { $0.type != "themes" }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !pinned.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(pinned) { item in
                            let added = controller.chatResources.contains { $0.id == item.id }
                            if item.enabled {
                                resourceLabel(item, symbol: "checkmark")
                                    .foregroundStyle(appTheme.muted)
                                    .background(appTheme.panel2, in: RoundedRectangle(cornerRadius: 6))
                                    .help("On for every chat. Change it in Pi Resources.")
                            } else {
                                Button {
                                    let updated = added
                                        ? controller.chatResources.filter { $0.id != item.id }
                                        : controller.chatResources + [item]
                                    model.updateLandingResources(updated, for: controller)
                                } label: {
                                    resourceLabel(item, symbol: added ? "checkmark" : "plus")
                                        .foregroundStyle(added ? appTheme.brass : appTheme.muted)
                                        .background(added ? appTheme.brass.opacity(0.12) : Color.clear,
                                                    in: RoundedRectangle(cornerRadius: 6))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 6)
                                                .strokeBorder(added ? appTheme.brass.opacity(0.7) : appTheme.line,
                                                              style: StrokeStyle(lineWidth: 1, dash: added ? [] : [3, 2]))
                                        }
                                }
                                .buttonStyle(.plain)
                                .help(added ? "Remove from this chat" : "Add to this chat only")
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { appTheme.line.frame(height: 1) }
            }
        }
        .task { await load() }
    }

    private func resourceLabel(_ item: PiResourceItem, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(AppFonts.ui(9, weight: .semibold))
            Text(item.displayName)
                .lineLimit(1)
            if item.type != "extensions" {
                Text(item.type == "skills" ? "skill" : "prompt")
                    .font(AppFonts.ui(9))
                    .opacity(0.8)
            }
        }
        .font(AppFonts.ui(11, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private func load() async {
        do {
            let listed = try await PiResourceService.list()
            guard !Task.isCancelled else { return }
            resources = listed
            let allowed = Set(pinned.filter { !$0.enabled }.map(\.id))
            model.updateLandingResources(controller.chatResources.filter { allowed.contains($0.id) }, for: controller)
        } catch {
            if !Task.isCancelled { resources = [] }
        }
    }
}

struct ChatResourceChips: View {
    @Environment(\.appTheme) private var appTheme
    let items: [PiResourceItem]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items) { item in
                    Text(item.displayName + (item.type == "extensions" ? "" : " · \(item.type == "skills" ? "skill" : "prompt")"))
                        .foregroundStyle(appTheme.brass)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(appTheme.panel2, in: RoundedRectangle(cornerRadius: 5))
                        .help("Added for this chat only · \(item.path)")
                }
            }
            .font(AppFonts.ui(10.5))
        }
    }
}
