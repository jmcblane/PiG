import SwiftUI

struct ModelsSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appTheme) private var appTheme
    @AppStorage(QuickModelSlots.key(1)) private var quickModel1 = ""
    @AppStorage(QuickModelSlots.key(2)) private var quickModel2 = ""
    @AppStorage(QuickModelSlots.key(3)) private var quickModel3 = ""
    @AppStorage(QuickModelSlots.key(4)) private var quickModel4 = ""
    @AppStorage(QuickModelSlots.key(5)) private var quickModel5 = ""
    @AppStorage(TitleGenerationExtensionsPreference.key) private var titleExtensions = ""
    @FocusState private var titleExtensionsFocused: Bool

    private let weekdays = [
        (2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"),
        (6, "Fri"), (7, "Sat"), (1, "Sun")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                newSessionsSection
                quickModelsSection
                sessionNamingSection
            }
            .padding(20)
        }
    }

    private var newSessionsSection: some View {
        GlowSection("New Chats") {
            GlowRow("Default") {
                GlowSegmented(selection: $model.newSessionModelMode, options: NewSessionModelMode.allCases, label: { $0.title })
            }

            if model.newSessionModelMode == .single {
                GlowBlockRow {
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
                }
            } else {
                scheduleRows
            }

            GlowRow("Default thinking") {
                GlowDropdown(selection: $model.defaultThinkingLevel, options: SessionController.thinkingLevels, label: { $0.capitalized })
            }
        }
    }

    @ViewBuilder
    private var scheduleRows: some View {
        GlowRow("Work days") {
            HStack(spacing: 4) {
                ForEach(weekdays, id: \.0) { day, name in
                    Toggle(name, isOn: weekdayBinding(day))
                        .toggleStyle(WeekdayChipToggleStyle())
                }
            }
        }

        GlowRow("Starts") {
            DatePicker("Starts", selection: minutesBinding($model.scheduledStartMinutes), displayedComponents: .hourAndMinute)
                .labelsHidden()
        }
        GlowRow("Ends") {
            DatePicker("Ends", selection: minutesBinding($model.scheduledEndMinutes), displayedComponents: .hourAndMinute)
                .labelsHidden()
        }

        TimeZoneSelectionControl(selection: $model.scheduledTimeZoneID)

        GlowBlockRow {
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
        }
        GlowBlockRow {
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
        }

        if !DefaultModelSchedule.isValid {
            GlowBlockRow {
                Label("Choose at least one work day and an end time after the start time.", systemImage: "exclamationmark.triangle.fill")
                    .font(AppFonts.ui(12))
                    .foregroundStyle(.orange)
            }
        } else {
            ScheduleStatus(models: model.sessionNamingModels)
        }
    }

    private var quickModelsSection: some View {
        GlowSection("Quick Models") {
            ForEach(1...5, id: \.self) { slot in
                GlowBlockRow {
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
        }
    }

    private var sessionNamingSection: some View {
        GlowSection("Chat Naming") {
            GlowBlockRow {
                Toggle(isOn: $model.automaticSessionNamingEnabled) {
                    Text("Automatically name new chats")
                        .font(AppFonts.ui(13))
                        .foregroundStyle(appTheme.text)
                }
                .toggleStyle(.glow)
            }

            Group {
                GlowRow("Naming model") {
                    GlowDropdown(selection: $model.sessionNamingModelMode, options: SessionNamingModelMode.allCases, label: { $0.title })
                }

                if model.sessionNamingModelMode == .specific {
                    GlowBlockRow {
                        ModelSelectionControl(
                            title: "Specific model",
                            selection: $model.sessionNamingModelID,
                            models: model.sessionNamingModels,
                            loadState: model.modelCatalogLoadState,
                            retry: model.reloadModelCatalog
                        )
                    }
                }

                if model.sessionNamingModelMode == .apple {
                    let status = AppleIntelligenceNaming.status
                    GlowBlockRow {
                        Label(status.message, systemImage: status.isReady ? "checkmark.circle" : "exclamationmark.triangle.fill")
                            .font(AppFonts.ui(11.5))
                            .foregroundStyle(status.isReady ? appTheme.muted : Color.orange)
                    }
                } else {
                    GlowRow("Naming thinking") {
                        GlowDropdown(selection: $model.sessionNamingThinkingLevel, options: SessionController.thinkingLevels, label: { $0.capitalized })
                    }

                    GlowBlockRow { titleExtensionsEditor }
                }
            }
            .disabled(!model.automaticSessionNamingEnabled)
            .opacity(model.automaticSessionNamingEnabled ? 1 : 0.55)
        }
    }

    private var titleExtensionsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Extensions for title generation")
                .font(AppFonts.ui(13))
                .foregroundStyle(appTheme.text)
            TextEditor(text: $titleExtensions)
                .font(AppFonts.code(12))
                .foregroundStyle(appTheme.text)
                .scrollContentBackground(.hidden)
                .focused($titleExtensionsFocused)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .frame(height: 72)
                .glowField(focused: titleExtensionsFocused)
            Text("One path per line. Loaded into the pi process that generates titles.")
                .font(AppFonts.ui(11.5))
                .foregroundStyle(appTheme.muted)
            ForEach(missingTitleExtensionPaths, id: \.self) { path in
                Label("Not found, will be skipped: \(path)", systemImage: "exclamationmark.triangle.fill")
                    .font(AppFonts.ui(11.5))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
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

/// Small on/off chip for the work-day row.
private struct WeekdayChipToggleStyle: ToggleStyle {
    @Environment(\.appTheme) private var appTheme

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return Button { configuration.isOn.toggle() } label: {
            configuration.label
                .font(AppFonts.ui(11.5, weight: configuration.isOn ? .semibold : .regular))
                .foregroundStyle(configuration.isOn ? appTheme.text : appTheme.muted)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(shape.fill(configuration.isOn ? appTheme.brass.opacity(0.18) : appTheme.panel))
                .overlay(shape.stroke(configuration.isOn ? appTheme.brass.opacity(0.55) : appTheme.line, lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

/// Trigger chrome shared by the time zone and model pickers, matching `GlowDropdown`.
private struct GlowPickerTrigger<Content: View>: View {
    @Environment(\.appTheme) private var appTheme
    let open: Bool
    let label: Content
    @State private var hovering = false

    init(open: Bool, @ViewBuilder label: () -> Content) {
        self.open = open
        self.label = label()
    }

    var body: some View {
        HStack(spacing: 6) {
            label
            Image(systemName: "chevron.down")
                .font(AppFonts.ui(8.5, weight: .bold))
                .foregroundStyle(appTheme.muted)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering || open ? appTheme.panel2 : appTheme.panel)
        )
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(appTheme.line, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct TimeZoneSelectionControl: View {
    @Environment(\.appTheme) private var appTheme
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
        GlowRow("Time zone") {
            Button {
                isPresented.toggle()
            } label: {
                GlowPickerTrigger(open: isPresented) {
                    Text(selectionLabel)
                        .font(AppFonts.ui(12))
                        .foregroundStyle(appTheme.text)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isPresented, arrowEdge: .trailing) {
                popoverContent
            }
        }
    }

    private var popoverContent: some View {
        VStack(spacing: 0) {
            GlowTextField("Search time zones", text: $query)
                .padding(10)
            Rectangle().fill(appTheme.line).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    timeZoneRow(
                        title: "System (\(TimeZone.autoupdatingCurrent.identifier))",
                        identifier: DefaultModelSchedule.systemTimeZoneID
                    )
                    PopoverMenuDivider()
                    ForEach(filteredIdentifiers, id: \.self) { identifier in
                        timeZoneRow(title: identifier, identifier: identifier)
                    }
                }
                .padding(.vertical, 5)
            }
        }
        .frame(width: 340, height: 390)
        .glowPresentationBackground()
        .environment(\.appTheme, appTheme)
    }

    private func timeZoneRow(title: String, identifier: String) -> some View {
        PopoverPickerRow(title: title, isSelected: selection == identifier) {
            selection = identifier
            isPresented = false
        }
    }
}

private struct ScheduleStatus: View {
    @Environment(\.appTheme) private var appTheme
    let models: [ModelInfo]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let activeID = DefaultModelSchedule.effectiveModelID(at: context.date) ?? "Not selected"
            let activeName = models.first(where: { $0.id == activeID })?.displayName ?? activeID
            GlowRow("Active for new chats") {
                Text(activeName)
                    .font(AppFonts.ui(12.5))
                    .foregroundStyle(appTheme.secondaryText)
                    .lineLimit(1)
            }
        }
    }
}

/// Model picker row: title on the left, a themed trigger that opens a searchable popover.
/// Draws no row chrome of its own; wrap it in a `GlowBlockRow` inside a `GlowSection`.
struct ModelSelectionControl: View {
    @Environment(\.appTheme) private var appTheme
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
            HStack(spacing: 12) {
                Text(title)
                    .font(AppFonts.ui(13))
                    .foregroundStyle(appTheme.text)
                Spacer(minLength: 8)
                trigger
            }

            if selection.isEmpty && !allowsEmptySelection {
                Label("Choose a model.", systemImage: "exclamationmark.triangle.fill")
                    .font(AppFonts.ui(11.5))
                    .foregroundStyle(.orange)
            } else if !selection.isEmpty && selectedModel == nil && loadState != .loading {
                Label("Saved model is unavailable. It will not be replaced automatically.", systemImage: "exclamationmark.triangle.fill")
                    .font(AppFonts.ui(11.5))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var trigger: some View {
        Button {
            pinnedIDs = PinnedModels.ids
            isPresented.toggle()
        } label: {
            GlowPickerTrigger(open: isPresented) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(selectedModel?.name ?? (selection.isEmpty ? (allowsEmptySelection ? emptyLabel : "Choose model") : selection))
                        .font(AppFonts.ui(12))
                        .foregroundStyle(appTheme.text)
                        .lineLimit(1)
                    if let selectedModel {
                        Text("\(selectedModel.provider)/\(selectedModel.modelId)")
                            .font(AppFonts.ui(10.5))
                            .foregroundStyle(appTheme.muted)
                            .lineLimit(1)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            pickerContent
        }
    }

    private var pickerContent: some View {
        VStack(spacing: 0) {
            GlowTextField("Search models", text: $query)
                .padding(10)

            divider

            if allowsEmptySelection && !selection.isEmpty {
                Button(clearLabel) {
                    selection = ""
                    isPresented = false
                }
                .buttonStyle(GlowButtonStyle())
                .padding(10)
                divider
            }

            if !models.isEmpty {
                if case .failed(let message) = loadState {
                    VStack(spacing: 6) {
                        Text("Model list may be incomplete. \(message)")
                            .font(AppFonts.ui(11.5))
                            .foregroundStyle(appTheme.muted)
                        Button("Retry", action: retry)
                            .buttonStyle(GlowButtonStyle())
                    }
                    .padding(10)
                } else if loadState == .loading {
                    SignalMarchLoadingLabel(text: "Refreshing models…")
                        .padding(10)
                }
            }

            modelList
        }
        .frame(width: 390, height: 410)
        .glowPresentationBackground()
        .environment(\.appTheme, appTheme)
    }

    private var divider: some View {
        Rectangle().fill(appTheme.line).frame(height: 1)
    }

    @ViewBuilder
    private var modelList: some View {
        switch loadState {
        case .loading where models.isEmpty:
            SignalMarchLoadingLabel(text: "Loading models…")
                .frame(maxWidth: .infinity, minHeight: 120)
        case .failed(let message) where models.isEmpty:
            VStack(spacing: 8) {
                Text(message)
                    .font(AppFonts.ui(12.5))
                    .foregroundStyle(appTheme.muted)
                    .multilineTextAlignment(.center)
                Button("Retry", action: retry)
                    .buttonStyle(GlowButtonStyle())
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
                            .font(AppFonts.ui(12.5))
                            .foregroundStyle(appTheme.muted)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                }
                .padding(.vertical, 5)
            }
        }
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(AppFonts.ui(10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(appTheme.muted)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }

    private func modelRow(_ model: ModelInfo) -> some View {
        ModelPickerRow(
            model: model,
            isSelected: selection == model.id,
            isPinned: pinnedIDs.contains(model.id),
            select: {
                selection = model.id
                isPresented = false
            },
            togglePin: {
                PinnedModels.toggle(model.id)
                pinnedIDs = PinnedModels.ids
            }
        )
    }
}

/// One row in the model picker popover: checkmark, name and id, and a pin star.
private struct ModelPickerRow: View {
    @Environment(\.appTheme) private var appTheme
    let model: ModelInfo
    let isSelected: Bool
    let isPinned: Bool
    let select: () -> Void
    let togglePin: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: select) {
                HStack {
                    Image(systemName: "checkmark")
                        .font(AppFonts.ui(10, weight: .bold))
                        .foregroundStyle(appTheme.brass)
                        .opacity(isSelected ? 1 : 0)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.name)
                            .font(AppFonts.ui(12.5, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(appTheme.text)
                        Text("\(model.provider)/\(model.modelId)")
                            .font(AppFonts.ui(11))
                            .foregroundStyle(appTheme.muted)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: togglePin) {
                Image(systemName: isPinned ? "star.fill" : "star")
                    .foregroundStyle(isPinned ? appTheme.brass : appTheme.muted)
            }
            .buttonStyle(.plain)
            .help(isPinned ? "Unpin" : "Pin to top")
            .accessibilityLabel(isPinned ? "Unpin \(model.name)" : "Pin \(model.name)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(hovering ? appTheme.brass.opacity(0.12) : Color.clear)
        .onHover { hovering = $0 }
    }
}
