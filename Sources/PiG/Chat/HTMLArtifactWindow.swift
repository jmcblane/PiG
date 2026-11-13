import AppKit
import SwiftUI

@MainActor
final class HTMLArtifactWindowController: NSWindowController, NSWindowDelegate {
    private static var openControllers: [HTMLArtifactWindowController] = []

    private let artifactID: String
    private let onSendMessage: ((String) -> Void)?
    private weak var opener: NSWindow?
    private var isConfirming = false

    static func show(
        artifact: HTMLArtifact, theme: AppThemeChoice, textStyle: TextStyle,
        appTheme: AppTheme, onSendMessage: ((String) -> Void)?
    ) {
        if let existing = openControllers.first(where: { $0.artifactID == artifact.id }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = HTMLArtifactWindowController(
            artifact: artifact, theme: theme, textStyle: textStyle, appTheme: appTheme, onSendMessage: onSendMessage
        )
        openControllers.append(controller)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(
        artifact: HTMLArtifact, theme: AppThemeChoice, textStyle: TextStyle,
        appTheme: AppTheme, onSendMessage: ((String) -> Void)?
    ) {
        artifactID = artifact.id
        self.onSendMessage = onSendMessage
        opener = NSApp.keyWindow
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = artifact.title
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 240)
        window.backgroundColor = theme.palette.background.nsColor
        window.appearance = NSAppearance(named: theme.isLight ? .aqua : .darkAqua)
        super.init(window: window)
        window.delegate = self

        let content = HTMLArtifactWindowContent(
            artifact: artifact, theme: theme, textStyle: textStyle,
            onAction: { [weak self] action in self?.confirmSend(action) }
        )
        .environment(\.appTheme, appTheme)
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 960, height: 720))
        if let opener {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: opener.frame.minX, y: opener.frame.maxY)))
        } else {
            window.center()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            Self.openControllers.removeAll { $0 === self }
        }
    }

    private func confirmSend(_ action: HTMLWidgetAction) {
        guard let onSendMessage, !isConfirming else { return }
        isConfirming = true
        opener?.makeKeyAndOrderFront(nil)
        let request = GlowDialogRequest(
            title: "Send message to the agent?",
            message: action.message,
            confirmTitle: "Send",
            onConfirm: { [weak self] _ in
                self?.isConfirming = false
                onSendMessage(action.message)
            },
            onCancel: { [weak self] in self?.isConfirming = false }
        )
        NotificationCenter.default.post(name: .pigPresentDialog, object: request)
    }
}

private struct HTMLArtifactWindowContent: View {
    @Environment(\.appTheme) private var appTheme
    let artifact: HTMLArtifact
    let theme: AppThemeChoice
    let textStyle: TextStyle
    let onAction: (HTMLWidgetAction) -> Void
    @State private var zoom: CGFloat = 1
    @State private var reloadToken = 0
    @State private var error: String?

    private static let zoomRange: ClosedRange<CGFloat> = 0.5...3

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Spacer()
                Button { setZoom(zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .keyboardShortcut("-", modifiers: .command)
                    .help("Zoom out")
                    .accessibilityLabel("Zoom out")
                    .disabled(zoom <= Self.zoomRange.lowerBound)
                Button("\(Int((zoom * 100).rounded()))%") { setZoom(1) }
                    .keyboardShortcut("0", modifiers: .command)
                    .help("Actual size")
                    .monospacedDigit()
                Button { setZoom(zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .keyboardShortcut("=", modifiers: .command)
                    .help("Zoom in")
                    .accessibilityLabel("Zoom in")
                    .disabled(zoom >= Self.zoomRange.upperBound)
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload controls")
                    .accessibilityLabel("Reload controls")
            }
            .buttonStyle(GlowButtonStyle(kind: .secondary))
            .padding(10)
            Rectangle().fill(appTheme.line).frame(height: 1)
            HTMLArtifactWebView(
                artifact: artifact, theme: theme, textStyle: textStyle,
                pageZoom: zoom, scrollsHorizontally: true,
                onHeight: { _ in }, onAction: onAction, onError: { error = $0 }
            )
            .id(reloadToken)
            .accessibilityLabel(artifact.title)
            if let error {
                Text(error)
                    .font(AppFonts.ui(11))
                    .foregroundStyle(appTheme.danger)
                    .padding(8)
            }
        }
        .foregroundStyle(appTheme.text)
        .background(appTheme.background)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func setZoom(_ value: CGFloat) {
        zoom = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, (value * 100).rounded() / 100))
    }

    private func reload() {
        error = nil
        reloadToken += 1
    }
}
