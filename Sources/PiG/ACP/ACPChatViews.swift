import SwiftUI
import AppKit

/// Full-featured composer for Antigravity ACP chats, matching PiG's `ComposerView` chrome.
struct ACPComposerView: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    @ObservedObject var controller: ACPChatController
    @Binding var draft: String
    @Binding var imageAttachments: [ImageAttachment]
    var beforeSubmit: (() -> Void)? = nil
    var focusOnAppear = false

    @State private var entryHeight: CGFloat = 36
    @State private var fileSuggestions: [ComposerFileSuggestion] = []
    @State private var suggestionIndex = 0
    @State private var suggestionsDismissed = false
    @State private var isFocused = false
    @State private var focusRequest = 0
    @State private var cursorEndRequest = 0

    private let shellRadius: CGFloat = 18

    var body: some View {
        let slash = displayedSlashSuggestions
        let files = displayedFileSuggestions
        let accentFocus = model.composerFocusAccent && isFocused

        VStack(spacing: 8) {
            if controller.authRequired {
                ACPAuthBanner(
                    onLogin: { model.openAntigravityLoginInTerminal() },
                    onRetry: {
                        Task {
                            await controller.retryLogin()
                        }
                    }
                )
            }
            if let prompt = controller.permissionPrompt {
                ACPPermissionCard(
                    prompt: prompt,
                    respond: { controller.respondToPermission(promptID: prompt.id, optionID: $0) },
                    cancel: { controller.cancelPermission(promptID: prompt.id) }
                )
            }
            if !controller.planEntries.isEmpty {
                ACPPlanStrip(entries: controller.planEntries)
            }
            if !slash.isEmpty {
                SlashCommandSuggestions(commands: slash, selectedIndex: min(suggestionIndex, slash.count - 1)) { command in
                    draft = command.insertionText
                    cursorEndRequest += 1
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .transition(.opacity)
            } else if !files.isEmpty {
                FileCompletionSuggestions(suggestions: files, selectedIndex: min(suggestionIndex, files.count - 1)) { suggestion in
                    draft = ComposerCompletion.replacingFileSuggestion(suggestion, in: draft)
                    cursorEndRequest += 1
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .transition(.opacity)
            }

            VStack(spacing: 0) {
                LastErrorAffordance(error: controller.errorText) { controller.errorText = nil }
                if !imageAttachments.isEmpty {
                    ComposerImageAttachmentsView(images: imageAttachments) { id in
                        imageAttachments.removeAll { $0.id == id }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    GrowingComposerTextView(
                        text: $draft,
                        height: $entryHeight,
                        theme: model.selectedTheme,
                        focusRequest: focusRequest,
                        cursorEndRequest: cursorEndRequest,
                        tabCompletion: completionForTab,
                        onKeyCommand: handleKeyCommand,
                        onCyclePinnedModel: cyclePinnedModel,
                        onFocusChange: { focused in
                            withAnimation(.easeInOut(duration: 0.15)) { isFocused = focused }
                        },
                        onImagesInserted: { imageAttachments.append(contentsOf: $0) },
                        onAttachmentError: { controller.errorText = $0 },
                        onSubmit: { submit() }
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: max(entryHeight, AppFonts.scaled(15.5) + 20))
                    ComposerSendButton(
                        aborting: controller.canAbort,
                        disabled: !controller.canAbort && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && imageAttachments.isEmpty
                    ) {
                        if controller.canAbort { controller.abort() }
                        else { submit() }
                    }
                    .padding(.bottom, 1)
                }
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .bottomLeading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: shellRadius, style: .continuous).fill(appTheme.panel.opacity(0.96)))
            .overlay(
                RoundedRectangle(cornerRadius: shellRadius, style: .continuous)
                    .stroke(accentFocus ? appTheme.brass.opacity(0.55) : appTheme.line, lineWidth: 1)
            )
            .shadow(color: accentFocus ? appTheme.brass.opacity(0.12) : .clear, radius: accentFocus ? 8 : 0, y: 0)
            .shadow(color: .black.opacity(appTheme.choice.isLight ? 0.08 : 0.3), radius: 18, y: 10)

            ACPComposerToolbar(controller: controller)
                .padding(.top, -2)
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .onChange(of: draft) { _, value in
            suggestionsDismissed = false
            suggestionIndex = 0
            let normalized = ComposerTokenCodec.normalizeExactReferences(
                in: value,
                skills: controller.slashCommands,
                projectPath: controller.projectPath
            )
            if normalized != value { draft = normalized }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pigFocusComposer)) { _ in
            focusRequest += 1
        }
        .task(id: fileSuggestionQuery) {
            await refreshFileSuggestions()
        }
        .onAppear {
            if focusOnAppear { DispatchQueue.main.async { focusRequest += 1 } }
        }
    }

    private var slashSuggestions: [SlashCommandInfo] {
        let text = String(draft.drop(while: { $0 == " " || $0 == "\t" }))
        guard text.hasPrefix("/"), !text.hasPrefix("//"), !text.contains("\n") else { return [] }
        let body = String(text.dropFirst())
        guard !body.contains(where: { $0.isWhitespace }) else { return [] }
        return GUIBuiltinSlashCommands.suggestions(for: body, in: controller.slashCommands)
    }

    private var displayedSlashSuggestions: [SlashCommandInfo] {
        suggestionsDismissed ? [] : slashSuggestions
    }

    private var displayedFileSuggestions: [ComposerFileSuggestion] {
        guard !suggestionsDismissed, slashSuggestions.isEmpty else { return [] }
        return fileSuggestions
    }

    private var fileSuggestionQuery: String { controller.id + "|" + draft }

    private func refreshFileSuggestions() async {
        guard ComposerCompletion.hasFileToken(in: draft) else {
            if !fileSuggestions.isEmpty { fileSuggestions = [] }
            return
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard !Task.isCancelled else { return }
        let suggestions = await ComposerCompletion.fileSuggestionsAsync(for: draft, projectPath: controller.projectPath)
        guard !Task.isCancelled else { return }
        fileSuggestions = suggestions
    }

    private func handleKeyCommand(_ command: ComposerKeyCommand) -> Bool {
        let slash = displayedSlashSuggestions
        let files = slash.isEmpty ? displayedFileSuggestions : []
        let count = !slash.isEmpty ? slash.count : files.count
        guard count > 0 else { return false }
        let index = min(suggestionIndex, count - 1)
        switch command {
        case .moveUp:
            suggestionIndex = (index - 1 + count) % count
            return true
        case .moveDown:
            suggestionIndex = (index + 1) % count
            return true
        case .accept:
            if !slash.isEmpty {
                let picked = slash[index]
                let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.caseInsensitiveCompare("/\(picked.name)") != .orderedSame else { return false }
                draft = picked.insertionText
            } else {
                draft = ComposerCompletion.replacingFileSuggestion(files[index], in: draft)
            }
            cursorEndRequest += 1
            return true
        case .dismiss:
            suggestionsDismissed = true
            return true
        }
    }

    private func cyclePinnedModel() -> Bool {
        let available = Set(controller.models.map(\.id))
        let pinned = PinnedModels.ids.filter { available.contains($0) }
        guard !pinned.isEmpty else { return true }
        let next = pinned.firstIndex(of: controller.selectedModelID)
            .map { pinned[($0 + 1) % pinned.count] } ?? pinned[0]
        if next != controller.selectedModelID {
            Task { await controller.setModel(next) }
        }
        return true
    }

    private func completionForTab(text: String, selectedRange: NSRange) -> ComposerTabCompletionResult {
        ComposerCompletion.completion(
            for: text,
            selectedRange: selectedRange,
            slashCommands: controller.slashCommands
        )
    }

    private func submit() {
        guard !controller.isWorking else { return }
        let submittedDraft = draft
        let normalized = ComposerTokenCodec.normalizeExactReferences(
            in: submittedDraft + " ",
            skills: controller.slashCommands,
            projectPath: controller.projectPath
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty || !imageAttachments.isEmpty else { return }

        let submittedImages = imageAttachments
        beforeSubmit?()
        Task {
            await controller.sendDraft(submittedDraft, images: submittedImages, normalizedText: normalized)
        }
    }
}

struct ACPComposerToolbar: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var controller: ACPChatController
    @State private var usageProvider: UsageLimitProvider?

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            ACPModelPickerMenu(controller: controller)
                .help("Model (⌘1–⌘5)")
            ACPThinkingDial(controller: controller)
            ACPModePicker(
                modes: controller.modes,
                selectedModeID: controller.currentModeID,
                onSelect: { modeID in
                    Task { await controller.setMode(modeID) }
                }
            )
            Spacer(minLength: 8)
            ACPContextUsageBadge(used: controller.contextUsed, window: controller.contextWindow, percent: controller.contextPercent)
            if let usageProvider {
                ACPStoredUsageLimitIndicator(store: model.usageLimitStore, provider: usageProvider) {
                    model.refreshUsageLimit(for: usageProvider)
                }
                .frame(width: 84)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .task(id: controller.activeModel) {
            let provider = UsageLimitProvider.from(model: controller.activeModel)
            guard !Task.isCancelled else { return }
            usageProvider = provider
            model.refreshUsageLimit(for: provider)
        }
    }
}

private struct ACPStoredUsageLimitIndicator: View {
    @ObservedObject var store: UsageLimitStore
    let provider: UsageLimitProvider
    let refresh: () -> Void

    var body: some View {
        UsageLimitIndicator(snapshot: store.limits[provider], refresh: refresh)
    }
}

struct ACPModePicker: View {
    @Environment(\.appTheme) private var appTheme
    let modes: [ACPModeInfo]
    let selectedModeID: String
    let onSelect: (String) -> Void
    @State private var isOpen = false
    @State private var hovering = false

    private var selectedMode: ACPModeInfo? {
        modes.first { $0.id == selectedModeID }
    }

    private var symbolName: String {
        switch selectedModeID {
        case "plan": return "list.bullet.clipboard"
        case "auto": return "bolt.shield"
        case "accept-edits": return "pencil.and.outline"
        default: return "shield"
        }
    }

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: symbolName)
                    .font(AppFonts.ui(11, weight: .medium))
                    .foregroundStyle(selectedModeID == "plan" ? appTheme.brass : appTheme.muted)
                Text(selectedMode?.name ?? selectedModeID.capitalized)
                    .font(AppFonts.ui(11.5, weight: .medium))
                    .foregroundStyle(hovering ? appTheme.text : appTheme.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovering ? Color.white.opacity(0.03) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .help(selectedMode?.description ?? "Antigravity approval mode")
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(modes) { mode in
                    Button {
                        onSelect(mode.id)
                        isOpen = false
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: mode.id == selectedModeID ? "checkmark" : "")
                                .font(AppFonts.ui(11, weight: .semibold))
                                .foregroundStyle(appTheme.brass)
                                .frame(width: 14, alignment: .center)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.name)
                                    .font(AppFonts.ui(12.5, weight: .medium))
                                    .foregroundStyle(appTheme.text)
                                if let desc = mode.description, !desc.isEmpty {
                                    Text(desc)
                                        .font(AppFonts.ui(11))
                                        .foregroundStyle(appTheme.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 5)
            .frame(width: 280)
            .glowPresentationBackground()
        }
    }
}

private struct ACPModelPickerMenu: View {
    @Environment(\.appTheme) private var appTheme
    @ObservedObject var controller: ACPChatController
    @State private var isOpen = false
    @State private var hovering = false
    @State private var pinnedIDs: [String] = PinnedModels.ids
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    private var selectedModelName: String {
        if controller.models.isEmpty { return "Loading…" }
        guard let active = controller.activeModel else {
            return controller.selectedModelID.nonEmptyTrimmed ?? "Select model"
        }
        return active.name.isEmpty ? active.modelId : active.name
    }

    private var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func matchesSearch(_ model: ModelInfo) -> Bool {
        model.displayName.lowercased().contains(normalizedSearch)
            || model.id.lowercased().contains(normalizedSearch)
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

    var body: some View {
        Button {
            pinnedIDs = PinnedModels.ids
            if !isOpen { searchText = "" }
            isOpen.toggle()
            if isOpen { DispatchQueue.main.async { searchFocused = true } }
        } label: {
            TabStripPickerLabel(
                value: selectedModelName,
                hovering: hovering,
                provider: ACPProvider.antigravityDisplayName
            )
        }
        .buttonStyle(.plain)
        .background(hovering ? Color.white.opacity(0.03) : Color.clear)
        .onHover { hovering = $0 }
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(AppFonts.ui(11, weight: .semibold))
                        .foregroundStyle(appTheme.muted)
                    TextField("Search Antigravity models", text: $searchText)
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
                        if pinnedModels.isEmpty && unpinnedModels.isEmpty {
                            Text("No matching models")
                                .font(AppFonts.ui(12.5))
                                .foregroundStyle(appTheme.muted)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                        } else {
                            ForEach(pinnedModels) { model in
                                row(model)
                            }
                            if !pinnedModels.isEmpty && !unpinnedModels.isEmpty {
                                PopoverMenuDivider()
                            }
                            ForEach(unpinnedModels) { model in
                                row(model)
                            }
                        }
                    }
                    .padding(.vertical, 5)
                    .padding(.trailing, 12)
                }
            }
            .frame(width: 320)
            .frame(maxHeight: 420)
            .glowPresentationBackground()
        }
    }

    private func row(_ model: ModelInfo) -> some View {
        ModelPickerRow(
            model: model,
            isSelected: model.id == controller.selectedModelID,
            isPinned: pinnedIDs.contains(model.id),
            select: {
                Task { await controller.setModel(model.id) }
                isOpen = false
            },
            togglePin: {
                PinnedModels.toggle(model.id)
                pinnedIDs = PinnedModels.ids
            }
        )
    }
}

private struct ACPThinkingDial: View {
    @Environment(\.appTheme) private var appTheme
    @ObservedObject var controller: ACPChatController
    @State private var hovering = false

    private var levels: [String] { controller.availableThinkingLevels }
    private var index: Int { levels.firstIndex(of: controller.thinkingLevel) ?? 0 }

    var body: some View {
        Button {
            guard !levels.isEmpty else { return }
            let next = levels[(index + 1) % levels.count]
            Task { await controller.setThinkingLevel(next) }
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
                Text(ThinkingDial.title(controller.thinkingLevel))
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
                    Task { await controller.setThinkingLevel(level) }
                } label: {
                    if level == controller.thinkingLevel {
                        Label(ThinkingDial.title(level), systemImage: "checkmark")
                    } else {
                        Text(ThinkingDial.title(level))
                    }
                }
            }
        }
    }
}

private struct ACPContextUsageBadge: View {
    @Environment(\.appTheme) private var appTheme
    let used: Int?
    let window: Int?
    let percent: Double?

    var body: some View {
        if let percent, let used, let window {
            let fraction = min(1, max(0, percent / 100))
            let ringColor: Color = percent >= 85 ? appTheme.danger : (percent >= 65 ? appTheme.brass : appTheme.muted)
            HStack(spacing: 5) {
                ZStack {
                    Circle()
                        .stroke(appTheme.muted.opacity(0.25), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(ringColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 13, height: 13)
                Text("\(Int(percent.rounded()))%")
                    .font(AppFonts.ui(11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(appTheme.muted)
            }
            .help("Context window: \(formatTokens(used)) / \(formatTokens(window)) tokens")
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
        return "\(count)"
    }
}

/// Inline ACP permission request card above the composer.
struct ACPPermissionCard: View {
    @Environment(\.appTheme) private var appTheme
    let prompt: ACPPermissionPrompt
    let respond: (_ optionID: String) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(AppFonts.ui(13, weight: .semibold))
                    .foregroundStyle(appTheme.brass)
                Text("Permission needed")
                    .font(AppFonts.heading(17, weight: .semibold))
                    .foregroundStyle(appTheme.text)
                Spacer()
                if let kind = prompt.kind, !kind.isEmpty {
                    Text(kind.uppercased())
                        .font(AppFonts.ui(10.5, weight: .semibold))
                        .foregroundStyle(appTheme.muted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(appTheme.panel2))
                }
            }
            Text(prompt.title)
                .font(AppFonts.ui(13.5, weight: .medium))
                .foregroundStyle(appTheme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let detail = prompt.detail, !detail.isEmpty {
                ScrollView {
                    Text(detail)
                        .font(AppFonts.code(12))
                        .foregroundStyle(appTheme.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(appTheme.codeBackground.opacity(0.6)))
            }
            HStack(spacing: 8) {
                Button("Cancel") { cancel() }
                Spacer()
                ForEach(prompt.options) { option in
                    Button(option.name) { respond(option.optionId) }
                }
            }
            .buttonStyle(ExtensionPromptButtonStyle())
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(appTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(appTheme.brass.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Permission needed")
    }
}

/// Auth prompt shown if `agy acp` returns JSON-RPC `-32000` (authentication required).
struct ACPAuthBanner: View {
    @Environment(\.appTheme) private var appTheme
    let onLogin: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.badge.key.fill")
                .font(AppFonts.ui(15, weight: .semibold))
                .foregroundStyle(appTheme.brass)
            VStack(alignment: .leading, spacing: 2) {
                Text("Antigravity login required")
                    .font(AppFonts.ui(13, weight: .semibold))
                    .foregroundStyle(appTheme.text)
                Text("Run `agy acp --login` to authenticate with Google, then retry.")
                    .font(AppFonts.ui(12))
                    .foregroundStyle(appTheme.muted)
            }
            Spacer()
            Button("Log in…", action: onLogin)
            Button("Retry", action: onRetry)
        }
        .buttonStyle(ExtensionPromptButtonStyle())
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(appTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(appTheme.brass.opacity(0.45), lineWidth: 1))
    }
}

/// Compact checklist strip for ACP `plan` updates.
struct ACPPlanStrip: View {
    @Environment(\.appTheme) private var appTheme
    let entries: [ACPPlanEntry]
    @State private var expanded = false

    private var completedCount: Int {
        entries.filter { $0.status == "completed" }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.14)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .font(AppFonts.ui(11.5, weight: .semibold))
                        .foregroundStyle(appTheme.brass)
                    Text("Plan · \(completedCount)/\(entries.count)")
                        .font(AppFonts.ui(12, weight: .semibold))
                        .foregroundStyle(appTheme.secondaryText)
                    if !expanded, let current = entries.first(where: { $0.status == "in_progress" }) ?? entries.first(where: { $0.status != "completed" }) {
                        Text(current.content)
                            .font(AppFonts.ui(12))
                            .foregroundStyle(appTheme.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(AppFonts.ui(10, weight: .medium))
                        .foregroundStyle(appTheme.muted)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(entries) { entry in
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: icon(for: entry.status))
                                .font(AppFonts.ui(11))
                                .foregroundStyle(color(for: entry.status))
                                .frame(width: 14)
                                .padding(.top, 2)
                            Text(entry.content)
                                .font(AppFonts.ui(12))
                                .foregroundStyle(entry.status == "completed" ? appTheme.muted : appTheme.text)
                                .strikethrough(entry.status == "completed")
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(appTheme.panel.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(appTheme.line, lineWidth: 1))
    }

    private func icon(for status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "circle.inset.filled"
        default: return "circle"
        }
    }

    private func color(for status: String) -> Color {
        switch status {
        case "completed": return appTheme.good
        case "in_progress": return appTheme.brass
        default: return appTheme.muted
        }
    }
}
