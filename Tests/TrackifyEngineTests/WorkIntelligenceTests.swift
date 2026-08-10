import Foundation
import Testing
import TrackifyDomain
import TrackifyStore

@testable import TrackifyEngine

@Suite("Goal 2 work intelligence")
struct WorkIntelligenceTests {
    @Test("Manual regeneration preserves each run and its exact one-off instructions")
    func manualRegenerationHistory() async throws {
        try await withSimulation { store, start, end in
            let queue = ReportQueue()
            let settings = TrackifySettings(providerSelection: .localOnly)
            let period = DateInterval(start: start, duration: 86_400)
            let (_, version) = try #require(try store.recipe(id: RecipeID("daily-work-summary")))
            func configuration(_ focus: String) -> ReportRunConfiguration {
                ReportRunConfiguration(
                    purpose: version.purpose, audience: version.audience,
                    repositoryIDs: version.repositoryIDs, groupNames: version.groupNames,
                    customFocus: focus, tone: version.tone, outputFormat: version.outputFormat,
                    maximumCharacters: version.maximumCharacters,
                    privacyProfile: version.privacyProfile, providerModeOverride: .localOnly)
            }
            let first = try queue.enqueueOnDemand(
                store: store, settings: settings, recipeID: version.recipeID,
                period: period, now: end, configuration: configuration("Write a stand-up update."))
            let second = try queue.enqueueOnDemand(
                store: store, settings: settings, recipeID: version.recipeID,
                period: period, now: end, configuration: configuration("Write a timesheet description."))
            #expect(first.id != second.id)
            _ = await queue.drain(store: store, settings: settings, now: { end }, maximumRuns: 2)
            let storedFirst = try #require(try store.reportRun(id: first.id))
            let storedSecond = try #require(try store.reportRun(id: second.id))
            #expect(storedFirst.configuration?.customFocus == "Write a stand-up update.")
            #expect(storedSecond.configuration?.customFocus == "Write a timesheet description.")
            #expect(storedFirst.artifactID != nil)
            #expect(storedSecond.artifactID != nil)
            #expect(try store.artifacts(limit: 20).filter { $0.reportRunID == first.id || $0.reportRunID == second.id }.count == 2)
        }
    }

    @Test("A provider run records measured usage and an immutable provenance-backed artifact")
    func measuredProviderRun() async throws {
        try await withSimulation { store, start, end in
            let counter = InvocationCounter()
            let queue = ReportQueue(
                providerFactory: { _, _ in MeasuredProvider(counter: counter) },
                allowanceReader: NoProviderAllowanceReader())
            let settings = TrackifySettings(
                providerSelection: .codex, automaticSummariesUseLLM: true)
            let period = DateInterval(start: start, duration: 86_400)
            let pending = try queue.enqueueOnDemand(
                store: store, settings: settings, recipeID: RecipeID("daily-work-summary"),
                period: period, now: end)

            let result = await queue.drain(
                store: store, settings: settings, now: { end }, maximumRuns: 1)

            #expect(counter.value == 1)
            #expect(result.completed.count == 1)
            let run = try #require(try store.reportRun(id: pending.id))
            #expect(run.state == .succeeded)
            #expect(run.effectiveProvider == .codex)
            #expect(run.effectiveModel == "measured-model")
            #expect(run.usage.inputTokens == 120)
            #expect(run.usage.cachedInputTokens == 20)
            #expect(run.usage.outputTokens == 18)
            #expect(run.usage.reasoningTokens == 7)
            #expect(run.usage.costKind == .providerEstimate)
            #expect((run.estimatedInputTokens ?? 0) >= GenerationBudgets.conservativeProviderOverheadTokens)
            let artifactID = try #require(run.artifactID)
            let artifact = try #require(try store.artifact(id: artifactID))
            #expect(artifact.reportRunID == run.id)
            #expect(artifact.recipeVersionID == RecipeVersionID("daily-work-summary:v2"))
            #expect(!artifact.evidenceIDs.isEmpty)
            #expect(artifact.content == "Measured evidence summary")
            let usage = try store.usage(from: start, through: end.addingTimeInterval(1))
            #expect(usage.runs == 1)
            #expect(usage.knownCost == Decimal(string: "0.04"))
            #expect(
                try store.generationTokenCommitment(
                    from: start, through: end.addingTimeInterval(1)) == 138)
        }
    }

    @Test("Budget exhaustion and quiet periods create local artifacts without invoking a provider")
    func budgetAndQuietFallback() async throws {
        try await withSimulation { store, start, end in
            let counter = InvocationCounter()
            let queue = ReportQueue(
                providerFactory: { _, _ in MeasuredProvider(counter: counter) },
                allowanceReader: NoProviderAllowanceReader())
            let budgets = GenerationBudgets(dailyTokenLimit: 1_000)
            let settings = TrackifySettings(
                providerSelection: .codex, generationBudgets: budgets,
                automaticSummariesUseLLM: true)
            let active = try queue.enqueueOnDemand(
                store: store, settings: settings, recipeID: RecipeID("daily-work-summary"),
                period: DateInterval(start: start, duration: 86_400), now: end)
            _ = await queue.drain(store: store, settings: settings, now: { end }, maximumRuns: 1)
            let activeRun = try #require(try store.reportRun(id: active.id))
            #expect(counter.value == 0)
            #expect(activeRun.state == .fallback)
            #expect(activeRun.failureClass == .budget)
            #expect(activeRun.failureDetail?.contains("LLM budget paused") == true)
            #expect(activeRun.artifactID != nil)

            let quietPeriod = DateInterval(start: end.addingTimeInterval(86_400), duration: 86_400)
            let quiet = try queue.enqueueOnDemand(
                store: store, settings: settings, recipeID: RecipeID("daily-work-summary"),
                period: quietPeriod, now: quietPeriod.end)
            _ = await queue.drain(
                store: store, settings: settings, now: { quietPeriod.end }, maximumRuns: 1)
            let quietRun = try #require(try store.reportRun(id: quiet.id))
            #expect(counter.value == 0)
            #expect(quietRun.state == .succeeded)
            #expect(quietRun.effectiveProvider == nil)
            let quietArtifactID = try #require(quietRun.artifactID)
            let artifact = try #require(try store.artifact(id: quietArtifactID))
            #expect(artifact.state == .noActivity)
        }
    }

    @Test("Model backfill is preview-only until explicit confirmation")
    func backfillConfirmation() async throws {
        try await withSimulation { store, start, end in
            let queue = ReportQueue(providerFactory: { _, _ in MeasuredProvider(counter: InvocationCounter()) })
            let settings = TrackifySettings(providerSelection: .codex)
            let periods = [DateInterval(start: start, duration: 86_400)]
            let plan = try queue.backfillPlan(
                store: store, recipeID: RecipeID("daily-work-summary"), periods: periods, cutoff: end)
            #expect(plan.activePeriods == 1)
            #expect(try store.reportRuns().isEmpty)
            #expect(throws: (any Error).self) {
                try queue.enqueueBackfill(
                    store: store, settings: settings, recipeID: RecipeID("daily-work-summary"),
                    periods: periods, now: end, confirmed: false)
            }
            #expect(try store.reportRuns().isEmpty)
            let runs = try queue.enqueueBackfill(
                store: store, settings: settings, recipeID: RecipeID("daily-work-summary"),
                periods: periods, now: end, confirmed: true)
            #expect(runs.count == 1)
        }
    }

    @Test("Privacy profiles fail closed and delivery is idempotent and profile-aware")
    func privacyAndDelivery() async throws {
        try await withSimulation { store, start, end in
            let version = try store.createRecipeVersion(
                recipeID: RecipeID("public-note"), name: "Public note", purpose: "Public update",
                audience: "public", cadence: .onDemand, tone: "plain",
                outputFormat: .markdown, maximumCharacters: 1_000,
                privacyProfile: .public, now: end)
            let raw = try ReportGenerator().evidencePacket(
                store: store, range: DateInterval(start: start, duration: 86_400), cutoff: end)
            let filtered = ReportRecipePolicy().apply(raw, recipe: version)
            #expect(filtered.state == .noActivity)
            #expect(filtered.events.isEmpty)

            let privateArtifact = Artifact(
                id: ArtifactID("private-delivery"), type: .report, format: .plainText,
                createdAt: end, recipeID: RecipeID("hourly-work-note"),
                recipeVersionID: RecipeVersionID("hourly-work-note:v1"),
                periodStart: start, periodEnd: end, privacyProfile: .private,
                state: .completed, content: "Private result", evidenceIDs: [], revision: 1)
            try store.saveArtifact(privateArtifact)
            let mock = Destination(
                id: DestinationID("private-mock"), kind: .mock, name: "Mock",
                privacyProfile: .private, permission: .local)
            try store.saveDestination(mock, now: end)
            let first = try ArtifactDeliveryService().deliver(
                artifact: privateArtifact, destination: mock, store: store, now: end)
            let second = try ArtifactDeliveryService().deliver(
                artifact: privateArtifact, destination: mock, store: store,
                now: end.addingTimeInterval(1))
            #expect(first.id == second.id)
            #expect(second.state == .delivered)

            let publicDestination = Destination(
                id: DestinationID("public-mock"), kind: .mock, name: "Public",
                privacyProfile: .public, permission: .approved)
            try store.saveDestination(publicDestination, now: end)
            #expect(throws: ArtifactDeliveryError.privacyMismatch) {
                try ArtifactDeliveryService().deliver(
                    artifact: privateArtifact, destination: publicDestination, store: store, now: end)
            }
        }
    }

    @Test("Named report groups resolve before bounded evidence selection")
    func namedGroupScope() throws {
        let directory = try temporaryDirectory("report-group")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LedgerStore(databaseURL: directory.appending(path: "ledger.sqlite"))
        let start = Date(timeIntervalSince1970: 1_754_294_400)
        let workRoot = DiscoveryRoot(
            id: DiscoveryRootID("work-root"), canonicalPath: "/workspace/Work",
            displayName: "Work", createdAt: start)
        let personalRoot = DiscoveryRoot(
            id: DiscoveryRootID("personal-root"), canonicalPath: "/workspace/Personal",
            displayName: "Personal", createdAt: start)
        try store.upsert(discoveryRoot: workRoot)
        try store.upsert(discoveryRoot: personalRoot)

        let workRepository = RepositoryID("work-repository")
        let personalRepository = RepositoryID("personal-repository")
        for (id, name, root) in [
            (workRepository, "Work App", workRoot),
            (personalRepository, "Personal App", personalRoot),
        ] {
            try store.upsert(
                repository: Repository(
                    id: id, displayName: name, firstObservedAt: start,
                    lastObservedAt: start.addingTimeInterval(3_600)),
                workingCopy: WorkingCopy(
                    id: WorkingCopyID("\(id.rawValue)-copy"), repositoryID: id,
                    canonicalPath: "\(root.canonicalPath)/\(id.rawValue)",
                    firstObservedAt: start, lastObservedAt: start.addingTimeInterval(3_600)),
                discoveryRootID: root.id, relativePath: id.rawValue)
        }

        for index in 0..<8 {
            let repositoryID = index < 2 ? workRepository : personalRepository
            let occurredAt = start.addingTimeInterval(TimeInterval(index * 60))
            let evidenceID = EvidenceID("group-evidence-\(index)")
            _ = try store.ingest(
                evidence: SourceEvidence(
                    id: evidenceID, source: .simulation, ingestionPath: .fixture,
                    sourceRecordID: "group-\(index)", fingerprint: "group-\(index)",
                    occurredAt: occurredAt, observedAt: occurredAt, adapterVersion: 1),
                event: LedgerEvent(
                    id: EventID("group-event-\(index)"), evidenceID: evidenceID,
                    occurredAt: occurredAt, observedAt: occurredAt, source: .simulation,
                    kind: .testFinished, repositoryID: repositoryID,
                    payload: ["suite": "group-\(index)", "result": "passed"]))
        }

        let recipe = try store.createRecipeVersion(
            recipeID: RecipeID("work-note"), name: "Work note", purpose: "Work summary",
            audience: "team", cadence: .onDemand, groupNames: ["work"],
            tone: "plain", outputFormat: .plainText, maximumCharacters: 500,
            privacyProfile: .team, now: start)
        let scope = try ReportScopeResolver().repositoryIDs(store: store, recipe: recipe)
        let resolved = try #require(scope)
        #expect(resolved == [workRepository])
        #expect(recipe.groupNames == ["work"])
        #expect(
            try store.events(
                from: start, through: start.addingTimeInterval(3_600),
                kinds: CoreEvidence.kinds
            ).count == 8)
        let raw = try ReportGenerator().evidencePacket(
            store: store, range: DateInterval(start: start, duration: 3_600),
            cutoff: start.addingTimeInterval(3_600), repositoryIDs: resolved)
        #expect(raw.activity.evidenceCount == 2)
        #expect(raw.events.count == 2)
        let filtered = ReportRecipePolicy().apply(
            raw, recipe: recipe, scopedRepositoryIDs: resolved)
        #expect(filtered.events.count == 2)

        let preview = try ReportQueue().preview(
            store: store, settings: TrackifySettings(providerSelection: .localOnly),
            recipeID: recipe.recipeID,
            period: DateInterval(start: start, duration: 3_600),
            cutoff: start.addingTimeInterval(3_600))
        #expect(preview.evidenceCount == 2)
    }

    @Test("Source and generation capabilities remain separate and automatic choice is deterministic")
    func capabilities() throws {
        let directory = try temporaryDirectory("capabilities")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appending(path: ".codex/sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: directory.appending(path: ".claude/projects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: directory.appending(
                path: "Library/Application Support/Claude/local-agent-mode-sessions"),
            withIntermediateDirectories: true)
        let store = try LedgerStore(databaseURL: directory.appending(path: "ledger.sqlite"))
        let discovery = CapabilityDiscovery()
        let sources = discovery.sources(store: store, homeDirectory: directory, now: .distantPast)
        #expect(sources.contains { $0.id == "claude-terminal-history" && $0.state == .available })
        #expect(sources.contains { $0.id == "claude-desktop-code-history" && $0.state == .available })
        let capabilities = [
            capability(.claude, authentication: .ready),
            capability(.codex, authentication: .ready),
        ]
        #expect(discovery.effectiveProvider(mode: .automatic, capabilities: capabilities) == .codex)
        #expect(discovery.effectiveProvider(mode: .claude, capabilities: capabilities) == .claude)
        #expect(discovery.effectiveProvider(mode: .localOnly, capabilities: capabilities) == nil)

        let unknown = [
            capability(.claude, authentication: .unknown),
            capability(.codex, authentication: .unknown),
        ]
        #expect(discovery.effectiveProvider(mode: .automatic, capabilities: unknown) == .codex)
        #expect(
            discovery.automaticInvocationProvider(mode: .automatic, capabilities: unknown)
                == .codex)
        #expect(
            discovery.automaticInvocationProvider(mode: .codex, capabilities: unknown)
                == .codex)

        let fallbackToUnknown = [
            capability(.codex, authentication: .unavailable),
            capability(.claude, authentication: .unknown),
        ]
        #expect(
            discovery.automaticInvocationProvider(
                mode: .automatic, capabilities: fallbackToUnknown) == .claude)
        #expect(
            discovery.automaticInvocationProvider(
                mode: .codex, capabilities: fallbackToUnknown) == nil)
    }

    @Test("Provider usage parsers preserve distinct token and cost categories")
    func usageParsing() {
        let claude = ProviderUsageParser.claude(
            Data(
                #"{"usage":{"input_tokens":100,"cache_read_input_tokens":30,"output_tokens":20},"total_cost_usd":0.12,"model":"claude-opus"}"#
                    .utf8))
        #expect(claude.inputTokens == 100)
        #expect(claude.cachedInputTokens == 30)
        #expect(claude.outputTokens == 20)
        #expect(claude.cost == Decimal(string: "0.12"))
        #expect(claude.costKind == .providerEstimate)
        let codex = ProviderUsageParser.codex(
            Data(
                "{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":80,\"cached_input_tokens\":10,\"output_tokens\":9,\"reasoning_tokens\":4}}\n"
                    .utf8))
        #expect(codex.inputTokens == 80)
        #expect(codex.cachedInputTokens == 10)
        #expect(codex.outputTokens == 9)
        #expect(codex.reasoningTokens == 4)
        #expect(codex.cost == nil)
        #expect(codex.costKind == .unknown)
    }

    @Test("Weekly allowance attribution pauses Trackify at its configured percentage")
    func weeklyAllowanceBudget() async throws {
        try await withSimulation { store, _, end in
            let reset = end.addingTimeInterval(7 * 86_400)
            let snapshot = ProviderAllowanceSnapshot(
                provider: .codex, limitID: "codex", plan: "pro",
                usedPercent: 27, windowDurationMinutes: 10_080,
                resetsAt: reset, observedAt: end)
            try store.saveProviderAllowanceAttribution(
                operationID: "one", provider: .codex, purpose: "summary",
                startedAt: end, finishedAt: end,
                before: allowance(snapshot, used: 24),
                after: allowance(snapshot, used: 26))
            try store.saveProviderAllowanceAttribution(
                operationID: "two", provider: .codex, purpose: "summary",
                startedAt: end, finishedAt: end,
                before: allowance(snapshot, used: 26),
                after: allowance(snapshot, used: 27))
            let controller = GenerationBudgetController(
                allowanceReader: FixedAllowanceReader(value: snapshot))
            let status = try controller.status(
                store: store, budgets: GenerationBudgets(),
                provider: .codex, now: end)
            #expect(status.allowanceAttributedPercent == 3)
            #expect(status.isPaused)
            #expect(status.pauseReason == "weekly Trackify allowance target")
        }
    }

    private func allowance(
        _ snapshot: ProviderAllowanceSnapshot,
        used: Int
    ) -> ProviderAllowanceSnapshot {
        ProviderAllowanceSnapshot(
            provider: snapshot.provider, limitID: snapshot.limitID,
            plan: snapshot.plan, usedPercent: used,
            windowDurationMinutes: snapshot.windowDurationMinutes,
            resetsAt: snapshot.resetsAt, observedAt: snapshot.observedAt)
    }

    @Test("Claude generation discovery prefers a user's standalone CLI before Desktop fallback")
    func claudeExecutableDiscovery() throws {
        let directory = try temporaryDirectory("claude-executables")
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appending(
            path: "Library/Application Support/Claude/claude-code/2.1.9/claude.app/Contents/MacOS/claude")
        let newest = directory.appending(
            path: "Library/Application Support/Claude/claude-code/2.1.221/claude.app/Contents/MacOS/claude")
        let terminal = directory.appending(path: ".local/bin/claude")
        for executable in [old, newest, terminal] {
            try FileManager.default.createDirectory(
                at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        let selected = ClaudeExecutableLocator.find(
            homeDirectory: directory, environment: ["PATH": ""])
        #expect(
            selected?.standardizedFileURL.resolvingSymlinksInPath()
                == terminal.standardizedFileURL.resolvingSymlinksInPath())
    }

    @Test("A slow provider never owns or delays the collection lease")
    func collectionDuringSlowProvider() async throws {
        try await withSimulation { store, start, end in
            let gate = ProviderGate()
            let queue = ReportQueue(
                providerFactory: { _, _ in GatedProvider(gate: gate) },
                allowanceReader: NoProviderAllowanceReader())
            let settings = TrackifySettings(providerSelection: .codex, automaticSummariesUseLLM: true)
            _ = try queue.enqueueOnDemand(
                store: store, settings: settings, recipeID: RecipeID("daily-work-summary"),
                period: DateInterval(start: start, duration: 86_400), now: end)
            let draining = Task {
                await queue.drain(store: store, settings: settings, now: { end }, maximumRuns: 1)
            }
            await gate.waitUntilStarted()

            let collection = try await LocalCollectionCoordinator(clock: FixedWallClock(end)).collect(
                store: store, gitRoots: [], includeCodex: false, includeClaude: false)
            #expect(collection.issues.isEmpty)
            await gate.release()
            #expect(await draining.value.completed.count == 1)
        }
    }

    @Test("Wake coalescing enqueues only the latest closed hour and day")
    func wakeCoalescing() async throws {
        try await withSimulation { store, _, end in
            let wake = end.addingTimeInterval(5 * 86_400)
            let settings = TrackifySettings(providerSelection: .localOnly)
            try store.setReportScheduleEnabled(
                true, id: ReportScheduleID("schedule:hourly-work-note"), now: wake)
            try store.setReportScheduleEnabled(
                true, id: ReportScheduleID("schedule:daily-work-summary"), now: wake)
            let result = try ReportQueue().enqueueDueReports(
                store: store, settings: settings, now: wake,
                calendar: Calendar(identifier: .gregorian))
            #expect(result.enqueued.count == 2)
            #expect(try store.reportRuns().count == 2)
            _ = await ReportQueue().drain(
                store: store, settings: settings, now: { wake }, maximumRuns: 2)
            #expect(try store.reportRuns().allSatisfy { $0.effectiveProvider == nil })
        }
    }

    @Test("Parallel reporters sharing a template remain independently scoped and idempotent")
    func parallelScheduledReporters() async throws {
        try await withSimulation { store, _, end in
            for existing in try store.reportSchedules() {
                try store.deleteReportSchedule(id: existing.id)
            }
            let firstID = ReportScheduleID("backend-daily")
            let secondID = ReportScheduleID("frontend-daily")
            _ = try store.saveReportSchedule(
                id: firstID,
                draft: ReportScheduleDraft(
                    name: "Backend daily", recipeID: RecipeID("daily-work-summary"),
                    cadence: .daily, repositoryIDs: [RepositoryID("backend")]),
                now: end)
            _ = try store.saveReportSchedule(
                id: secondID,
                draft: ReportScheduleDraft(
                    name: "Frontend daily", recipeID: RecipeID("daily-work-summary"),
                    cadence: .daily, repositoryIDs: [RepositoryID("frontend")]),
                now: end)

            let wake = end.addingTimeInterval(86_400)
            let settings = TrackifySettings(providerSelection: .localOnly)
            let first = try ReportQueue().enqueueDueReports(
                store: store, settings: settings, now: wake,
                calendar: Calendar(identifier: .gregorian))
            let repeated = try ReportQueue().enqueueDueReports(
                store: store, settings: settings, now: wake,
                calendar: Calendar(identifier: .gregorian))

            #expect(first.enqueued.count == 2)
            #expect(repeated.enqueued.isEmpty)
            let runs = try store.reportRuns()
            #expect(Set(runs.compactMap(\.scheduleID)) == Set([firstID, secondID]))
            #expect(
                Set(runs.compactMap { $0.configuration?.repositoryIDs.first }) == Set([RepositoryID("backend"), RepositoryID("frontend")]))

            try store.setReportScheduleEnabled(false, id: secondID, now: wake)
            let nextWake = wake.addingTimeInterval(86_400)
            let next = try ReportQueue().enqueueDueReports(
                store: store, settings: settings, now: nextWake,
                calendar: Calendar(identifier: .gregorian))
            #expect(next.enqueued.count == 1)
            #expect(try store.reportRun(id: next.enqueued[0])?.scheduleID == firstID)
        }
    }

    @Test("An interrupted running job is recovered locally without replaying the provider")
    func interruptedRecovery() async throws {
        try await withSimulation { store, start, end in
            let counter = InvocationCounter()
            let queue = ReportQueue(
                providerFactory: { _, _ in MeasuredProvider(counter: counter) },
                allowanceReader: NoProviderAllowanceReader())
            let settings = TrackifySettings(providerSelection: .codex)
            let pending = try queue.enqueueOnDemand(
                store: store, settings: settings, recipeID: RecipeID("daily-work-summary"),
                period: DateInterval(start: start, duration: 86_400), now: end)
            _ = try store.beginReportRun(id: pending.id, now: end)

            let result = await queue.drain(
                store: store, settings: settings, now: { end.addingTimeInterval(1) }, maximumRuns: 1)

            #expect(counter.value == 0)
            #expect(result.completed.count == 1)
            let run = try #require(try store.reportRun(id: pending.id))
            #expect(run.state == .fallback)
            #expect(run.failureClass == .cancelled)
        }
    }

    @Test("An explicit provider failure never silently invokes the other provider")
    func explicitProviderNoFailover() async throws {
        try await withSimulation { store, start, end in
            let recorder = ProviderRecorder()
            let queue = ReportQueue(
                providerFactory: { id, _ in
                    recorder.record(id)
                    return UnavailableProvider(id: id)
                }, allowanceReader: NoProviderAllowanceReader())
            let settings = TrackifySettings(providerSelection: .claude)
            let pending = try queue.enqueueOnDemand(
                store: store, settings: settings, recipeID: RecipeID("daily-work-summary"),
                period: DateInterval(start: start, duration: 86_400), now: end)
            _ = await queue.drain(store: store, settings: settings, now: { end }, maximumRuns: 1)
            let run = try #require(try store.reportRun(id: pending.id))
            #expect(recorder.values == [.claude])
            #expect(run.requestedProvider == .claude)
            #expect(run.effectiveProvider == .claude)
            #expect(run.state == .fallback)
            #expect(run.failureClass == .unavailable)
            #expect(run.artifactID != nil)
        }
    }

    @Test("One-year dashboard queries stay bounded with more than one hundred repositories")
    func oneYearScale() throws {
        let directory = try temporaryDirectory("scale")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LedgerStore(databaseURL: directory.appending(path: "ledger.sqlite"))
        let start = Date(timeIntervalSince1970: 1_753_920_000)
        let repositoryCount = 120
        let dayCount = 365
        for index in 0..<repositoryCount {
            let repositoryID = RepositoryID("scale-repository-\(index)")
            try store.upsert(
                repository: Repository(
                    id: repositoryID, displayName: "Repository \(index)",
                    firstObservedAt: start, lastObservedAt: start.addingTimeInterval(365 * 86_400)),
                workingCopy: WorkingCopy(
                    id: WorkingCopyID("scale-copy-\(index)"), repositoryID: repositoryID,
                    canonicalPath: "/workspace/repository-\(index)", firstObservedAt: start,
                    lastObservedAt: start.addingTimeInterval(365 * 86_400)))
        }
        for day in 0..<dayCount {
            for slot in 0..<6 {
                let index = day * 6 + slot
                let occurredAt = start.addingTimeInterval(TimeInterval(day * 86_400 + slot * 3_600))
                let evidenceID = EvidenceID("scale-evidence-\(index)")
                let repositoryID = RepositoryID("scale-repository-\(index % repositoryCount)")
                let kind: EventKind = slot.isMultiple(of: 3) ? .gitCommitObserved : .agentMessageObserved
                let payload =
                    kind == .gitCommitObserved
                    ? ["additions": "12", "deletions": "3", "filesChanged": "2"]
                    : ["role": slot.isMultiple(of: 2) ? "user" : "assistant"]
                _ = try store.ingest(
                    evidence: SourceEvidence(
                        id: evidenceID, source: .simulation, ingestionPath: .fixture,
                        sourceRecordID: "scale-\(index)", fingerprint: "scale-\(index)",
                        occurredAt: occurredAt, observedAt: occurredAt, adapterVersion: 1),
                    event: LedgerEvent(
                        id: EventID("scale-event-\(index)"), evidenceID: evidenceID,
                        occurredAt: occurredAt, observedAt: occurredAt, source: .simulation,
                        kind: kind, repositoryID: repositoryID, payload: payload))
            }
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let ranges = (0..<dayCount).map {
            DateInterval(start: start.addingTimeInterval(TimeInterval($0 * 86_400)), duration: 86_400)
        }
        let measuredAt = Date()
        let snapshots = try ActivityQueries().snapshots(
            store: store, ranges: ranges, cutoff: ranges.last!.end, calendar: calendar)
        let catalog = try store.repositoryCatalog()
        let recent = try store.recentEvents(
            from: ranges.first!.start, through: ranges.last!.end,
            kinds: [.gitCommitObserved, .agentMessageObserved], limit: 500)
        let elapsed = Date().timeIntervalSince(measuredAt)

        #expect(catalog.count == repositoryCount)
        #expect(snapshots.count == dayCount)
        #expect(snapshots.reduce(0) { $0 + $1.evidenceCount } == dayCount * 6)
        #expect(recent.count == 500)
        #expect(elapsed < 5, "Bounded one-year UI queries took \(elapsed) seconds")
    }

    @Test("Dense hourly snapshots preserve totals without rescanning each bucket")
    func denseHourlySnapshots() async throws {
        try await withSimulation { store, start, end in
            var ranges: [DateInterval] = []
            var cursor = start
            while cursor < end {
                let next = Calendar.current.date(byAdding: .hour, value: 1, to: cursor)!
                ranges.append(DateInterval(start: cursor, end: min(next, end)))
                cursor = next
            }

            let queries = ActivityQueries()
            let hourly = try queries.snapshots(store: store, ranges: ranges, cutoff: end)
            let complete = try queries.snapshot(
                store: store, range: DateInterval(start: start, end: end), cutoff: end)

            #expect(hourly.count == ranges.count)
            #expect(hourly.reduce(0) { $0 + $1.activeHours } == complete.activeHours)
            #expect(hourly.reduce(0) { $0 + $1.llmTurns } == complete.llmTurns)
            #expect(hourly.reduce(0) { $0 + $1.commits } == complete.commits)
            #expect(hourly.reduce(0) { $0 + $1.additions } == complete.additions)
            #expect(hourly.reduce(0) { $0 + $1.deletions } == complete.deletions)
        }
    }

    private func withSimulation(
        _ body: (LedgerStore, Date, Date) async throws -> Void
    ) async throws {
        let directory = try temporaryDirectory("queue")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LedgerStore(databaseURL: directory.appending(path: "ledger.sqlite"))
        let start = Date(timeIntervalSince1970: 1_754_284_800)
        let result = try await FoundationSimulation().run(store: store, start: start)
        try await body(store, start, result.endedAt)
    }

    private func temporaryDirectory(_ suffix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "trackify-goal2-\(suffix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func capability(
        _ id: SummaryProviderID,
        authentication: AuthenticationState
    ) -> GenerationCapability {
        GenerationCapability(
            id: id, executablePath: "/tmp/\(id.rawValue)", cliVersion: "test",
            authentication: authentication, structuredOutput: true, usageReporting: true,
            hardMonetaryCap: false, requestedModel: "test", effectiveModelKnown: false,
            invocationContractVersion: "test", lastProbeAt: .distantPast)
    }
}

private final class InvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private struct MeasuredProvider: SummaryProvider {
    let id = "measured"
    let model = "requested-model"
    let counter: InvocationCounter

    func summarize(_ packet: ReportEvidencePacket) async throws -> ProviderSummary {
        result(packet).summary
    }

    func generate(
        _ packet: ReportEvidencePacket,
        recipe: ReportRecipeVersion?
    ) async throws -> ProviderGenerationResult {
        counter.increment()
        return result(packet)
    }

    private func result(_ packet: ReportEvidencePacket) -> ProviderGenerationResult {
        ProviderGenerationResult(
            summary: ProviderSummary(
                summary: "Measured evidence summary", topics: ["testing"],
                evidenceAliases: packet.events.first.map { [$0.eventID.rawValue] } ?? []),
            usage: ProviderUsage(
                inputTokens: 120, cachedInputTokens: 20, outputTokens: 18,
                reasoningTokens: 7, cost: Decimal(string: "0.04"), currency: "USD",
                costKind: .providerEstimate, billingContext: "fixture"),
            effectiveModel: "measured-model", invocationVersion: "fixture-v1")
    }
}

private struct FixedAllowanceReader: ProviderAllowanceReading {
    let value: ProviderAllowanceSnapshot

    func snapshot(provider: SummaryProviderID, now: Date) -> ProviderAllowanceSnapshot? {
        provider == value.provider ? value : nil
    }
}

private actor ProviderGate {
    private var started = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private struct GatedProvider: SummaryProvider {
    let id = "gated"
    let model = "fixture"
    let gate: ProviderGate

    func summarize(_ packet: ReportEvidencePacket) async throws -> ProviderSummary {
        await gate.wait()
        return ProviderSummary(
            summary: "Gated summary", topics: [],
            evidenceAliases: packet.events.first.map { [$0.eventID.rawValue] } ?? [])
    }
}

private final class ProviderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SummaryProviderID] = []
    func record(_ value: SummaryProviderID) { lock.withLock { storage.append(value) } }
    var values: [SummaryProviderID] { lock.withLock { storage } }
}

private struct UnavailableProvider: SummaryProvider {
    let providerID: SummaryProviderID
    var id: String { "\(providerID.rawValue)-fixture" }
    let model = "fixture"

    init(id: SummaryProviderID) { providerID = id }

    func summarize(_ packet: ReportEvidencePacket) async throws -> ProviderSummary {
        throw SummaryProviderError.executableNotFound(providerID.rawValue.capitalized)
    }
}
