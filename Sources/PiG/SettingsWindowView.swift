import SwiftUI
import AppKit

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case models
    case agents
    case pi
    case extensions

    static let storageKey = "PiG.settingsTab"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .models: return "Models"
        case .agents: return "Agents"
        case .pi: return "Pi"
        case .extensions: return "Extensions"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .models: return "cpu"
        case .agents: return "person.2"
        case .pi: return "shippingbox"
        case .extensions: return "puzzlepiece.extension"
        }
    }

    static func open(_ tab: SettingsTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: storageKey)
        NotificationCenter.default.post(name: .pigOpenSettings, object: nil)
    }
}

extension Notification.Name {
    static let pigOpenSettings = Notification.Name("pigOpenSettings")
}

/// Settings window content: a centered tab strip over the selected tab, on the window's glow backdrop.
struct SettingsWindowView: View {
    @Environment(\.appTheme) private var appTheme
    @AppStorage(SettingsTab.storageKey) private var tab = SettingsTab.general

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
                .padding(.top, 2)
                .padding(.bottom, 10)
            Rectangle()
                .fill(appTheme.line.opacity(0.6))
                .frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background { WindowBackdrop() }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .modifier(HiddenWindowTitle())
        .background { SettingsWindowChrome().frame(width: 0, height: 0) }
    }

    private var tabStrip: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { item in
                tabButton(item)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func tabButton(_ item: SettingsTab) -> some View {
        let selected = item == tab
        return Button { tab = item } label: {
            HStack(spacing: 6) {
                Image(systemName: item.symbol)
                    .font(AppFonts.ui(12))
                Text(item.title)
                    .font(AppFonts.ui(12.5, weight: selected ? .semibold : .medium))
            }
            .foregroundStyle(selected ? appTheme.text : appTheme.muted)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? appTheme.brass.opacity(0.14) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .general: GeneralSettingsView()
        case .models: ModelsSettingsView()
        case .agents: AgentsSettingsView()
        case .pi: PiSettingsView()
        case .extensions: PiResourcesView()
        }
    }
}

/// Makes the Settings window's title bar transparent so the backdrop runs under it.
/// Drops the toolbar's window title where SwiftUI supports it (macOS 15+).
private struct HiddenWindowTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}

private struct SettingsWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            Self.apply(to: window)
            // SwiftUI configures the Settings window after this view joins it.
            DispatchQueue.main.async { [weak window] in
                if let window { Self.apply(to: window) }
            }
        }

        private static func apply(to window: NSWindow) {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
        }
    }
}
