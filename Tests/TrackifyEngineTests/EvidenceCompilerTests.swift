import Foundation
import Testing
import TrackifyDomain
import TrackifyStore

@testable import TrackifyEngine

@Suite("Smart evidence compiler")
struct EvidenceCompilerTests {
    @Test("Startup recovery reclaims only an abandoned generation lease")
    func startupSummaryRecovery() async throws {
        try await withCompilerStore { store in
            let started = Date(timeIntervalSince1970: 1_754_294_400)
            let abandoned = SummaryRun(
                id: SummaryRunID("abandoned-summary"), kind: .segment,
                periodStart: started, periodEnd: started.addingTimeInterval(1_800),
                selectionMode: .codex, requestedProvider: .codex,
                effectiveProvider: .codex, sourceFingerprint: "abandoned",
                queuedAt: started, startedAt: started, state: .running)
            try store.save(summaryRun: abandoned)
            #expect(
                try store.acquireLease(
                    name: ProviderGenerationLease.name,
                    ownerID: "summaries:2147483000:abandoned",
                    now: started, duration: 3_600))

            let recoveredAt = started.addingTimeInterval(30)
            let recovered = try SummaryCoordinator.recoverInterruptedRuns(
                store: store, now: recoveredAt)

            #expect(recovered.map(\.id) == [abandoned.id])
            #expect(recovered[0].state == .failed)
            #expect(recovered[0].failureClass == .cancelled)
            #expect(try store.leaseOwner(name: ProviderGenerationLease.name) == nil)

            let active = SummaryRun(
                id: SummaryRunID("active-summary"), kind: .segment,
                periodStart: started, periodEnd: started.addingTimeInterval(1_800),
                selectionMode: .codex, requestedProvider: .codex,
                effectiveProvider: .codex, sourceFingerprint: "active",
                queuedAt: started, startedAt: started, state: .running)
            try store.save(summaryRun: active)
            let activeOwner =
                "summaries:\(ProcessInfo.processInfo.processIdentifier):active"
            #expect(
                try store.acquireLease(
                    name: ProviderGenerationLease.name, ownerID: activeOwner,
                    now: started, duration: 3_600))

            #expect(
                try SummaryCoordinator.recoverInterruptedRuns(
                    store: store, now: recoveredAt
                ).isEmpty)
            #expect(try store.summaryRuns().first { $0.id == active.id }?.state == .running)
            try store.releaseLease(name: ProviderGenerationLease.name, ownerID: activeOwner)
        }
    }

    @Test("Selection is deterministic, bounded, aliased, and representative across parallel projects")
    func deterministicParallelSelection() async throws {
        try await withCompilerStore { store in
            let start = Date(timeIntervalSince1970: 1_754_294_400)
            let range = DateInterval(start: start, duration: 3_600)
            let repoA = try addRepository("compiler-repo-a", name: "Trackify", store: store, at: start)
            let repoB = try addRepository("compiler-repo-b", name: "ClientApp", store: store, at: start)
            let sessionA = SessionID("compiler-session-a-stable")
            let sessionB = SessionID("compiler-session-b-stable")
            try store.upsert(
                session: ConversationSession(
                    id: sessionA,
                    source: .codex,
                    sourceSessionID: sessionA.rawValue,
                    startedAt: start,
                    lastObservedAt: range.end,
                    state: .inProgress
                ))
            try store.upsert(
                session: ConversationSession(
                    id: sessionB,
                    source: .claude,
                    sourceSessionID: sessionB.rawValue,
                    startedAt: start,
                    lastObservedAt: range.end,
                    state: .inProgress
                ))

            try addMessage(
                "intent-stable-id",
                text: "Make the smart evidence compiler preserve user intent across parallel projects",
                role: .user,
                repositoryID: repoA.id,
                sessionID: sessionA,
                at: start.addingTimeInterval(30),
                store: store
            )
            for index in 0..<80 {
                try addMessage(
                    "assistant-chatter-\(index)",
                    text: "Progress update \(index): continuing repetitive implementation details that should not crowd out intent.",
                    role: .assistant,
                    repositoryID: repoA.id,
                    sessionID: sessionA,
                    at: start.addingTimeInterval(Double(60 + index)),
                    store: store
                )
            }
            try addEvent(
                "client-failure-stable-id",
                kind: .testFinished,
                repositoryID: repoB.id,
                sessionID: sessionB,
                state: .failed,
                payload: ["suite": "Client export tests", "result": "failed"],
                at: start.addingTimeInterval(300),
                store: store
            )
            try addEvent(
                "trackify-dirty-stable-id",
                kind: .gitWorkingTreeChanged,
                repositoryID: repoA.id,
                state: .inProgress,
                payload: ["clean": "false", "changedFiles": "7", "additions": "90", "deletions": "14"],
                at: start.addingTimeInterval(500),
                store: store
            )
            try addEvent(
                "client-dirty-stable-id",
                kind: .gitWorkingTreeChanged,
                repositoryID: repoB.id,
                state: .inProgress,
                payload: ["clean": "false", "changedFiles": "2"],
                at: start.addingTimeInterval(510),
                store: store
            )

            let compiler = EvidenceCompiler(
                configuration: .init(maxHourlyEvents: 8, maxSerializedBytes: 20 * 1_024)
            )
            let generator = ReportGenerator(compiler: compiler)
            let first = try generator.evidencePacket(store: store, range: range, cutoff: range.end)
            let second = try generator.evidencePacket(store: store, range: range, cutoff: range.end)

            #expect(first == second)
            #expect(first.schemaVersion == 4)
            #expect(first.selection.compilerVersion == EvidenceCompiler.version)
            #expect(first.events.count <= 8)
            #expect(first.selection.omittedEventCount > 70)
            #expect(first.selection.activeContextCount == 2)
            #expect(first.selection.representedContextCount == 2)
            #expect(first.selection.omittedContextCount == 0)
            #expect(first.serializedByteCount <= 20 * 1_024)
            #expect(first.estimatedInputTokens <= 5_120)
            #expect(first.events.contains { $0.messageRole == .user })
            #expect(first.events.count { $0.messageRole == .assistant } <= 3)
            #expect(first.events.contains { $0.kind == .testFinished && $0.state == .failed })
            #expect(Set(first.events.compactMap(\.repositoryName)) == ["Trackify", "ClientApp"])
            #expect(first.events.map(\.eventID.rawValue) == (1...first.events.count).map { "e\($0)" })
            #expect(first.events.allSatisfy { $0.repositoryID?.rawValue.hasPrefix("r") ?? true })
            #expect(first.events.allSatisfy { $0.sessionID?.rawValue.hasPrefix("s") ?? true })

            let encoded = try encodedString(first)
            for stableValue in [
                repoA.id.rawValue, repoB.id.rawValue, sessionA.rawValue, sessionB.rawValue,
                "intent-stable-id", "client-failure-stable-id", "trackify-dirty-stable-id",
            ] {
                #expect(!encoded.contains(stableValue))
            }
            #expect(encoded.contains("user_intent"))
            #expect(encoded.contains("final_state"))
            #expect(encoded.contains("project_coverage"))
        }
    }

    @Test("Compiler keeps concrete commits and removes unrelated payload fields and secrets")
    func concreteEvidenceAndPrivacy() async throws {
        try await withCompilerStore { store in
            let start = Date(timeIntervalSince1970: 1_754_294_400)
            let range = DateInterval(start: start, duration: 3_600)
            let repository = try addRepository("compiler-commit-repo", name: "LedgerKit", store: store, at: start)
            let secret = "sk-example1234567890"
            try store.upsert(
                commit: GitCommit(
                    id: "compiler-commit-id",
                    repositoryID: repository.id,
                    hash: "abcdef123456",
                    authorTime: start.addingTimeInterval(120),
                    message: "Implement compiler without leaking \(secret)",
                    additions: 42,
                    deletions: 5,
                    filesChanged: 3,
                    firstObservedAt: start,
                    lastObservedAt: start,
                    isReachable: true
                ))
            try addEvent(
                "compiler-commit-event-stable",
                kind: .gitCommitObserved,
                repositoryID: repository.id,
                state: .completed,
                payload: [
                    "hash": "abcdef123456",
                    "message": "Implement compiler without leaking \(secret)",
                    "additions": "42",
                    "deletions": "5",
                    "filesChanged": "3",
                    "command": "curl -H Authorization:\(secret)",
                ],
                at: start.addingTimeInterval(120),
                store: store
            )

            let packet = try ReportGenerator().evidencePacket(store: store, range: range, cutoff: range.end)
            let commit = try #require(packet.events.first { $0.kind == .gitCommitObserved })
            let encoded = try encodedString(packet)

            #expect(commit.selectionReasons.contains(.concreteOutcome))
            #expect(commit.payload["message"]?.contains("[REDACTED_OPENAI_KEY]") == true)
            #expect(commit.payload["command"] == nil)
            #expect(commit.payload["hash"] == nil)
            #expect(!encoded.contains(secret))
            #expect(!encoded.contains("compiler-commit-event-stable"))
            #expect(packet.allEvidenceIDs == [EvidenceID("compiler-commit-event-stable-evidence")])
        }
    }

    @Test("Daily packets use active hourly reports across the full day and preserve quiet-hour metadata")
    func hierarchicalDailyPacket() async throws {
        try await withCompilerStore { store in
            let day = Date(timeIntervalSince1970: 1_754_284_800)
            let range = DateInterval(start: day, duration: 86_400)
            let repository = try addRepository("daily-repo", name: "DayLedger", store: store, at: day)
            try addEvent(
                "morning-work",
                kind: .gitWorkingTreeChanged,
                repositoryID: repository.id,
                state: .inProgress,
                payload: ["clean": "false", "changedFiles": "2"],
                at: day.addingTimeInterval(9 * 3_600),
                store: store
            )
            try addEvent(
                "evening-work",
                kind: .gitWorkingTreeChanged,
                repositoryID: repository.id,
                state: .inProgress,
                payload: ["clean": "false", "changedFiles": "4"],
                at: day.addingTimeInterval(20 * 3_600),
                store: store
            )
            try saveSegmentSummary(
                id: "morning-report",
                start: day.addingTimeInterval(9 * 3_600),
                state: .completed,
                summary: "Completed the morning evidence compiler foundation.",
                evidenceIDs: [EvidenceID("morning-work-evidence")],
                store: store
            )
            try saveSegmentSummary(
                id: "quiet-report",
                start: day.addingTimeInterval(13 * 3_600),
                state: .noActivity,
                summary: "No development activity was detected during this period.",
                evidenceIDs: [],
                store: store
            )
            try saveSegmentSummary(
                id: "evening-report",
                start: day.addingTimeInterval(20 * 3_600),
                state: .inProgress,
                summary: "Continued validation in the evening; work remained unfinished.",
                evidenceIDs: [EvidenceID("evening-work-evidence")],
                store: store
            )

            let packet = try ReportGenerator().evidencePacket(store: store, range: range, cutoff: range.end)
            #expect(packet.priorSummaries.map(\.alias) == ["s1", "s2"])
            #expect(packet.priorSummaries.map(\.summary).contains { $0.contains("morning") })
            #expect(packet.priorSummaries.map(\.summary).contains { $0.contains("evening") })
            #expect(packet.selection.totalPriorSummaryCount == 3)
            #expect(packet.selection.selectedPriorSummaryCount == 2)
            #expect(packet.selection.omittedQuietSummaryCount == 1)
            #expect(
                packet.evidenceIDs(for: ["s1", "s2"]) == [
                    EvidenceID("morning-work-evidence"), EvidenceID("evening-work-evidence"),
                ])
            #expect(packet.serializedByteCount <= 20 * 1_024)

            let encoded = try encodedString(packet)
            #expect(encoded.contains("priorSummaries"))
            #expect(encoded.contains("omittedQuietSummaryCount"))
            #expect(!encoded.contains("morning-work-evidence"))
            #expect(!encoded.contains("evening-work-evidence"))

            let report = try await ReportGenerator().generate(
                store: store,
                range: range,
                cutoff: range.end,
                provider: PriorSummaryProvider()
            )
            #expect(
                report.evidenceIDs == [
                    EvidenceID("morning-work-evidence"), EvidenceID("evening-work-evidence"),
                ])
        }
    }

    @Test("Serialized byte budget trims lower-priority evidence")
    func hardByteBudget() async throws {
        try await withCompilerStore { store in
            let start = Date(timeIntervalSince1970: 1_754_294_400)
            let range = DateInterval(start: start, duration: 3_600)
            let repository = try addRepository("budget-repo", name: "BudgetKit", store: store, at: start)
            let session = SessionID("budget-session")
            try store.upsert(
                session: ConversationSession(
                    id: session,
                    source: .codex,
                    sourceSessionID: session.rawValue,
                    startedAt: start,
                    lastObservedAt: range.end,
                    state: .inProgress
                ))
            for index in 0..<20 {
                try addMessage(
                    "budget-message-\(index)",
                    text: "Detailed progress \(index) " + String(repeating: "bounded evidence ", count: 80),
                    role: index == 0 ? .user : .assistant,
                    repositoryID: repository.id,
                    sessionID: session,
                    at: start.addingTimeInterval(Double(index + 1)),
                    store: store
                )
            }

            let packet = try ReportGenerator(
                compiler: EvidenceCompiler(
                    configuration: .init(maxHourlyEvents: 20, maxSerializedBytes: 2_500)
                )
            ).evidencePacket(store: store, range: range, cutoff: range.end)

            #expect(packet.serializedByteCount <= 2_500)
            #expect(packet.events.count < 20)
            #expect(packet.events.contains { $0.messageRole == .user })
            #expect(packet.selection.omittedEventCount > 0)
        }
    }

    @Test("Provider aliases resolve back to stable evidence provenance")
    func providerAliasResolution() async throws {
        try await withCompilerStore { store in
            let start = Date(timeIntervalSince1970: 1_754_294_400)
            let range = DateInterval(start: start, duration: 3_600)
            let repository = try addRepository("alias-repo", name: "AliasKit", store: store, at: start)
            try addEvent(
                "alias-tree",
                kind: .gitWorkingTreeChanged,
                repositoryID: repository.id,
                state: .inProgress,
                payload: ["clean": "false", "changedFiles": "1"],
                at: start.addingTimeInterval(60),
                store: store
            )

            let report = try await ReportGenerator().generate(
                store: store,
                range: range,
                cutoff: range.end,
                provider: AliasSummaryProvider()
            )

            #expect(report.provider == "alias-test")
            #expect(report.evidenceIDs == [EvidenceID("alias-tree-evidence")])
        }
    }

    @Test("Canonical summary coverage preserves full intent and commits while bounding assistant text")
    func canonicalSummaryCoverage() async throws {
        try await withCompilerStore { store in
            let start = Date(timeIntervalSince1970: 1_754_294_400)
            let range = DateInterval(start: start, duration: 1_800)
            let repository = try addRepository(
                "summary-coverage-repo", name: "Trackify", store: store, at: start)
            let sessionID = SessionID("summary-coverage-session")
            try store.upsert(
                session: ConversationSession(
                    id: sessionID, source: .codex, sourceSessionID: sessionID.rawValue,
                    startedAt: start, lastObservedAt: range.end, state: .inProgress))
            let userText = "USER-BEGIN-" + String(repeating: "intent detail ", count: 750) + "-USER-END"
            let assistantText =
                "ASSISTANT-BEGIN-" + String(repeating: "implementation detail ", count: 180)
                + "-ASSISTANT-END"
            let commitMessage =
                "COMMIT-BEGIN-" + String(repeating: "complete commit detail ", count: 420)
                + "-COMMIT-END"
            try addMessage(
                "summary-user", text: userText, role: .user,
                repositoryID: repository.id, sessionID: sessionID,
                at: start.addingTimeInterval(60), store: store)
            try addMessage(
                "summary-assistant", text: assistantText, role: .assistant,
                repositoryID: repository.id, sessionID: sessionID,
                at: start.addingTimeInterval(120), store: store)
            try store.upsert(
                commit: GitCommit(
                    id: "summary-commit", repositoryID: repository.id, hash: "abcdef123456",
                    authorTime: start.addingTimeInterval(180), message: commitMessage,
                    additions: 20, deletions: 2, filesChanged: 3,
                    firstObservedAt: start, lastObservedAt: start, isReachable: true))
            try addEvent(
                "summary-commit-event", kind: .gitCommitObserved,
                repositoryID: repository.id, state: .completed,
                payload: [
                    "hash": "abcdef123456", "message": commitMessage,
                    "additions": "20", "deletions": "2", "filesChanged": "3",
                ],
                at: start.addingTimeInterval(180), store: store)

            let compilation = try SummaryCoverageCompiler().compile(
                store: store, range: range, cutoff: range.end)
            let events = compilation.chunks.flatMap(\.events)
            let userFragments = events.filter { $0.messageRole == MessageRole.user }
                .sorted { ($0.fragmentIndex ?? 1) < ($1.fragmentIndex ?? 1) }
            let commitFragments = events.filter { $0.kind == .gitCommitObserved }
                .sorted { ($0.fragmentIndex ?? 1) < ($1.fragmentIndex ?? 1) }
            guard
                let assistant = events.first(where: {
                    $0.messageRole?.rawValue == MessageRole.assistant.rawValue
                })
            else {
                Issue.record("Expected the assistant message in canonical summary coverage.")
                return
            }

            #expect(userFragments.compactMap(\.messageExcerpt).joined() == userText)
            #expect(commitFragments.compactMap { $0.payload["message"] }.joined() == commitMessage)
            #expect(assistant.wasTruncated)
            #expect(assistant.originalCharacterCount == assistantText.count)
            #expect((assistant.messageExcerpt?.count ?? 0) < assistantText.count)
            #expect(compilation.coverage.eligibleEventCount == 3)
            #expect(compilation.coverage.coveredEventCount == 3)
            #expect(compilation.coverage.truncatedAssistantCount == 1)
            #expect(compilation.coverage.isComplete)
            #expect(compilation.chunks.allSatisfy { $0.serializedByteCount <= 20 * 1_024 })
        }
    }

    @Test("Summary coordinator persists project structure, compact copy, hierarchy, and stable revisions")
    func canonicalSummaryHierarchy() async throws {
        try await withCompilerStore { store in
            let day = Date(timeIntervalSince1970: 1_754_284_800)
            let now = day.addingTimeInterval(10 * 3_600 + 10 * 60)
            let first = try addRepository("summary-project-a", name: "Trackify", store: store, at: day)
            let second = try addRepository("summary-project-b", name: "ClientApp", store: store, at: day)
            try addEvent(
                "summary-a-work", kind: .gitWorkingTreeChanged,
                repositoryID: first.id, state: .inProgress,
                payload: ["clean": "false", "changedFiles": "2"],
                at: day.addingTimeInterval(9 * 3_600 + 5 * 60), store: store)
            try addEvent(
                "summary-b-work", kind: .gitWorkingTreeChanged,
                repositoryID: second.id, state: .inProgress,
                payload: ["clean": "false", "changedFiles": "1"],
                at: day.addingTimeInterval(9 * 3_600 + 10 * 60), store: store)
            let counter = ProviderInvocationCounter()
            let coordinator = SummaryCoordinator(
                providerFactory: { _, _ in StructuredSummaryProvider(counter: counter) },
                allowanceReader: NoProviderAllowanceReader(),
                availableProvider: { _, _, _ in .codex })
            let settings = TrackifySettings(
                providerSelection: .codex,
                generationBudgets: GenerationBudgets(
                    maximumCallsPerDay: 20, dailyTokenLimit: 500_000,
                    monthlyTokenLimit: 5_000_000),
                automaticSummariesUseLLM: true)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!

            let initial = await coordinator.refresh(
                store: store, settings: settings, now: now,
                calendar: calendar, lookbackDays: 1)
            #expect(initial.issues.isEmpty)
            #expect(initial.generated.count == 4)
            let current = try #require(try store.latestSummary(kind: .current))
            #expect(current.provider == nil)
            #expect(current.content.compactNarrative.contains("Trackify"))
            #expect(Set(current.content.projectSections.map(\.project)) == ["Trackify", "ClientApp"])
            #expect(current.childSummaryIDs.count == 2)
            #expect(current.coverage.isComplete)

            let unchanged = await coordinator.refresh(
                store: store, settings: settings, now: now,
                calendar: calendar, lookbackDays: 1)
            #expect(unchanged.generated.isEmpty)
            #expect(await counter.value == 2)

            try addEvent(
                "late-summary-work", kind: .testFinished,
                repositoryID: first.id, state: .completed,
                payload: ["suite": "Summary tests", "result": "passed"],
                at: day.addingTimeInterval(9 * 3_600 + 20 * 60), store: store)
            let revised = await coordinator.refresh(
                store: store, settings: settings, now: now,
                calendar: calendar, lookbackDays: 1)
            #expect(revised.issues.isEmpty)
            #expect(revised.generated.count == 3)
            let segments = try store.summaries(kinds: [.segment], limit: 20)
            #expect(segments.map(\.revision).max() == 2)
            #expect(await counter.value == 3)

            let reportPeriod = try #require(calendar.dateInterval(of: .day, for: now))
            let run = try ReportQueue().enqueueOnDemand(
                store: store, settings: TrackifySettings(providerSelection: .localOnly),
                recipeID: RecipeID("daily-work-summary"), period: reportPeriod, now: now)
            let latestDay = try #require(
                try store.latestSummary(kind: .day, overlapping: reportPeriod))
            #expect(try store.reportRunSummaryIDs(id: run.id) == [latestDay.id])
        }
    }

    @Test("A local summary upgrades once a selected provider becomes ready")
    func localSummaryProviderUpgrade() async throws {
        try await withCompilerStore { store in
            let day = Date(timeIntervalSince1970: 1_754_284_800)
            let now = day.addingTimeInterval(10 * 3_600 + 10 * 60)
            let repository = try addRepository(
                "summary-upgrade", name: "Trackify", store: store, at: day)
            try addEvent(
                "summary-upgrade-work", kind: .gitWorkingTreeChanged,
                repositoryID: repository.id, state: .inProgress,
                payload: ["clean": "false", "changedFiles": "2"],
                at: day.addingTimeInterval(9 * 3_600 + 5 * 60), store: store)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!

            let local = await SummaryCoordinator().refresh(
                store: store,
                settings: TrackifySettings(providerSelection: .localOnly),
                now: now, calendar: calendar, lookbackDays: 1)
            #expect(local.issues.isEmpty)
            let localCurrent = try #require(try store.latestSummary(kind: .current))
            #expect(localCurrent.provider == nil)

            let counter = ProviderInvocationCounter()
            let coordinator = SummaryCoordinator(
                providerFactory: { _, _ in StructuredSummaryProvider(counter: counter) },
                allowanceReader: NoProviderAllowanceReader(),
                availableProvider: { _, _, _ in .codex })
            let upgraded = await coordinator.refresh(
                store: store,
                settings: TrackifySettings(
                    providerSelection: .codex,
                    generationBudgets: GenerationBudgets(
                        maximumCallsPerDay: 20, dailyTokenLimit: 500_000,
                        monthlyTokenLimit: 5_000_000),
                    automaticSummariesUseLLM: true),
                now: now, calendar: calendar, lookbackDays: 1)
            #expect(upgraded.issues.isEmpty)
            let modelCurrent = try #require(try store.latestSummary(kind: .current))
            #expect(modelCurrent.provider == nil)
            #expect(modelCurrent.revision == localCurrent.revision + 1)
            #expect(try store.latestSummary(kind: .segment)?.provider == .codex)
            #expect(await counter.value == 1)
        }
    }

    @Test("A budget fallback stays bounded and upgrades immediately after recovery")
    func budgetFallbackRecovery() async throws {
        try await withCompilerStore { store in
            let day = Date(timeIntervalSince1970: 1_754_284_800)
            let now = day.addingTimeInterval(10 * 3_600 + 10 * 60)
            let repository = try addRepository(
                "summary-budget-recovery", name: "Trackify", store: store, at: day)
            try addEvent(
                "summary-budget-recovery-work", kind: .gitWorkingTreeChanged,
                repositoryID: repository.id, state: .inProgress,
                payload: ["clean": "false", "changedFiles": "2"],
                at: day.addingTimeInterval(9 * 3_600 + 5 * 60), store: store)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let counter = ProviderInvocationCounter()
            let coordinator = SummaryCoordinator(
                providerFactory: { _, _ in StructuredSummaryProvider(counter: counter) },
                allowanceReader: NoProviderAllowanceReader(),
                availableProvider: { _, _, _ in .codex })
            let blocked = TrackifySettings(
                providerSelection: .codex,
                generationBudgets: GenerationBudgets(
                    maximumCallsPerDay: 20, dailyTokenLimit: 1_000,
                    monthlyTokenLimit: 5_000_000),
                automaticSummariesUseLLM: true)

            let fallback = await coordinator.refresh(
                store: store, settings: blocked, now: now,
                calendar: calendar, lookbackDays: 1)
            #expect(fallback.issues.isEmpty)
            #expect(await counter.value == 0)
            #expect(try store.latestSummary(kind: .current)?.provider == nil)
            #expect(try store.summaryRuns(limit: 20).contains { $0.failureClass == .budget })
            let fallbackRunCount = try store.summaryRuns(limit: 100).count

            let stillBlocked = await coordinator.refresh(
                store: store, settings: blocked, now: now,
                calendar: calendar, lookbackDays: 1)
            #expect(stillBlocked.generated.isEmpty)
            #expect(try store.summaryRuns(limit: 100).count == fallbackRunCount)
            #expect(await counter.value == 0)

            let recovered = TrackifySettings(
                providerSelection: .codex,
                generationBudgets: GenerationBudgets(
                    maximumCallsPerDay: 20, dailyTokenLimit: 500_000,
                    monthlyTokenLimit: 5_000_000),
                automaticSummariesUseLLM: true)
            let upgraded = await coordinator.refresh(
                store: store, settings: recovered, now: now,
                calendar: calendar, lookbackDays: 1)
            #expect(upgraded.issues.isEmpty)
            #expect(try store.latestSummary(kind: .current)?.provider == nil)
            #expect(try store.latestSummary(kind: .segment)?.provider == .codex)
            #expect(await counter.value == 1)
        }
    }

    @Test("Local summaries distinguish agent progress from developer intent")
    func localSummaryUsesSemanticIntent() async throws {
        try await withCompilerStore { store in
            let day = Date(timeIntervalSince1970: 1_754_284_800)
            let now = day.addingTimeInterval(10 * 3_600 + 10 * 60)
            let repository = try addRepository(
                "semantic-summary", name: "Trackify", store: store, at: day)
            let sessionID = SessionID("semantic-summary-session")
            try store.upsert(
                session: ConversationSession(
                    id: sessionID, source: .claude, sourceSessionID: sessionID.rawValue,
                    startedAt: day, lastObservedAt: now, state: .inProgress))
            try addMessage(
                "semantic-human", text: "Polish automatic summaries", role: .user,
                provenance: ConversationProvenance(
                    origin: .human, semanticKind: .intent, disposition: .work,
                    classificationReason: "fixture-human-intent"),
                repositoryID: repository.id, sessionID: sessionID,
                at: day.addingTimeInterval(9 * 3_600 + 1 * 60), store: store)
            let notification =
                "<task-notification><status>completed</status><summary>Background agent finished</summary></task-notification>"
            try addMessage(
                "semantic-progress", text: notification, role: .user,
                provenance: ConversationProvenance(
                    origin: .agent, semanticKind: .progress, disposition: .work,
                    classificationReason: "claude-agent-task-notification"),
                repositoryID: repository.id, sessionID: sessionID,
                at: day.addingTimeInterval(9 * 3_600 + 2 * 60), store: store)

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let result = await SummaryCoordinator().refresh(
                store: store,
                settings: TrackifySettings(providerSelection: .localOnly),
                now: now, calendar: calendar, lookbackDays: 1)
            #expect(result.issues.isEmpty)
            let segment = try #require(try store.latestSummary(kind: .segment))
            #expect(segment.coverage.eligibleEventCount == 2)
            #expect(segment.content.intents == ["Polish automatic summaries"])
            #expect(segment.content.projectSections.first?.intents == ["Polish automatic summaries"])
            let rendered = String(decoding: try JSONEncoder().encode(segment.content), as: UTF8.self)
            #expect(!rendered.contains("task-notification"))
            #expect(!rendered.contains("Background agent finished"))
        }
    }

    @Test("An active day invokes the provider only for leaves and one closed-day synthesis")
    func automaticSummaryPacing() async throws {
        try await withCompilerStore { store in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let seed = Date(timeIntervalSince1970: 1_754_294_400)
            let day = try #require(calendar.dateInterval(of: .day, for: seed))
            let repository = try addRepository(
                "summary-pacing", name: "Trackify", store: store, at: day.start)
            for index in 0..<24 {
                try addEvent(
                    "summary-pacing-\(index)", kind: .gitWorkingTreeChanged,
                    repositoryID: repository.id, state: .inProgress,
                    payload: ["clean": "false", "changedFiles": "\(index + 1)"],
                    at: day.start.addingTimeInterval(
                        7 * 3_600 + Double(index * 1_800) + 60),
                    store: store)
            }
            let counter = ProviderInvocationCounter()
            let coordinator = SummaryCoordinator(
                providerFactory: { _, _ in StructuredSummaryProvider(counter: counter) },
                allowanceReader: NoProviderAllowanceReader(),
                availableProvider: { _, _, _ in .codex })
            let settings = TrackifySettings(
                providerSelection: .codex,
                generationBudgets: GenerationBudgets(
                    maximumCallsPerDay: 48, dailyTokenLimit: 2_000_000,
                    monthlyTokenLimit: 30_000_000),
                automaticSummariesUseLLM: true)

            let openDay = await coordinator.refresh(
                store: store, settings: settings,
                now: day.start.addingTimeInterval(19 * 3_600 + 10 * 60),
                calendar: calendar, lookbackDays: 1)
            #expect(openDay.issues.isEmpty)
            #expect(openDay.generated.count == 26)
            #expect(await counter.value == 24)
            #expect(try store.summaries(kinds: [.segment], limit: 100).count == 24)
            #expect(try store.latestSummary(kind: .current)?.provider == nil)
            #expect(try store.latestSummary(kind: .day)?.provider == nil)

            let closedDay = await coordinator.refresh(
                store: store, settings: settings,
                now: day.end.addingTimeInterval(3_600),
                calendar: calendar, lookbackDays: 2)
            #expect(closedDay.issues.isEmpty)
            #expect(await counter.value == 25)
            let finalized = try #require(
                try store.summaries(
                    overlapping: day, kinds: [.day], includeSuperseded: true, limit: 20
                ).first { $0.periodStart == day.start && $0.periodEnd == day.end })
            #expect(finalized.provider == .codex)
        }
    }

    @Test("Concurrent summary refreshes coalesce before invoking a provider")
    func concurrentSummaryRefreshCoalesces() async throws {
        try await withCompilerStore { store in
            let now = Date(timeIntervalSince1970: 1_754_320_800)
            let acquired = try store.acquireLease(
                name: ProviderGenerationLease.name, ownerID: "another-refresh",
                now: now, duration: 300)
            #expect(acquired)
            let counter = ProviderInvocationCounter()
            let coordinator = SummaryCoordinator(
                providerFactory: { _, _ in StructuredSummaryProvider(counter: counter) },
                allowanceReader: NoProviderAllowanceReader(),
                availableProvider: { _, _, _ in .codex })
            let result = await coordinator.refresh(
                store: store,
                settings: TrackifySettings(
                    providerSelection: .codex, automaticSummariesUseLLM: true),
                now: now, lookbackDays: 1)

            #expect(result.generated.isEmpty)
            #expect(result.issues.isEmpty)
            #expect(await counter.value == 0)
        }
    }
}

private actor ProviderInvocationCounter {
    private var count = 0
    func increment() { count += 1 }
    var value: Int { count }
}

private struct StructuredSummaryProvider: SummaryProvider {
    let id = "structured-summary-test"
    let model = "fixture-model"
    let counter: ProviderInvocationCounter

    func summarize(_ packet: ReportEvidencePacket) async throws -> ProviderSummary {
        await counter.increment()
        return ProviderSummary(
            summary: "Trackify and ClientApp work was captured with project-specific detail.",
            compactSummary: "Dense menu line.", topics: ["summaries"],
            evidenceAliases: Array(packet.evidenceAliases).sorted(),
            projects: ["Trackify", "ClientApp"],
            projectSummaries: [
                SummaryProjectSection(
                    project: "Trackify", narrative: "Implemented canonical summaries.",
                    outcomes: ["Stored structured summary data."], openWork: ["Validate UI."]),
                SummaryProjectSection(
                    project: "ClientApp", narrative: "Tracked parallel client work.",
                    intents: ["Keep the client context visible."]),
            ],
            intents: ["Build canonical summaries."],
            outcomes: ["Structured summaries persisted."],
            openWork: ["Validate UI."], blockers: [])
    }
}

private struct AliasSummaryProvider: SummaryProvider {
    let id = "alias-test"
    let model = "fixture"

    func summarize(_ packet: ReportEvidencePacket) async throws -> ProviderSummary {
        ProviderSummary(
            summary: "Work remained in progress with local provenance.",
            topics: ["compiler"],
            evidenceAliases: [packet.events[0].eventID.rawValue]
        )
    }
}

private struct PriorSummaryProvider: SummaryProvider {
    let id = "prior-report-test"
    let model = "fixture"

    func summarize(_ packet: ReportEvidencePacket) async throws -> ProviderSummary {
        ProviderSummary(
            summary: "Morning work completed and evening validation remained in progress.",
            topics: ["daily hierarchy"],
            evidenceAliases: packet.priorSummaries.map(\.alias)
        )
    }
}

private func addRepository(
    _ id: String,
    name: String,
    store: LedgerStore,
    at date: Date
) throws -> Repository {
    let repository = Repository(
        id: RepositoryID(id),
        displayName: name,
        firstObservedAt: date,
        lastObservedAt: date
    )
    try store.upsert(
        repository: repository,
        workingCopy: WorkingCopy(
            id: WorkingCopyID("\(id)-copy"),
            repositoryID: repository.id,
            canonicalPath: "/tmp/\(id)",
            firstObservedAt: date,
            lastObservedAt: date
        ))
    return repository
}

private func addMessage(
    _ id: String,
    text: String,
    role: MessageRole,
    provenance: ConversationProvenance = ConversationProvenance(),
    repositoryID: RepositoryID,
    sessionID: SessionID,
    at date: Date,
    store: LedgerStore
) throws {
    let message = ConversationMessage(
        id: MessageID("\(id)-message"),
        sessionID: sessionID,
        sourceMessageID: id,
        role: role,
        occurredAt: date,
        normalizedText: text,
        fingerprint: "\(id)-fingerprint",
        provenance: provenance
    )
    try store.upsert(message: message)
    try addEvent(
        id,
        kind: .agentMessageObserved,
        repositoryID: repositoryID,
        sessionID: sessionID,
        payload: ["messageID": message.id.rawValue, "role": role.rawValue],
        at: date,
        store: store
    )
}

private func addEvent(
    _ id: String,
    kind: EventKind,
    repositoryID: RepositoryID? = nil,
    sessionID: SessionID? = nil,
    state: ObservedState? = nil,
    payload: [String: String] = [:],
    at date: Date,
    store: LedgerStore
) throws {
    let evidenceID = EvidenceID("\(id)-evidence")
    _ = try store.ingest(
        evidence: SourceEvidence(
            id: evidenceID,
            source: .simulation,
            ingestionPath: .fixture,
            sourceRecordID: id,
            fingerprint: "\(id)-fingerprint",
            occurredAt: date,
            observedAt: date,
            adapterVersion: 1
        ),
        event: LedgerEvent(
            id: EventID(id),
            evidenceID: evidenceID,
            occurredAt: date,
            observedAt: date,
            source: .simulation,
            kind: kind,
            repositoryID: repositoryID,
            sessionID: sessionID,
            state: state,
            payload: payload
        )
    )
}

private func saveSegmentSummary(
    id: String,
    start: Date,
    state: ReportPeriodState,
    summary: String,
    evidenceIDs: [EvidenceID],
    store: LedgerStore
) throws {
    try store.save(
        summary: WorkSummary(
            id: SummaryID(id), kind: .segment,
            periodStart: start, periodEnd: start.addingTimeInterval(3_600),
            generatedAt: start.addingTimeInterval(3_600), state: state,
            content: SummaryContent(narrative: summary),
            evidenceIDs: evidenceIDs, generationSource: .local,
            generatorVersion: "fixture", promptVersion: "fixture",
            schemaVersion: "work-summary-v1", sourceFingerprint: id,
            coverage: SummaryCoverage(
                eligibleEventCount: evidenceIDs.count,
                coveredEventCount: evidenceIDs.count),
            revision: 1))
}

private func encodedString(_ packet: ReportEvidencePacket) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(packet), as: UTF8.self)
}

private func withCompilerStore(
    _ body: (LedgerStore) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "trackify-compiler-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(LedgerStore(databaseURL: directory.appending(path: "ledger.sqlite")))
}
