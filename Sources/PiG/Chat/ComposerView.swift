import SwiftUI
import AppKit
import ImageIO

struct ComposerView: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    @ObservedObject var controller: SessionController
    @Binding var draft: String
    @Binding var imageAttachments: [ImageAttachment]
    var beforeSubmit: (() -> Void)? = nil
    var focusOnAppear = false
    var showsLandingResources = false
    @State private var entryHeight: CGFloat = 36
    @State private var fileSuggestions: [ComposerFileSuggestion] = []
    @State private var suggestionIndex = 0
    @State private var suggestionsDismissed = false
    @State private var isFocused = false
    @State private var focusRequest = 0
    @State private var cursorEndRequest = 0
    @State private var isSubmitting = false

    private let shellRadius: CGFloat = 18

    var body: some View {
        let slash = displayedSlashSuggestions
        let skills = displayedSkillSuggestions
        let files = displayedFileSuggestions
        let accentFocus = model.composerFocusAccent && isFocused
        VStack(spacing: 8) {
            if !slash.isEmpty {
                SlashCommandSuggestions(commands: slash, selectedIndex: min(suggestionIndex, slash.count - 1)) { command in
                    draft = command.insertionText
                    cursorEndRequest += 1
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .transition(.opacity)
            } else if !skills.isEmpty {
                SkillCompletionSuggestions(suggestions: skills, selectedIndex: min(suggestionIndex, skills.count - 1)) { suggestion in
                    draft = ComposerCompletion.replacingSkillSuggestion(suggestion, in: draft)
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
                if showsLandingResources {
                    SessionResourceStrip(controller: controller)
                }
                LastErrorAffordance(controller: controller)
                if !imageAttachments.isEmpty {
                    ComposerImageAttachmentsView(images: imageAttachments) { id in
                        imageAttachments.removeAll { $0.id == id }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                }
                if !controller.queuedSteering.isEmpty || !controller.queuedFollowUps.isEmpty || controller.queuedImageCount > 0 {
                    QueuedMessagesView(
                        steering: controller.queuedSteering,
                        followUps: controller.queuedFollowUps,
                        imageCount: controller.queuedImageCount,
                        dequeue: { Task { await controller.restoreQueuedMessages() } }
                    )
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
                        onDequeue: { Task { await controller.restoreQueuedMessages() } },
                        onImagesInserted: { imageAttachments.append(contentsOf: $0) },
                        onAttachmentError: { controller.errorText = $0 },
                        onSubmit: { submit() },
                        onFollowUpSubmit: { submit(requestFollowUp: true) }
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: max(entryHeight, AppFonts.scaled(15.5) + 20))
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(appTheme.codeBackground.opacity(0.18)))
                    Button {
                        if controller.canAbort { Task { await controller.abort() } }
                        else { submit() }
                    } label: {
                        if controller.canAbort {
                            Image(systemName: "stop.fill")
                                .font(AppFonts.ui(14, weight: .bold))
                                .frame(width: 34, height: 34)
                        } else {
                            Image(systemName: "arrow.right")
                                .font(AppFonts.ui(14, weight: .bold))
                                .frame(width: 34, height: 34)
                        }
                    }
                    .buttonStyle(SendButtonStyle(active: controller.canAbort))
                    .disabled(isSubmitting || (!controller.canAbort && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && imageAttachments.isEmpty))
                    .help(controller.canAbort ? "Abort" : "Send")
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .bottomLeading)
                ComposerToolbar(controller: controller)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: shellRadius, style: .continuous).fill(appTheme.panel.opacity(0.96)))
            .overlay(
                RoundedRectangle(cornerRadius: shellRadius, style: .continuous)
                    .stroke(accentFocus ? appTheme.brass.opacity(0.55) : appTheme.line, lineWidth: 1)
            )
            .shadow(color: accentFocus ? appTheme.brass.opacity(0.12) : .clear, radius: accentFocus ? 8 : 0, y: 0)
            if showsLandingResources && !controller.chatResources.isEmpty {
                Text("Added resources apply only to this chat. Your defaults stay the same.")
                    .font(AppFonts.ui(11))
                    .foregroundStyle(appTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .onChange(of: draft) { _, value in
            suggestionsDismissed = false
            suggestionIndex = 0
            let normalized = ComposerTokenCodec.normalizeExactReferences(
                in: value,
                skills: allSlashCommands,
                projectPath: controller.projectPath
            )
            if normalized != value { draft = normalized }
        }
        .onChange(of: controller.composerPrefillRequest) { _, request in
            applyComposerPrefill(request)
        }
        .task(id: fileSuggestionQuery) {
            await refreshFileSuggestions()
        }
        .onAppear {
            applyComposerPrefill(controller.composerPrefillRequest)
            if focusOnAppear { DispatchQueue.main.async { focusRequest += 1 } }
        }
    }

    private func applyComposerPrefill(_ request: ComposerPrefillRequest?) {
        guard let request else { return }
        if request.insertsAtEnd {
            let separator = draft.last.map { $0.isWhitespace ? "" : " " } ?? ""
            draft += separator + request.text + " "
            cursorEndRequest += 1
        } else if request.appendsToDraft, !draft.isEmpty {
            draft = request.text + "\n\n" + draft
        } else if !request.text.isEmpty {
            draft = request.text
        }
        imageAttachments.append(contentsOf: request.images.filter { image in
            !imageAttachments.contains(where: { $0.id == image.id })
        })
        focusRequest += 1
        controller.consumeComposerPrefill(request.id)
    }

    private var slashSuggestions: [SlashCommandInfo] {
        let text = String(draft.drop(while: { $0 == " " || $0 == "\t" }))
        guard text.hasPrefix("/"), !text.hasPrefix("//"), !text.contains("\n") else { return [] }
        let body = String(text.dropFirst())
        guard !body.contains(where: { $0.isWhitespace }) else { return [] }
        let token = body
        return GUIBuiltinSlashCommands.suggestions(for: token, in: allSlashCommands)
    }

    private var displayedSlashSuggestions: [SlashCommandInfo] {
        suggestionsDismissed ? [] : slashSuggestions
    }

    private var skillSuggestions: [ComposerSkillSuggestion] {
        ComposerCompletion.skillSuggestions(for: draft, commands: allSlashCommands)
    }

    private var displayedSkillSuggestions: [ComposerSkillSuggestion] {
        guard !suggestionsDismissed, slashSuggestions.isEmpty else { return [] }
        return skillSuggestions
    }

    private var displayedFileSuggestions: [ComposerFileSuggestion] {
        guard !suggestionsDismissed, slashSuggestions.isEmpty, skillSuggestions.isEmpty else { return [] }
        return fileSuggestions
    }

    private var fileSuggestionQuery: String { controller.id + "|" + draft }

    // File suggestions scan the project directory tree, so they run
    // debounced on a background task instead of during body evaluation.
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
        let skills = slash.isEmpty ? displayedSkillSuggestions : []
        let files = slash.isEmpty && skills.isEmpty ? displayedFileSuggestions : []
        let count = !slash.isEmpty ? slash.count : (!skills.isEmpty ? skills.count : files.count)
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
                // The typed command is already complete: let Return submit it.
                guard trimmed.caseInsensitiveCompare("/\(picked.name)") != .orderedSame else { return false }
                draft = picked.insertionText
            } else if !skills.isEmpty {
                draft = ComposerCompletion.replacingSkillSuggestion(skills[index], in: draft)
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

    private var allSlashCommands: [SlashCommandInfo] {
        (GUIBuiltinSlashCommands.commands + controller.slashCommands).reduce(into: [SlashCommandInfo]()) { result, command in
            if !result.contains(where: { $0.name.caseInsensitiveCompare(command.name) == .orderedSame }) { result.append(command) }
        }
    }

    private func cyclePinnedModel() -> Bool {
        let available = Set(controller.models.map(\.id))
        let pinned = PinnedModels.ids.filter { available.contains($0) }
        guard !pinned.isEmpty else { return true }
        let next = pinned.firstIndex(of: controller.selectedModelID)
            .map { pinned[($0 + 1) % pinned.count] } ?? pinned[0]
        if next != controller.selectedModelID { controller.setModel(next) }
        return true
    }

    private func completionForTab(text: String, selectedRange: NSRange) -> ComposerTabCompletionResult {
        ComposerCompletion.completion(
            for: text,
            selectedRange: selectedRange,
            slashCommands: allSlashCommands
        )
    }

    private func submit(requestFollowUp: Bool = false) {
        guard !isSubmitting else { return }
        let normalized = ComposerTokenCodec.normalizeExactReferences(
            in: draft + " ",
            skills: allSlashCommands,
            projectPath: controller.projectPath
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty || !imageAttachments.isEmpty else { return }
        let submittedDraft = draft
        let submittedImages = imageAttachments
        controller.resumeRuntimeLoading()
        isSubmitting = true
        Task {
            let accepted = await controller.send(normalized, images: submittedImages, requestFollowUp: requestFollowUp)
            isSubmitting = false
            guard accepted else { return }
            beforeSubmit?()
            if draft == submittedDraft { draft = "" }
            let submittedIDs = Set(submittedImages.map(\.id))
            imageAttachments.removeAll { submittedIDs.contains($0.id) }
            entryHeight = max(36, AppFonts.scaled(15.5) + 20)
        }
    }
}

private struct ComposerImageAttachmentsView: View {
    @Environment(\.appTheme) private var appTheme
    let images: [ImageAttachment]
    let remove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images) { attachment in
                    HStack(spacing: 7) {
                        ImageAttachmentThumbnail(attachment: attachment, maxDimension: 96, style: .composer)
                        Text(attachment.name)
                            .font(AppFonts.ui(11.5, weight: .semibold))
                            .lineLimit(1)
                            .frame(maxWidth: 130)
                        Button { remove(attachment.id) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(appTheme.muted)
                        }
                        .buttonStyle(.plain)
                        .help("Remove \(attachment.name)")
                    }
                    .padding(5)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(appTheme.codeBackground.opacity(0.45)))
                }
            }
        }
    }
}

/// Small muted row above the composer shell: keeps the full error text
/// available (selectable, copyable) after the transient toast is dismissed,
/// without reintroducing a large persistent banner. Dismissing the toast
/// never clears errorText; Clear here resolves it.
private struct LastErrorAffordance: View {
    @Environment(\.appTheme) private var appTheme
    @ObservedObject var controller: SessionController
    @State private var showingDetails = false

    var body: some View {
        if let error = controller.errorText, !error.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(AppFonts.ui(10, weight: .semibold))
                    .foregroundStyle(appTheme.danger.opacity(0.85))
                Text("Last error")
                    .font(AppFonts.ui(11, weight: .semibold))
                    .foregroundStyle(appTheme.muted)
                Text(error.oneLine(max: 90))
                    .font(AppFonts.ui(11))
                    .foregroundStyle(appTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Button("Details") { showingDetails.toggle() }
                    .font(AppFonts.ui(11, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(appTheme.secondaryText)
                    .popover(isPresented: $showingDetails, arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Last error")
                                .font(AppFonts.ui(12, weight: .semibold))
                                .foregroundStyle(appTheme.text)
                            ScrollView {
                                Text(error)
                                    .font(AppFonts.ui(12.5))
                                    .foregroundStyle(appTheme.text)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 220)
                            HStack {
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(error, forType: .string)
                                }
                                Button("Clear") { controller.errorText = nil }
                                Spacer()
                                Button("Close") { showingDetails = false }
                                    .keyboardShortcut(.cancelAction)
                            }
                        }
                        .padding(14)
                        .frame(width: 380)
                    }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Last error: \(error.oneLine(max: 120))")
        }
    }
}

private struct QueuedMessagesView: View {
    @Environment(\.appTheme) private var appTheme
    let steering: [String]
    let followUps: [String]
    let imageCount: Int
    let dequeue: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                if !steering.isEmpty {
                    queueRow("Steering", symbol: "arrow.triangle.branch", messages: steering)
                }
                if !followUps.isEmpty {
                    queueRow("Follow-up", symbol: "arrow.right.to.line", messages: followUps)
                }
                if imageCount > 0 {
                    Label("\(imageCount) queued image\(imageCount == 1 ? "" : "s") kept locally until delivery", systemImage: "photo")
                        .foregroundStyle(appTheme.muted)
                }
            }
            Spacer(minLength: 8)
            Button(action: dequeue) {
                Image(systemName: "arrow.up.to.line")
                    .font(AppFonts.ui(11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(appTheme.brass)
            .help("Return queued messages to the composer (Option-Up)")
        }
        .font(AppFonts.ui(11.5))
        .foregroundStyle(appTheme.secondaryText)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(appTheme.codeBackground.opacity(0.4)))
    }

    @ViewBuilder private func queueRow(_ label: String, symbol: String, messages: [String]) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .frame(width: 13)
            Text("\(label) \(messages.count)")
                .font(AppFonts.ui(11.5, weight: .semibold))
            Text(messages.prefix(2).map { $0.oneLine(max: 48) }.joined(separator: " · "))
                .lineLimit(1)
        }
    }
}

struct SkillCompletionSuggestions: View {
    @Environment(\.appTheme) private var appTheme
    let suggestions: [ComposerSkillSuggestion]
    var selectedIndex: Int? = nil
    let onPick: (ComposerSkillSuggestion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                let command = suggestion.command
                Button { onPick(suggestion) } label: {
                    HStack(spacing: 10) {
                        Text("$")
                            .font(AppFonts.ui(13.5, weight: .bold))
                            .foregroundStyle(appTheme.brass)
                            .frame(width: 18)
                        Text(ComposerTokenCodec.skillDisplayName(command))
                            .font(AppFonts.ui(13.5, weight: .semibold))
                            .foregroundStyle(appTheme.text)
                            .frame(width: 190, alignment: .leading)
                            .lineLimit(1)
                        Text(command.description)
                            .font(AppFonts.ui(13.5))
                            .foregroundStyle(appTheme.muted)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text("SKILL")
                            .font(AppFonts.heading(11.5, weight: .semibold))
                            .tracking(1.1)
                            .foregroundStyle(appTheme.muted)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(index == selectedIndex ? appTheme.brass.opacity(0.24) : appTheme.panel2.opacity(0.9))
            }
        }
        .shadow(color: Color.black.opacity(0.18), radius: 10, y: -2)
    }
}

struct SlashCommandSuggestions: View {
    @Environment(\.appTheme) private var appTheme
    let commands: [SlashCommandInfo]
    var selectedIndex: Int? = nil
    let onPick: (SlashCommandInfo) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                Button { onPick(command) } label: {
                    HStack(spacing: 10) {
                        Text("/\(command.name)")
                            .font(AppFonts.ui(13.5, weight: .semibold))
                            .foregroundStyle(appTheme.text)
                            .frame(width: 150, alignment: .leading)
                        if let hint = command.argumentHint {
                            Text(hint)
                                .font(AppFonts.ui(13.5))
                                .foregroundStyle(appTheme.brass)
                                .lineLimit(1)
                        }
                        Text(command.description)
                            .font(AppFonts.ui(13.5))
                            .foregroundStyle(appTheme.muted)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(command.displaySource)
                            .font(AppFonts.heading(11.5, weight: .semibold))
                            .tracking(1.1)
                            .foregroundStyle(appTheme.muted)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(index == selectedIndex ? appTheme.brass.opacity(0.24) : appTheme.panel2.opacity(command.source == "builtin" ? 0.72 : 0.92))
            }
        }
        .shadow(color: Color.black.opacity(0.18), radius: 10, y: -2)
    }
}

struct FileCompletionSuggestions: View {
    @Environment(\.appTheme) private var appTheme
    let suggestions: [ComposerFileSuggestion]
    var selectedIndex: Int? = nil
    let onPick: (ComposerFileSuggestion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button { onPick(suggestion) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: suggestion.isDirectory ? "folder" : "doc.text")
                            .font(AppFonts.ui(12, weight: .semibold))
                            .foregroundStyle(appTheme.brass)
                            .frame(width: 18)
                        Text(suggestion.displayName)
                            .font(AppFonts.ui(13.5, weight: .semibold))
                            .foregroundStyle(appTheme.text)
                            .frame(width: 190, alignment: .leading)
                            .lineLimit(1)
                        Text(suggestion.displayPath)
                            .font(AppFonts.ui(13.5))
                            .foregroundStyle(appTheme.muted)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(suggestion.kind)
                            .font(AppFonts.heading(11.5, weight: .semibold))
                            .tracking(1.1)
                            .foregroundStyle(appTheme.muted)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(index == selectedIndex ? appTheme.brass.opacity(0.24) : appTheme.panel2.opacity(suggestion.isDirectory ? 0.82 : 0.72))
            }
        }
        .shadow(color: Color.black.opacity(0.18), radius: 10, y: -2)
    }
}
