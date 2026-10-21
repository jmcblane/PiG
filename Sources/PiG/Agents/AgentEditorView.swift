import SwiftUI
import AppKit

/// Sheet for creating or editing an agent. The backend is fixed once the agent exists.
struct AgentEditorView: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    let isNew: Bool
    @State private var agent: Agent
    @State private var apiKey = ""
    @State private var skillCatalog: [SkillOption] = []
    @State private var extensionCatalog: [PiResourceItem] = []
    @State private var extensionCatalogState: CatalogState = .loading
    /// Custom extension list kept while "pi defaults" is chosen, so toggling back restores it.
    @State private var stashedCustomExtensions: [String] = []
    @State private var probe: ProbeState = .idle
    @State private var discoveredModels: [String] = []

    private struct SkillOption: Identifiable, Hashable {
        var id: String { path }
        let name: String
        let path: String
    }

    private enum CatalogState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private enum ProbeState: Equatable {
        case idle
        case checking
        case success(Int)
        case failure(String)
    }

    init(request: AgentEditorRequest) {
        var agent = request.agent
        if agent.backend == .hermes, agent.hermes == nil { agent.hermes = HermesConnection() }
        _agent = State(initialValue: agent)
        _stashedCustomExtensions = State(initialValue: agent.extensions ?? [])
        isNew = request.isNew
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                personaSection
                lookSection
                switch agent.backend {
                case .pi:
                    piWorkspaceSection
                    skillsSection
                    extensionsSection
                case .hermes:
                    hermesSection
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Divider()
            footer
        }
        .frame(width: 580, height: 700)
        .background(appTheme.panel)
        .task {
            guard agent.backend == .pi else { return }
            skillCatalog = Self.scanSkills()
            await loadExtensionCatalog()
        }
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 12) {
            AgentAvatar(look: agent.look, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFonts.heading(18, weight: .semibold))
                    .foregroundStyle(appTheme.text)
                    .lineLimit(1)
                Text(agent.backend == .pi ? "Pi agent · runs locally" : "Hermes agent · runs on a remote server")
                    .font(AppFonts.ui(12))
                    .foregroundStyle(appTheme.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .help("The backend can’t be changed after the agent is created.")
    }

    private var title: String {
        if isNew { return agent.backend == .pi ? "New Pi Agent" : "New Hermes Agent" }
        return "Edit \(agent.name.nonEmptyTrimmed ?? "Agent")"
    }

    private var footer: some View {
        HStack {
            if let problem = validationProblem {
                Text(problem)
                    .font(AppFonts.ui(12))
                    .foregroundStyle(appTheme.muted)
            }
            Spacer()
            Button("Cancel") { model.agentEditorRequest = nil }
                .keyboardShortcut(.cancelAction)
            Button(isNew ? "Create Agent" : "Save") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(validationProblem != nil)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var validationProblem: String? {
        if agent.name.nonEmptyTrimmed == nil { return "Enter a name." }
        if agent.backend == .hermes {
            guard let hermes = agent.hermes else { return "Missing Hermes connection." }
            if hermes.host.nonEmptyTrimmed == nil { return "Enter a host." }
            if !(1...65535).contains(hermes.port) { return "Enter a port between 1 and 65535." }
        }
        return nil
    }

    private func save() {
        var saved = agent
        saved.name = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.role = agent.role.trimmingCharacters(in: .whitespacesAndNewlines)
        if var hermes = saved.hermes {
            hermes.host = hermes.host.trimmingCharacters(in: .whitespacesAndNewlines)
            hermes.profile = hermes.profile.trimmingCharacters(in: .whitespacesAndNewlines)
            saved.hermes = hermes
        }
        let key = saved.backend == .hermes ? apiKey.nonEmptyTrimmed : nil
        model.saveAgent(saved, hermesAPIKey: key)
        model.agentEditorRequest = nil
    }

    // MARK: Persona and look

    private var personaSection: some View {
        Section {
            TextField("Name", text: $agent.name)
            TextField("Role", text: $agent.role, prompt: Text("e.g. Code reviewer"))
        } header: {
            Text("Persona")
        } footer: {
            note("Name, role, skills, and extensions take effect on the agent’s next /reload or /new.")
        }
    }

    private var lookSection: some View {
        Section("Look") {
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 8) {
                    AgentPortrait(look: agent.look, scale: 2)
                    Button {
                        agent.look = .random()
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Hair", selection: $agent.look.hairStyle) {
                        ForEach(Look.Hair.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    Picker("Top", selection: $agent.look.top) {
                        ForEach(Look.Top.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    Picker("Accessory", selection: $agent.look.accessory) {
                        ForEach(Look.Accessory.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    Toggle("Smiling", isOn: $agent.look.happy)
                }
                .pickerStyle(.menu)
            }
            swatches("Skin", Look.skins, $agent.look.skin)
            swatches("Hair color", Look.hairs, $agent.look.hair)
            swatches("Shirt", Look.shirts, $agent.look.shirt)
            swatches("Pants", Look.pantsColors, $agent.look.pants)
            swatches("Shoes", Look.shoeColors, $agent.look.shoes)
            swatches("Glasses", Look.accents, $agent.look.accentColor)
        }
    }

    private func swatches(_ label: String, _ palette: [String], _ selection: Binding<String>) -> some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                ForEach(palette, id: \.self) { hex in
                    let selected = selection.wrappedValue.lowercased() == hex.lowercased()
                    Button {
                        selection.wrappedValue = hex
                    } label: {
                        Circle()
                            .fill(Color(lookHex: hex))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 1))
                            .padding(2)
                            .overlay(Circle().strokeBorder(selected ? appTheme.brass : Color.clear, lineWidth: 2))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(label) \(hex)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    // MARK: Pi

    private var piWorkspaceSection: some View {
        Section("Workspace") {
            LabeledContent("Folder") {
                HStack(spacing: 8) {
                    Text(agent.projectPath?.abbreviatingHomeDirectory() ?? "Quick Chats (saved sessions)")
                        .foregroundStyle(agent.projectPath == nil ? appTheme.muted : appTheme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(agent.projectPath ?? agent.workingDirectory)
                    Button("Choose…", action: chooseFolder)
                    if agent.projectPath != nil {
                        Button("Clear") { agent.projectPath = nil }
                            .help("Use PiG’s Quick Chats folder (chats are saved)")
                    }
                }
            }
            ModelSelectionControl(
                title: "Default model",
                selection: Binding(
                    get: { agent.modelID ?? "" },
                    set: { agent.modelID = $0.nonEmptyTrimmed }
                ),
                models: model.sessionNamingModels,
                loadState: model.modelCatalogLoadState,
                retry: model.reloadModelCatalog,
                allowsEmptySelection: true,
                emptyLabel: "PiG default",
                clearLabel: "Use PiG default"
            )
            Picker("Thinking", selection: $agent.thinking) {
                Text("PiG default").tag(String?.none)
                ForEach(SessionController.thinkingLevels, id: \.self) { level in
                    Text(level).tag(String?.some(level))
                }
            }
            .pickerStyle(.menu)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder \(agent.name.nonEmptyTrimmed ?? "this agent") works in."
        if let path = agent.projectPath { panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true) }
        if panel.runModal() == .OK, let url = panel.url {
            agent.projectPath = url.standardizedFileURL.path
        }
    }

    private var skillsSection: some View {
        Section {
            let catalogPaths = Set(skillCatalog.map(\.path))
            let missing = agent.skills.filter { !catalogPaths.contains($0) }
            if skillCatalog.isEmpty && missing.isEmpty {
                Text("No skills found in \(PiPaths.agentDir.appendingPathComponent("skills").path.abbreviatingHomeDirectory()).")
                    .foregroundStyle(appTheme.muted)
            }
            ForEach(skillCatalog) { skill in
                Toggle(skill.name, isOn: membership(skill.path, in: $agent.skills))
                    .help(skill.path)
            }
            ForEach(missing, id: \.self) { path in
                missingEntry(path, detail: "SKILL.md not found") {
                    agent.skills.removeAll { $0 == path }
                }
            }
        } header: {
            Text("Skills")
        } footer: {
            note("Checked skills are appended to the agent’s system prompt.")
        }
    }

    private var extensionsSection: some View {
        Section {
            Picker("Extensions", selection: customExtensionsBinding) {
                Text("pi defaults").tag(false)
                Text("Custom: only these").tag(true)
            }
            .pickerStyle(.segmented)
            if agent.extensions != nil {
                switch extensionCatalogState {
                case .loading:
                    SignalMarchLoadingLabel(text: "Loading extensions…")
                case .failed(let message):
                    HStack {
                        Text(message)
                            .foregroundStyle(appTheme.muted)
                            .lineLimit(2)
                        Spacer()
                        Button("Retry") { Task { await loadExtensionCatalog() } }
                    }
                case .loaded:
                    if extensionCatalog.isEmpty {
                        Text("No extensions found.")
                            .foregroundStyle(appTheme.muted)
                    }
                }
                ForEach(extensionCatalog) { item in
                    Toggle(isOn: membership(item.path, in: customExtensionsList)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.displayName)
                            if !item.groupLabel.isEmpty {
                                Text(item.groupLabel)
                                    .font(AppFonts.ui(11))
                                    .foregroundStyle(appTheme.muted)
                            }
                        }
                    }
                    .help(item.path)
                }
                if extensionCatalogState != .loading {
                    let catalogPaths = Set(extensionCatalog.map(\.path))
                    ForEach((agent.extensions ?? []).filter { !catalogPaths.contains($0) }, id: \.self) { entry in
                        missingEntry(entry, detail: "Not in the extension catalog") {
                            agent.extensions?.removeAll { $0 == entry }
                        }
                    }
                }
            }
        } header: {
            Text("Extensions")
        } footer: {
            note(agent.extensions == nil
                 ? "Loads the same extensions as your other pi sessions."
                 : "Launches with --no-extensions and loads only the checked extensions.")
        }
    }

    private var customExtensionsBinding: Binding<Bool> {
        Binding(
            get: { agent.extensions != nil },
            set: { custom in
                if custom {
                    agent.extensions = agent.extensions ?? stashedCustomExtensions
                } else {
                    stashedCustomExtensions = agent.extensions ?? []
                    agent.extensions = nil
                }
            }
        )
    }

    private var customExtensionsList: Binding<[String]> {
        Binding(get: { agent.extensions ?? [] }, set: { agent.extensions = $0 })
    }

    private func loadExtensionCatalog() async {
        extensionCatalogState = .loading
        do {
            var seen = Set<String>()
            extensionCatalog = try await PiResourceService.list()
                .filter { $0.type == "extensions" && seen.insert($0.path).inserted }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            extensionCatalogState = .loaded
        } catch {
            extensionCatalogState = .failed(error.localizedDescription)
        }
    }

    private static func scanSkills() -> [SkillOption] {
        let root = PiPaths.agentDir.appendingPathComponent("skills", isDirectory: true)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        return entries.compactMap { dir in
            let file = dir.appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: file.path) else { return nil }
            return SkillOption(name: dir.lastPathComponent, path: file.standardizedFileURL.path)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Hermes

    private var hermesSection: some View {
        Section {
            TextField("Host", text: hermesBinding.host, prompt: Text("SSH alias or user@host"))
            TextField("Profile", text: hermesBinding.profile, prompt: Text("default"))
            TextField("Port", value: hermesBinding.port, format: .number.grouping(.never), prompt: Text("8642"))
            SecureField("API key", text: $apiKey, prompt: Text(isNew ? "API key" : "Leave blank to keep the saved key"))
            HStack(spacing: 10) {
                Button("Check Connection", action: checkConnection)
                    .disabled(probe == .checking || agent.hermes?.host.nonEmptyTrimmed == nil)
                probeStatus
                Spacer(minLength: 0)
            }
            Picker("Default model", selection: $agent.modelID) {
                Text("Server default").tag(String?.none)
                ForEach(hermesModelOptions, id: \.self) { id in
                    Text(id).tag(String?.some(id))
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text("Hermes Connection")
        } footer: {
            note("PiG reaches the server over an SSH tunnel. Check Connection discovers the server’s models without starting a turn.")
        }
        .onChange(of: agent.hermes) { _, _ in probe = .idle }
        .onChange(of: apiKey) { _, _ in probe = .idle }
    }

    private var hermesBinding: Binding<HermesConnection> {
        Binding(get: { agent.hermes ?? HermesConnection(credentialID: "") }, set: { agent.hermes = $0 })
    }

    private var hermesModelOptions: [String] {
        var options = discoveredModels
        if let saved = agent.modelID, !options.contains(saved) { options.insert(saved, at: 0) }
        return options
    }

    @ViewBuilder private var probeStatus: some View {
        switch probe {
        case .idle:
            EmptyView()
        case .checking:
            SignalMarchLoadingLabel(text: "Checking…")
        case .success(let count):
            Label(count == 1 ? "Connected · 1 model" : "Connected · \(count) models", systemImage: "checkmark.circle.fill")
                .foregroundStyle(appTheme.good)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(appTheme.danger)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }

    private func checkConnection() {
        guard var connection = agent.hermes else { return }
        connection.host = connection.host.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.profile = connection.profile.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.nonEmptyTrimmed
        probe = .checking
        Task {
            do {
                let result = try await HermesProbe.check(connection, apiKey: key)
                discoveredModels = result.models
                probe = .success(result.models.count)
            } catch {
                probe = .failure(error.localizedDescription)
            }
        }
    }

    // MARK: Helpers

    private func note(_ text: String) -> some View {
        Text(text)
            .font(AppFonts.ui(11.5))
            .foregroundStyle(appTheme.muted)
    }

    private func missingEntry(_ value: String, detail: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(value.abbreviatingHomeDirectory())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(AppFonts.ui(11))
                    .foregroundStyle(appTheme.muted)
            }
            .help(value)
            Spacer()
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(appTheme.muted)
            .help("Remove")
            .accessibilityLabel("Remove \(value)")
        }
    }

    private func membership(_ value: String, in list: Binding<[String]>) -> Binding<Bool> {
        Binding(
            get: { list.wrappedValue.contains(value) },
            set: { isOn in
                if isOn {
                    if !list.wrappedValue.contains(value) { list.wrappedValue.append(value) }
                } else {
                    list.wrappedValue.removeAll { $0 == value }
                }
            }
        )
    }
}
