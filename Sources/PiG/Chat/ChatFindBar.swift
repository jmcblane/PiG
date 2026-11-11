import SwiftUI
import AppKit

extension Notification.Name {
    static let pigFindInChat = Notification.Name("pigFindInChat")
    static let pigFindNext = Notification.Name("pigFindNext")
    static let pigFindPrevious = Notification.Name("pigFindPrevious")
}

private struct ChatFindEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var chatFindEnabled: Bool {
        get { self[ChatFindEnabledKey.self] }
        set { self[ChatFindEnabledKey.self] = newValue }
    }
}

struct ChatFindTextKey: Hashable {
    let segment: Int
    var cell: Int = -1
}

struct ChatFindMatch: Equatable {
    let messageID: String
    let textKey: ChatFindTextKey
    let range: NSRange
}

struct ChatFindTextHighlights: Equatable {
    var ranges: [NSRange] = []
    var currentRange: NSRange?
}

struct ChatFindMessageHighlights: Equatable {
    let query: String
    var texts: [ChatFindTextKey: ChatFindTextHighlights]
}

enum ChatFindMatching {
    static func ranges(in text: String, query: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let string = text as NSString
        var remaining = NSRange(location: 0, length: string.length)
        var ranges: [NSRange] = []
        while remaining.length > 0 {
            let range = string.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: remaining)
            guard range.location != NSNotFound, range.length > 0 else { break }
            ranges.append(range)
            remaining = NSRange(location: NSMaxRange(range), length: string.length - NSMaxRange(range))
        }
        return ranges
    }
}

@MainActor
final class ChatFindState: ObservableObject {
    @Published var isOpen = false
    @Published var query = ""
    @Published private(set) var matches: [ChatFindMatch] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var highlights: [String: ChatFindMessageHighlights] = [:]
    @Published private(set) var focusRequest = 0
    @Published private(set) var navigationRequest = 0

    private struct CachedMessage {
        let markdown: String
        let role: MessageRole
        let theme: AppThemeChoice
        let textStyle: TextStyle
        let projectPath: String?
        let texts: [(ChatFindTextKey, String)]
        var query: String
        var matches: [ChatFindMatch]
    }

    private var cache: [String: CachedMessage] = [:]
    private var appliedQuery = ""
    private var refreshTask: Task<Void, Never>?

    var currentMatch: ChatFindMatch? {
        guard let currentIndex, matches.indices.contains(currentIndex) else { return nil }
        return matches[currentIndex]
    }

    func open() {
        isOpen = true
        focusRequest += 1
    }

    func close() {
        refreshTask?.cancel()
        refreshTask = nil
        isOpen = false
        query = ""
        appliedQuery = ""
        matches = []
        currentIndex = nil
        highlights = [:]
        cache = [:]
    }

    func scheduleRefresh(queryChanged: Bool = false, refresh: @escaping @MainActor () -> Void) {
        if queryChanged {
            refreshTask?.cancel()
            refreshTask = nil
        }
        guard isOpen else { return }
        if query.isEmpty {
            guard !appliedQuery.isEmpty else { return }
            matches = []
            currentIndex = nil
            highlights = [:]
            appliedQuery = ""
            return
        }
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) }
            catch { return }
            guard let self, self.isOpen else { return }
            self.refreshTask = nil
            refresh()
        }
    }

    func refresh(messages: [ChatMessage], theme: AppThemeChoice, textStyle: TextStyle, projectPath: String?) {
        guard isOpen, !query.isEmpty else { return }
        let previous = appliedQuery == query ? currentMatch : nil
        let previousIndex = appliedQuery == query ? currentIndex : nil
        var next: [ChatFindMatch] = []
        var retained = Set<String>()
        for message in messages where message.role == .user || message.role == .assistant {
            retained.insert(message.id)
            let markdown = message.canonicalText ?? message.text
            var cached = cache[message.id]
            if cached?.markdown != markdown || cached?.role != message.role || cached?.theme != theme ||
                cached?.textStyle != textStyle || cached?.projectPath != projectPath {
                let texts = NativeMarkdownView.findTexts(markdown: markdown, role: message.role, theme: theme,
                                                        projectPath: projectPath, isStreaming: message.isStreaming)
                cached = CachedMessage(markdown: markdown, role: message.role, theme: theme, textStyle: textStyle,
                                       projectPath: projectPath, texts: texts, query: "", matches: [])
            }
            guard var entry = cached else { continue }
            if entry.query != query {
                entry.query = query
                entry.matches = entry.texts.flatMap { key, text in
                    ChatFindMatching.ranges(in: text, query: query).map {
                        ChatFindMatch(messageID: message.id, textKey: key, range: $0)
                    }
                }
            }
            cache[message.id] = entry
            next.append(contentsOf: entry.matches)
        }
        cache = cache.filter { retained.contains($0.key) }
        guard next != matches || appliedQuery != query else { return }
        matches = next
        appliedQuery = query
        if let previous, let index = next.firstIndex(of: previous) {
            currentIndex = index
        } else if let previous, let index = next.indices.filter({
            next[$0].messageID == previous.messageID && next[$0].textKey == previous.textKey
        }).min(by: {
            abs(next[$0].range.location - previous.range.location) < abs(next[$1].range.location - previous.range.location)
        }) {
            currentIndex = index
        } else if let previousIndex, !next.isEmpty {
            currentIndex = min(previousIndex, next.count - 1)
        } else {
            currentIndex = next.isEmpty ? nil : next.count - 1
        }
        updateHighlights()
        if currentMatch != previous { navigationRequest += 1 }
    }

    func step(_ direction: Int) {
        guard !matches.isEmpty else { return }
        currentIndex = ((currentIndex ?? -1) + direction + matches.count) % matches.count
        updateHighlights()
        navigationRequest += 1
    }

    private func updateHighlights() {
        var result: [String: ChatFindMessageHighlights] = [:]
        let current = currentMatch
        for match in matches {
            result[match.messageID, default: ChatFindMessageHighlights(query: appliedQuery, texts: [:])]
                .texts[match.textKey, default: ChatFindTextHighlights()].ranges.append(match.range)
            if match == current {
                result[match.messageID]?.texts[match.textKey]?.currentRange = match.range
            }
        }
        highlights = result
    }
}

struct ChatFindBar: View {
    @Environment(\.appTheme) private var appTheme
    @ObservedObject var state: ChatFindState
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(AppFonts.ui(12))
                .foregroundStyle(appTheme.muted)
            ChatFindTextField(query: $state.query, focusRequest: state.focusRequest,
                              textColor: NSColor(appTheme.text), step: state.step, close: close)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Find in chat")
            if !state.query.isEmpty {
                Text(state.matches.isEmpty ? "No results" : "\((state.currentIndex ?? 0) + 1) of \(state.matches.count)")
                    .font(AppFonts.ui(11.5))
                    .monospacedDigit()
                    .foregroundStyle(appTheme.muted)
                    .fixedSize()
            }
            icon("chevron.up", label: "Previous match", help: "Previous match (⇧⌘G)", disabled: state.matches.isEmpty) {
                state.step(-1)
            }
            icon("chevron.down", label: "Next match", help: "Next match (⌘G)", disabled: state.matches.isEmpty) {
                state.step(1)
            }
            icon("xmark", label: "Close find", help: "Close (Esc)", action: close)
        }
        .padding(.horizontal, 8)
        .frame(width: 320, height: 34)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(appTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(appTheme.line, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.18), radius: 12, y: 4)
    }

    private func icon(_ name: String, label: String, help: String, disabled: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(AppFonts.ui(11, weight: .semibold))
                .foregroundStyle(appTheme.muted)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .help(help)
        .accessibilityLabel(label)
    }
}

@MainActor
enum ChatFindComposerFocus {
    static func restore() {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow, let content = window.contentView else { return }
            func composer(in view: NSView) -> NSTextView? {
                if let text = view as? GrowingComposerTextView.SubmitTextView, !text.isHiddenOrHasHiddenAncestor {
                    return text
                }
                for child in view.subviews {
                    if let text = composer(in: child) { return text }
                }
                return nil
            }
            if let text = composer(in: content) { window.makeFirstResponder(text) }
        }
    }
}

private struct ChatFindTextField: NSViewRepresentable {
    @Binding var query: String
    let focusRequest: Int
    let textColor: NSColor
    let step: (Int) -> Void
    let close: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.placeholderString = "Find in chat"
        field.font = AppFonts.nsUI(13)
        field.setAccessibilityLabel("Find in chat")
        field.delegate = context.coordinator
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak field, weak coordinator = context.coordinator] event in
            guard let field, let coordinator, event.window === field.window, event.keyCode == 53 else { return event }
            coordinator.parent.close()
            return nil
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.textColor = textColor
        if field.stringValue != query { field.stringValue = query }
        guard context.coordinator.lastFocusRequest != focusRequest else { return }
        context.coordinator.lastFocusRequest = focusRequest
        DispatchQueue.main.async { [weak field] in
            guard let field, let window = field.window else { return }
            window.makeFirstResponder(field)
            field.selectText(nil)
        }
    }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ChatFindTextField
        var lastFocusRequest: Int?
        var monitor: Any?

        init(_ parent: ChatFindTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.query = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
                commandSelector == #selector(NSResponder.insertLineBreak(_:)) ||
                commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                parent.step(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.close()
                return true
            }
            return false
        }
    }
}
