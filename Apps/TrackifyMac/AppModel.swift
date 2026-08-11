import AppKit
import Foundation
import ServiceManagement
import SwiftUI
import TrackifyDomain
import TrackifyEngine
import TrackifyStore

struct HourActivity: Identifiable, Sendable {
    let start: Date
    let activity: ActivitySnapshot
    var id: Date { start }
    var evidenceCount: Int { activity.evidenceCount }
}

struct CalendarActivity: Identifiable, Sendable {
    let date: Date
    let activity: ActivitySnapshot
    var id: Date { date }
    var activeHours: Int { activity.activeHours }
    var commits: Int { activity.commits }
}

struct TimelineEntry: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case summary
        case commit
        case conversation
        case change
        case test
    }

    let id: String
    let occurredAt: Date
    let kind: Kind
    let title: String
    let detail: String?
    let repositoryID: RepositoryID?
    let source: SourceKind?
    let state: String?
    let messageRole: MessageRole?
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var dashboard: ActivityDashboard?
    @Published private(set) var repositories: [RepositoryCatalogItem] = []
    @Published private(set) var roots: [DiscoveryRoot] = []
    @Published private(set) var summaries: [WorkSummary] = []
    @Published private(set) var hours: [HourActivity] = []
    @Published private(set) var historyDays: [CalendarActivity] = []
    @Published private(set) var timeline: [TimelineEntry] = []
    @Published private(set) var providerHealth: [ProviderHealth] = []
    @Published private(set) var sourceCapabilities: [SourceCapability] = []
    @Published private(set) var evidenceQuality = EvidenceQualitySnapshot(
        state: .healthy, projectionVersion: ConversationProvenance.currentClassificationVersion,
        unresolvedRecordCount: 0, diagnosticRecordCount: 0,
        aliasRecordCount: 0, replayRecordCount: 0, issues: [])
    @Published private(set) var generationCapabilities: [GenerationCapability] = []
    @Published private(set) var providerSelection: ProviderSelectionMode = .automatic
    @Published private(set) var effectiveProvider: SummaryProviderID?
    @Published private(set) var generationBudgets = GenerationBudgets()
    @Published private(set) var automaticSummariesUseLLM = true
    @Published private(set) var usageToday = UsageSummary(
        runs: 0, succeeded: 0, failed: 0, inputTokens: 0, cachedInputTokens: 0,
        outputTokens: 0, reasoningTokens: 0, durationSeconds: 0, knownCost: 0,
        currency: nil, hasUnknownCost: false)
    @Published private(set) var usageMonth = UsageSummary(
        runs: 0, succeeded: 0, failed: 0, inputTokens: 0, cachedInputTokens: 0,
        outputTokens: 0, reasoningTokens: 0, durationSeconds: 0, knownCost: 0,
        currency: nil, hasUnknownCost: false)
    @Published private(set) var generationBudgetStatus = GenerationBudgetStatus(
        allowance: nil, allowanceAttributedPercent: 0, allowancePercentLimit: 3,
        estimatedCreditsUsed: 0, weeklyCreditLimit: 500,
        callsToday: 0, callsPerDayLimit: 48, isPaused: false, pauseReason: nil)
    @Published private(set) var reportRuns: [ReportRun] = []
    @Published private(set) var summaryRuns: [SummaryRun] = []
    @Published private(set) var recipes: [ReportRecipe] = []
    @Published private(set) var reportTemplates: [ReportTemplate] = []
    @Published private(set) var reportSchedules: [ReportSchedule] = []
    @Published private(set) var artifacts: [Artifact] = []
    @Published private(set) var isSummarizing = false
    @Published private(set) var isCollecting = false
    @Published private(set) var lastCollection: Date?
    @Published var errorMessage: String?
    @Published private(set) var collectorIssueCount = 0
    @Published private(set) var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    @Published private(set) var collectionPaused = false
    @Published private(set) var automaticUpdateChecks = true
    @Published private(set) var liveCollectorStatus = LiveCollectorRuntimeStatus(mode: .stopped)

    let isUIValidation: Bool
    private let clock: any WallClock
    private var schedulerTask: Task<Void, Never>?
    private var isStarting = false
    private var liveCollectionRuntime: AppLiveCollectionRuntime?
    private var isRefreshingEvidence = false
    private var evidenceRefreshPending = false
    private var presentationLastRefreshedAt: Date?
    private var hasLoadedFullPresentation = false
    private var hasInitializedOverviewPresentation = false
    private var observedGenerationConfiguration: GenerationConfiguration?
    private var observedBudgetPaused: Bool?
    private var lastFullReconciliation: Date?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        clock: (any WallClock)? = nil
    ) {
        isUIValidation = environment["TRACKIFY_UI_VALIDATION"] == "1"
        if let clock {
            self.clock = clock
        } else if let fixedNow = environment["TRACKIFY_UI_NOW"].flatMap(Self.parseISO8601) {
            self.clock = FixedWallClock(fixedNow)
        } else {
            self.clock = SystemWallClock()
        }
    }

    var referenceNow: Date { clock.now() }

    var hasEvidenceToday: Bool { dashboard?.activity.evidenceCount ?? 0 > 0 }
    var latestEvidenceAt: Date? { dashboard?.activity.lastEvidenceAt }
    var degradedMessage: String? {
        errorMessage
            ?? (liveCollectorStatus.mode == .degraded
                ? liveCollectorStatus.lastError ?? "Live collection is degraded. Run trackify doctor for details."
                : nil)
            ?? (evidenceQuality.state == .degraded
                ? "Evidence quality is degraded; some visible statistics may be incomplete. Open Settings > Sources or run trackify doctor."
                : nil)
            ?? (collectorIssueCount > 0
                ? "Collection has \(collectorIssueCount) source, summary, or report issue\(collectorIssueCount == 1 ? "" : "s"). Run trackify doctor for details."
                : nil)
    }

    var llmBudgetPaused: Bool {
        Self.liveBudgetIsPaused(generationBudgetStatus)
    }

    var isAnyCollectionActive: Bool {
        isCollecting || liveCollectorStatus.mode == .collecting
    }

    var isRecordingPending: Bool {
        liveCollectorStatus.mode == .pending
    }

    nonisolated static func liveBudgetIsPaused(_ status: GenerationBudgetStatus) -> Bool {
        status.isPaused
    }

    var menuBarEvidenceHours: String? { dashboard.map { "\($0.activity.activeHours)h" } }
    var menuBarPace: String? {
        guard dashboard?.comparison.activeDays ?? 0 > 0,
            let percent = dashboard?.comparison.activeHours.percentChange
        else { return nil }
        return "\(percent >= 0 ? "+" : "")\(Int(percent.rounded()))%"
    }

    var activeRepositoryNames: [String] {
        repositoryNames(for: Set(dashboard?.activity.repositoryIDs ?? []))
    }

    var latestCurrentSummary: WorkSummary? {
        let today = Calendar.current.dateInterval(of: .day, for: referenceNow)
        let todaySummaries = summaries.filter { summary in
            today.map { summary.periodEnd > $0.start && summary.periodStart < $0.end } ?? false
        }
        return todaySummaries.filter { $0.kind == .current }
            .max { $0.generatedAt < $1.generatedAt }
            ?? todaySummaries.filter { $0.kind == .day }
            .max { $0.generatedAt < $1.generatedAt }
    }

    deinit {
        schedulerTask?.cancel()
    }

    func stop() {
        schedulerTask?.cancel()
        schedulerTask = nil
        liveCollectionRuntime?.stop()
        liveCollectionRuntime = nil
    }

    func claimInitialOverviewPresentation() -> Bool {
        guard !hasInitializedOverviewPresentation else { return false }
        hasInitializedOverviewPresentation = true
        return true
    }

    func start() async {
        guard schedulerTask == nil, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        if !isUIValidation { configureLoginItemIfNeeded() }
        if !isUIValidation {
            do {
                let now = referenceNow
                let startup = try await Task.detached(priority: .utility) {
                    let paths = try TrackifyPaths.default()
                    let store = try LedgerStore(databaseURL: paths.ledgerURL)
                    _ = try SummaryCoordinator.recoverInterruptedRuns(store: store, now: now)
                    _ = try ReportQueue().recoverInterruptedRuns(store: store, now: now)
                    let reconciliation = try store.heartbeatObservedAt(service: "reconciliation")
                    let collector = try store.collectorStatus().observedAt
                    return (
                        paused: try SettingsStore(fileURL: paths.settingsURL).load().collectionPaused,
                        lastFullReconciliation: reconciliation ?? collector
                    )
                }.value
                collectionPaused = startup.paused
                lastFullReconciliation = startup.lastFullReconciliation
            } catch {
                errorMessage = "Collection settings could not be loaded: \(error.localizedDescription)"
            }
            await startLiveCollection()
        }
        if isUIValidation {
            await refresh()
            return
        }
        await refreshEvidence()
        let launchedAt = referenceNow
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await self?.reloadCollectionSettings()
                await self?.refreshEvidenceIfChanged()
                guard let self else { return }
                let hasPassedStartupGrace = self.referenceNow.timeIntervalSince(launchedAt) >= 60
                if hasPassedStartupGrace,
                    self.referenceNow.timeIntervalSince(self.lastFullReconciliation ?? .distantPast) >= 30 * 60
                {
                    await self.collectNow()
                }
            }
        }
    }

    func refreshEvidence() async {
        if isRefreshingEvidence {
            evidenceRefreshPending = true
            return
        }
        isRefreshingEvidence = true
        repeat {
            evidenceRefreshPending = false
            do {
                let now = referenceNow
                let loadDetailedHistory = hasLoadedFullPresentation
                let snapshot = try await Task.detached(priority: .utility) { () -> EvidenceAppSnapshot in
                    let paths = try TrackifyPaths.default()
                    let store = try LedgerStore(databaseURL: paths.ledgerURL)
                    let day = Self.day(containing: now)
                    let dashboard = try ActivityQueries().dashboard(store: store, range: day, cutoff: now)
                    let hours = try Self.hourActivity(store: store, range: day, cutoff: now)
                    let historyStart =
                        loadDetailedHistory
                        ? Calendar.current.date(byAdding: .day, value: -41, to: day.start)!
                        : day.start
                    let summaries = try store.summaries(
                        overlapping: DateInterval(start: historyStart, end: day.end),
                        kinds: [.current, .day, .segment], limit: loadDetailedHistory ? 1_000 : 20)
                    let repositories = try store.repositoryCatalog()
                    let events =
                        loadDetailedHistory
                        ? try store.recentEvents(
                            from: historyStart, through: now,
                            kinds: [
                                .gitCommitObserved, .gitWorkingTreeChanged,
                                .agentMessageObserved, .testFinished,
                            ],
                            limit: 500)
                        : []
                    let messageIDs = events.compactMap { event in
                        event.payload["messageID"].map { MessageID($0) }
                    }
                    let messages = try store.messagesResolvingAliases(ids: Array(messageIDs.prefix(500)))
                    let collectorStatus = try store.collectorStatus()
                    return EvidenceAppSnapshot(
                        dashboard: dashboard,
                        repositories: repositories,
                        summaries: summaries,
                        hours: hours,
                        currentDay: CalendarActivity(date: day.start, activity: dashboard.activity),
                        timeline: Self.makeTimeline(events: events, summaries: summaries, messages: messages),
                        evidenceQuality: try store.evidenceQuality(),
                        collectorIssueCount: collectorStatus.issueCount,
                        lastCollection: collectorStatus.observedAt)
                }.value
                dashboard = snapshot.dashboard
                repositories = snapshot.repositories
                summaries = snapshot.summaries
                hours = snapshot.hours
                timeline = snapshot.timeline
                evidenceQuality = snapshot.evidenceQuality
                collectorIssueCount = snapshot.collectorIssueCount
                lastCollection = snapshot.lastCollection
                presentationLastRefreshedAt = now
                if let index = historyDays.firstIndex(where: {
                    Calendar.current.isDate($0.date, inSameDayAs: snapshot.currentDay.date)
                }) {
                    historyDays[index] = snapshot.currentDay
                } else {
                    historyDays.append(snapshot.currentDay)
                    historyDays.sort { $0.date < $1.date }
                }
                errorMessage = nil
            } catch {
                errorMessage = String(describing: error)
            }
        } while evidenceRefreshPending
        isRefreshingEvidence = false
    }

    func applyLiveCollectorStatus(_ status: LiveCollectorRuntimeStatus) {
        liveCollectorStatus = status
    }

    func refreshEvidenceIfChanged() async {
        do {
            let latestMutation = try await Task.detached(priority: .utility) { () -> Date? in
                let paths = try TrackifyPaths.default()
                let store = try LedgerStore(databaseURL: paths.ledgerURL)
                return [
                    try store.liveCollectorStatus()?.lastMutationAt,
                    try store.collectorStatus().observedAt,
                ].compactMap { $0 }.max()
            }.value
            guard let latestMutation,
                latestMutation > (presentationLastRefreshedAt ?? .distantPast)
            else { return }
            await refreshEvidence()
        } catch {
            errorMessage = "Evidence freshness could not be checked: \(error.localizedDescription)"
        }
    }

    func reloadCollectionSettings() async {
        do {
            let paused = try await Task.detached(priority: .utility) {
                let paths = try TrackifyPaths.default()
                return try SettingsStore(fileURL: paths.settingsURL).load().collectionPaused
            }.value
            collectionPaused = paused
            liveCollectionRuntime?.setPaused(paused)
        } catch {
            errorMessage = "Collection settings could not be reloaded: \(error.localizedDescription)"
        }
    }

    private func startLiveCollection() async {
        guard liveCollectionRuntime == nil, !isUIValidation else { return }
        do {
            liveCollectionRuntime = try await AppLiveCollectionRuntime.start(
                model: self, clock: clock, paused: collectionPaused)
        } catch {
            errorMessage = "Live collection could not start: \(error.localizedDescription)"
        }
    }

    func refresh() async {
        do {
            let now = referenceNow
            let inspectProviders = generationCapabilities.isEmpty && !isUIValidation
            let cachedGenerationCapabilities = generationCapabilities
            let uiValidation = isUIValidation
            let snapshot = try await Task.detached(priority: .utility) { () -> AppSnapshot in
                let paths = try TrackifyPaths.default()
                let store = try LedgerStore(databaseURL: paths.ledgerURL)
                let settings = try SettingsStore(fileURL: paths.settingsURL).load()
                let collectorStatus = try store.collectorStatus()
                let day = Self.day(containing: now)
                let dashboard = try ActivityQueries().dashboard(store: store, range: day, cutoff: now)
                let historyStart = Calendar.current.date(byAdding: .day, value: -41, to: day.start)!
                let historyRanges = Self.dayRanges(from: historyStart, through: day.end)
                let historySnapshots = try ActivityQueries().snapshots(
                    store: store, ranges: historyRanges, cutoff: now, calendar: Calendar.current)
                let historyDays = zip(historyRanges, historySnapshots).map {
                    CalendarActivity(date: $0.0.start, activity: $0.1)
                }

                let hours = try Self.hourActivity(store: store, range: day, cutoff: now)

                let summaryRange = DateInterval(start: historyStart, end: day.end)
                let summaries = try store.summaries(
                    overlapping: summaryRange, kinds: [.current, .day, .segment], limit: 1_000)
                let repositoryCatalog = try store.repositoryCatalog()
                let events = try store.recentEvents(
                    from: historyStart,
                    through: now,
                    kinds: [.gitCommitObserved, .gitWorkingTreeChanged, .agentMessageObserved, .testFinished],
                    limit: 500
                )
                let messageIDs = events.compactMap { event in
                    event.payload["messageID"].map { MessageID($0) }
                }
                let messageByID = try store.messagesResolvingAliases(ids: Array(messageIDs.prefix(500)))
                let timeline = Self.makeTimeline(
                    events: events, summaries: summaries, messages: messageByID)
                let calendar = Calendar.current
                let today = calendar.dateInterval(of: .day, for: now)!
                let month = calendar.dateInterval(of: .month, for: now)!
                let discovery = CapabilityDiscovery()
                let generators =
                    uiValidation
                    ? Self.validationGenerationCapabilities(now: now)
                    : inspectProviders ? discovery.generators(store: store, now: now) : nil
                let sources =
                    uiValidation
                    ? Self.validationSourceCapabilities(now: now)
                    : discovery.sources(store: store, now: now)
                let effectiveProvider = discovery.effectiveProvider(
                    mode: settings.providerSelection,
                    capabilities: generators ?? cachedGenerationCapabilities)
                let allowanceReader: any ProviderAllowanceReading =
                    uiValidation ? NoProviderAllowanceReader() : AutomaticProviderAllowanceReader()
                let budgetStatus = try GenerationBudgetController(
                    allowanceReader: allowanceReader
                ).status(
                    store: store, budgets: settings.generationBudgets,
                    provider: effectiveProvider, now: now)

                return AppSnapshot(
                    dashboard: dashboard,
                    repositories: repositoryCatalog,
                    roots: try store.discoveryRoots(),
                    summaries: summaries,
                    hours: hours,
                    historyDays: historyDays,
                    timeline: timeline,
                    providerHealth: inspectProviders ? SummaryProviderFactory.health() : nil,
                    sourceCapabilities: sources,
                    evidenceQuality: try store.evidenceQuality(),
                    generationCapabilities: generators,
                    providerSelection: settings.providerSelection,
                    effectiveProvider: effectiveProvider,
                    generationBudgets: settings.generationBudgets,
                    automaticSummariesUseLLM: settings.automaticSummariesUseLLM,
                    usageToday: try store.usage(from: today.start, through: today.end),
                    usageMonth: try store.usage(from: month.start, through: month.end),
                    generationBudgetStatus: budgetStatus,
                    reportRuns: try store.reportRuns(limit: 50),
                    summaryRuns: try store.summaryRuns(limit: 50),
                    recipes: try store.recipes(), reportTemplates: try store.reportTemplates(),
                    reportSchedules: try store.reportSchedules(),
                    artifacts: try store.artifacts(limit: 100),
                    collectorIssueCount: collectorStatus.issueCount,
                    collectionPaused: settings.collectionPaused,
                    automaticUpdateChecks: settings.automaticUpdateChecks
                )
            }.value
            let nextGenerationConfiguration = GenerationConfiguration(snapshot: snapshot)
            let generationConfigurationChanged =
                observedGenerationConfiguration != nil
                && observedGenerationConfiguration != nextGenerationConfiguration
            observedGenerationConfiguration = nextGenerationConfiguration
            let budgetRecovered =
                observedBudgetPaused == true && !snapshot.generationBudgetStatus.isPaused
            observedBudgetPaused = snapshot.generationBudgetStatus.isPaused
            dashboard = snapshot.dashboard
            repositories = snapshot.repositories
            roots = snapshot.roots
            summaries = snapshot.summaries
            hours = snapshot.hours
            historyDays = snapshot.historyDays
            timeline = snapshot.timeline
            if let health = snapshot.providerHealth { providerHealth = health }
            sourceCapabilities = snapshot.sourceCapabilities
            evidenceQuality = snapshot.evidenceQuality
            if let capabilities = snapshot.generationCapabilities {
                generationCapabilities = capabilities
            }
            providerSelection = snapshot.providerSelection
            effectiveProvider = snapshot.effectiveProvider
            generationBudgets = snapshot.generationBudgets
            automaticSummariesUseLLM = snapshot.automaticSummariesUseLLM
            usageToday = snapshot.usageToday
            usageMonth = snapshot.usageMonth
            generationBudgetStatus = snapshot.generationBudgetStatus
            reportRuns = snapshot.reportRuns
            summaryRuns = snapshot.summaryRuns
            recipes = snapshot.recipes
            reportTemplates = snapshot.reportTemplates
            reportSchedules = snapshot.reportSchedules
            artifacts = snapshot.artifacts
            collectorIssueCount = snapshot.collectorIssueCount
            collectionPaused = snapshot.collectionPaused
            automaticUpdateChecks = snapshot.automaticUpdateChecks
            errorMessage = nil
            presentationLastRefreshedAt = now
            hasLoadedFullPresentation = true
            if generationConfigurationChanged || budgetRecovered,
                !isUIValidation,
                snapshot.automaticSummariesUseLLM,
                snapshot.effectiveProvider != nil,
                !snapshot.generationBudgetStatus.isPaused
            {
                Task { [weak self] in
                    await self?.generateSummariesAndReportsNow()
                }
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func hourActivity(for date: Date) async -> [HourActivity] {
        let day = Self.day(containing: date)
        return await hourActivity(from: day.start, through: day.end)
    }

    func hourActivity(from start: Date, through end: Date) async -> [HourActivity] {
        do {
            let cutoff = referenceNow
            return try await Task.detached(priority: .utility) {
                let paths = try TrackifyPaths.default()
                let store = try LedgerStore(databaseURL: paths.ledgerURL)
                return try Self.hourActivity(
                    store: store,
                    range: DateInterval(start: start, end: end),
                    cutoff: min(cutoff, end)
                )
            }.value
        } catch {
            errorMessage = "Hourly activity could not be loaded: \(error)"
            return []
        }
    }

    func collectNow() async {
        guard !isCollecting && !isUIValidation else { return }
        isCollecting = true
        do {
            let clock = self.clock
            let issueCount = try await Task.detached(priority: .utility) { () -> Int? in
                let paths = try TrackifyPaths.default()
                let settings = try SettingsStore(fileURL: paths.settingsURL).load()
                guard !settings.collectionPaused else { return nil }
                let store = try LedgerStore(databaseURL: paths.ledgerURL)
                let roots = try store.discoveryRoots(enabledOnly: true).map {
                    GitCollectionRoot(
                        path: URL(filePath: $0.canonicalPath), discoveryRootID: $0.id,
                        excludedPaths: Set($0.excludedPaths))
                }
                let collection = try await LocalCollectionCoordinator(clock: clock).collect(
                    store: store, gitRoots: roots, hookInboxURL: paths.hookInboxURL)
                let now = clock.now()
                let issues = collection.issues.map { (sourceKey: $0.sourceKey, message: $0.message) }
                try store.replaceCollectorIssues(issues, at: now)
                try store.recordHeartbeat(
                    service: "collector", processID: ProcessInfo.processInfo.processIdentifier,
                    observedAt: now, state: issues.isEmpty ? "healthy" : "degraded")
                return issues.count
            }.value
            if issueCount != nil {
                lastCollection = referenceNow
                lastFullReconciliation = referenceNow
            }
            isCollecting = false
            await refreshAfterBackgroundMutation()
            Task { [weak self] in await self?.generateSummariesAndReportsNow() }
        } catch LocalCollectionError.collectionAlreadyRunning {
            isCollecting = false
            errorMessage = nil
            await refreshAfterBackgroundMutation()
        } catch {
            isCollecting = false
            errorMessage = String(describing: error)
        }
    }

    func generateSummariesAndReportsNow() async {
        guard !isUIValidation, !isSummarizing else { return }
        isSummarizing = true
        defer { isSummarizing = false }
        do {
            let now = referenceNow
            let issues = try await Task.detached(priority: .utility) { () -> [String] in
                let paths = try TrackifyPaths.default()
                let store = try LedgerStore(databaseURL: paths.ledgerURL)
                let settings = try SettingsStore(fileURL: paths.settingsURL).load()
                let summaries = await SummaryCoordinator().refresh(
                    store: store, settings: settings, now: now)
                let queue = ReportQueue()
                let enqueued = try queue.enqueueDueReports(
                    store: store, settings: settings, now: now)
                let drained = await queue.drain(store: store, settings: settings)
                return summaries.issues + enqueued.issues + drained.issues
            }.value
            if let issue = issues.first { errorMessage = issue }
            await refreshAfterBackgroundMutation()
        } catch {
            errorMessage = "Summaries or reports could not be generated: \(error)"
        }
    }

    private func refreshAfterBackgroundMutation() async {
        if hasLoadedFullPresentation {
            await refresh()
        } else {
            await refreshEvidence()
        }
    }

    func previewReport(
        recipeID: RecipeID,
        period: DateInterval,
        configuration: ReportRunConfiguration
    ) async -> ReportGenerationPreview? {
        do {
            let cutoff = referenceNow
            return try await Task.detached(priority: .utility) {
                let paths = try TrackifyPaths.default()
                let store = try LedgerStore(databaseURL: paths.ledgerURL)
                let settings = try SettingsStore(fileURL: paths.settingsURL).load()
                return try ReportQueue().preview(
                    store: store, settings: settings, recipeID: recipeID,
                    period: period, cutoff: cutoff, configuration: configuration)
            }.value
        } catch {
            errorMessage = "Report preview could not be prepared: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func generateReport(
        recipeID: RecipeID,
        period: DateInterval,
        configuration: ReportRunConfiguration
    ) async -> ArtifactID? {
        guard !isSummarizing else { return nil }
        isSummarizing = true
        defer { isSummarizing = false }
        do {
            let now = referenceNow
            let artifactID = try await Task.detached(priority: .userInitiated) { () async throws -> ArtifactID? in
                let paths = try TrackifyPaths.default()
                let store = try LedgerStore(databaseURL: paths.ledgerURL)
                let settings = try SettingsStore(fileURL: paths.settingsURL).load()
                let queue = ReportQueue()
                let run = try queue.enqueueOnDemand(
                    store: store, settings: settings, recipeID: recipeID,
                    period: period, now: now, configuration: configuration)
                _ = await queue.drain(store: store, settings: settings, maximumRuns: 1)
                return try store.reportRun(id: run.id)?.artifactID
            }.value
            await refresh()
            return artifactID
        } catch {
            errorMessage = "Report could not be generated: \(error.localizedDescription)"
            return nil
        }
    }

    func saveTemplate(id: RecipeID, draft: ReportTemplateDraft) async -> Bool {
        do {
            let now = referenceNow
            try await Task.detached(priority: .utility) {
                let paths = try TrackifyPaths.default()
                let store = try LedgerStore(databaseURL: paths.ledgerURL)
                _ = try store.createRecipeVersion(
                    recipeID: id, name: draft.name, purpose: draft.purpose,
                    audience: draft.audience, cadence: draft.cadence,
                    repositoryIDs: draft.repositoryIDs, groupNames: draft.groupNames,
                    customFocus: draft.customFocus, tone: draft.tone,
                    outputFormat: draft.outputFormat,
                    maximumCharacters: draft.maximumCharacters,
                    privacyProfile: draft.privacyProfile,
                    providerModeOverride: draft.providerModeOverride, now: now)
            }.value
            await refresh()
            return true
        } catch {
            errorMessage = "Template could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    func duplicateTemplate(_ template: ReportTemplate, name: String? = nil) async -> RecipeID? {
        let base = Self.slug(name ?? "\(template.recipe.name) Copy")
        let existing = Set(reportTemplates.map { $0.id.rawValue })
        var value = base
        var suffix = 2
        while existing.contains(value) {
            value = "\(base)-\(suffix)"
            suffix += 1
        }
        let id = RecipeID(value)
        var draft = ReportTemplateDraft(template: template, name: name ?? "\(template.recipe.name) Copy")
        draft.cadence = .onDemand
        return await saveTemplate(id: id, draft: draft) ? id : nil
    }

    func createTemplate(_ draft: ReportTemplateDraft) async -> RecipeID? {
        let base = Self.slug(draft.name)
        guard !base.isEmpty else {
            errorMessage = "Template name must contain at least one letter or number."
            return nil
        }
        let existing = Set(reportTemplates.map { $0.id.rawValue })
        var value = base
        var suffix = 2
        while existing.contains(value) {
            value = "\(base)-\(suffix)"
            suffix += 1
        }
        let id = RecipeID(value)
        return await saveTemplate(id: id, draft: draft) ? id : nil
    }

    func setTemplateEnabled(_ enabled: Bool, id: RecipeID) async {
        do {
            let paths = try TrackifyPaths.default()
            try LedgerStore(databaseURL: paths.ledgerURL).setRecipeEnabled(enabled, id: id)
            await refresh()
        } catch { errorMessage = "Template state could not be saved: \(error.localizedDescription)" }
    }

    func saveSchedule(id: ReportScheduleID?, draft: ReportScheduleDraft) async -> ReportScheduleID? {
        do {
            let scheduleID = id ?? ReportScheduleID.random()
            let now = referenceNow
            try await Task.detached(priority: .utility) {
                let paths = try TrackifyPaths.default()
                let store = try LedgerStore(databaseURL: paths.ledgerURL)
                _ = try store.saveReportSchedule(id: scheduleID, draft: draft, now: now)
            }.value
            await refresh()
            return scheduleID
        } catch {
            errorMessage = "Scheduled reporter could not be saved: \(error.localizedDescription)"
            return nil
        }
    }

    func setScheduleEnabled(_ enabled: Bool, id: ReportScheduleID) async {
        do {
            let paths = try TrackifyPaths.default()
            try LedgerStore(databaseURL: paths.ledgerURL).setReportScheduleEnabled(
                enabled, id: id, now: referenceNow)
            await refresh()
        } catch {
            errorMessage = "Scheduled reporter state could not be saved: \(error.localizedDescription)"
        }
    }

    func deleteSchedule(id: ReportScheduleID) async -> Bool {
        do {
            let paths = try TrackifyPaths.default()
            try LedgerStore(databaseURL: paths.ledgerURL).deleteReportSchedule(id: id)
            await refresh()
            return true
        } catch {
            errorMessage = "Scheduled reporter could not be removed: \(error.localizedDescription)"
            return false
        }
    }

    func rescanCapabilities() async {
        generationCapabilities = []
        providerHealth = []
        await refresh()
    }

    func setProviderSelection(_ mode: ProviderSelectionMode) async {
        do {
            let paths = try TrackifyPaths.default()
            let store = SettingsStore(fileURL: paths.settingsURL)
            var settings = try store.load()
            settings.providerSelection = mode
            try store.save(settings)
            providerSelection = mode
            effectiveProvider = CapabilityDiscovery().effectiveProvider(
                mode: mode, capabilities: generationCapabilities)
            await refresh()
        } catch { errorMessage = "Provider preference could not be saved: \(error)" }
    }

    func setAutomaticSummariesUseLLM(_ enabled: Bool) async {
        do {
            let paths = try TrackifyPaths.default()
            let store = SettingsStore(fileURL: paths.settingsURL)
            var settings = try store.load()
            settings.automaticSummariesUseLLM = enabled
            try store.save(settings)
            automaticSummariesUseLLM = enabled
            await refresh()
        } catch { errorMessage = "Summary preference could not be saved: \(error)" }
    }

    func saveGenerationBudgets(_ budgets: GenerationBudgets) async {
        do {
            let budgets = budgets.normalized()
            let paths = try TrackifyPaths.default()
            let store = SettingsStore(fileURL: paths.settingsURL)
            var settings = try store.load()
            settings.generationBudgets = budgets
            try store.save(settings)
            generationBudgets = budgets
            await refresh()
        } catch { errorMessage = "Generation budgets could not be saved: \(error)" }
    }

    func testProvider(_ id: SummaryProviderID) async {
        guard !isSummarizing else { return }
        isSummarizing = true
        defer { isSummarizing = false }
        do {
            let result = try await Task.detached(priority: .utility) {
                let paths = try TrackifyPaths.default()
                let store = try LedgerStore(databaseURL: paths.ledgerURL)
                let settings = try SettingsStore(fileURL: paths.settingsURL).load()
                return try await ReportQueue().testProvider(id, store: store, settings: settings, now: Date())
            }.value
            if result.state != .succeeded {
                errorMessage = result.failureDetail ?? "Provider test did not succeed."
            }
            await refresh()
        } catch { errorMessage = "Provider test failed: \(error)" }
    }

    func summaries(on date: Date) -> [WorkSummary] {
        let day = Self.day(containing: date)
        return summaries.filter { $0.periodStart >= day.start && $0.periodStart < day.end }
    }

    func repositoryName(_ id: RepositoryID?) -> String? {
        guard let id else { return nil }
        return repositories.first { $0.repository.id == id }?.repository.displayName
    }

    func repositoryNames(for ids: Set<RepositoryID>) -> [String] {
        Array(Set(repositories.filter { ids.contains($0.repository.id) }.map { $0.repository.displayName })).sorted()
    }

    func setCollectionPaused(_ paused: Bool) async {
        do {
            let paths = try TrackifyPaths.default()
            let store = SettingsStore(fileURL: paths.settingsURL)
            var settings = try store.load()
            settings.collectionPaused = paused
            try store.save(settings)
            collectionPaused = paused
            liveCollectionRuntime?.setPaused(paused)
        } catch { errorMessage = String(describing: error) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            let paths = try TrackifyPaths.default()
            let settingsStore = SettingsStore(fileURL: paths.settingsURL)
            var settings = try settingsStore.load()
            settings.launchAtLoginEnabled = launchAtLoginEnabled
            try settingsStore.save(settings)
        } catch {
            errorMessage = String(describing: error)
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        }
    }

    func setAutomaticUpdateChecks(_ enabled: Bool) {
        do {
            let paths = try TrackifyPaths.default()
            let settingsStore = SettingsStore(fileURL: paths.settingsURL)
            var settings = try settingsStore.load()
            settings.automaticUpdateChecks = enabled
            try settingsStore.save(settings)
            automaticUpdateChecks = enabled
        } catch { errorMessage = "Update preference could not be saved: \(error)" }
    }

    func prepareForUninstall() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
        } catch {
            errorMessage = "Launch-at-login registration could not be removed: \(error)"
            return
        }
        NSApp.terminate(nil)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func configureLoginItemIfNeeded() {
        do {
            let paths = try TrackifyPaths.default()
            let settingsStore = SettingsStore(fileURL: paths.settingsURL)
            var settings = try settingsStore.load()
            guard settings.launchAtLoginEnabled == nil else { return }
            try SMAppService.mainApp.register()
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            settings.launchAtLoginEnabled = launchAtLoginEnabled
            try settingsStore.save(settings)
        } catch { errorMessage = "Launch at login could not be configured: \(error)" }
    }

    private nonisolated static func makeTimeline(
        events: [LedgerEvent], summaries: [WorkSummary], messages: [MessageID: ConversationMessage]
    ) -> [TimelineEntry] {
        var seenMessages: Set<MessageID> = []
        let eventEntries = events.compactMap { event -> TimelineEntry? in
            switch event.kind {
            case .gitCommitObserved:
                return TimelineEntry(
                    id: event.id.rawValue, occurredAt: event.occurredAt, kind: .commit,
                    title: event.payload["message"] ?? "Commit recorded",
                    detail: lineDetail(event.payload), repositoryID: event.repositoryID,
                    source: event.source, state: event.state?.rawValue, messageRole: nil)
            case .agentMessageObserved:
                guard let value = event.payload["messageID"], let message = messages[MessageID(value)]
                else { return nil }
                switch message.role {
                case .user, .assistant: break
                case .system: return nil
                }
                guard let workText = ConversationMessageVisibility.workText(message) else {
                    return nil
                }
                guard seenMessages.insert(message.id).inserted else { return nil }
                return TimelineEntry(
                    id: event.id.rawValue, occurredAt: event.occurredAt, kind: .conversation,
                    title: workText, detail: nil, repositoryID: event.repositoryID,
                    source: event.source, state: event.state?.rawValue, messageRole: message.role)
            case .gitWorkingTreeChanged:
                return TimelineEntry(
                    id: event.id.rawValue, occurredAt: event.occurredAt, kind: .change,
                    title: event.state == .inProgress ? "Uncommitted work in progress" : "Working tree changed",
                    detail: event.payload["filesChanged"].map { "\($0) files changed" },
                    repositoryID: event.repositoryID, source: event.source, state: event.state?.rawValue,
                    messageRole: nil)
            case .testFinished:
                return TimelineEntry(
                    id: event.id.rawValue, occurredAt: event.occurredAt, kind: .test,
                    title: event.state == .failed ? "Tests need attention" : "Tests passed",
                    detail: event.payload["suite"], repositoryID: event.repositoryID,
                    source: event.source, state: event.state?.rawValue, messageRole: nil)
            default:
                return nil
            }
        }
        let summaryEntries =
            summaries
            .filter { $0.kind == .segment }
            .map {
                TimelineEntry(
                    id: $0.id.rawValue, occurredAt: $0.periodEnd, kind: .summary,
                    title: $0.content.compactNarrative,
                    detail: "\($0.coverage.coveredEventCount) covered events",
                    repositoryID: nil, source: nil, state: $0.state.rawValue, messageRole: nil)
            }
        return (eventEntries + summaryEntries).sorted {
            if $0.occurredAt == $1.occurredAt { return $0.id > $1.id }
            return $0.occurredAt > $1.occurredAt
        }
    }

    private nonisolated static func lineDetail(_ payload: [String: String]) -> String? {
        guard let additions = payload["additions"], let deletions = payload["deletions"] else { return nil }
        let files = payload["filesChanged"].map { " · \($0) files" } ?? ""
        return "+\(additions) / −\(deletions)\(files)"
    }

    private nonisolated static func dayRanges(from start: Date, through end: Date) -> [DateInterval] {
        var ranges: [DateInterval] = []
        var cursor = start
        while cursor < end {
            let next = Calendar.current.date(byAdding: .day, value: 1, to: cursor)!
            ranges.append(DateInterval(start: cursor, end: min(next, end)))
            cursor = next
        }
        return ranges
    }

    private nonisolated static func hourActivity(
        store: LedgerStore,
        range: DateInterval,
        cutoff: Date
    ) throws -> [HourActivity] {
        var ranges: [DateInterval] = []
        var cursor = range.start
        while cursor < range.end {
            guard let next = Calendar.current.date(byAdding: .hour, value: 1, to: cursor), next > cursor else {
                break
            }
            ranges.append(DateInterval(start: cursor, end: min(next, range.end)))
            cursor = next
        }
        let snapshots = try ActivityQueries().snapshots(
            store: store,
            ranges: ranges,
            cutoff: cutoff,
            calendar: Calendar.current
        )
        return zip(ranges, snapshots).map { HourActivity(start: $0.0.start, activity: $0.1) }
    }

    private nonisolated static func day(containing date: Date) -> DateInterval {
        let start = Calendar.current.startOfDay(for: date)
        return DateInterval(start: start, end: Calendar.current.date(byAdding: .day, value: 1, to: start)!)
    }

    private nonisolated static func parseISO8601(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private nonisolated static func slug(_ value: String) -> String {
        let allowed = value.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        return String(allowed).split(separator: "-").filter { !$0.isEmpty }.joined(separator: "-")
    }

    private nonisolated static func validationGenerationCapabilities(now: Date) -> [GenerationCapability] {
        [
            GenerationCapability(
                id: .codex, executablePath: "/Applications/ChatGPT.app/Contents/Resources/codex",
                cliVersion: "codex-cli showcase", authentication: .ready,
                structuredOutput: true, usageReporting: true, hardMonetaryCap: false,
                requestedModel: "gpt-5.6-sol", effectiveModelKnown: true,
                invocationContractVersion: CodexSummaryProvider.invocationVersion,
                lastProbeAt: now),
            GenerationCapability(
                id: .claude, executablePath: "/usr/local/bin/claude",
                cliVersion: "Claude Code showcase", authentication: .unknown,
                structuredOutput: true, usageReporting: true, hardMonetaryCap: false,
                requestedModel: "opus", effectiveModelKnown: false,
                invocationContractVersion: ClaudeSummaryProvider.invocationVersion,
                lastProbeAt: now,
                detail: "Authentication is verified only by an explicit synthetic test."),
        ]
    }

    private nonisolated static func validationSourceCapabilities(now: Date) -> [SourceCapability] {
        [
            SourceCapability(
                id: "codex-cli-history", family: "codex", surface: "Codex CLI/Desktop history",
                location: "/Users/demo/.codex/sessions", adapterVersion: 1, state: .available,
                lastProbeAt: now, lastSuccessfulImportAt: now.addingTimeInterval(-30),
                importedRecordCount: 248),
            SourceCapability(
                id: "codex-archive-history", family: "codex", surface: "Codex archived history",
                location: "/Users/demo/.codex/archived_sessions", adapterVersion: 1, state: .available,
                lastProbeAt: now, lastSuccessfulImportAt: now.addingTimeInterval(-30),
                importedRecordCount: 248),
            SourceCapability(
                id: "claude-terminal-history", family: "claude", surface: "Claude Code terminal history",
                location: "/Users/demo/.claude/projects", adapterVersion: 1, state: .available,
                lastProbeAt: now, lastSuccessfulImportAt: now.addingTimeInterval(-45),
                importedRecordCount: 183),
            SourceCapability(
                id: "claude-desktop-code-history", family: "claude", surface: "Claude Desktop Code history",
                location: "/Users/demo/Library/Application Support/Claude/local-agent-mode-sessions",
                adapterVersion: 1, state: .degraded,
                lastProbeAt: now, lastSuccessfulImportAt: now.addingTimeInterval(-45),
                importedRecordCount: 183,
                detail: "A future-version record was skipped safely."),
        ]
    }
}

private struct AppSnapshot: Sendable {
    let dashboard: ActivityDashboard
    let repositories: [RepositoryCatalogItem]
    let roots: [DiscoveryRoot]
    let summaries: [WorkSummary]
    let hours: [HourActivity]
    let historyDays: [CalendarActivity]
    let timeline: [TimelineEntry]
    let providerHealth: [ProviderHealth]?
    let sourceCapabilities: [SourceCapability]
    let evidenceQuality: EvidenceQualitySnapshot
    let generationCapabilities: [GenerationCapability]?
    let providerSelection: ProviderSelectionMode
    let effectiveProvider: SummaryProviderID?
    let generationBudgets: GenerationBudgets
    let automaticSummariesUseLLM: Bool
    let usageToday: UsageSummary
    let usageMonth: UsageSummary
    let generationBudgetStatus: GenerationBudgetStatus
    let reportRuns: [ReportRun]
    let summaryRuns: [SummaryRun]
    let recipes: [ReportRecipe]
    let reportTemplates: [ReportTemplate]
    let reportSchedules: [ReportSchedule]
    let artifacts: [Artifact]
    let collectorIssueCount: Int
    let collectionPaused: Bool
    let automaticUpdateChecks: Bool
}

private struct EvidenceAppSnapshot: Sendable {
    let dashboard: ActivityDashboard
    let repositories: [RepositoryCatalogItem]
    let summaries: [WorkSummary]
    let hours: [HourActivity]
    let currentDay: CalendarActivity
    let timeline: [TimelineEntry]
    let evidenceQuality: EvidenceQualitySnapshot
    let collectorIssueCount: Int
    let lastCollection: Date?
}

private struct GenerationConfiguration: Equatable {
    let providerSelection: String
    let automaticSummariesUseLLM: Bool
    let budgets: GenerationBudgets

    init(snapshot: AppSnapshot) {
        providerSelection = snapshot.providerSelection.rawValue
        automaticSummariesUseLLM = snapshot.automaticSummariesUseLLM
        budgets = snapshot.generationBudgets
    }
}
