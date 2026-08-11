import AppKit
import SwiftUI
import TrackifyDomain
import TrackifyEngine

struct ReportsView: View {
    @ObservedObject var model: AppModel
    @State private var section: ReportsSection
    @State private var sheet: ReportsSheet?
    @State private var selectedArtifactID: ArtifactID?
    @State private var selectedTemplateID: RecipeID?
    @State private var selectedScheduleID: ReportScheduleID?

    init(model: AppModel) {
        self.model = model
        let requested =
            ProcessInfo.processInfo.environment["TRACKIFY_UI_REPORTS_MODE"]
            .flatMap(ReportsSection.init(rawValue:)) ?? .history
        _section = State(initialValue: requested)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch section {
                case .history: history
                case .templates: templates
                case .scheduled: scheduled
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            selectDefaults()
            openValidationSheetIfRequested()
        }
        .onChange(of: model.artifacts) { _, _ in selectDefaults() }
        .onChange(of: model.reportTemplates) { _, _ in selectDefaults() }
        .onChange(of: model.reportSchedules) { _, _ in selectDefaults() }
        .sheet(item: $sheet) { item in
            switch item.content {
            case .composer(let seed):
                ReportComposer(model: model, seed: seed) { artifactID in
                    selectedArtifactID = artifactID
                    section = .history
                    sheet = nil
                }
                .frame(width: 720, height: 650)
            case .template(let seed):
                TemplateEditor(model: model, seed: seed) { recipeID in
                    selectedTemplateID = recipeID
                    section = .templates
                    sheet = nil
                }
                .frame(width: 640, height: 650)
            case .schedule(let schedule):
                ScheduleEditor(model: model, schedule: schedule) { scheduleID in
                    selectedScheduleID = scheduleID
                    section = .scheduled
                    sheet = nil
                }
                .frame(width: 580, height: 510)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                Text("EVIDENCE-BACKED OUTPUTS")
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(.tint)
                Text("Reports").font(.largeTitle.bold())
                Text(section.subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Section", selection: $section) {
                ForEach(ReportsSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 310)
            Button(actionTitle, systemImage: "plus") { performPrimaryAction() }
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }

    private var actionTitle: String {
        switch section {
        case .history: "New report"
        case .templates: "New template"
        case .scheduled: "New reporter"
        }
    }

    private func performPrimaryAction() {
        switch section {
        case .history:
            sheet = ReportsSheet(.composer(.new(defaultTemplateID: preferredTemplate?.id)))
        case .templates:
            guard let base = preferredTemplate else { return }
            sheet = ReportsSheet(.template(.new(base: base)))
        case .scheduled:
            sheet = ReportsSheet(.schedule(nil))
        }
    }

    private var history: some View {
        ReportHistoryView(
            model: model,
            selection: $selectedArtifactID,
            onNewReport: { sheet = ReportsSheet(.composer(.new(defaultTemplateID: preferredTemplate?.id))) },
            onRegenerate: { artifact in
                sheet = ReportsSheet(.composer(.regenerate(artifact: artifact, run: run(for: artifact))))
            })
    }

    private var templates: some View {
        TemplateLibraryView(
            model: model,
            selection: $selectedTemplateID,
            onEdit: { sheet = ReportsSheet(.template(.edit($0))) },
            onDuplicate: { sheet = ReportsSheet(.template(.duplicate($0))) })
    }

    private var scheduled: some View {
        ScheduleLibraryView(
            model: model,
            selection: $selectedScheduleID,
            onEdit: { sheet = ReportsSheet(.schedule($0)) })
    }

    private var reportArtifacts: [Artifact] {
        model.artifacts.filter { $0.type == .report }
    }

    private var preferredTemplate: ReportTemplate? {
        model.reportTemplates.first { $0.id.rawValue == "daily-work-summary" }
            ?? model.reportTemplates.first { $0.recipe.isEnabled && $0.id.rawValue != "legacy-v1-report" }
    }

    private func run(for artifact: Artifact) -> ReportRun? {
        artifact.reportRunID.flatMap { id in model.reportRuns.first { $0.id == id } }
    }

    private func selectDefaults() {
        if selectedArtifactID.flatMap({ id in reportArtifacts.first { $0.id == id } }) == nil {
            selectedArtifactID =
                ReportHistoryView.latestArtifacts(reportArtifacts).first?.id
                ?? reportArtifacts.first?.id
        }
        if selectedTemplateID.flatMap({ id in model.reportTemplates.first { $0.id == id } }) == nil {
            selectedTemplateID = preferredTemplate?.id
        }
        if selectedScheduleID.flatMap({ id in model.reportSchedules.first { $0.id == id } }) == nil {
            selectedScheduleID = model.reportSchedules.first?.id
        }
    }

    private func openValidationSheetIfRequested() {
        switch ProcessInfo.processInfo.environment["TRACKIFY_UI_REPORTS_SHEET"] {
        case "new-report":
            sheet = ReportsSheet(.composer(.new(defaultTemplateID: preferredTemplate?.id)))
        case "new-template":
            if let base = preferredTemplate { sheet = ReportsSheet(.template(.new(base: base))) }
        case "new-reporter":
            sheet = ReportsSheet(.schedule(nil))
        default:
            break
        }
    }
}

private enum ReportsSection: String, CaseIterable, Identifiable {
    case history, templates, scheduled
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var subtitle: String {
        switch self {
        case .history: "Generate, inspect, and copy useful accounts of your work."
        case .templates: "Define what a report should say."
        case .scheduled: "Choose which reports run automatically and when."
        }
    }
}

private struct ReportsSheet: Identifiable {
    enum Content {
        case composer(ReportComposerSeed)
        case template(TemplateEditorSeed)
        case schedule(ReportSchedule?)
    }
    let id = UUID()
    let content: Content
    init(_ content: Content) { self.content = content }
}

// MARK: - History

private struct ReportHistoryView: View {
    @ObservedObject var model: AppModel
    @Binding var selection: ArtifactID?
    let onNewReport: () -> Void
    let onRegenerate: (Artifact) -> Void
    @State private var search = ""
    @State private var filter: HistoryFilter = .latest

    private var reports: [Artifact] {
        let source = model.artifacts.filter { $0.type == .report }
        let visible = filter == .latest ? Self.latestArtifacts(source) : source
        guard !search.isEmpty else { return visible }
        return visible.filter { artifact in
            let name = model.reportTemplates.first { $0.id == artifact.recipeID }?.recipe.name ?? ""
            return name.localizedCaseInsensitiveContains(search)
                || artifact.content.localizedCaseInsensitiveContains(search)
        }
    }

    private var selected: Artifact? {
        reports.first { $0.id == selection } ?? reports.first
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    SearchField(placeholder: "Search reports", text: $search)
                    Picker("History", selection: $filter) {
                        ForEach(HistoryFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 125)
                }
                .padding(12)
                Divider()
                if reports.isEmpty {
                    ContentUnavailableView(
                        search.isEmpty ? "No reports yet" : "No matching reports",
                        systemImage: search.isEmpty ? "doc.text" : "magnifyingglass",
                        description: Text(search.isEmpty ? "Generate a report when you need a reusable summary." : "Try another search."))
                } else {
                    List(selection: $selection) {
                        ForEach(reports) { artifact in
                            ReportHistoryRow(
                                artifact: artifact,
                                name: templateName(artifact),
                                badge: historyBadge(artifact)
                            )
                            .tag(artifact.id)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(minWidth: 300, idealWidth: 350, maxWidth: 420)

            if let selected {
                ReportDetail(
                    artifact: selected,
                    templateName: templateName(selected),
                    run: run(for: selected),
                    copy: model.copy,
                    regenerate: { onRegenerate(selected) })
            } else {
                ContentUnavailableView {
                    Label("No report selected", systemImage: "doc.text")
                } description: {
                    Text("Generate a report to turn local evidence into a useful summary.")
                } actions: {
                    Button("New report") { onNewReport() }.buttonStyle(.borderedProminent)
                }
            }
        }
        .onChange(of: filter) { _, _ in selection = reports.first?.id }
        .onChange(of: search) { _, _ in
            if let selection, !reports.contains(where: { $0.id == selection }) {
                self.selection = reports.first?.id
            }
        }
    }

    static func latestArtifacts(_ artifacts: [Artifact]) -> [Artifact] {
        let clean = artifacts.filter { artifact in
            artifact.recipeID.rawValue != "legacy-v1-report" && !containsInternalEnvelope(artifact.content)
        }
        return Dictionary(grouping: clean, by: historyKey)
            .values
            .compactMap { group in
                group.max { lhs, rhs in lhs.revision == rhs.revision ? lhs.createdAt < rhs.createdAt : lhs.revision < rhs.revision }
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private static func historyKey(_ artifact: Artifact) -> String {
        "\(artifact.recipeID.rawValue)|\(artifact.periodStart.timeIntervalSince1970)|\(artifact.periodEnd.timeIntervalSince1970)"
    }

    private static func containsInternalEnvelope(_ content: String) -> Bool {
        let value = content.lowercased()
        return ["<codex_internal_context", "<app-context", "<environment_context", "codex_internal_context source="].contains {
            value.contains($0)
        }
    }

    private func templateName(_ artifact: Artifact) -> String {
        model.reportTemplates.first { $0.id == artifact.recipeID }?.recipe.name ?? artifact.recipeID.rawValue
    }

    private func run(for artifact: Artifact) -> ReportRun? {
        artifact.reportRunID.flatMap { id in model.reportRuns.first { $0.id == id } }
    }

    private func historyBadge(_ artifact: Artifact) -> String? {
        guard filter == .all else { return nil }
        if artifact.recipeID.rawValue == "legacy-v1-report" || Self.containsInternalEnvelope(artifact.content) { return "Legacy" }
        let allForPeriod = model.artifacts.filter { Self.historyKey($0) == Self.historyKey(artifact) }
        return allForPeriod.contains { $0.revision > artifact.revision } ? "Superseded" : nil
    }
}

private enum HistoryFilter: String, CaseIterable, Identifiable {
    case latest, all
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

private struct ReportHistoryRow: View {
    let artifact: Artifact
    let name: String
    let badge: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(name).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                if let badge {
                    Text(badge).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            Text(artifact.content).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text(artifact.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
    }
}

private struct ReportDetail: View {
    let artifact: Artifact
    let templateName: String
    let run: ReportRun?
    let copy: (String) -> Void
    let regenerate: () -> Void
    @State private var instructionsExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(templateName).font(.title2.bold())
                        Text(
                            "\(artifact.periodStart.formatted(date: .abbreviated, time: .shortened)) – \(artifact.periodEnd.formatted(date: .abbreviated, time: .shortened))"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Regenerate", systemImage: "arrow.clockwise") { regenerate() }
                    Button("Copy", systemImage: "doc.on.doc") { copy(artifact.content) }
                        .buttonStyle(.borderedProminent)
                }
                Text(artifact.content)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 18) {
                    Label("\(artifact.evidenceIDs.count) evidence links", systemImage: "link")
                    Label(artifact.privacyProfile.rawValue.capitalized, systemImage: "lock")
                    if let run {
                        Label(run.effectiveProvider?.rawValue.capitalized ?? "Local", systemImage: "sparkles")
                        Label("\((run.usage.knownTokenTotal ?? run.estimatedInputTokens ?? 0).formatted()) tokens", systemImage: "number")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let focus = run?.configuration?.customFocus, !focus.isEmpty {
                    DisclosureGroup(isExpanded: $instructionsExpanded) {
                        Text(focus)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    } label: {
                        Label("Generation instructions", systemImage: "text.quote")
                    }
                    .font(.callout)
                    .padding(14)
                    .background(
                        Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .onChange(of: artifact.id) { _, _ in instructionsExpanded = false }
    }
}

// MARK: - Composer

private struct ReportComposerSeed {
    var templateID: RecipeID?
    var period: ReportPeriodChoice
    var originalPeriod: DateInterval?
    var instructions: String?
    var repositoryID: RepositoryID?
    var provider: ProviderChoice?

    static func new(defaultTemplateID: RecipeID?) -> Self {
        Self(templateID: defaultTemplateID, period: .today, originalPeriod: nil)
    }

    static func regenerate(artifact: Artifact, run: ReportRun?) -> Self {
        return Self(
            templateID: artifact.recipeID, period: .original,
            originalPeriod: DateInterval(start: artifact.periodStart, end: artifact.periodEnd),
            instructions: run?.configuration?.customFocus,
            repositoryID: run?.configuration?.repositoryIDs.count == 1 ? run?.configuration?.repositoryIDs.first : nil,
            provider: ProviderChoice(run?.configuration?.providerModeOverride))
    }
}

private struct ReportComposer: View {
    @ObservedObject var model: AppModel
    let seed: ReportComposerSeed
    let onGenerated: (ArtifactID?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var templateID: RecipeID
    @State private var period: ReportPeriodChoice
    @State private var instructions: String
    @State private var repositoryID: RepositoryID?
    @State private var provider: ProviderChoice
    @State private var preview: ReportGenerationPreview?
    @State private var advanced = false

    init(model: AppModel, seed: ReportComposerSeed, onGenerated: @escaping (ArtifactID?) -> Void) {
        self.model = model
        self.seed = seed
        self.onGenerated = onGenerated
        let fallback = seed.templateID ?? model.reportTemplates.first?.id ?? RecipeID("daily-work-summary")
        let template = model.reportTemplates.first { $0.id == fallback }
        _templateID = State(initialValue: fallback)
        _period = State(initialValue: seed.period)
        _instructions = State(initialValue: seed.instructions ?? template?.version.customFocus ?? "")
        _repositoryID = State(initialValue: seed.repositoryID)
        _provider = State(
            initialValue: seed.provider ?? ProviderChoice(template?.version.providerModeOverride))
    }

    private var template: ReportTemplate? { model.reportTemplates.first { $0.id == templateID } }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: "New report",
                subtitle: "Choose a template, adjust its instructions, and generate a private local artifact.")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    field("Template") {
                        Picker("Template", selection: $templateID) {
                            ForEach(availableTemplates) { Text($0.recipe.name).tag($0.id) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Instructions").font(.callout.weight(.semibold))
                            Spacer()
                            Button("Reset to template") { instructions = template?.version.customFocus ?? "" }
                                .buttonStyle(.link)
                                .disabled(instructions == (template?.version.customFocus ?? ""))
                        }
                        TextEditor(text: $instructions)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(height: 150)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                            .overlay { RoundedRectangle(cornerRadius: 9).stroke(Color.secondary.opacity(0.18)) }
                        if let instructionError {
                            Label(instructionError, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.red)
                        } else {
                            Text("Edit this for a one-off report. The template itself will not change.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack(alignment: .top, spacing: 18) {
                        field("Period") {
                            Picker("Period", selection: $period) {
                                ForEach(periodOptions) { Text($0.title).tag($0) }
                            }.labelsHidden()
                        }
                        field("Project") {
                            Picker("Project", selection: $repositoryID) {
                                Text(templateScopeTitle).tag(Optional<RepositoryID>.none)
                                ForEach(model.repositories, id: \.repository.id) { item in
                                    Text(item.repository.displayName).tag(Optional(item.repository.id))
                                }
                            }.labelsHidden()
                        }
                    }
                    DisclosureGroup("Advanced", isExpanded: $advanced) {
                        field("Provider") {
                            Picker("Provider", selection: $provider) {
                                ForEach(ProviderChoice.allCases) { Text($0.title).tag($0) }
                            }.labelsHidden()
                        }
                        .padding(.top, 10)
                    }
                    .font(.callout.weight(.semibold))
                    previewLine
                }
                .padding(24)
            }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button {
                    Task {
                        guard let template else { return }
                        let artifactID = await model.generateReport(
                            recipeID: template.id,
                            period: selectedPeriod,
                            configuration: effectiveConfiguration(template))
                        if artifactID != nil { onGenerated(artifactID) }
                    }
                } label: {
                    if model.isSummarizing { ProgressView().controlSize(.small) } else { Label("Generate report", systemImage: "sparkles") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(template == nil || model.isSummarizing || instructionError != nil)
            }
            .padding(18)
        }
        .onChange(of: templateID) { _, _ in
            instructions = template?.version.customFocus ?? ""
            repositoryID = nil
            provider = ProviderChoice(template?.version.providerModeOverride)
        }
        .task(id: previewKey) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await updatePreview()
        }
    }

    private var availableTemplates: [ReportTemplate] {
        model.reportTemplates.filter { $0.recipe.isEnabled && $0.id.rawValue != "legacy-v1-report" }
    }

    private var previewLine: some View {
        Group {
            if let preview {
                VStack(alignment: .leading, spacing: 5) {
                    Label(
                        "\(preview.evidenceCount) evidence items · about \(preview.estimatedInputTokens.formatted()) input tokens · \(preview.providerMode.displayName)",
                        systemImage: preview.state == .noActivity ? "circle.dotted" : "checkmark.circle")
                    if preview.providerMode == .localOnly && !instructions.isEmpty {
                        Text("Local-only reports use deterministic facts and cannot fully follow custom prose instructions.")
                            .foregroundStyle(.orange)
                    }
                }
            } else {
                Label("Preparing evidence preview…", systemImage: "ellipsis")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.callout.weight(.semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func effectiveConfiguration(_ template: ReportTemplate) -> ReportRunConfiguration {
        let base = template.version
        return ReportRunConfiguration(
            purpose: base.purpose, audience: base.audience,
            repositoryIDs: repositoryID.map { [$0] } ?? base.repositoryIDs,
            groupNames: repositoryID == nil ? base.groupNames : [],
            customFocus: instructions.nilIfEmpty, tone: base.tone,
            outputFormat: base.outputFormat, maximumCharacters: base.maximumCharacters,
            privacyProfile: base.privacyProfile, providerModeOverride: provider.mode)
    }

    private var templateScopeTitle: String {
        guard let template else { return "Template scope" }
        let groups = template.version.groupNames
        let repositoryCount = template.version.repositoryIDs.count
        if !groups.isEmpty {
            return "Template scope · \(groups.joined(separator: ", "))"
        }
        if repositoryCount > 0 {
            return "Template scope · \(repositoryCount) project\(repositoryCount == 1 ? "" : "s")"
        }
        return "All projects"
    }

    private func updatePreview() async {
        guard let template, instructionError == nil else { return }
        preview = await model.previewReport(
            recipeID: template.id, period: selectedPeriod,
            configuration: effectiveConfiguration(template))
    }

    private var previewKey: String {
        "\(templateID.rawValue)|\(period.rawValue)|\(repositoryID?.rawValue ?? "all")|\(provider.rawValue)|\(instructions)"
    }

    private var periodOptions: [ReportPeriodChoice] {
        seed.originalPeriod == nil ? [.today, .yesterday, .lastHour] : ReportPeriodChoice.allCases
    }

    private var selectedPeriod: DateInterval {
        if period == .original, let originalPeriod = seed.originalPeriod { return originalPeriod }
        return period.interval(now: model.referenceNow)
    }

    private var instructionError: String? {
        guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            _ = try ReportRecipeValidator.customFocus(instructions)
            return nil
        } catch { return error.localizedDescription }
    }
}

// MARK: - Templates

private struct TemplateLibraryView: View {
    @ObservedObject var model: AppModel
    @Binding var selection: RecipeID?
    let onEdit: (ReportTemplate) -> Void
    let onDuplicate: (ReportTemplate) -> Void
    @State private var search = ""

    private var templates: [ReportTemplate] {
        model.reportTemplates.filter { template in
            template.id.rawValue != "legacy-v1-report"
                && (search.isEmpty || template.recipe.name.localizedCaseInsensitiveContains(search))
        }
    }

    private var selected: ReportTemplate? {
        templates.first { $0.id == selection } ?? templates.first
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                SearchField(placeholder: "Search templates", text: $search).padding(12)
                Divider()
                List(selection: $selection) {
                    templateSection("Built-in", items: templates.filter { $0.recipe.isBuiltIn })
                    templateSection("Custom", items: templates.filter { !$0.recipe.isBuiltIn && $0.recipe.isEnabled })
                    templateSection("Archived", items: templates.filter { !$0.recipe.isBuiltIn && !$0.recipe.isEnabled })
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            .frame(minWidth: 270, idealWidth: 320, maxWidth: 380)
            if let selected {
                TemplateDetail(
                    model: model, template: selected,
                    onEdit: { onEdit(selected) }, onDuplicate: { onDuplicate(selected) }
                )
                .id(selected.version.id)
            } else {
                ContentUnavailableView("No templates", systemImage: "doc.badge.gearshape")
            }
        }
    }

    @ViewBuilder
    private func templateSection(_ title: String, items: [ReportTemplate]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { template in
                    Label(template.recipe.name, systemImage: template.recipe.isBuiltIn ? "seal" : "doc.text")
                        .tag(template.id)
                }
            }
        }
    }
}

private struct TemplateDetail: View {
    @ObservedObject var model: AppModel
    let template: ReportTemplate
    let onEdit: () -> Void
    let onDuplicate: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(template.recipe.name).font(.title2.bold())
                            if template.recipe.isBuiltIn {
                                Text("Built-in").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                            } else if !template.recipe.isEnabled {
                                Text("Archived").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                        }
                        Text(
                            template.recipe.isBuiltIn
                                ? "A stable Trackify default. Duplicate it to customize."
                                : "Version \(template.version.version) · edits create an immutable new version."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !template.recipe.isBuiltIn {
                        Button("Edit") { onEdit() }
                    }
                    Button("Duplicate") { onDuplicate() }.buttonStyle(.borderedProminent)
                }
                detailBlock("Instructions", value: template.version.customFocus ?? "No additional instructions.")
                HStack(spacing: 28) {
                    detailBlock("Style", value: TemplateStyle(draftTone: template.version.tone).title)
                    detailBlock("Length", value: TemplateLength(characters: template.version.maximumCharacters).title)
                    detailBlock("Audience", value: TemplateAudience(profile: template.version.privacyProfile).title)
                    detailBlock("Format", value: template.version.outputFormat.displayName)
                }
                Divider()
                if !template.recipe.isBuiltIn {
                    Button(template.recipe.isEnabled ? "Archive template" : "Restore template") {
                        Task { await model.setTemplateEnabled(!template.recipe.isEnabled, id: template.id) }
                    }
                    .foregroundStyle(template.recipe.isEnabled ? .red : .primary)
                }
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
        }
    }

    private func detailBlock(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text(value).font(.body).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TemplateEditorSeed {
    enum Intent { case new, edit, duplicate }
    let template: ReportTemplate
    let intent: Intent

    static func new(base: ReportTemplate) -> Self { Self(template: base, intent: .new) }
    static func edit(_ template: ReportTemplate) -> Self { Self(template: template, intent: .edit) }
    static func duplicate(_ template: ReportTemplate) -> Self { Self(template: template, intent: .duplicate) }
}

private struct TemplateEditor: View {
    @ObservedObject var model: AppModel
    let seed: TemplateEditorSeed
    let onSaved: (RecipeID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ReportTemplateDraft
    @State private var style: TemplateStyle
    @State private var length: TemplateLength
    @State private var audience: TemplateAudience

    init(model: AppModel, seed: TemplateEditorSeed, onSaved: @escaping (RecipeID) -> Void) {
        self.model = model
        self.seed = seed
        self.onSaved = onSaved
        let name: String
        switch seed.intent {
        case .new: name = "Untitled template"
        case .duplicate: name = "\(seed.template.recipe.name) Copy"
        case .edit: name = seed.template.recipe.name
        }
        var initial = ReportTemplateDraft(template: seed.template, name: name)
        initial.cadence = .onDemand
        if seed.intent == .new { initial.customFocus = nil }
        _draft = State(initialValue: initial)
        _style = State(initialValue: TemplateStyle(draftTone: initial.tone))
        _length = State(initialValue: TemplateLength(characters: initial.maximumCharacters))
        _audience = State(initialValue: TemplateAudience(profile: initial.privacyProfile))
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: title, subtitle: "Templates define what to write. Scheduling is configured separately.")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    editorField("Name") {
                        TextField("Template name", text: $draft.name).textFieldStyle(.roundedBorder)
                    }
                    editorField("Instructions") {
                        TextEditor(text: Binding(get: { draft.customFocus ?? "" }, set: { draft.customFocus = $0.nilIfEmpty }))
                            .scrollContentBackground(.hidden)
                            .padding(8).frame(height: 130)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                            .overlay { RoundedRectangle(cornerRadius: 9).stroke(Color.secondary.opacity(0.18)) }
                        if let focusError { Text(focusError).font(.caption).foregroundStyle(.red) }
                    }
                    editorField("Style") { segmented($style) }
                    editorField("Length") { segmented($length) }
                    HStack(alignment: .top, spacing: 18) {
                        editorField("Audience") { segmented($audience) }
                        editorField("Format") {
                            Picker("Format", selection: $draft.outputFormat) {
                                Text("Plain").tag(RecipeOutputFormat.plainText)
                                Text("Markdown").tag(RecipeOutputFormat.markdown)
                            }.labelsHidden().pickerStyle(.segmented)
                        }
                    }
                }
                .padding(24)
            }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save template") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || focusError != nil)
            }
            .padding(18)
        }
    }

    private var title: String {
        switch seed.intent {
        case .new: "New template"
        case .edit: "Edit template"
        case .duplicate: "Duplicate template"
        }
    }

    private func editorField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.callout.weight(.semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func segmented<Value: Hashable & CaseIterable & Identifiable>(_ binding: Binding<Value>) -> some View
    where Value.AllCases: RandomAccessCollection, Value.AllCases.Element == Value, Value.ID == Value {
        Picker("", selection: binding) {
            ForEach(Value.allCases) { value in Text(String(describing: value).capitalized).tag(value) }
        }
        .labelsHidden().pickerStyle(.segmented)
    }

    private func save() {
        draft.tone = style.tone
        draft.maximumCharacters = length.characters
        draft.audience = audience.audience
        draft.privacyProfile = audience.profile
        draft.cadence = .onDemand
        Task {
            let id: RecipeID?
            switch seed.intent {
            case .edit:
                id = await model.saveTemplate(id: seed.template.id, draft: draft) ? seed.template.id : nil
            case .new, .duplicate:
                id = await model.createTemplate(draft)
            }
            if let id { onSaved(id) }
        }
    }

    private var focusError: String? {
        guard let focus = draft.customFocus else { return nil }
        do {
            _ = try ReportRecipeValidator.customFocus(focus)
            return nil
        } catch { return error.localizedDescription }
    }
}

private enum TemplateStyle: String, CaseIterable, Identifiable {
    case concise, detailed, executive, technical
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var tone: String {
        switch self {
        case .concise: "concise and factual"
        case .detailed: "detailed and factual"
        case .executive: "executive and outcome-focused"
        case .technical: "technical and precise"
        }
    }
    init(draftTone: String) {
        let value = draftTone.lowercased()
        if value.contains("executive") {
            self = .executive
        } else if value.contains("technical") {
            self = .technical
        } else if value.contains("detailed") {
            self = .detailed
        } else {
            self = .concise
        }
    }
}

private enum TemplateLength: String, CaseIterable, Identifiable {
    case short, standard, detailed
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var characters: Int {
        switch self {
        case .short: 600
        case .standard: 1_200
        case .detailed: 2_000
        }
    }
    init(characters: Int) { self = characters <= 700 ? .short : (characters >= 1_600 ? .detailed : .standard) }
}

private enum TemplateAudience: String, CaseIterable, Identifiable {
    case `self`, team, client, `public`
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var audience: String {
        switch self {
        case .self: "self"
        case .team: "development team"
        case .client: "client"
        case .public: "public"
        }
    }
    var profile: PrivacyProfile {
        switch self {
        case .self: .private
        case .team: .team
        case .client: .client
        case .public: .public
        }
    }
    init(profile: PrivacyProfile) {
        switch profile {
        case .private: self = .self
        case .team: self = .team
        case .client: self = .client
        case .public: self = .public
        }
    }
}

// MARK: - Scheduled reporters

private struct ScheduleLibraryView: View {
    @ObservedObject var model: AppModel
    @Binding var selection: ReportScheduleID?
    let onEdit: (ReportSchedule) -> Void

    private var selected: ReportSchedule? {
        model.reportSchedules.first { $0.id == selection } ?? model.reportSchedules.first
    }

    var body: some View {
        HSplitView {
            if model.reportSchedules.isEmpty {
                ContentUnavailableView("No scheduled reporters", systemImage: "calendar.badge.clock")
                    .frame(minWidth: 320)
            } else {
                List(selection: $selection) {
                    ForEach(model.reportSchedules) { schedule in
                        ScheduleRow(model: model, schedule: schedule).tag(schedule.id)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(minWidth: 320, idealWidth: 380, maxWidth: 440)
            }
            if let selected {
                ScheduleDetail(model: model, schedule: selected, onEdit: { onEdit(selected) })
            } else {
                ContentUnavailableView("Select a reporter", systemImage: "calendar.badge.clock")
            }
        }
    }
}

private struct ScheduleRow: View {
    @ObservedObject var model: AppModel
    let schedule: ReportSchedule
    var body: some View {
        HStack(spacing: 12) {
            Toggle(
                "",
                isOn: Binding(
                    get: { schedule.isEnabled },
                    set: { enabled in Task { await model.setScheduleEnabled(enabled, id: schedule.id) } })
            )
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                Text(schedule.name).font(.callout.weight(.semibold))
                Text("\(schedule.cadence.title) · \(scopeTitle(schedule))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

private struct ScheduleDetail: View {
    @ObservedObject var model: AppModel
    let schedule: ReportSchedule
    let onEdit: () -> Void
    @State private var confirmingDelete = false

    private var templateName: String {
        model.reportTemplates.first { $0.id == schedule.recipeID }?.recipe.name ?? schedule.recipeID.rawValue
    }
    private var latestRun: ReportRun? {
        model.reportRuns.filter { $0.scheduleID == schedule.id }.max { $0.queuedAt < $1.queuedAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(schedule.name).font(.title2.bold())
                        Text(schedule.isEnabled ? "Active" : "Paused")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(schedule.isEnabled ? Color.green : Color.secondary)
                    }
                    Spacer()
                    Button("Edit") { onEdit() }.buttonStyle(.borderedProminent)
                }
                scheduleValue("Template", templateName)
                scheduleValue("Runs", schedule.cadence.description)
                scheduleValue("Projects", scopeTitle(schedule))
                scheduleValue("Provider", ProviderChoice(schedule.providerModeOverride).title)
                scheduleValue(
                    "Latest run",
                    latestRun.map { "\($0.state.displayName) · \($0.queuedAt.formatted(date: .abbreviated, time: .shortened))" }
                        ?? "Not run yet")
                Divider()
                Button("Delete reporter", role: .destructive) { confirmingDelete = true }
                    .confirmationDialog(
                        "Delete \(schedule.name)?", isPresented: $confirmingDelete,
                        titleVisibility: .visible
                    ) {
                        Button("Delete reporter", role: .destructive) {
                            Task { _ = await model.deleteSchedule(id: schedule.id) }
                        }
                    } message: {
                        Text("Existing report history will be preserved.")
                    }
            }
            .padding(28)
            .frame(maxWidth: 780, alignment: .leading)
        }
    }

    private func scheduleValue(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).foregroundStyle(.secondary) }
            .font(.body)
    }
}

private struct ScheduleEditor: View {
    @ObservedObject var model: AppModel
    let schedule: ReportSchedule?
    let onSaved: (ReportScheduleID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var templateID: RecipeID
    @State private var cadence: ReportScheduleCadence
    @State private var repositoryID: RepositoryID?
    @State private var provider: ProviderChoice
    @State private var isEnabled: Bool

    init(model: AppModel, schedule: ReportSchedule?, onSaved: @escaping (ReportScheduleID) -> Void) {
        self.model = model
        self.schedule = schedule
        self.onSaved = onSaved
        let defaultTemplate =
            model.reportTemplates.first { $0.id.rawValue == "daily-work-summary" }?.id
            ?? model.reportTemplates.first?.id ?? RecipeID("daily-work-summary")
        _name = State(initialValue: schedule?.name ?? "Daily work summary")
        _templateID = State(initialValue: schedule?.recipeID ?? defaultTemplate)
        _cadence = State(initialValue: schedule?.cadence ?? .daily)
        _repositoryID = State(initialValue: schedule?.repositoryIDs.count == 1 ? schedule?.repositoryIDs.first : nil)
        _provider = State(initialValue: ProviderChoice(schedule?.providerModeOverride))
        _isEnabled = State(initialValue: schedule?.isEnabled ?? true)
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: schedule == nil ? "New scheduled reporter" : "Edit scheduled reporter",
                subtitle: "A reporter combines a template, cadence, scope, and provider.")
            Divider()
            Form {
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                Picker("Template", selection: $templateID) {
                    ForEach(model.reportTemplates.filter { $0.recipe.isEnabled && $0.id.rawValue != "legacy-v1-report" }) {
                        Text($0.recipe.name).tag($0.id)
                    }
                }
                Picker("Cadence", selection: $cadence) {
                    Text("Hourly").tag(ReportScheduleCadence.hourly)
                    Text("Daily").tag(ReportScheduleCadence.daily)
                }
                .pickerStyle(.segmented)
                Picker("Projects", selection: $repositoryID) {
                    Text("All projects").tag(Optional<RepositoryID>.none)
                    ForEach(model.repositories, id: \.repository.id) { item in
                        Text(item.repository.displayName).tag(Optional(item.repository.id))
                    }
                }
                Picker("Provider", selection: $provider) {
                    ForEach(ProviderChoice.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Enabled", isOn: $isEnabled)
                Text(cadence.description).font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save reporter") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(18)
        }
    }

    private func save() {
        let draft = ReportScheduleDraft(
            name: name, recipeID: templateID, cadence: cadence,
            repositoryIDs: repositoryID.map { [$0] } ?? [],
            providerModeOverride: provider.mode, isEnabled: isEnabled)
        Task {
            if let id = await model.saveSchedule(id: schedule?.id, draft: draft) { onSaved(id) }
        }
    }
}

// MARK: - Shared report controls

private struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(placeholder, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.15)) }
    }
}

private struct SheetHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.bold())
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
    }
}

private enum ReportPeriodChoice: String, CaseIterable, Identifiable {
    case original, today, yesterday, lastHour
    var id: Self { self }
    var title: String {
        switch self {
        case .original: "Original period"
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .lastHour: "Last hour"
        }
    }
    func interval(now: Date) -> DateInterval {
        switch self {
        case .original: DateInterval(start: now, end: now)
        case .today: DateInterval(start: Calendar.current.startOfDay(for: now), end: now)
        case .yesterday:
            DateInterval(
                start: Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: now))!,
                end: Calendar.current.startOfDay(for: now))
        case .lastHour: DateInterval(start: now.addingTimeInterval(-3_600), end: now)
        }
    }
}

private enum ProviderChoice: String, CaseIterable, Identifiable {
    case appDefault, automatic, codex, claude, localOnly
    var id: Self { self }
    init(_ mode: ProviderSelectionMode?) {
        switch mode {
        case nil: self = .appDefault
        case .automatic: self = .automatic
        case .codex: self = .codex
        case .claude: self = .claude
        case .localOnly: self = .localOnly
        }
    }
    var mode: ProviderSelectionMode? {
        switch self {
        case .appDefault: nil
        case .automatic: .automatic
        case .codex: .codex
        case .claude: .claude
        case .localOnly: .localOnly
        }
    }
    var title: String {
        switch self {
        case .appDefault: "App default"
        case .automatic: "Automatic"
        case .codex: "Codex"
        case .claude: "Claude"
        case .localOnly: "Local only"
        }
    }
}

private func scopeTitle(_ schedule: ReportSchedule) -> String {
    if schedule.repositoryIDs.isEmpty { return "All projects" }
    if schedule.repositoryIDs.count == 1 { return schedule.repositoryIDs[0].rawValue }
    return "\(schedule.repositoryIDs.count) projects"
}

extension ReportScheduleCadence {
    fileprivate var title: String { rawValue.capitalized }
    fileprivate var description: String {
        switch self {
        case .hourly: "After each completed hour"
        case .daily: "After each completed day"
        }
    }
}

extension ReportRunState {
    fileprivate var displayName: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
}

extension RecipeOutputFormat {
    fileprivate var displayName: String {
        switch self {
        case .plainText: "Plain text"
        case .markdown: "Markdown"
        case .structuredJSON: "Structured JSON"
        }
    }
}

extension ProviderSelectionMode {
    fileprivate var displayName: String {
        switch self {
        case .automatic: "Automatic provider"
        case .codex: "Codex"
        case .claude: "Claude"
        case .localOnly: "Local only"
        }
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
