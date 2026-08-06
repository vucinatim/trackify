import Foundation
import TrackifyDomain
import TrackifyStore

/// A deterministic, visually rich ledger used by UI previews and screenshot validation.
/// It intentionally exercises the same ingestion and query paths as real collection.
public struct ShowcaseSimulation {
    public init() {}

    public func run(store: LedgerStore, start: Date, days: Int = 42) async throws -> SimulationResult {
        precondition(days > 0)
        let calendar = Calendar(identifier: .gregorian)
        let end = calendar.date(byAdding: .day, value: days, to: start)!
        let roots = makeRoots(at: start)
        for root in roots { try store.upsert(discoveryRoot: root) }

        let projects = makeProjects(roots: roots, start: start, end: end)
        let clock = MutableWallClock(end)
        let engine = CollectionEngine(store: store, clock: clock)
        var sessions: [ConversationSession] = []
        var messages: [ConversationMessage] = []
        var commits: [GitCommit] = []
        var records: [CollectedRecord] = []
        var dailyEvidence: [[EvidenceID]] = Array(repeating: [], count: days)

        for dayIndex in 0..<days {
            let dayStart = calendar.date(byAdding: .day, value: dayIndex, to: start)!
            let weekday = calendar.component(.weekday, from: dayStart)
            let isWeekend = weekday == 1 || weekday == 7
            let isQuietDay = dayIndex % 11 == 2 || (isWeekend && dayIndex % 3 != 0)
            guard !isQuietDay else { continue }

            let focusCount = dayIndex % 5 == 0 ? 2 : 1
            for focus in 0..<focusCount {
                let project = projects[(dayIndex + focus * 2) % projects.count]
                let source: SourceKind = (dayIndex + focus).isMultiple(of: 3) ? .claude : .codex
                let hour = focus == 0 ? 9 + (dayIndex % 3) : 14
                let sessionStart = calendar.date(byAdding: .hour, value: hour, to: dayStart)!
                let isLatestSession = dayIndex == days - 1 && focus == focusCount - 1
                let sessionID = SessionID("showcase-session-\(dayIndex)-\(focus)")
                sessions.append(
                    ConversationSession(
                        id: sessionID,
                        source: source,
                        sourceSessionID: sessionID.rawValue,
                        startedAt: sessionStart,
                        lastObservedAt: sessionStart.addingTimeInterval(isLatestSession ? 2_400 : 5_400),
                        workingDirectory: project.workingCopy.canonicalPath,
                        sourceVersion: source == .codex ? "0.151.0" : "2.1.31",
                        state: isLatestSession ? .inProgress : .completed
                    ))

                let pair = messageCopy(day: dayIndex, project: project.repository.displayName, focus: focus)
                for (offset, role, text) in [
                    (0, MessageRole.user, pair.request),
                    (1_500, MessageRole.assistant, pair.response),
                ] {
                    let key = "message-\(dayIndex)-\(focus)-\(role.rawValue)"
                    let date = sessionStart.addingTimeInterval(TimeInterval(offset))
                    let message = ConversationMessage(
                        id: MessageID("showcase-\(key)"),
                        sessionID: sessionID,
                        sourceMessageID: key,
                        role: role,
                        occurredAt: date,
                        normalizedText: text,
                        fingerprint: "showcase-fingerprint-\(key)"
                    )
                    let record = makeRecord(
                        key: key,
                        at: date,
                        source: source,
                        kind: .agentMessageObserved,
                        repositoryID: project.repository.id,
                        workingCopyID: project.workingCopy.id,
                        sessionID: sessionID,
                        state: role == .assistant && isLatestSession ? .inProgress : nil,
                        payload: ["messageID": message.id.rawValue, "role": role.rawValue]
                    )
                    messages.append(message)
                    records.append(record)
                    dailyEvidence[dayIndex].append(record.evidence.id)
                }

                let treeRecord = makeRecord(
                    key: "tree-\(dayIndex)-\(focus)",
                    at: sessionStart.addingTimeInterval(2_100),
                    source: .git,
                    kind: .gitWorkingTreeChanged,
                    repositoryID: project.repository.id,
                    workingCopyID: project.workingCopy.id,
                    sessionID: sessionID,
                    state: isLatestSession ? .inProgress : .completed,
                    payload: ["filesChanged": String(2 + dayIndex % 7)]
                )
                records.append(treeRecord)
                dailyEvidence[dayIndex].append(treeRecord.evidence.id)

                if !isLatestSession {
                    let commitCount = 1 + (dayIndex + focus) % 2
                    for commitIndex in 0..<commitCount {
                        let commitTime = sessionStart.addingTimeInterval(TimeInterval(3_000 + commitIndex * 1_200))
                        let commitID = "showcase-commit-\(dayIndex)-\(focus)-\(commitIndex)"
                        let title = commitTitle(day: dayIndex, project: project.repository.displayName, index: commitIndex)
                        let additions = 34 + (dayIndex * 17 + commitIndex * 29) % 420
                        let deletions = 4 + (dayIndex * 7 + commitIndex * 3) % 96
                        commits.append(
                            GitCommit(
                                id: commitID,
                                repositoryID: project.repository.id,
                                hash: String(format: "%040x", dayIndex * 100 + focus * 10 + commitIndex + 1),
                                authorTime: commitTime,
                                message: title,
                                additions: additions,
                                deletions: deletions,
                                filesChanged: 2 + (dayIndex + commitIndex) % 10,
                                firstObservedAt: commitTime,
                                lastObservedAt: commitTime,
                                isReachable: true
                            ))
                        let record = makeRecord(
                            key: commitID,
                            at: commitTime,
                            source: .git,
                            kind: .gitCommitObserved,
                            repositoryID: project.repository.id,
                            workingCopyID: project.workingCopy.id,
                            payload: [
                                "commitID": commitID,
                                "message": title,
                                "additions": String(additions),
                                "deletions": String(deletions),
                                "filesChanged": String(2 + (dayIndex + commitIndex) % 10),
                            ]
                        )
                        records.append(record)
                        dailyEvidence[dayIndex].append(record.evidence.id)
                    }
                }

                if dayIndex % 3 != 1 {
                    let testState: ObservedState = dayIndex % 13 == 0 ? .failed : .completed
                    let record = makeRecord(
                        key: "test-\(dayIndex)-\(focus)",
                        at: sessionStart.addingTimeInterval(4_800),
                        source: .process,
                        kind: .testFinished,
                        repositoryID: project.repository.id,
                        workingCopyID: project.workingCopy.id,
                        sessionID: sessionID,
                        state: testState,
                        payload: ["suite": "Unit tests", "result": testState.rawValue]
                    )
                    records.append(record)
                    dailyEvidence[dayIndex].append(record.evidence.id)
                }
            }
        }

        _ = try await engine.ingest(
            CollectionBatch(
                sourceKey: "simulation:showcase",
                repositories: projects,
                sessions: sessions,
                messages: messages,
                commits: commits,
                records: records
            ))
        try saveReports(store: store, start: start, days: days, evidenceByDay: dailyEvidence)
        try saveWorkIntelligenceShowcase(
            store: store, start: start, end: end,
            evidenceIDs: dailyEvidence.flatMap { $0 })

        let ranges = (0..<days).map { dayIndex in
            let dayStart = calendar.date(byAdding: .day, value: dayIndex, to: start)!
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
            return DateInterval(start: dayStart, end: dayEnd)
        }
        let snapshots = try ActivityQueries().snapshots(store: store, ranges: ranges, cutoff: end, calendar: calendar)
        return try SimulationResult(
            startedAt: start,
            endedAt: end,
            generatedEvents: records.count,
            counts: store.counts(),
            days: snapshots
        )
    }

    private func makeRoots(at start: Date) -> [DiscoveryRoot] {
        [
            DiscoveryRoot(
                id: DiscoveryRootID("showcase-work"), canonicalPath: "/Users/demo/zerodays",
                displayName: "Work", sortOrder: 0, createdAt: start, lastScannedAt: start),
            DiscoveryRoot(
                id: DiscoveryRootID("showcase-personal"), canonicalPath: "/Users/demo/MyProjects",
                displayName: "Personal", sortOrder: 1, createdAt: start, lastScannedAt: start),
        ]
    }

    private func makeProjects(roots: [DiscoveryRoot], start: Date, end: Date) -> [CollectedRepository] {
        let specifications = [
            ("trackify", "Trackify", 1, "trackify", "main"),
            ("atlas", "Atlas", 0, "platform/atlas", "feature/usage-ledger"),
            ("relay", "Relay API", 0, "services/relay", "main"),
            ("studio", "Studio", 1, "studio", "design-system"),
        ]
        return specifications.map { slug, name, rootIndex, relativePath, branch in
            let repositoryID = RepositoryID("showcase-repository-\(slug)")
            return CollectedRepository(
                repository: Repository(
                    id: repositoryID,
                    displayName: name,
                    remoteIdentity: "github.com/demo/\(slug)",
                    firstObservedAt: start,
                    lastObservedAt: end.addingTimeInterval(-1)
                ),
                workingCopy: WorkingCopy(
                    id: WorkingCopyID("showcase-copy-\(slug)"),
                    repositoryID: repositoryID,
                    canonicalPath: roots[rootIndex].canonicalPath + "/" + relativePath,
                    branch: branch,
                    headCommit: String(format: "%040x", rootIndex + 10),
                    firstObservedAt: start,
                    lastObservedAt: end.addingTimeInterval(-1)
                ),
                discoveryRootID: roots[rootIndex].id,
                relativePath: relativePath
            )
        }
    }

    private func saveReports(
        store: LedgerStore,
        start: Date,
        days: Int,
        evidenceByDay: [[EvidenceID]]
    ) throws {
        let calendar = Calendar(identifier: .gregorian)
        for dayIndex in 0..<days where !evidenceByDay[dayIndex].isEmpty {
            let dayStart = calendar.date(byAdding: .day, value: dayIndex, to: start)!
            let isLatest = dayIndex == days - 1
            let state: ReportPeriodState = isLatest ? .inProgress : (dayIndex % 13 == 0 ? .investigating : .completed)
            let summary = reportCopy(day: dayIndex, latest: isLatest)
            try store.save(
                report: WorkReport(
                    id: ReportID("showcase-daily-report-\(dayIndex)"),
                    periodStart: dayStart,
                    periodEnd: calendar.date(byAdding: .day, value: 1, to: dayStart)!,
                    state: state,
                    summary: summary,
                    evidenceIDs: evidenceByDay[dayIndex],
                    provider: dayIndex.isMultiple(of: 3) ? "claude" : "codex",
                    model: dayIndex.isMultiple(of: 3) ? "opus" : "gpt-5.6-sol",
                    generatorVersion: "showcase-v1",
                    revision: 1
                ))
            if dayIndex >= days - 7 {
                let hourStart = calendar.date(byAdding: .hour, value: 9 + dayIndex % 3, to: dayStart)!
                try store.save(
                    report: WorkReport(
                        id: ReportID("showcase-hourly-report-\(dayIndex)"),
                        periodStart: hourStart,
                        periodEnd: hourStart.addingTimeInterval(3_600),
                        state: state,
                        summary: isLatest
                            ? "Trackify’s reports browser is being rebuilt; the new history layout is implemented but visual validation is still running."
                            : "Implemented the core slice, verified its tests, and recorded the remaining follow-up in the daily ledger.",
                        evidenceIDs: Array(evidenceByDay[dayIndex].prefix(6)),
                        provider: "codex",
                        model: "gpt-5.6-sol",
                        generatorVersion: "showcase-v1",
                        revision: 1
                    ))
            }
        }
    }

    private func saveWorkIntelligenceShowcase(
        store: LedgerStore,
        start: Date,
        end: Date,
        evidenceIDs: [EvidenceID]
    ) throws {
        let period = DateInterval(start: end.addingTimeInterval(-86_400), end: end)
        let succeededID = ReportRunID("showcase-run-succeeded")
        let succeededArtifactID = ArtifactID("showcase-artifact-succeeded")
        let succeeded = ReportRun(
            id: succeededID, recipeID: RecipeID("daily-work-summary"),
            recipeVersionID: RecipeVersionID("daily-work-summary:v1"),
            periodStart: period.start, periodEnd: period.end, intent: .scheduled,
            selectionMode: .codex, requestedProvider: .codex, requestedModel: "gpt-5.6-sol",
            effectiveProvider: .codex, effectiveModel: "gpt-5.6-sol",
            compilerVersion: EvidenceCompiler.version, promptVersion: ReportRecipePolicy.promptVersion,
            invocationVersion: CodexSummaryProvider.invocationVersion,
            outputSchemaVersion: ReportRecipePolicy.outputSchemaVersion,
            inputBytes: 8_240, estimatedInputTokens: 2_060,
            usage: ProviderUsage(
                inputTokens: 1_920, cachedInputTokens: 320, outputTokens: 96,
                reasoningTokens: 40, costKind: .includedSubscription,
                billingContext: "Showcase subscription fixture"),
            queuedAt: period.end.addingTimeInterval(-20),
            startedAt: period.end.addingTimeInterval(-18), finishedAt: period.end.addingTimeInterval(-8),
            state: .succeeded, artifactID: succeededArtifactID)
        _ = try store.enqueue(EnqueueReportRun(run: succeeded))
        try store.updateReportRun(succeeded)
        try store.saveArtifact(
            Artifact(
                id: succeededArtifactID, type: .report, format: .markdown,
                createdAt: period.end.addingTimeInterval(-8),
                recipeID: succeeded.recipeID, recipeVersionID: succeeded.recipeVersionID,
                reportRunID: succeeded.id, periodStart: period.start, periodEnd: period.end,
                privacyProfile: .private, state: .inProgress,
                content: "Refined the activity and reporting surfaces; visual validation remains in progress.",
                evidenceIDs: Array(evidenceIDs.suffix(4)), revision: 1))

        let budgetID = ReportRunID("showcase-run-budget")
        let budgetArtifactID = ArtifactID("showcase-artifact-budget")
        let budget = ReportRun(
            id: budgetID, recipeID: RecipeID("hourly-work-note"),
            recipeVersionID: RecipeVersionID("hourly-work-note:v1"),
            periodStart: period.end.addingTimeInterval(-3_600), periodEnd: period.end,
            intent: .onDemand, selectionMode: .automatic,
            compilerVersion: EvidenceCompiler.version, promptVersion: ReportRecipePolicy.promptVersion,
            outputSchemaVersion: ReportRecipePolicy.outputSchemaVersion,
            inputBytes: 7_000, estimatedInputTokens: 1_750,
            queuedAt: period.end.addingTimeInterval(-7), finishedAt: period.end.addingTimeInterval(-6),
            state: .fallback, failureClass: .budget,
            failureDetail: "LLM budget paused: daily token limit", artifactID: budgetArtifactID)
        _ = try store.enqueue(EnqueueReportRun(run: budget))
        try store.updateReportRun(budget)
        try store.saveArtifact(
            Artifact(
                id: budgetArtifactID, type: .report, format: .plainText,
                createdAt: period.end.addingTimeInterval(-6), recipeID: budget.recipeID,
                recipeVersionID: budget.recipeVersionID, reportRunID: budget.id,
                periodStart: budget.periodStart, periodEnd: budget.periodEnd,
                privacyProfile: .private, state: .inProgress,
                content: "Local evidence shows the reporting work remains in progress.",
                evidenceIDs: Array(evidenceIDs.suffix(2)), revision: 1))

        for (index, state, failure) in [
            (0, ReportRunState.pending, Optional<GenerationFailureClass>.none),
            (1, .running, nil),
            (2, .failed, .invalidResponse),
            (3, .timedOut, .timeout),
        ] {
            let run = ReportRun(
                id: ReportRunID("showcase-run-\(state.rawValue)"),
                recipeID: RecipeID("stand-up-draft"),
                recipeVersionID: RecipeVersionID("stand-up-draft:v1"),
                periodStart: start.addingTimeInterval(TimeInterval(index * 3_600)),
                periodEnd: start.addingTimeInterval(TimeInterval((index + 1) * 3_600)),
                intent: index.isMultiple(of: 2) ? .onDemand : .backfill,
                selectionMode: .claude, requestedProvider: .claude, requestedModel: "opus",
                effectiveProvider: state == .pending ? nil : .claude,
                effectiveModel: state == .pending ? nil : "opus",
                compilerVersion: EvidenceCompiler.version,
                promptVersion: ReportRecipePolicy.promptVersion,
                invocationVersion: state == .pending ? nil : ClaudeSummaryProvider.invocationVersion,
                outputSchemaVersion: ReportRecipePolicy.outputSchemaVersion,
                inputBytes: 4_000, estimatedInputTokens: 1_000,
                queuedAt: end.addingTimeInterval(TimeInterval(index)),
                startedAt: state == .pending ? nil : end.addingTimeInterval(TimeInterval(index)),
                finishedAt: state == .pending || state == .running ? nil : end.addingTimeInterval(TimeInterval(index + 1)),
                state: state, failureClass: failure,
                failureDetail: failure.map { "Showcase \($0.rawValue)" })
            _ = try store.enqueue(EnqueueReportRun(run: run))
            try store.updateReportRun(run)
        }
    }

    private func messageCopy(day: Int, project: String, focus: Int) -> (request: String, response: String) {
        let requests = [
            "Make the \(project) activity history easier to scan and preserve the existing query boundaries.",
            "Investigate the failing synchronization path in \(project) and leave the unfinished state explicit.",
            "Polish the \(project) reporting flow, then run the focused validation suite.",
            "Refactor the \(project) data boundary so the UI stays small and testable.",
        ]
        let responses = [
            "Implemented the history slice with bounded queries and added coverage for ordering and empty states.",
            "Traced the issue to stale association data; the fix is in progress and no completion is claimed yet.",
            "Updated the reporting flow and verified the focused suite. Visual review is the only remaining step.",
            "Moved aggregation behind the ledger API and removed duplicate view-level state.",
        ]
        let index = (day + focus) % requests.count
        return (requests[index], responses[index])
    }

    private func commitTitle(day: Int, project: String, index: Int) -> String {
        let titles = [
            "Add bounded activity timeline query",
            "Polish report detail layout",
            "Preserve unfinished work state",
            "Tighten repository association tests",
            "Refine daily trend aggregation",
            "Fix collection status refresh",
        ]
        return "\(titles[(day + index) % titles.count]) in \(project)"
    }

    private func reportCopy(day: Int, latest: Bool) -> String {
        if latest {
            return
                "Rebuilt Trackify’s history surfaces and report browser. The implementation is active and honest about its unfinished visual-validation pass."
        }
        let summaries = [
            "Shipped the bounded activity timeline, tightened repository associations, and verified the affected store tests.",
            "Investigated synchronization drift across Atlas and Relay API; isolated the stale-cursor path and documented the remaining edge case.",
            "Polished the reports workflow, simplified the navigation state, and completed the macOS layout validation pass.",
            "Refactored ledger aggregation behind a smaller query boundary and removed duplicated UI-derived statistics.",
            "Added coverage for incomplete agent work, fixed the collection refresh path, and reviewed the resulting activity history.",
        ]
        return summaries[day % summaries.count]
    }

    private func makeRecord(
        key: String,
        at date: Date,
        source: SourceKind,
        kind: EventKind,
        repositoryID: RepositoryID,
        workingCopyID: WorkingCopyID,
        sessionID: SessionID? = nil,
        state: ObservedState? = nil,
        payload: [String: String] = [:]
    ) -> CollectedRecord {
        let evidence = SourceEvidence(
            id: EvidenceID("showcase-evidence-\(key)"),
            source: source,
            ingestionPath: .fixture,
            sourceRecordID: key,
            fingerprint: "showcase-fingerprint-\(key)",
            occurredAt: date,
            observedAt: date,
            adapterVersion: 1
        )
        return CollectedRecord(
            evidence: evidence,
            event: LedgerEvent(
                id: EventID("showcase-event-\(key)"),
                evidenceID: evidence.id,
                occurredAt: date,
                observedAt: date,
                source: source,
                kind: kind,
                repositoryID: repositoryID,
                workingCopyID: workingCopyID,
                sessionID: sessionID,
                state: state,
                payload: payload
            )
        )
    }
}
