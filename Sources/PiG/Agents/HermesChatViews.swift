import SwiftUI

/// Text-only composer for Hermes agent chats, styled like `ComposerView`.
/// Return sends, Shift-Return inserts a newline, `/new` starts a new agent chat.
/// Sending is disabled while Hermes works (no steering here); the button stops the run.
struct HermesComposerView: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    @ObservedObject var controller: HermesChatController
    @Binding var draft: String
    var beforeSubmit: (() -> Void)? = nil
    @State private var entryHeight: CGFloat = 36
    @State private var isFocused = false
    @State private var isSending = false

    private let shellRadius: CGFloat = 18
    private var minEntryHeight: CGFloat { max(36, AppFonts.scaled(15.5) + 20) }
    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isNewChatCommand: Bool { trimmedDraft == "/new" }
    private var canSubmit: Bool {
        !isSending && !trimmedDraft.isEmpty && (isNewChatCommand || !controller.isWorking)
    }

    var body: some View {
        let accentFocus = model.composerFocusAccent && isFocused
        VStack(spacing: 8) {
            if let approval = controller.approval {
                HermesApprovalCard(approval: approval) { controller.respondToApproval(allow: $0) }
            }
            VStack(spacing: 0) {
                LastErrorAffordance(error: controller.errorText) { controller.errorText = nil }
                HStack(alignment: .bottom, spacing: 10) {
                    GrowingComposerTextView(
                        text: $draft,
                        height: $entryHeight,
                        theme: model.selectedTheme,
                        focusRequest: 0,
                        cursorEndRequest: 0,
                        onFocusChange: { focused in
                            withAnimation(.easeInOut(duration: 0.15)) { isFocused = focused }
                        },
                        onSubmit: { submit() }
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: max(entryHeight, minEntryHeight))
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(appTheme.codeBackground.opacity(0.18)))
                    Button {
                        if controller.isWorking { Task { await controller.abort() } }
                        else { submit() }
                    } label: {
                        Image(systemName: controller.isWorking ? "stop.fill" : "arrow.right")
                            .font(AppFonts.ui(14, weight: .bold))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(SendButtonStyle(active: controller.isWorking))
                    .disabled(!controller.isWorking && !canSubmit)
                    .help(controller.isWorking ? "Stop" : "Send")
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .bottomLeading)
                toolbar
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: shellRadius, style: .continuous).fill(appTheme.panel.opacity(0.96)))
            .overlay(
                RoundedRectangle(cornerRadius: shellRadius, style: .continuous)
                    .stroke(accentFocus ? appTheme.brass.opacity(0.55) : appTheme.line, lineWidth: 1)
            )
            .shadow(color: accentFocus ? appTheme.brass.opacity(0.12) : .clear, radius: accentFocus ? 8 : 0, y: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

    private var toolbar: some View {
        HStack(alignment: .center, spacing: 8) {
            HermesModelPicker(controller: controller)
            Spacer(minLength: 8)
            if controller.approval != nil {
                InlineActivityIndicator(text: "Waiting for approval")
            } else if controller.isWorking {
                InlineActivityIndicator(text: controller.currentTool?.nonEmptyTrimmed?.oneLine(max: 40) ?? "Working")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    private func submit() {
        guard canSubmit else { return }
        let text = trimmedDraft
        let startsNewChat = isNewChatCommand
        draft = ""
        entryHeight = minEntryHeight
        if startsNewChat {
            model.selectAgent(controller.agentID)
            return
        }
        beforeSubmit?()
        model.recordHermesSend(text, controller: controller)
        isSending = true
        Task {
            await controller.send(text)
            isSending = false
        }
    }
}

/// Inline tool-approval request above the Hermes composer.
struct HermesApprovalCard: View {
    @Environment(\.appTheme) private var appTheme
    let approval: HermesApprovalPrompt
    let respond: (_ allow: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(AppFonts.ui(13, weight: .semibold))
                    .foregroundStyle(appTheme.brass)
                Text("Approval needed")
                    .font(AppFonts.heading(17, weight: .semibold))
                    .foregroundStyle(appTheme.text)
            }
            Text(approval.title)
                .font(AppFonts.ui(13.5))
                .foregroundStyle(appTheme.secondaryText)
                .textSelection(.enabled)
                .lineLimit(16)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                Spacer()
                Button("Deny") { respond(false) }
                Button("Allow once") { respond(true) }
            }
            .buttonStyle(ExtensionPromptButtonStyle())
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(appTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(appTheme.brass.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval needed")
    }
}

/// "Server default" plus the server's model catalog. Applies to the next message.
private struct HermesModelPicker: View {
    @Environment(\.appTheme) private var appTheme
    @ObservedObject var controller: HermesChatController
    @State private var isOpen = false
    @State private var hovering = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            TabStripPickerLabel(value: controller.selectedModelID ?? "Server default", dot: appTheme.brass, hovering: hovering)
        }
        .buttonStyle(.plain)
        .background(hovering ? Color.white.opacity(0.03) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .help("Model (applies to the next message)")
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                PopoverPickerRow(title: "Server default", isSelected: controller.selectedModelID == nil) {
                    select(nil)
                }
                if !controller.models.isEmpty {
                    PopoverMenuDivider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(controller.models, id: \.self) { id in
                                PopoverPickerRow(title: id, isSelected: controller.selectedModelID == id) {
                                    select(id)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 5)
            .frame(width: 280)
        }
    }

    private func select(_ id: String?) {
        controller.setModel(id)
        isOpen = false
    }
}
