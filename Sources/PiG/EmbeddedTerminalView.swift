import SwiftUI
import AppKit
import SwiftTerm

/// A shell running in a SwiftTerm terminal view.
struct EmbeddedTerminalView: NSViewRepresentable {
    @Environment(\.appTheme) private var appTheme
    let workingDirectoryPath: String?
    let isActive: Bool
    let onExit: () -> Void
    let onTitleChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onExit: onExit, onTitleChange: onTitleChange)
    }

    func makeNSView(context: Context) -> ShellTerminalView {
        let view = ShellTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.processDelegate = context.coordinator
        view.optionAsMetaKey = false
        view.isHidden = !isActive
        applyTheme(to: view)
        view.startShell(workingDirectoryPath: workingDirectoryPath)
        return view
    }

    func updateNSView(_ view: ShellTerminalView, context: Context) {
        context.coordinator.onExit = onExit
        context.coordinator.onTitleChange = onTitleChange
        applyTheme(to: view)
        setActive(isActive, view: view)
    }

    /// Tabs are stacked AppKit views. SwiftUI's opacity and hit-testing
    /// modifiers don't stop an NSView from taking clicks and keystrokes,
    /// so inactive tabs are hidden in AppKit and focus follows the active tab.
    private func setActive(_ active: Bool, view: ShellTerminalView) {
        guard view.isHidden == active else { return }
        view.isHidden = !active
        if active {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        } else if view.window?.firstResponder === view {
            view.window?.makeFirstResponder(nil)
        }
    }

    static func dismantleNSView(_ view: ShellTerminalView, coordinator: Coordinator) {
        view.processDelegate = nil
        view.terminate()
    }

    private func applyTheme(to view: ShellTerminalView) {
        if view.ansiTheme != appTheme.choice {
            view.ansiTheme = appTheme.choice
            view.installColors(appTheme.choice.terminalANSIColors.map {
                SwiftTerm.Color(red8: UInt16(($0 >> 16) & 0xff), green8: UInt16(($0 >> 8) & 0xff), blue8: UInt16($0 & 0xff))
            })
        }
        let palette = appTheme.palette
        let font = AppFonts.nsCode(13)
        if view.font != font { view.font = font }
        if view.nativeBackgroundColor != palette.background.nsColor { view.nativeBackgroundColor = palette.background.nsColor }
        if view.nativeForegroundColor != palette.text.nsColor { view.nativeForegroundColor = palette.text.nsColor }
        if view.caretColor != palette.accent.nsColor { view.caretColor = palette.accent.nsColor }
        let selection = palette.accent.nsColor.withAlphaComponent(0.35)
        if view.selectedTextBackgroundColor != selection { view.selectedTextBackgroundColor = selection }
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var onExit: () -> Void
        var onTitleChange: (String) -> Void

        init(onExit: @escaping () -> Void, onTitleChange: @escaping (String) -> Void) {
            self.onExit = onExit
            self.onTitleChange = onTitleChange
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            onTitleChange(title)
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            onExit()
        }
    }
}

final class ShellTerminalView: LocalProcessTerminalView {
    var ansiTheme: AppThemeChoice?

    func startShell(workingDirectoryPath: String?) {
        let shell = PiEnvironment.userShell
        var extra = ["TERM": "xterm-256color", "COLORTERM": "truecolor", "PIG": "1"]
        if let workingDirectoryPath { extra["PIG_PROJECT_PATH"] = workingDirectoryPath }
        let environment = PiEnvironment.merged(extra: extra).map { "\($0.key)=\($0.value)" }
        startProcess(
            executable: shell.path,
            environment: environment,
            execName: "-" + shell.lastPathComponent,
            currentDirectory: Self.resolvedDirectory(workingDirectoryPath)
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if !isHidden { window?.makeFirstResponder(self) }
    }

    private static func resolvedDirectory(_ path: String?) -> String {
        var isDirectory: ObjCBool = false
        if let path, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return path
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }
}
