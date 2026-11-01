import SwiftUI
import AppKit
import ImageIO

/// Model, thinking level, and subscription usage, shown under the composer.
struct ComposerToolbar: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var controller: SessionController
    @State private var usageProvider: UsageLimitProvider?

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            ModelPickerMenu(controller: controller, value: selectedModelName)
                .help("Model (⌘1–⌘5)")
            ThinkingDial(controller: controller)
            Spacer(minLength: 8)
            if let usageProvider {
                Group {
                    if usageProvider == .claudeBridge {
                        UsageLimitIndicator(
                            snapshot: controller.claudeBridgeUsage ?? UsageLimitSnapshot(serviceName: "Claude Code"),
                            pendingText: "Waiting for Claude Code quota data…"
                        ) { }
                    } else {
                        UsageLimitIndicator(snapshot: model.usageLimit(for: usageProvider)) { model.refreshUsageLimit(for: usageProvider) }
                    }
                }
                .frame(width: 84)
            }
        }
        .padding(.leading, 44)
        .padding(.trailing, 14)
        .task(id: selectedModel) {
            _ = await PiEnvironment.mergedAsync()
            let provider = UsageLimitProvider.from(model: selectedModel)
            guard !Task.isCancelled else { return }
            usageProvider = provider
            if provider != .claudeBridge { model.refreshUsageLimit(for: provider) }
        }
    }

    private var selectedModel: ModelInfo? {
        controller.models.first(where: { $0.id == controller.selectedModelID })
    }

    private var selectedModelName: String {
        if controller.models.isEmpty { return "Loading…" }
        guard let selectedModel else { return controller.selectedModelID.nonEmptyTrimmed ?? "Select model" }
        return selectedModel.name.isEmpty ? selectedModel.modelId : selectedModel.name
    }
}

/// Thinking level as rising bars. Click steps to the next level; right-click picks one.
struct ThinkingDial: View {
    @Environment(\.appTheme) private var appTheme
    @ObservedObject var controller: SessionController
    @State private var hovering = false

    private var levels: [String] { controller.availableThinkingLevels }
    private var index: Int { levels.firstIndex(of: controller.thinkingLevel) ?? 0 }

    var body: some View {
        Button {
            guard !levels.isEmpty else { return }
            controller.setThinkingLevel(levels[(index + 1) % levels.count])
        } label: {
            HStack(spacing: 6) {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(1..<max(2, levels.count), id: \.self) { bar in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(bar <= index ? appTheme.brass : appTheme.muted.opacity(0.45))
                            .frame(width: 3, height: 3 + CGFloat(bar) * 9 / CGFloat(max(1, levels.count - 1)))
                    }
                }
                .frame(height: 12, alignment: .bottom)
                Text(Self.title(controller.thinkingLevel))
                    .font(AppFonts.ui(11.5, weight: .medium))
                    .foregroundStyle(hovering ? appTheme.text : appTheme.secondaryText)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Thinking level")
        .contextMenu {
            ForEach(levels, id: \.self) { level in
                Button {
                    controller.setThinkingLevel(level)
                } label: {
                    if level == controller.thinkingLevel {
                        Label(Self.title(level), systemImage: "checkmark")
                    } else {
                        Text(Self.title(level))
                    }
                }
            }
        }
    }

    static func title(_ level: String) -> String {
        level == "xhigh" ? "Extra high" : level.capitalized
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

struct TabStripPickerLabel: View {
    @Environment(\.appTheme) private var appTheme
    let value: String
    var dot: Color? = nil
    let hovering: Bool

    var body: some View {
        Text(value)
            .font(AppFonts.ui(11.5, weight: .medium))
            .foregroundStyle(hovering ? appTheme.text : appTheme.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
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
