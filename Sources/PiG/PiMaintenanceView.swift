import SwiftUI

struct PiMaintenanceHost: View {
    @Environment(\.appTheme) private var appTheme
    @ObservedObject var controller: PiMaintenanceController
    let theme: AppThemeChoice

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .sheet(item: $controller.sheet) { _ in
                PiMaintenanceSheetView(controller: controller, theme: theme)
                    .environment(\.appTheme, appTheme)
            }
    }
}

private struct PiMaintenanceSheetView: View {
    @Environment(\.appTheme) private var appTheme
    @ObservedObject var controller: PiMaintenanceController
    let theme: AppThemeChoice

    var body: some View {
        Group {
            switch controller.sheet {
            case .updates:
                UpdatesView(controller: controller)
            case .changelog:
                ChangelogView(controller: controller, theme: theme)
            case .confirm(let action):
                UpdateConfirmationView(controller: controller, action: action)
            case .progress:
                UpdateProgressView(controller: controller, action: controller.updateAction)
            case nil:
                EmptyView()
            }
        }
        .background(appTheme.background)
    }
}

private struct UpdatesView: View {
    @Environment(\.appTheme) private var appTheme
    @ObservedObject var controller: PiMaintenanceController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MaintenanceHeader(title: "Pi Updates", close: { controller.sheet = nil })

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    updateSection
                    Divider().overlay(appTheme.line).padding(.vertical, 24)
                    extensionSection
                }
                .padding(28)
            }

            Divider().overlay(appTheme.line)
            HStack {
                Button {
                    Task { await controller.checkForUpdates() }
                } label: {
                    Label(controller.isChecking ? "Checking…" : "Check Again", systemImage: "arrow.clockwise")
                }
                .disabled(controller.isChecking)
                Spacer()
                Button("Close") { controller.sheet = nil }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(18)
        }
        .frame(width: 620, height: 560)
    }

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Pi", systemImage: "shippingbox")
                .font(AppFonts.heading(19, weight: .semibold))
                .foregroundStyle(appTheme.text)
            HStack(alignment: .firstTextBaseline) {
                Text("Installed \(controller.installedVersion)")
                    .foregroundStyle(appTheme.secondaryText)
                Spacer()
                if let release = controller.latestRelease,
                   PiMaintenanceVersion.isNewer(release.version, than: controller.installedVersion) {
                    Text("Version \(release.version) available")
                        .foregroundStyle(.orange)
                } else {
                    Text("Up to date")
                        .foregroundStyle(appTheme.palette.good.color)
                }
            }
            .font(AppFonts.ui(13))
            HStack(spacing: 14) {
                Button("What’s New") { controller.openChangelog() }
                Button("Update Pi") { controller.requestUpdate(.pi) }
                    .disabled(controller.isUpdating)
                Button("Refresh Model Catalogs") { controller.requestUpdate(.models) }
                    .disabled(controller.isUpdating)
            }
        }
    }

    private var extensionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Extensions", systemImage: "puzzlepiece.extension")
                .font(AppFonts.heading(19, weight: .semibold))
                .foregroundStyle(appTheme.text)
            if controller.packageUpdates.isEmpty {
                Text(controller.isChecking ? "Checking installed packages…" : "No extension updates found.")
                    .font(AppFonts.ui(13))
                    .foregroundStyle(appTheme.secondaryText)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(controller.packageUpdates) { update in
                        HStack {
                            Text(update.displayName)
                                .foregroundStyle(appTheme.text)
                            Spacer()
                            Text(update.scope.capitalized)
                                .foregroundStyle(appTheme.muted)
                        }
                    }
                }
                .font(AppFonts.ui(13))
                Button("Update Extensions") { controller.requestUpdate(.extensions) }
                    .disabled(controller.isUpdating)
            }
            Text("Context: \(controller.contextName)")
                .font(AppFonts.ui(11.5))
                .foregroundStyle(appTheme.muted)
        }
    }
}

private struct ChangelogView: View {
    @Environment(\.appTheme) private var appTheme
    @ObservedObject var controller: PiMaintenanceController
    let theme: AppThemeChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MaintenanceHeader(title: controller.changelogTitle, close: { controller.sheet = nil })
            Divider().overlay(appTheme.line)
            ScrollView {
                NativeMarkdownView(
                    markdown: controller.changelogMarkdown,
                    role: .assistant,
                    theme: theme,
                    projectPath: PiMaintenancePaths.packageRootPath
                )
                .padding(28)
            }
        }
        .frame(width: 760, height: 720)
    }
}

private struct UpdateConfirmationView: View {
    @Environment(\.appTheme) private var appTheme
    @ObservedObject var controller: PiMaintenanceController
    let action: PiUpdateAction

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: action.includesExtensions ? "arrow.down.circle" : "shippingbox.and.arrow.backward")
                    .font(AppFonts.ui(28, weight: .light))
                    .foregroundStyle(appTheme.brass)
                Text(action.title + "?")
                    .font(AppFonts.heading(22, weight: .semibold))
                    .foregroundStyle(appTheme.text)
            }
            Text("PiG will run `pi \(action.arguments.joined(separator: " "))` in \(controller.contextName).")
                .font(AppFonts.ui(14))
                .foregroundStyle(appTheme.secondaryText)
            HStack {
                Spacer()
                Button("Cancel") { controller.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(action.title) { controller.runConfirmedUpdate(action) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 500)
    }
}

private struct UpdateProgressView: View {
    @Environment(\.appTheme) private var appTheme
    @ObservedObject var controller: PiMaintenanceController
    let action: PiUpdateAction

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MaintenanceHeader(
                title: controller.isUpdating ? action.progressTitle : (controller.updateSucceeded == true ? "Update Complete" : "Update Failed"),
                close: controller.isUpdating ? nil : { controller.sheet = nil }
            )
            Divider().overlay(appTheme.line)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(controller.updateOutput.isEmpty ? "Starting…" : controller.updateOutput)
                        .font(AppFonts.code(12.5))
                        .foregroundStyle(appTheme.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(22)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: controller.updateOutput) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            Divider().overlay(appTheme.line)
            HStack {
                if controller.isUpdating {
                    SignalMarchLoadingLabel(text: "Do not quit PiG while the update is running.")
                } else if controller.updateSucceeded == true {
                    Label("Finished successfully", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(appTheme.palette.good.color)
                } else {
                    Label("Command exited with an error", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(appTheme.danger)
                }
                Spacer()
                if !controller.isUpdating {
                    Button("Done") { controller.sheet = nil }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .font(AppFonts.ui(13))
            .padding(18)
        }
        .frame(width: 680, height: 500)
        .interactiveDismissDisabled(controller.isUpdating)
    }
}

private struct MaintenanceHeader: View {
    @Environment(\.appTheme) private var appTheme
    let title: String
    let close: (() -> Void)?

    var body: some View {
        HStack {
            Text(title)
                .font(AppFonts.heading(22, weight: .semibold))
                .foregroundStyle(appTheme.text)
            Spacer()
            if let close {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(appTheme.muted)
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 66)
    }
}

// Small read-only adapters keep fileprivate maintenance parsing details out of the views.
enum PiMaintenanceVersion {
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = candidate.split(separator: ".").prefix(3).map { Int($0) ?? 0 }
        let rhs = current.split(separator: ".").prefix(3).map { Int($0) ?? 0 }
        for index in 0..<3 {
            let l = index < lhs.count ? lhs[index] : 0
            let r = index < rhs.count ? rhs[index] : 0
            if l != r { return l > r }
        }
        return false
    }
}

enum PiMaintenancePaths {
    static var packageRootPath: String? {
        PiPaths.piDistIndex?.deletingLastPathComponent().deletingLastPathComponent().path
    }
}
