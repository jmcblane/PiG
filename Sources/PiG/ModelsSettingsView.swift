import SwiftUI

struct ModelsSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(QuickModelSlots.key(1)) private var quickModel1 = ""
    @AppStorage(QuickModelSlots.key(2)) private var quickModel2 = ""
    @AppStorage(QuickModelSlots.key(3)) private var quickModel3 = ""
    @AppStorage(QuickModelSlots.key(4)) private var quickModel4 = ""
    @AppStorage(QuickModelSlots.key(5)) private var quickModel5 = ""
    @AppStorage(TitleGenerationExtensionsPreference.key) private var titleExtensions = ""

    private let weekdays = [
        (2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"),
        (6, "Fri"), (7, "Sat"), (1, "Sun")
    ]

    var body: some View {
        Form {
            Section("New Sessions") {
                Picker("Default", selection: $model.newSessionModelMode) {
                    ForEach(NewSessionModelMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if model.newSessionModelMode == .single {
                    ModelSelectionControl(
                        title: "Model",
                        selection: $model.singleSessionModelID,
                        models: model.sessionNamingModels,
                        loadState: model.modelCatalogLoadState,
                        retry: model.reloadModelCatalog,
                        allowsEmptySelection: true,
                        emptyLabel: "Pi default",
                        clearLabel: "Use pi default"
                    )
                } else {
                    LabeledContent("Work days") {
                        HStack(spacing: 4) {
                            ForEach(weekdays, id: \.0) { day, name in
                                Toggle(name, isOn: weekdayBinding(day))
                                    .toggleStyle(.button)
                                    .controlSize(.small)
                            }
                        }
                    }

                    DatePicker("Starts", selection: minutesBinding($model.scheduledStartMinutes), displayedComponents: .hourAndMinute)
                    DatePicker("Ends", selection: minutesBinding($model.scheduledEndMinutes), displayedComponents: .hourAndMinute)

                    TimeZoneSelectionControl(selection: $model.scheduledTimeZoneID)

                    ModelSelectionControl(
                        title: "Work model",
                        selection: $model.scheduledWorkModelID,
                        models: model.sessionNamingModels,
                        loadState: model.modelCatalogLoadState,
                        retry: model.reloadModelCatalog,
                        allowsEmptySelection: true,
                        emptyLabel: "Pi default",
                        clearLabel: "Use pi default"
                    )
                    ModelSelectionControl(
                        title: "Off-hours model",
                        selection: $model.scheduledOffHoursModelID,
                        models: model.sessionNamingModels,
                        loadState: model.modelCatalogLoadState,
                        retry: model.reloadModelCatalog,
                        allowsEmptySelection: true,
                        emptyLabel: "Pi default",
                        clearLabel: "Use pi default"
                    )

                    if !DefaultModelSchedule.isValid {
                        Label("Choose at least one work day and an end time after the start time.", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    } else {
                        ScheduleStatus(models: model.sessionNamingModels)
                    }
                }

                Picker("Default thinking", selection: $model.defaultThinkingLevel) {
                    ForEach(SessionController.thinkingLevels, id: \.self) { level in
                        Text(level.capitalized).tag(level)
                    }
                }
            }

            Section("Quick Models") {
                ForEach(1...5, id: \.self) { slot in
                    ModelSelectionControl(
                        title: "⌘\(slot)",
                        selection: quickModelBinding(slot),
                        models: model.sessionNamingModels,
                        loadState: model.modelCatalogLoadState,
                        retry: model.reloadModelCatalog,
                        allowsEmptySelection: true
                    )
                }
            }

            Section("Session Naming") {
                Toggle("Automatically name new sessions", isOn: $model.automaticSessionNamingEnabled)

                Group {
                    Picker("Naming model", selection: $model.sessionNamingModelMode) {
                        ForEach(SessionNamingModelMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }

                    if model.sessionNamingModelMode == .specific {
                        ModelSelectionControl(
                            title: "Specific model",
                            selection: $model.sessionNamingModelID,
                            models: model.sessionNamingModels,
                            loadState: model.modelCatalogLoadState,
                            retry: model.reloadModelCatalog
                        )
                    }

                    if model.sessionNamingModelMode == .apple {
                        let status = AppleIntelligenceNaming.status
                        Label(status.message, systemImage: status.isReady ? "checkmark.circle" : "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(status.isReady ? Color.secondary : Color.orange)
                    } else {
                        Picker("Naming thinking", selection: $model.sessionNamingThinkingLevel) {
                            ForEach(SessionController.thinkingLevels, id: \.self) { level in
                                Text(level.capitalized).tag(level)
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Extensions for title generation")
                            TextEditor(text: $titleExtensions)
                                .font(.system(.callout, design: .monospaced))
                                .frame(height: 72)
                                .border(.separator)
                            Text("One path per line. Loaded into the pi process that generates titles.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            ForEach(missingTitleExtensionPaths, id: \.self) { path in
                                Label("Not found, will be skipped: \(path)", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
                .disabled(!model.automaticSessionNamingEnabled)
            }
        }
        .formStyle(.grouped)
    }

    private var missingTitleExtensionPaths: [String] {
        titleExtensions
            .components(separatedBy: .newlines)
            .compactMap(\.nonEmptyTrimmed)
            .filter { !FileManager.default.fileExists(atPath: ($0 as NSString).expandingTildeInPath) }
    }

    private func weekdayBinding(_ day: Int) -> Binding<Bool> {
        Binding {
            model.scheduledWorkWeekdays.contains(day)
        } set: { isOn in
            if isOn { model.scheduledWorkWeekdays.insert(day) }
            else { model.scheduledWorkWeekdays.remove(day) }
        }
    }

    private func quickModelBinding(_ slot: Int) -> Binding<String> {
        switch slot {
        case 1: return $quickModel1
        case 2: return $quickModel2
        case 3: return $quickModel3
        case 4: return $quickModel4
        default: return $quickModel5
        }
    }

    private func minutesBinding(_ source: Binding<Int>) -> Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: source.wrappedValue / 60, minute: source.wrappedValue % 60, second: 0, of: Date()) ?? Date()
        } set: { date in
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            source.wrappedValue = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        }
    }
}

private struct TimeZoneSelectionControl: View {
    @Binding var selection: String
    @State private var isPresented = false
    @State private var query = ""

    private var filteredIdentifiers: [String] {
        guard let needle = query.nonEmptyTrimmed?.lowercased() else {
            return TimeZone.knownTimeZoneIdentifiers
        }
        return TimeZone.knownTimeZoneIdentifiers.filter { $0.lowercased().contains(needle) }
    }

    private var selectionLabel: String {
        selection == DefaultModelSchedule.systemTimeZoneID
            ? "System (\(TimeZone.autoupdatingCurrent.identifier))"
            : selection
    }

    var body: some View {
        LabeledContent("Time zone") {
            Button {
                isPresented.toggle()
            } label: {
                HStack(spacing: 5) {
                    Text(selectionLabel)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
            }
            .popover(isPresented: $isPresented, arrowEdge: .trailing) {
                VStack(spacing: 0) {
                    TextField("Search time zones", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .padding(10)
                    Divider()
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            timeZoneRow(
                                title: "System (\(TimeZone.autoupdatingCurrent.identifier))",
                                identifier: DefaultModelSchedule.systemTimeZoneID
                            )
                            Divider()
                            ForEach(filteredIdentifiers, id: \.self) { identifier in
                                timeZoneRow(title: identifier, identifier: identifier)
                            }
                        }
                        .padding(.vertical, 5)
                    }
                }
                .frame(width: 340, height: 390)
            }
        }
    }

    private func timeZoneRow(title: String, identifier: String) -> some View {
        Button {
            selection = identifier
            isPresented = false
        } label: {
            HStack {
                Image(systemName: "checkmark")
                    .opacity(selection == identifier ? 1 : 0)
                    .frame(width: 14)
                Text(title)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}

private struct ScheduleStatus: View {
    let models: [ModelInfo]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let activeID = DefaultModelSchedule.effectiveModelID(at: context.date) ?? "Not selected"
            let activeName = models.first(where: { $0.id == activeID })?.displayName ?? activeID
            LabeledContent("Active for new sessions", value: activeName)
        }
    }
}

private struct ModelSelectionControl: View {
    let title: String
    @Binding var selection: String
    let models: [ModelInfo]
    let loadState: ModelCatalogLoadState
    let retry: () -> Void
    var allowsEmptySelection = false
    var emptyLabel = "None"
    var clearLabel = "Clear shortcut"

    @State private var isPresented = false
    @State private var query = ""
    @State private var pinnedIDs = PinnedModels.ids

    private var selectedModel: ModelInfo? { models.first { $0.id == selection } }
    private var filteredModels: [ModelInfo] {
        guard let needle = query.nonEmptyTrimmed?.lowercased() else { return models }
        return models.filter {
            [$0.name, $0.modelId, $0.provider, $0.id].contains { $0.lowercased().contains(needle) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            LabeledContent(title) {
                Button {
                    pinnedIDs = PinnedModels.ids
                    isPresented.toggle()
                } label: {
                    HStack(spacing: 5) {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(selectedModel?.name ?? (selection.isEmpty ? (allowsEmptySelection ? emptyLabel : "Choose model") : selection))
                                .lineLimit(1)
                            if let selectedModel {
                                Text("\(selectedModel.provider)/\(selectedModel.modelId)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                }
                .popover(isPresented: $isPresented, arrowEdge: .trailing) {
                    pickerContent
                }
            }

            if selection.isEmpty && !allowsEmptySelection {
                Label("Choose a model.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if !selection.isEmpty && selectedModel == nil && loadState != .loading {
                Label("Saved model is unavailable. It will not be replaced automatically.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var pickerContent: some View {
        VStack(spacing: 0) {
            TextField("Search models", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(10)

            Divider()

            if allowsEmptySelection && !selection.isEmpty {
                Button(clearLabel) {
                    selection = ""
                    isPresented = false
                }
                .padding(10)
                Divider()
            }

            if !models.isEmpty {
                if case .failed(let message) = loadState {
                    VStack(spacing: 6) {
                        Text("Model list may be incomplete. \(message)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Retry", action: retry)
                    }
                    .padding(10)
                } else if loadState == .loading {
                    SignalMarchLoadingLabel(text: "Refreshing models…")
                        .padding(10)
                }
            }

            switch loadState {
            case .loading where models.isEmpty:
                SignalMarchLoadingLabel(text: "Loading models…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            case .failed(let message) where models.isEmpty:
                VStack(spacing: 8) {
                    Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Retry", action: retry)
                }
                .padding()
                .frame(maxWidth: .infinity, minHeight: 120)
            default:
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let pinned = filteredModels.filter { pinnedIDs.contains($0.id) }
                        if !pinned.isEmpty {
                            groupHeader("Pinned")
                            ForEach(pinned) { model in modelRow(model) }
                        }
                        ForEach(Dictionary(grouping: filteredModels.filter { !pinnedIDs.contains($0.id) }, by: \.provider).keys.sorted(), id: \.self) { provider in
                            groupHeader(provider)
                            ForEach(filteredModels.filter { $0.provider == provider && !pinnedIDs.contains($0.id) }) { model in
                                modelRow(model)
                            }
                        }
                        if filteredModels.isEmpty {
                            Text("No matching models")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding()
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .frame(width: 390, height: 410)
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }

    private func modelRow(_ model: ModelInfo) -> some View {
        HStack(spacing: 8) {
            Button {
                selection = model.id
                isPresented = false
            } label: {
                HStack {
                    Image(systemName: "checkmark")
                        .opacity(selection == model.id ? 1 : 0)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.name).foregroundStyle(.primary)
                        Text("\(model.provider)/\(model.modelId)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                PinnedModels.toggle(model.id)
                pinnedIDs = PinnedModels.ids
            } label: {
                Image(systemName: pinnedIDs.contains(model.id) ? "star.fill" : "star")
                    .foregroundStyle(pinnedIDs.contains(model.id) ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .help(pinnedIDs.contains(model.id) ? "Unpin" : "Pin to top")
            .accessibilityLabel(pinnedIDs.contains(model.id) ? "Unpin \(model.name)" : "Pin \(model.name)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}
