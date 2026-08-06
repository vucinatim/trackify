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
        case report
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
    @Published private(set) var reports: [WorkReport] = []
    @Published private(set) var hours: [HourActivity] = []
    @Published private(set) var historyDays: [CalendarActivity] = []
    @Published private(set) var timeline: [TimelineEntry] = []
    @Published private(set) var providerHealth: [ProviderHealth] = []
    @Published private(set) var sourceCapabilities: [SourceCapability] = []
    @Published private(set) var generationCapabilities: [GenerationCapability] = []
    @Published private(set) var providerSelection: ProviderSelectionMode = .automatic
    @Published private(set) var effectiveProvider: SummaryProviderID?
    @Published private(set) var generationBudgets = GenerationBudgets()
    @Published private(set) var scheduledModelReportsEnabled = true
    @Published private(set) var usageToday = UsageSummary(
        runs: 0, succeeded: 0, failed: 0, inputTokens: 0, cachedInputTokens: 0,
        outputTokens: 0, reasoningTokens: 0, durationSeconds: 0, knownCost: 0,
        currency: nil, hasUnknownCost: false)
    @Published private(set) var usageMonth = UsageSummary(
        runs: 0, succeeded: 0, failed: 0, inputTokens: 0, cachedInputTokens: 0,
        outputTokens: 0, reasoningTokens: 0, durationSeconds: 0, knownCost: 0,
        currency: nil, hasUnknownCost: false)
    @Published private(set) var reportRuns: [ReportRun] = []
    @Published private(set) var recipes: [ReportRecipe] = []
    @Published private(set) var artifacts: [Artifact] = []
    @Published private(set) var isSummarizing = false
    @Published private(set) var isCollecting = false
    @Published private(set) var lastCollection: Date?
    @Published var errorMessage: String?
    @Published private(set) var collectorIssueCount = 0
    @Published private(set) var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    @Published private(set) var collectionPaused = false
    @Published private(set) var automaticUpdateChecks = true

    let isUIValidation: Bool
    private let clock: any WallClock
    private var schedulerTask: Task<Void, Never>?
    private var hasInitializedOverviewPresentation = false

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
            ?? (collectorIssueCount > 0
                ? "Collection has \(collectorIssueCount) source or report issue\(collectorIssueCount == 1 ? "" : "s"). Run trackify doctor for details."
                : nil)
    }

    var llmBudgetPaused: Bool {
        reportRuns.first?.failureClass == .budget && reportRuns.first?.state == .fallback
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

    deinit { schedulerTask?.cancel() }

    func claimInitialOverviewPresentation() -> Bool {
        guard !hasInitializedOverviewPresentation else { return false }
        hasInitializedOverviewPresentation = true
        return true
    }

    func start() async {
        guard schedulerTask == nil else { return }
        if !isUIValidation { configureLoginItemIfNeeded() }
        await refresh()
        guard !isUIValidation else { return }
        schedulerTask = Task { [weak self] in
            await self?.generateReportsNow()
            await self?.refresh()
            await self?.collectNow()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await self?.refresh()
                if self?.referenceNow.timeIntervalSince(self?.lastCollection ?? .distantPast) ?? 0 >= 30 * 60 {
                    await self?.collectNow()
                }
            }
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

                let hours = try Self.hourActivity(store: store, day: day, cutoff: now)

                let reportRange = DateInterval(start: historyStart, end: day.end)
                let reports = try store.reports(overlapping: reportRange).sorted { $0.periodStart > $1.periodStart }
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
                let timeline = Self.makeTimeline(events: events, reports: reports, messages: messageByID)
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

                return AppSnapshot(
                    dashboard: dashboard,
                    repositories: repositoryCatalog,
                    roots: try store.discoveryRoots(),
                    reports: reports,
                    hours: hours,
                    historyDays: historyDays,
                    timeline: timeline,
                    providerHealth: inspectProviders ? SummaryProviderFactory.health() : nil,
                    sourceCapabilities: sources,
                    generationCapabilities: generators,
                    providerSelection: settings.providerSelection,
                    effectiveProvider: discovery.effectiveProvider(
                        mode: settings.providerSelection,
                        capabilities: generators ?? cachedGenerationCapabilities),
                    generationBudgets: settings.generationBudgets,
                    scheduledModelReportsEnabled: settings.scheduledModelReportsEnabled,
                    usageToday: try store.usage(from: today.start, through: today.end),
                    usageMonth: try store.usage(from: month.start, through: month.end),
                    reportRuns: try store.reportRuns(limit: 50),
                    recipes: try store.recipes(), artifacts: try store.artifacts(limit: 50),
                    collectorIssueCount: collectorStatus.issueCount,
                    collectionPaused: settings.collectionPaused,
                    automaticUpdateChecks: settings.automaticUpdateChecks
                )
            }.value
            dashboard = snapshot.dashboard
            repositories = snapshot.repositories
            roots = snapshot.roots
            reports = snapshot.reports
            hours = snapshot.hours
            historyDays = snapshot.historyDays
            timeline = snapshot.timeline
            if let health = snapshot.providerHealth { providerHealth = health }
            sourceCapabilities = snapshot.sourceCapabilities
            if let capabilities = snapshot.generationCapabilities {
                generationCapabilities = capabilities
            }
            providerSelection = snapshot.providerSelection
            effectiveProvider = snapshot.effectiveProvider
            generationBudgets = snapshot.generationBudgets
            scheduledModelReportsEnabled = snapshot.scheduledModelReportsEnabled
            usageToday = snapshot.usageToday
            usageMonth = snapshot.usageMonth
            reportRuns = snapshot.reportRuns
            recipes = snapshot.recipes
            artifacts = snapshot.artifacts
            collectorIssueCount = snapshot.collectorIssueCount
            collectionPaused = snapshot.collectionPaused
            automaticUpdateChecks = snapshot.automaticUpdateChecks
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func hourActivity(for date: Date) async -> [HourActivity] {
        do {
            let cutoff = referenceNow
            return try await Task.detached(priority: .utility) {
                let paths = try TrackifyPaths.default()
                let store = try LedgerStore(databaseURL: paths.ledgerURL)
                let day = Self.day(containing: date)
                return try Self.hourActivity(store: store, day: day, cutoff: min(cutoff, day.end))
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
            if issueCount != nil { lastCollection = referenceNow }
            isCollecting = false
            await refresh()
            Task { [weak self] in await self?.generateReportsNow() }
        } catch LocalCollectionError.collectionAlreadyRunning {
            isCollecting = false
            errorMessage = nil
            await refresh()
        } catch {
            isCollecting = false
            errorMessage = String(describing: error)
        }
    }

    func generateReportsNow() async {
        guard !isUIValidation, !isSummarizing else { return }
        isSummarizing = true
        defer { isSummarizing = false }
        do {
            let now = referenceNow
            let result = try await Task.detached(priority: .utility) { () -> ReportQueueResult in
                let paths = try TrackifyPaths.default()
                let store = try LedgerStore(databaseURL: paths.ledgerURL)
                let settings = try SettingsStore(fileURL: paths.settingsURL).load()
                let queue = ReportQueue()
                let enqueued = try queue.enqueueDueReports(
                    store: store, settings: settings, now: now)
                let drained = await queue.drain(store: store, settings: settings)
                return ReportQueueResult(
                    enqueued: enqueued.enqueued, completed: drained.completed,
                    issues: enqueued.issues + drained.issues)
            }.value
            if let issue = result.issues.first { errorMessage = issue }
            await refresh()
        } catch {
            errorMessage = "Reports could not be generated: \(error)"
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
            settings.summaryProvider = mode.explicitProvider
            try store.save(settings)
            providerSelection = mode
            effectiveProvider = CapabilityDiscovery().effectiveProvider(
                mode: mode, capabilities: generationCapabilities)
        } catch { errorMessage = "Provider preference could not be saved: \(error)" }
    }

    func setScheduledModelReportsEnabled(_ enabled: Bool) async {
        do {
            let paths = try TrackifyPaths.default()
            let store = SettingsStore(fileURL: paths.settingsURL)
            var settings = try store.load()
            settings.scheduledModelReportsEnabled = enabled
            try store.save(settings)
            scheduledModelReportsEnabled = enabled
        } catch { errorMessage = "Summary preference could not be saved: \(error)" }
    }

    func saveGenerationBudgets(_ budgets: GenerationBudgets) async {
        do {
            let paths = try TrackifyPaths.default()
            let store = SettingsStore(fileURL: paths.settingsURL)
            var settings = try store.load()
            settings.generationBudgets = budgets
            try store.save(settings)
            generationBudgets = budgets
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

    func reports(on date: Date) -> [WorkReport] {
        let day = Self.day(containing: date)
        return reports.filter { $0.periodStart >= day.start && $0.periodStart < day.end }
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
        events: [LedgerEvent], reports: [WorkReport], messages: [MessageID: ConversationMessage]
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
                guard seenMessages.insert(message.id).inserted else { return nil }
                return TimelineEntry(
                    id: event.id.rawValue, occurredAt: event.occurredAt, kind: .conversation,
                    title: message.normalizedText, detail: nil, repositoryID: event.repositoryID,
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
        let reportEntries = reports.map {
            TimelineEntry(
                id: $0.id.rawValue, occurredAt: $0.periodStart, kind: .report,
                title: $0.summary, detail: "\($0.evidenceIDs.count) evidence records",
                repositoryID: nil, source: nil, state: $0.state.rawValue, messageRole: nil)
        }
        return (eventEntries + reportEntries).sorted {
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
        day: DateInterval,
        cutoff: Date
    ) throws -> [HourActivity] {
        let ranges = (0..<24).map { hour -> DateInterval in
            let start = Calendar.current.date(byAdding: .hour, value: hour, to: day.start)!
            let end = min(Calendar.current.date(byAdding: .hour, value: 1, to: start)!, day.end)
            return DateInterval(start: start, end: end)
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
    let reports: [WorkReport]
    let hours: [HourActivity]
    let historyDays: [CalendarActivity]
    let timeline: [TimelineEntry]
    let providerHealth: [ProviderHealth]?
    let sourceCapabilities: [SourceCapability]
    let generationCapabilities: [GenerationCapability]?
    let providerSelection: ProviderSelectionMode
    let effectiveProvider: SummaryProviderID?
    let generationBudgets: GenerationBudgets
    let scheduledModelReportsEnabled: Bool
    let usageToday: UsageSummary
    let usageMonth: UsageSummary
    let reportRuns: [ReportRun]
    let recipes: [ReportRecipe]
    let artifacts: [Artifact]
    let collectorIssueCount: Int
    let collectionPaused: Bool
    let automaticUpdateChecks: Bool
}
