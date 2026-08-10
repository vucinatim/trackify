import Foundation
import TrackifyDomain
import TrackifyStore

public struct ReportQueueResult: Codable, Equatable, Sendable {
    public let enqueued: [ReportRunID]
    public let completed: [ArtifactID]
    public let issues: [String]

    public init(enqueued: [ReportRunID] = [], completed: [ArtifactID] = [], issues: [String] = []) {
        self.enqueued = enqueued
        self.completed = completed
        self.issues = issues
    }
}

public struct ModelBackfillPlan: Codable, Equatable, Sendable {
    public let periods: [DateInterval]
    public let activePeriods: Int
    public let maximumCalls: Int
    public let estimatedInputTokens: Int

    public init(periods: [DateInterval], activePeriods: Int, maximumCalls: Int, estimatedInputTokens: Int) {
        self.periods = periods
        self.activePeriods = activePeriods
        self.maximumCalls = maximumCalls
        self.estimatedInputTokens = estimatedInputTokens
    }
}

public struct ReportGenerationPreview: Codable, Equatable, Sendable {
    public let state: ReportPeriodState
    public let evidenceCount: Int
    public let serializedBytes: Int
    public let estimatedInputTokens: Int
    public let providerMode: ProviderSelectionMode

    public init(
        state: ReportPeriodState, evidenceCount: Int, serializedBytes: Int,
        estimatedInputTokens: Int, providerMode: ProviderSelectionMode
    ) {
        self.state = state
        self.evidenceCount = evidenceCount
        self.serializedBytes = serializedBytes
        self.estimatedInputTokens = estimatedInputTokens
        self.providerMode = providerMode
    }
}

public struct ReportQueue: Sendable {
    public typealias ProviderFactory = @Sendable (SummaryProviderID, TimeInterval) -> any SummaryProvider

    private let providerFactory: ProviderFactory
    private let generator: ReportGenerator
    private let recipePolicy: ReportRecipePolicy
    private let budgetController: GenerationBudgetController
    private let allowanceReader: any ProviderAllowanceReading

    public init(
        providerFactory: @escaping ProviderFactory = { id, deadline in
            SummaryProviderFactory.make(id, timeout: deadline)
        },
        generator: ReportGenerator = ReportGenerator(),
        recipePolicy: ReportRecipePolicy = ReportRecipePolicy(),
        allowanceReader: any ProviderAllowanceReading = AutomaticProviderAllowanceReader(),
        budgetController: GenerationBudgetController? = nil
    ) {
        self.providerFactory = providerFactory
        self.generator = generator
        self.recipePolicy = recipePolicy
        self.allowanceReader = allowanceReader
        self.budgetController =
            budgetController
            ?? GenerationBudgetController(allowanceReader: allowanceReader)
    }

    /// Enqueues only the most recent closed hour and day. This deliberately
    /// coalesces sleep/wake and never turns evidence backfill into a call storm.
    public func enqueueDueReports(
        store: LedgerStore,
        settings: TrackifySettings,
        now: Date,
        calendar: Calendar = .current
    ) throws -> ReportQueueResult {
        guard let hour = calendar.dateInterval(of: .hour, for: now),
            let hourStart = calendar.date(byAdding: .hour, value: -1, to: hour.start),
            let day = calendar.dateInterval(of: .day, for: now),
            let dayStart = calendar.date(byAdding: .day, value: -1, to: day.start)
        else { return ReportQueueResult(issues: ["Could not calculate closed report periods."]) }
        let candidates: [(DateInterval, ReportSchedule)] = try store.reportSchedules(enabledOnly: true).map {
            schedule in
            switch schedule.cadence {
            case .hourly: return (DateInterval(start: hourStart, end: hour.start), schedule)
            case .daily: return (DateInterval(start: dayStart, end: day.start), schedule)
            }
        }
        var enqueued: [ReportRunID] = []
        var issues: [String] = []
        for (period, schedule) in candidates {
            do {
                guard let (template, storedRecipe) = try store.recipe(id: schedule.recipeID),
                    template.isEnabled
                else { continue }
                guard try !store.hasReportRun(period: period, scheduleID: schedule.id) else { continue }
                let configuration = ReportRunConfiguration(
                    purpose: storedRecipe.purpose, audience: storedRecipe.audience,
                    repositoryIDs: schedule.repositoryIDs, groupNames: schedule.groupNames,
                    customFocus: storedRecipe.customFocus, tone: storedRecipe.tone,
                    outputFormat: storedRecipe.outputFormat,
                    maximumCharacters: storedRecipe.maximumCharacters,
                    privacyProfile: storedRecipe.privacyProfile,
                    providerModeOverride: schedule.providerModeOverride
                        ?? storedRecipe.providerModeOverride)
                let recipe = configuration.recipeVersion(basedOn: storedRecipe)
                let packet = try evidencePacket(
                    store: store, range: period, cutoff: period.end, recipe: recipe)
                let run = makePendingRun(
                    recipe: recipe, period: period, intent: .scheduled,
                    mode: recipe.providerModeOverride ?? settings.providerSelection,
                    packet: packet, now: now, configuration: configuration,
                    scheduleID: schedule.id)
                let persisted = try store.enqueue(
                    EnqueueReportRun(
                        run: run, evidence: provenance(packet),
                        summaries: summaryProvenance(packet)))
                if persisted.state == .pending { enqueued.append(persisted.id) }
            } catch {
                issues.append("Could not enqueue \(schedule.id.rawValue): \(error.localizedDescription)")
            }
        }
        return ReportQueueResult(enqueued: enqueued, issues: issues)
    }

    public func enqueueOnDemand(
        store: LedgerStore,
        settings: TrackifySettings,
        recipeID: RecipeID,
        period: DateInterval,
        now: Date,
        intent: ReportRunIntent = .onDemand,
        configuration: ReportRunConfiguration? = nil
    ) throws -> ReportRun {
        guard let (_, storedRecipe) = try store.recipe(id: recipeID) else {
            throw LedgerStoreError.unsupportedValue(type: "ReportRecipe", value: recipeID.rawValue)
        }
        let runConfiguration = try validated(configuration ?? ReportRunConfiguration(recipe: storedRecipe))
        let recipe = runConfiguration.recipeVersion(basedOn: storedRecipe)
        let packet = try evidencePacket(
            store: store, range: period, cutoff: min(now, period.end), recipe: recipe)
        let run = makePendingRun(
            recipe: recipe, period: period, intent: intent,
            mode: recipe.providerModeOverride ?? settings.providerSelection,
            packet: packet, now: now, configuration: runConfiguration)
        return try store.enqueue(
            EnqueueReportRun(
                run: run, evidence: provenance(packet),
                summaries: summaryProvenance(packet)))
    }

    public func preview(
        store: LedgerStore,
        settings: TrackifySettings,
        recipeID: RecipeID,
        period: DateInterval,
        cutoff: Date,
        configuration: ReportRunConfiguration? = nil
    ) throws -> ReportGenerationPreview {
        guard let (_, storedRecipe) = try store.recipe(id: recipeID) else {
            throw LedgerStoreError.unsupportedValue(type: "ReportRecipe", value: recipeID.rawValue)
        }
        let runConfiguration = try validated(configuration ?? ReportRunConfiguration(recipe: storedRecipe))
        let recipe = runConfiguration.recipeVersion(basedOn: storedRecipe)
        let packet = try evidencePacket(
            store: store, range: period, cutoff: min(cutoff, period.end), recipe: recipe)
        let mode = recipe.providerModeOverride ?? settings.providerSelection
        return ReportGenerationPreview(
            state: packet.state, evidenceCount: packet.selection.selectedEventCount,
            serializedBytes: packet.serializedByteCount,
            estimatedInputTokens: estimatedInputTokens(packet: packet, mode: mode),
            providerMode: mode)
    }

    public func backfillPlan(
        store: LedgerStore,
        recipeID: RecipeID,
        periods: [DateInterval],
        cutoff: Date,
        providerMode: ProviderSelectionMode = .automatic
    ) throws -> ModelBackfillPlan {
        guard let (_, recipe) = try store.recipe(id: recipeID) else {
            throw LedgerStoreError.unsupportedValue(type: "ReportRecipe", value: recipeID.rawValue)
        }
        var active = 0
        var tokens = 0
        for period in periods {
            let packet = try evidencePacket(
                store: store, range: period, cutoff: min(cutoff, period.end), recipe: recipe)
            guard packet.state != .noActivity else { continue }
            active += 1
            tokens += estimatedInputTokens(packet: packet, mode: providerMode)
        }
        return ModelBackfillPlan(
            periods: periods, activePeriods: active, maximumCalls: active,
            estimatedInputTokens: tokens)
    }

    public func enqueueBackfill(
        store: LedgerStore,
        settings: TrackifySettings,
        recipeID: RecipeID,
        periods: [DateInterval],
        now: Date,
        confirmed: Bool
    ) throws -> [ReportRun] {
        guard confirmed else {
            throw LedgerStoreError.unsupportedValue(
                type: "ModelBackfill", value: "explicit confirmation required after preview")
        }
        return try periods.map {
            try enqueueOnDemand(
                store: store, settings: settings, recipeID: recipeID,
                period: $0, now: now, intent: .backfill)
        }
    }

    public func drain(
        store: LedgerStore,
        settings: TrackifySettings,
        now: @escaping @Sendable () -> Date = Date.init,
        maximumRuns: Int = 2
    ) async -> ReportQueueResult {
        precondition((1...20).contains(maximumRuns))
        let ownerID = "reports:\(ProcessInfo.processInfo.processIdentifier):\(UUID().uuidString)"
        do {
            guard
                try store.acquireLease(
                    name: ProviderGenerationLease.name, ownerID: ownerID,
                    now: now(), duration: 240)
            else { return ReportQueueResult() }
        } catch {
            return ReportQueueResult(issues: ["Could not acquire report queue: \(error.localizedDescription)"])
        }
        defer { try? store.releaseLease(name: ProviderGenerationLease.name, ownerID: ownerID) }

        var completed: [ArtifactID] = []
        var issues: [String] = []
        do {
            for run in try store.recoverInterruptedReportRuns(at: now()) where run.intent != .providerTest {
                guard let storedRecipe = try store.recipeVersion(id: run.recipeVersionID) else { continue }
                let recipe = run.configuration?.recipeVersion(basedOn: storedRecipe) ?? storedRecipe
                let packet = try evidencePacket(
                    store: store,
                    range: DateInterval(start: run.periodStart, end: run.periodEnd),
                    cutoff: run.periodEnd, recipe: recipe)
                let artifact = try deterministicArtifact(
                    run: run, recipe: recipe, packet: packet,
                    summary: generator.deterministicSummary(packet), failureClass: .cancelled,
                    failureDetail: run.failureDetail, store: store, now: now())
                completed.append(artifact.id)
            }
        } catch {
            issues.append("Could not recover an interrupted report run: \(error.localizedDescription)")
        }
        for _ in 0..<maximumRuns {
            do {
                guard let run = try store.claimNextReportRun(now: now()) else { break }
                if let artifact = try await execute(
                    run: run, store: store, settings: settings, now: now)
                {
                    completed.append(artifact.id)
                }
            } catch {
                issues.append("Report queue failed: \(error.localizedDescription)")
            }
        }
        return ReportQueueResult(completed: completed, issues: issues)
    }

    public func testProvider(
        _ providerID: SummaryProviderID,
        store: LedgerStore,
        settings: TrackifySettings,
        now: Date
    ) async throws -> ReportRun {
        let ownerID = "provider-test:\(ProcessInfo.processInfo.processIdentifier):\(UUID().uuidString)"
        guard
            try store.acquireLease(
                name: ProviderGenerationLease.name, ownerID: ownerID, now: now, duration: 60)
        else {
            throw LedgerStoreError.unsupportedValue(
                type: "ProviderTest", value: "another report run is active")
        }
        defer { try? store.releaseLease(name: ProviderGenerationLease.name, ownerID: ownerID) }
        let recipe = try syntheticTestRecipe(store: store)
        let interval = DateInterval(start: now, duration: 1)
        let activity = ActivitySnapshot(
            rangeStart: now, rangeEnd: interval.end, activeHours: 0, llmTurns: 0,
            conversationMessages: 0, commits: 0, additions: 0, deletions: 0,
            filesChanged: 0, repositoryIDs: [], evidenceCount: 1,
            firstEvidenceAt: now, lastEvidenceAt: now)
        let packet = ReportEvidencePacket(
            schemaVersion: 4, periodStart: now, periodEnd: interval.end, state: .observed,
            activity: activity,
            events: [
                ReportEventDigest(
                    eventID: EventID("e1"), evidenceID: EvidenceID("synthetic-provider-test"),
                    occurredAt: now, source: .simulation, kind: .agentRunFinished,
                    state: .completed, payload: ["synthetic": "true"],
                    selectionReasons: [.representative])
            ],
            selection: ReportPacketSelection(
                compilerVersion: "synthetic", totalEventCount: 1, selectedEventCount: 1,
                omittedEventCount: 0, omittedByKind: [:], activeContextCount: 1,
                representedContextCount: 1, omittedContextCount: 0,
                serializedByteLimit: 4 * 1_024))
        let pending = makePendingRun(
            recipe: recipe, period: interval, intent: .providerTest,
            mode: providerID == .codex ? .codex : .claude, packet: packet, now: now)
        // Synthetic evidence is intentionally not linked to the work ledger.
        let enqueued = try store.enqueue(EnqueueReportRun(run: pending))
        guard let claimed = try store.beginReportRun(id: enqueued.id, now: now) else { return enqueued }
        let provider = providerFactory(providerID, min(60, TimeInterval(settings.generationBudgets.processDeadlineSeconds)))
        let running = replacing(
            claimed, requestedProvider: providerID, requestedModel: provider.model,
            effectiveProvider: providerID, effectiveModel: provider.model,
            invocationVersion: nil, inputBytes: packet.serializedByteCount,
            estimatedInputTokens: runningEstimate(claimed, packet: packet), usage: ProviderUsage(),
            startedAt: claimed.startedAt ?? now, finishedAt: nil, state: .running,
            failureClass: nil, failureDetail: nil, artifactID: nil)
        try store.updateReportRun(running)
        do {
            let result = try await RegisteredProviderInvocation.generate(
                provider: provider, providerID: providerID,
                packet: packet, recipe: recipe, purpose: "provider-test",
                store: store, allowanceReader: allowanceReader, now: Date.init)
            let content = SecretRedactor.redact(result.summary.summary)
            _ = try saveArtifact(
                run: replacing(
                    running, requestedProvider: providerID, requestedModel: provider.model,
                    effectiveProvider: providerID, effectiveModel: result.effectiveModel ?? provider.model,
                    invocationVersion: result.invocationVersion, inputBytes: packet.serializedByteCount,
                    estimatedInputTokens: runningEstimate(running, packet: packet), usage: result.usage,
                    startedAt: running.startedAt, finishedAt: Date(), state: .succeeded,
                    failureClass: nil, failureDetail: nil, artifactID: nil),
                recipe: recipe, packet: packet, content: content, evidenceIDs: [],
                store: store, now: Date())
        } catch {
            let failure = classify(error)
            _ = try finishFailure(
                running, class: failure.0, detail: failure.1, store: store, now: Date())
        }
        return try store.reportRun(id: enqueued.id) ?? enqueued
    }

    private func execute(
        run: ReportRun,
        store: LedgerStore,
        settings: TrackifySettings,
        now: @escaping @Sendable () -> Date
    ) async throws -> Artifact? {
        guard let storedRecipe = try store.recipeVersion(id: run.recipeVersionID) else {
            return try finishFailure(
                run, class: .unknown, detail: "Recipe version no longer exists", store: store, now: now())
        }
        let recipe = run.configuration?.recipeVersion(basedOn: storedRecipe) ?? storedRecipe
        let packet: ReportEvidencePacket
        if run.intent == .providerTest {
            return try finishFailure(
                run, class: .cancelled, detail: "Interrupted provider test was not replayed",
                store: store, now: now())
        } else {
            packet = try evidencePacket(
                store: store,
                range: DateInterval(start: run.periodStart, end: run.periodEnd),
                cutoff: run.periodEnd, recipe: recipe)
        }
        if packet.state == .noActivity {
            return try deterministicArtifact(
                run: run, recipe: recipe, packet: packet,
                summary: "No development activity was detected during this period.",
                store: store, now: now())
        }
        guard let selectedProviderID = providerSelection(for: run, store: store) else {
            return try deterministicArtifact(
                run: run, recipe: recipe, packet: packet,
                summary: generator.deterministicSummary(packet), store: store, now: now())
        }
        let provider = providerFactory(
            selectedProviderID,
            TimeInterval(settings.generationBudgets.processDeadlineSeconds))
        let budget = try budgetController.decision(
            request: GenerationBudgetRequest(
                provider: selectedProviderID, model: provider.model, calls: 1,
                maximumInputBytes: packet.serializedByteCount,
                maximumEstimatedInputTokens: runningEstimate(run, packet: packet),
                totalEstimatedInputTokens: runningEstimate(run, packet: packet)),
            budgets: settings.generationBudgets, store: store, now: now())
        if !budget.allowed {
            return try deterministicArtifact(
                run: run, recipe: recipe, packet: packet,
                summary: generator.deterministicSummary(packet), failureClass: .budget,
                failureDetail: "LLM budget paused: \(budget.reason ?? "budget unavailable")",
                store: store, now: now())
        }

        let startedAt = now()
        let running = replacing(
            run, requestedProvider: selectedProviderID, requestedModel: provider.model,
            effectiveProvider: selectedProviderID, effectiveModel: provider.model,
            invocationVersion: nil, inputBytes: packet.serializedByteCount,
            estimatedInputTokens: runningEstimate(run, packet: packet), usage: ProviderUsage(),
            startedAt: run.startedAt ?? startedAt, finishedAt: nil, state: .running,
            failureClass: nil, failureDetail: nil, artifactID: nil)
        try store.updateReportRun(running)
        do {
            let result = try await RegisteredProviderInvocation.generate(
                provider: provider, providerID: selectedProviderID,
                packet: packet, recipe: recipe,
                purpose: "report:\(run.id.rawValue)", store: store,
                allowanceReader: allowanceReader, now: now)
            if try store.reportRun(id: run.id)?.state == .cancelled { return nil }
            let content = SecretRedactor.redact(result.summary.summary)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty, content.count <= recipe.maximumCharacters else {
                throw SummaryProviderError.invalidResponse(selectedProviderID.rawValue)
            }
            return try saveArtifact(
                run: replacing(
                    running, requestedProvider: selectedProviderID, requestedModel: provider.model,
                    effectiveProvider: selectedProviderID,
                    effectiveModel: result.effectiveModel ?? provider.model,
                    invocationVersion: result.invocationVersion,
                    inputBytes: packet.serializedByteCount,
                    estimatedInputTokens: runningEstimate(running, packet: packet), usage: result.usage,
                    startedAt: running.startedAt, finishedAt: now(), state: .succeeded,
                    failureClass: nil, failureDetail: nil, artifactID: nil),
                recipe: recipe, packet: packet, content: content,
                evidenceIDs: packet.evidenceIDs(for: result.summary.evidenceAliases),
                store: store, now: now())
        } catch {
            let failure = classify(error)
            if failure.0 == .cancelled {
                _ = try finishFailure(
                    running, class: .cancelled, detail: failure.1,
                    store: store, now: now())
                return nil
            }
            return try deterministicArtifact(
                run: replacing(
                    running, requestedProvider: selectedProviderID, requestedModel: provider.model,
                    effectiveProvider: selectedProviderID, effectiveModel: provider.model,
                    invocationVersion: nil, inputBytes: packet.serializedByteCount,
                    estimatedInputTokens: runningEstimate(running, packet: packet), usage: ProviderUsage(),
                    startedAt: running.startedAt, finishedAt: nil, state: .running,
                    failureClass: nil, failureDetail: nil, artifactID: nil),
                recipe: recipe, packet: packet, summary: generator.deterministicSummary(packet),
                failureClass: failure.0, failureDetail: failure.1,
                store: store, now: now())
        }
    }

    private func providerSelection(for run: ReportRun, store: LedgerStore) -> SummaryProviderID? {
        guard run.selectionMode != .localOnly else { return nil }
        if let explicit = run.selectionMode.explicitProvider { return explicit }
        let discovery = CapabilityDiscovery()
        let capabilities = discovery.generators(store: store)
        return discovery.automaticInvocationProvider(
            mode: run.selectionMode, capabilities: capabilities)
    }

    private func deterministicArtifact(
        run: ReportRun,
        recipe: ReportRecipeVersion,
        packet: ReportEvidencePacket?,
        summary: String,
        failureClass: GenerationFailureClass? = nil,
        failureDetail: String? = nil,
        store: LedgerStore,
        now: Date
    ) throws -> Artifact {
        let state: ReportRunState = failureClass == nil ? .succeeded : .fallback
        return try saveArtifact(
            run: replacing(
                run, requestedProvider: run.requestedProvider, requestedModel: run.requestedModel,
                effectiveProvider: run.effectiveProvider, effectiveModel: run.effectiveModel,
                invocationVersion: run.invocationVersion,
                inputBytes: packet?.serializedByteCount ?? run.inputBytes,
                estimatedInputTokens: packet?.estimatedInputTokens ?? run.estimatedInputTokens,
                usage: run.usage, startedAt: run.startedAt, finishedAt: now, state: state,
                failureClass: failureClass, failureDetail: failureDetail, artifactID: nil),
            recipe: recipe, packet: packet, content: summary,
            evidenceIDs: packet?.allEvidenceIDs ?? [], store: store, now: now)
    }

    private func saveArtifact(
        run: ReportRun,
        recipe: ReportRecipeVersion,
        packet: ReportEvidencePacket?,
        content: String,
        evidenceIDs: [EvidenceID],
        store: LedgerStore,
        now: Date
    ) throws -> Artifact {
        let artifactID = ArtifactID(StableHash.sha256("artifact:\(run.id.rawValue)"))
        let previous = try store.artifacts(since: nil, limit: 1_000).filter {
            $0.recipeID == recipe.recipeID && $0.periodStart == run.periodStart && $0.periodEnd == run.periodEnd
        }.max { $0.revision < $1.revision }
        let artifact = Artifact(
            id: artifactID, type: run.intent == .providerTest ? .providerTest : .report,
            format: recipe.outputFormat, createdAt: now, recipeID: recipe.recipeID,
            recipeVersionID: recipe.id, reportRunID: run.id,
            periodStart: run.periodStart, periodEnd: run.periodEnd,
            repositoryIDs: recipe.repositoryIDs, groupNames: recipe.groupNames,
            privacyProfile: recipe.privacyProfile, state: packet?.state ?? .observed,
            content: content, evidenceIDs: evidenceIDs,
            revision: (previous?.revision ?? 0) + 1, revisesArtifactID: previous?.id)
        try store.saveArtifact(artifact)
        let finished = replacing(
            run, requestedProvider: run.requestedProvider, requestedModel: run.requestedModel,
            effectiveProvider: run.effectiveProvider, effectiveModel: run.effectiveModel,
            invocationVersion: run.invocationVersion, inputBytes: run.inputBytes,
            estimatedInputTokens: run.estimatedInputTokens, usage: run.usage,
            startedAt: run.startedAt, finishedAt: run.finishedAt ?? now, state: run.state,
            failureClass: run.failureClass, failureDetail: run.failureDetail, artifactID: artifact.id)
        try store.updateReportRun(finished)
        return artifact
    }

    private func finishFailure(
        _ run: ReportRun,
        class failureClass: GenerationFailureClass,
        detail: String,
        store: LedgerStore,
        now: Date
    ) throws -> Artifact? {
        let state: ReportRunState
        switch failureClass {
        case .cancelled: state = .cancelled
        case .timeout: state = .timedOut
        default: state = .failed
        }
        let failed = replacing(
            run, requestedProvider: run.requestedProvider, requestedModel: run.requestedModel,
            effectiveProvider: run.effectiveProvider, effectiveModel: run.effectiveModel,
            invocationVersion: run.invocationVersion, inputBytes: run.inputBytes,
            estimatedInputTokens: run.estimatedInputTokens, usage: run.usage,
            startedAt: run.startedAt, finishedAt: now, state: state,
            failureClass: failureClass, failureDetail: detail, artifactID: nil)
        try store.updateReportRun(failed)
        return nil
    }

    private func makePendingRun(
        recipe: ReportRecipeVersion,
        period: DateInterval,
        intent: ReportRunIntent,
        mode: ProviderSelectionMode,
        packet: ReportEvidencePacket,
        now: Date,
        configuration: ReportRunConfiguration? = nil,
        scheduleID: ReportScheduleID? = nil
    ) -> ReportRun {
        let uniquePart = scheduleID?.rawValue ?? (intent == .scheduled ? "scheduled" : UUID().uuidString)
        let identity = [
            recipe.id.rawValue, String(period.start.timeIntervalSince1970),
            String(period.end.timeIntervalSince1970), intent.rawValue, uniquePart,
        ].joined(separator: ":")
        return ReportRun(
            id: ReportRunID(StableHash.sha256("report-run:\(identity)")),
            recipeID: recipe.recipeID, recipeVersionID: recipe.id,
            periodStart: period.start, periodEnd: period.end, intent: intent,
            selectionMode: mode, requestedProvider: mode.explicitProvider,
            compilerVersion: packet.selection.compilerVersion,
            promptVersion: ReportRecipePolicy.promptVersion,
            outputSchemaVersion: ReportRecipePolicy.outputSchemaVersion,
            inputBytes: packet.serializedByteCount,
            estimatedInputTokens: estimatedInputTokens(packet: packet, mode: mode),
            queuedAt: now, state: .pending,
            configuration: configuration ?? ReportRunConfiguration(recipe: recipe),
            scheduleID: scheduleID)
    }

    private func validated(_ configuration: ReportRunConfiguration) throws -> ReportRunConfiguration {
        guard (100...2_000).contains(configuration.maximumCharacters) else {
            throw RecipeValidationError.invalidMaximumCharacters
        }
        return ReportRunConfiguration(
            purpose: configuration.purpose, audience: configuration.audience,
            repositoryIDs: configuration.repositoryIDs, groupNames: configuration.groupNames,
            customFocus: try configuration.customFocus.map(ReportRecipeValidator.customFocus),
            tone: configuration.tone, outputFormat: configuration.outputFormat,
            maximumCharacters: configuration.maximumCharacters,
            privacyProfile: configuration.privacyProfile,
            providerModeOverride: configuration.providerModeOverride)
    }

    private func estimatedInputTokens(
        packet: ReportEvidencePacket,
        mode: ProviderSelectionMode
    ) -> Int {
        guard mode != .localOnly else { return packet.estimatedInputTokens }
        return packet.estimatedInputTokens + GenerationBudgets.conservativeProviderOverheadTokens
    }

    private func evidencePacket(
        store: LedgerStore,
        range: DateInterval,
        cutoff: Date,
        recipe: ReportRecipeVersion
    ) throws -> ReportEvidencePacket {
        let repositoryIDs = try ReportScopeResolver().repositoryIDs(store: store, recipe: recipe)
        let raw = try generator.evidencePacket(
            store: store, range: range, cutoff: cutoff,
            repositoryIDs: repositoryIDs)
        return recipePolicy.apply(
            raw, recipe: recipe, scopedRepositoryIDs: repositoryIDs)
    }

    private func runningEstimate(_ run: ReportRun, packet: ReportEvidencePacket) -> Int {
        run.estimatedInputTokens
            ?? estimatedInputTokens(packet: packet, mode: run.selectionMode)
    }

    private func provenance(_ packet: ReportEvidencePacket) -> [(String, EvidenceID, String)] {
        var values = packet.events.map {
            ($0.eventID.rawValue, $0.evidenceID, $0.selectionReasons.map(\.rawValue).joined(separator: ","))
        }
        for summary in packet.priorSummaries {
            values.append(contentsOf: summary.evidenceIDs.map { (summary.alias, $0, "prior_summary") })
        }
        return values
    }

    private func summaryProvenance(
        _ packet: ReportEvidencePacket
    ) -> [(alias: String, summaryID: SummaryID)] {
        packet.priorSummaries.compactMap { summary in
            summary.summaryID.map { (summary.alias, $0) }
        }
    }

    private func classify(_ error: Error) -> (GenerationFailureClass, String) {
        if let process = error as? ProcessRunnerError {
            switch process {
            case .timedOut: return (.timeout, process.localizedDescription)
            default: return (.process, process.localizedDescription)
            }
        }
        if let provider = error as? SummaryProviderError {
            switch provider {
            case .executableNotFound: return (.unavailable, provider.localizedDescription)
            case .authenticationFailed: return (.authentication, provider.localizedDescription)
            case .rateLimited: return (.rateLimited, provider.localizedDescription)
            case .modelUnavailable: return (.unavailable, provider.localizedDescription)
            case .invalidResponse, .packetTooLarge: return (.invalidResponse, provider.localizedDescription)
            case .processFailed: return (.process, provider.localizedDescription)
            }
        }
        if error is CancellationError { return (.cancelled, "Cancelled") }
        return (.unknown, String(describing: error))
    }

    private func syntheticTestRecipe(store: LedgerStore) throws -> ReportRecipeVersion {
        if let (_, version) = try store.recipe(id: RecipeID("hourly-work-note")) { return version }
        throw LedgerStoreError.unsupportedValue(type: "ReportRecipe", value: "hourly-work-note")
    }

    private func replacing(
        _ run: ReportRun,
        requestedProvider: SummaryProviderID?, requestedModel: String?,
        effectiveProvider: SummaryProviderID?, effectiveModel: String?,
        invocationVersion: String?, inputBytes: Int?, estimatedInputTokens: Int?,
        usage: ProviderUsage, startedAt: Date?, finishedAt: Date?, state: ReportRunState,
        failureClass: GenerationFailureClass?, failureDetail: String?, artifactID: ArtifactID?
    ) -> ReportRun {
        ReportRun(
            id: run.id, recipeID: run.recipeID, recipeVersionID: run.recipeVersionID,
            periodStart: run.periodStart, periodEnd: run.periodEnd, intent: run.intent,
            selectionMode: run.selectionMode, requestedProvider: requestedProvider,
            requestedModel: requestedModel, effectiveProvider: effectiveProvider,
            effectiveModel: effectiveModel, compilerVersion: run.compilerVersion,
            promptVersion: run.promptVersion, invocationVersion: invocationVersion,
            outputSchemaVersion: run.outputSchemaVersion, inputBytes: inputBytes,
            estimatedInputTokens: estimatedInputTokens, usage: usage, queuedAt: run.queuedAt,
            startedAt: startedAt, finishedAt: finishedAt, state: state,
            failureClass: failureClass, failureDetail: failureDetail, artifactID: artifactID,
            configuration: run.configuration, scheduleID: run.scheduleID)
    }
}
