import SwiftUI
import AppKit

struct PiSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        PiSettingsForm(maintenance: model.piMaintenance)
    }
}

private struct PiSettingsForm: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appTheme) private var appTheme
    @ObservedObject var maintenance: PiMaintenanceController
    @State private var piExecutablePath = PiExecutablePreference.path ?? ""
    @State private var detectedPiPath = PiPaths.detectedPiExecutable.path

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                piSection
                extensionUpdatesSection
                extensionStatusSection
                piExecutableSection
            }
            .padding(20)
        }
        .task {
            _ = await PiEnvironment.mergedAsync()
            detectedPiPath = PiPaths.detectedPiExecutable.path
        }
        .piChangelogSheet(controller: maintenance, window: .settings, theme: model.selectedTheme)
    }

    private var piSection: some View {
        GlowSection("Pi") {
            GlowBlockRow {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(maintenance.installedVersion == "—" ? "Pi" : "Pi \(maintenance.installedVersion)")
                            .font(AppFonts.ui(13))
                            .foregroundStyle(appTheme.text)
                        statusText(releaseStatus)
                    }
                    Spacer(minLength: 8)
                    Button {
                        Task { await maintenance.checkForUpdates() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(GlowButtonStyle())
                    .disabled(maintenance.isChecking || maintenance.isUpdating)
                    .help("Check for updates")
                    .accessibilityLabel("Check for updates")
                    Button("What’s New") { maintenance.openChangelog(in: .settings) }
                        .buttonStyle(GlowButtonStyle())
                    Button(PiUpdateAction.pi.title) { maintenance.requestUpdate(.pi) }
                        .buttonStyle(GlowButtonStyle(kind: availableRelease == nil ? .secondary : .primary))
                        .disabled(maintenance.isUpdating)
                }
            }
            activityRow(for: [.pi, .all])
            GlowRow("Model catalogs", subtitle: "Fetches the latest model lists for your providers.") {
                Button("Refresh") { maintenance.requestUpdate(.models) }
                    .buttonStyle(GlowButtonStyle())
                    .disabled(maintenance.isUpdating)
            }
            activityRow(for: [.models])
        }
    }

    private var extensionUpdatesSection: some View {
        GlowSection(
            "Extension updates",
            footer: "Global extensions are always checked. Choose a project to also check the extensions installed in it."
        ) {
            GlowRow("Project") {
                GlowDropdown(selection: contextBinding, options: contextOptions, label: contextLabel)
                    .disabled(maintenance.isUpdating)
            }
            GlowBlockRow {
                HStack(spacing: 8) {
                    statusText(packageStatus, size: 13)
                    Spacer(minLength: 8)
                    if !maintenance.packageUpdates.isEmpty {
                        Button(PiUpdateAction.extensions.title) { maintenance.requestUpdate(.extensions) }
                            .buttonStyle(GlowButtonStyle(kind: .primary))
                            .disabled(maintenance.isUpdating)
                    }
                }
            }
            ForEach(maintenance.packageUpdates) { update in
                GlowBlockRow {
                    HStack {
                        Text(update.displayName)
                            .font(AppFonts.ui(13))
                            .foregroundStyle(appTheme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(update.scope == "project" ? "Project" : "Global")
                            .font(AppFonts.ui(12))
                            .foregroundStyle(appTheme.muted)
                    }
                }
            }
            activityRow(for: [.extensions])
        }
    }

    private var extensionStatusSection: some View {
        GlowSection("Extension status items") {
            if model.extensionStatusKeys.isEmpty {
                GlowBlockRow {
                    Text("Status items appear here after an extension in a loaded chat reports one.")
                        .font(AppFonts.ui(12.5))
                        .foregroundStyle(appTheme.muted)
                }
            } else {
                ForEach(model.extensionStatusKeys, id: \.self) { key in
                    SettingsToggleRow(
                        title: model.extensionStatusLabel(for: key),
                        isOn: Binding(
                            get: { !model.hiddenExtensionStatusKeys.contains(key) },
                            set: { visible in
                                model.setExtensionStatusHidden(key, hidden: !visible)
                            }
                        )
                    )
                }
            }
        }
    }

    private var piExecutableSection: some View {
        GlowSection("Pi executable") {
            GlowBlockRow {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Override path")
                        .font(AppFonts.ui(13))
                        .foregroundStyle(appTheme.text)
                    GlowTextField(detectedPiPathLabel, text: $piExecutablePath, monospaced: true)
                        .onChange(of: piExecutablePath) { _, value in PiExecutablePreference.path = value }
                }
            }
            GlowBlockRow {
                HStack(spacing: 8) {
                    piExecutableStatus
                    Spacer()
                    Button("Choose…") { choosePiExecutable() }
                        .buttonStyle(GlowButtonStyle())
                    Button("Clear") { piExecutablePath = "" }
                        .buttonStyle(GlowButtonStyle())
                        .disabled(piExecutablePath.isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private func activityRow(for actions: [PiUpdateAction]) -> some View {
        if let action = maintenance.updateAction, actions.contains(action) {
            GlowBlockRow { PiUpdateOutputView(maintenance: maintenance) }
        } else if let action = maintenance.pendingAction, actions.contains(action) {
            GlowBlockRow { confirmation(action) }
        }
    }

    private func confirmation(_ action: PiUpdateAction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(action.title + "?")
                .font(AppFonts.ui(13, weight: .semibold))
                .foregroundStyle(appTheme.text)
            Text("PiG will run this command in \(runLocation):")
                .font(AppFonts.ui(12))
                .foregroundStyle(appTheme.muted)
            Text(action.command)
                .font(AppFonts.code(12))
                .foregroundStyle(appTheme.secondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .glowField(focused: false)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { maintenance.cancelPendingUpdate() }
                    .buttonStyle(GlowButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(action.title) { maintenance.runConfirmedUpdate(action) }
                    .buttonStyle(GlowButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)
        }
    }

    private func statusText(_ status: (text: String, color: Color), size: CGFloat = 11.5) -> some View {
        Text(status.text)
            .font(AppFonts.ui(size))
            .foregroundStyle(status.color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var availableRelease: PiRelease? {
        guard let release = maintenance.latestRelease,
              isNewerVersion(release.version, than: maintenance.installedVersion) else { return nil }
        return release
    }

    private var releaseStatus: (text: String, color: Color) {
        if maintenance.isChecking { return ("Checking for updates…", appTheme.muted) }
        if let availableRelease { return ("Pi \(availableRelease.version) is available", .orange) }
        switch maintenance.releaseCheckState {
        case .notChecked: return ("Not checked yet", appTheme.muted)
        case .succeeded: return ("Up to date", appTheme.palette.good.color)
        case .failed: return ("Couldn’t check for a new version of pi", .orange)
        case .skipped: return ("Version check is off because PI_OFFLINE or PI_SKIP_VERSION_CHECK is set", appTheme.muted)
        }
    }

    private var packageStatus: (text: String, color: Color) {
        if maintenance.isChecking { return ("Checking extensions…", appTheme.muted) }
        switch maintenance.packageCheckState {
        case .notChecked: return ("Not checked yet", appTheme.muted)
        case .failed: return ("Couldn’t check extensions for updates", .orange)
        case .skipped: return ("Extension check skipped", appTheme.muted)
        case .succeeded:
            let count = maintenance.packageUpdates.count
            if count == 0 { return ("Extensions are up to date", appTheme.palette.good.color) }
            return ("\(count) update\(count == 1 ? "" : "s") available", appTheme.text)
        }
    }

    private var runLocation: String {
        maintenance.contextPath == PiPaths.home.path ? "your home folder" : maintenance.contextPath.abbreviatingHomeDirectory()
    }

    private var contextOptions: [String] {
        var paths = [PiPaths.home.path]
        for project in model.projects where !paths.contains(project.path) {
            paths.append(project.path)
        }
        if !paths.contains(maintenance.contextPath) { paths.append(maintenance.contextPath) }
        return paths
    }

    private func contextLabel(_ path: String) -> String {
        if path == PiPaths.home.path { return "None (global only)" }
        if let project = model.projects.first(where: { $0.path == path }) { return project.displayName }
        return path == maintenance.contextPath ? maintenance.contextName : URL(fileURLWithPath: path).lastPathComponent
    }

    private var contextBinding: Binding<String> {
        Binding {
            maintenance.contextPath
        } set: { path in
            guard path != maintenance.contextPath else { return }
            let name = contextLabel(path)
            Task { await maintenance.checkForUpdates(cwd: path, projectName: name) }
        }
    }

    private var detectedPiPathLabel: String {
        detectedPiPath == "/usr/bin/env" ? "pi not found on PATH" : detectedPiPath
    }

    @ViewBuilder
    private var piExecutableStatus: some View {
        if let path = piExecutablePath.nonEmptyTrimmed {
            if FileManager.default.isExecutableFile(atPath: (path as NSString).expandingTildeInPath) {
                Label("Executable found", systemImage: "checkmark.circle")
                    .font(AppFonts.ui(12))
                    .foregroundStyle(appTheme.muted)
            } else {
                Label("Not found or not executable", systemImage: "exclamationmark.triangle.fill")
                    .font(AppFonts.ui(12))
                    .foregroundStyle(.orange)
            }
        } else {
            Label("Using auto-detected pi", systemImage: "magnifyingglass")
                .font(AppFonts.ui(12))
                .foregroundStyle(appTheme.muted)
        }
    }

    private func choosePiExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        let current = piExecutablePath.nonEmptyTrimmed.map { ($0 as NSString).expandingTildeInPath } ?? detectedPiPath
        panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent()
        panel.prompt = "Choose"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                piExecutablePath = url.path
            }
        }
    }
}

private struct PiUpdateOutputView: View {
    @Environment(\.appTheme) private var appTheme
    @ObservedObject var maintenance: PiMaintenanceController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if maintenance.isUpdating {
                    SignalMarchLoadingLabel(text: "Do not quit PiG while the update is running.")
                } else if maintenance.updateSucceeded == true {
                    Label("Finished successfully", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(appTheme.palette.good.color)
                } else {
                    Label("Command exited with an error", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(appTheme.danger)
                }
                Spacer(minLength: 8)
                if !maintenance.isUpdating {
                    Button("Done") { maintenance.dismissUpdateResult() }
                        .buttonStyle(GlowButtonStyle())
                }
            }
            .font(AppFonts.ui(12.5))
            ScrollViewReader { proxy in
                ScrollView {
                    Text(maintenance.updateOutput)
                        .font(AppFonts.code(12))
                        .foregroundStyle(appTheme.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(height: 200)
                .glowField(focused: false)
                .onChange(of: maintenance.updateOutput) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }
}
