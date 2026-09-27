import SwiftUI
import AppKit
import ImageIO

struct ComposerToolbar: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var controller: SessionController
    @State private var usageProvider: UsageLimitProvider?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 0) {
                ModelPickerMenu(controller: controller, value: selectedModelName)
                    .help("Model")

                ThinkingPickerMenu(controller: controller)
                    .help("Reasoning")
            }
            .fixedSize(horizontal: false, vertical: true)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 4) {
                if let usageProvider {
                    UsageLimitIndicator(snapshot: model.usageLimit(for: usageProvider)) { model.refreshUsageLimit(for: usageProvider) }
                }
                ContextUsageBar(percent: controller.contextPercent, tokens: controller.contextTokens, window: controller.contextWindow)
            }
            .frame(width: 118, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .task(id: selectedModel) {
            _ = await PiEnvironment.mergedAsync()
            let provider = UsageLimitProvider.from(model: selectedModel)
            guard !Task.isCancelled else { return }
            usageProvider = provider
            model.refreshUsageLimit(for: provider)
        }
    }

    private var selectedModel: ModelInfo? {
        controller.models.first(where: { $0.id == controller.selectedModelID })
    }

    private var selectedModelName: String {
        if controller.models.isEmpty { return "Loading…" }
        return selectedModel?.displayName ?? controller.selectedModelID.nonEmptyTrimmed ?? "Select model"
    }

}

struct ModelPickerMenu: View {
    @Environment(\.appTheme) private var appTheme
    @ObservedObject var controller: SessionController
    let value: String
    @State private var isOpen = false
    @State private var hovering = false
    @State private var pinnedIDs: [String] = PinnedModels.ids
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    private var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func matchesSearch(_ model: ModelInfo) -> Bool {
        model.displayName.lowercased().contains(normalizedSearch) ||
        model.id.lowercased().contains(normalizedSearch)
    }

    var body: some View {
        Button {
            pinnedIDs = PinnedModels.ids
            if !isOpen { searchText = "" }
            isOpen.toggle()
            if isOpen {
                DispatchQueue.main.async { searchFocused = true }
            }
        } label: {
            TabStripPickerLabel(value: value, dot: appTheme.brass, hovering: hovering)
        }
        .buttonStyle(.plain)
        .background(hovering ? Color.white.opacity(0.03) : Color.clear)
        .onHover { hovering = $0 }
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            menuContent
        }
    }

    private var pinnedModels: [ModelInfo] {
        let byID = Dictionary(uniqueKeysWithValues: controller.models.map { ($0.id, $0) })
        let base = pinnedIDs.compactMap { byID[$0] }
        guard !normalizedSearch.isEmpty else { return base }
        return base.filter { matchesSearch($0) }
    }
    private var unpinnedModels: [ModelInfo] {
        let base = controller.models.filter { !pinnedIDs.contains($0.id) }
        guard !normalizedSearch.isEmpty else { return base }
        return base.filter { matchesSearch($0) }
    }

    private var menuContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(AppFonts.ui(11, weight: .semibold))
                    .foregroundStyle(appTheme.muted)
                TextField("Search models", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(AppFonts.ui(12.5))
                    .focused($searchFocused)
                    .foregroundStyle(appTheme.text)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(appTheme.muted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(appTheme.panel2.opacity(0.65))

            PopoverMenuDivider()

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !controller.hasCompleteModelCatalog {
                    Text(controller.isDiscoveringModels ? "Loading all available models…" : "Available models may be incomplete")
                        .font(AppFonts.ui(12.5))
                        .foregroundStyle(appTheme.muted)
                        .padding(10)
                    if !controller.models.isEmpty {
                        PopoverMenuDivider()
                    }
                }
                if pinnedModels.isEmpty && unpinnedModels.isEmpty {
                    if !controller.models.isEmpty {
                        Text("No matching models")
                            .font(AppFonts.ui(12.5))
                            .foregroundStyle(appTheme.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                    }
                } else {
                ForEach(pinnedModels) { model in
                    modelRow(model)
                }
                if !pinnedModels.isEmpty && !unpinnedModels.isEmpty {
                    PopoverMenuDivider()
                }
                ForEach(unpinnedModels) { model in
                    modelRow(model)
                }
                }
            }
            .padding(.vertical, 5)
            .padding(.trailing, 12)
            }
        }
        .frame(width: 320)
        .frame(maxHeight: 420)
    }

    private func modelRow(_ model: ModelInfo) -> some View {
        ModelPickerRow(
            model: model,
            isSelected: model.id == controller.selectedModelID,
            isPinned: pinnedIDs.contains(model.id),
            select: {
                controller.setModel(model.id)
                isOpen = false
            },
            togglePin: {
                PinnedModels.toggle(model.id)
                pinnedIDs = PinnedModels.ids
            }
        )
    }
}

struct ThinkingPickerMenu: View {
    @Environment(\.appTheme) private var appTheme
    @ObservedObject var controller: SessionController
    @State private var isOpen = false
    @State private var hovering = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            TabStripPickerLabel(
                value: controller.thinkingLevel.capitalized,
                dot: appTheme.codeText,
                hovering: hovering
            )
        }
        .buttonStyle(.plain)
        .background(hovering ? Color.white.opacity(0.03) : Color.clear)
        .onHover { hovering = $0 }
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(controller.availableThinkingLevels, id: \.self) { level in
                    PopoverPickerRow(title: level.capitalized, isSelected: level == controller.thinkingLevel) {
                        controller.setThinkingLevel(level)
                        isOpen = false
                    }
                }
            }
            .padding(.vertical, 5)
            .frame(width: 130)
        }
    }
}

private struct TabStripPickerLabel: View {
    @Environment(\.appTheme) private var appTheme
    let value: String
    let dot: Color
    let hovering: Bool

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(dot)
                .frame(width: 5, height: 5)
            Text(value)
                .font(AppFonts.ui(11.5, weight: .semibold))
                .foregroundStyle(hovering ? appTheme.text : appTheme.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

private struct ModelPickerRow: View {
    @Environment(\.appTheme) private var appTheme
    let model: ModelInfo
    let isSelected: Bool
    let isPinned: Bool
    let select: () -> Void
    let togglePin: () -> Void
    @State private var hoveringStar = false

    var body: some View {
        PopoverPickerRow(title: model.displayName, isSelected: isSelected, action: select) { rowHovering in
            Button(action: togglePin) {
                Image(systemName: isPinned ? "star.fill" : "star")
                    .font(AppFonts.ui(11))
                    .foregroundStyle(isPinned || hoveringStar ? appTheme.brass : appTheme.muted)
                    .opacity(isPinned || hoveringStar ? 1 : (rowHovering ? 0.9 : 0.35))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringStar = $0 }
            .help(isPinned ? "Unpin" : "Pin to top")
        }
        .contextMenu {
            Button(isPinned ? "Unpin" : "Pin to Top", action: togglePin)
        }
    }
}
