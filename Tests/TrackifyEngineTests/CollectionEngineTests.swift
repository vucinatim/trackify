import Foundation
import Testing
import TrackifyDomain
import TrackifyStore

@testable import TrackifyEngine

@Suite("Collection engine")
struct CollectionEngineTests {
    @Test("Collection reclaims a lease whose local owner process has exited")
    func reclaimsDeadCollectorLease() async throws {
        try await withTemporaryStore { store in
            let now = Date(timeIntervalSince1970: 1_754_294_400)
            let staleOwner = "cli:2147483000:stale"
            #expect(try store.acquireLease(name: "collection", ownerID: staleOwner, now: now, duration: 900))

            _ = try await LocalCollectionCoordinator(clock: FixedWallClock(now)).collect(
                store: store,
                gitRoots: [],
                includeCodex: false,
                includeClaude: false
            )

            #expect(try store.leaseOwner(name: "collection") == nil)
        }
    }

    @Test("Process runner terminates a command that exceeds its deadline")
    func processDeadline() throws {
        let runner = ProcessRunner(timeout: 0.05, terminationGrace: 0.05)
        var timedOut = false
        do {
            _ = try runner.run(
                executable: URL(filePath: "/usr/bin/tail"),
                arguments: ["-f", "/dev/null"],
                workingDirectory: nil,
                environment: nil,
                outputLimit: 1_024
            )
        } catch ProcessRunnerError.timedOut {
            timedOut = true
        }
        #expect(timedOut)
    }

    @Test("Cancelling an asynchronous process run terminates its exact child promptly")
    func processCancellation() async throws {
        let runner = ProcessRunner(timeout: 30, terminationGrace: 0.1)
        let task = Task {
            try await runner.runAsync(
                executable: URL(filePath: "/bin/sleep"), arguments: ["10"],
                workingDirectory: nil, environment: nil, input: Data(), outputLimit: 1_024)
        }
        try await Task.sleep(for: .milliseconds(80))
        let cancellationRequestedAt = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("A cancelled process should not return normally.")
        } catch is CancellationError {
            // Expected.
        }
        #expect(cancellationRequestedAt.duration(to: .now) < .seconds(2))
    }

    @Test("Provider readiness is honest about authentication certainty")
    func providerHealth() {
        let executable = URL(filePath: "/usr/bin/true")
        let codexRunner = InvocationCountingRunner()
        let codex = ProviderHealthInspector(runner: codexRunner).codex(executable: executable)
        let passiveRunner = InvocationCountingRunner()
        let claude = ProviderHealthInspector(runner: passiveRunner).claude(executable: executable)

        #expect(codex.state == .authenticationUnknown)
        #expect(codexRunner.invocationCount == 0)
        #expect(claude.state == .authenticationUnknown)
        #expect(passiveRunner.invocationCount == 0)
        #expect(ProviderHealthInspector().claude(executable: nil).state == .notInstalled)
    }

    @Test("Installation origin selects exactly one update owner")
    func installationOriginPolicy() {
        let direct = InstallationMetadata.parse(info: [
            "TrackifyInstallationOrigin": "direct",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "123",
            "CFBundleIdentifier": "com.zoulabs.trackify",
            "SUPublicEDKey": "configured-key",
        ])
        #expect(direct.origin == .direct)
        #expect(direct.version == "1.2.3")
        #expect(direct.build == "123")
        #expect(direct.updateAction == .sparkle)

        for (origin, action) in [
            (InstallationOrigin.homebrew, UpdateInstallAction.homebrew),
            (.managed, .managed),
            (.development, .disabled),
        ] {
            let metadata = InstallationMetadata.parse(info: [
                "TrackifyInstallationOrigin": origin.rawValue,
                "CFBundleIdentifier": "com.zoulabs.trackify",
                "SUPublicEDKey": "configured-key",
            ])
            #expect(metadata.updateAction == action)
        }

        let unsignedDirect = InstallationMetadata.parse(info: [
            "TrackifyInstallationOrigin": "direct",
            "CFBundleIdentifier": "com.zoulabs.trackify",
            "SUPublicEDKey": "UNCONFIGURED",
        ])
        #expect(unsignedDirect.updateAction == .disabled)
    }

    @Test("Exported diagnostics contain only allowlisted operational fields")
    func safeDiagnosticExport() async throws {
        try await withTemporaryStore { store in
            let secretPath = "/Users/example/PrivateClient/repository"
            let secretToken = "sk-example1234567890"
            try store.replaceCollectorIssues(
                [(sourceKey: secretPath, message: "authentication failed for \(secretToken)")],
                at: Date(timeIntervalSince1970: 1_754_294_400)
            )
            let destination = store.databaseURL.deletingLastPathComponent().appending(path: "diagnostic.json")

            let exporter = DiagnosticExporter()
            try exporter.write(
                exporter.make(store: store, generatedAt: Date(timeIntervalSince1970: 1_754_294_500)),
                to: destination
            )

            let contents = try String(contentsOf: destination, encoding: .utf8)
            #expect(!contents.contains(secretPath))
            #expect(!contents.contains(secretToken))
            #expect(!contents.contains(store.databaseURL.path))
            #expect(contents.contains(#""collectorIssueCount" : 1"#))
            let permissions = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o600)
        }
    }

    @Test("Report scheduler creates completed periods once")
    func scheduledReportsAreIdempotent() async throws {
        try await withTemporaryStore { store in
            let now = try #require(try? Date("2026-08-04T10:23:00Z", strategy: .iso8601))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
            let first = await ReportScheduler().generateDueReports(
                store: store,
                now: now,
                calendar: calendar
            )
            let second = await ReportScheduler().generateDueReports(
                store: store,
                now: now,
                calendar: calendar
            )

            #expect(first.generated.count == 2)
            #expect(first.issues.isEmpty)
            #expect(second.generated.isEmpty)
            #expect(
                try store.reports(
                    overlapping: DateInterval(
                        start: now.addingTimeInterval(-2 * 86_400),
                        end: now
                    )
                ).count == 2)
        }
    }

    @Test("Report scheduler catches up an older active hour without extra provider work")
    func scheduledReportCatchup() async throws {
        try await withTemporaryStore { store in
            let now = try #require(try? Date("2026-08-04T10:23:00Z", strategy: .iso8601))
            let eventTime = try #require(try? Date("2026-08-04T07:05:00Z", strategy: .iso8601))
            let evidence = SourceEvidence(
                id: EvidenceID("catchup-evidence"),
                source: .simulation,
                ingestionPath: .fixture,
                sourceRecordID: "catchup",
                fingerprint: "catchup",
                occurredAt: eventTime,
                observedAt: now,
                adapterVersion: 1
            )
            _ = try store.ingest(
                evidence: evidence,
                event: LedgerEvent(
                    id: EventID("catchup-event"),
                    evidenceID: evidence.id,
                    occurredAt: eventTime,
                    observedAt: now,
                    source: .simulation,
                    kind: .buildFinished,
                    state: .completed
                )
            )
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

            let result = await ReportScheduler().generateDueReports(store: store, now: now, calendar: calendar)

            #expect(result.issues.isEmpty)
            #expect(result.generated.count == 3)
            #expect(result.generated.contains { calendar.component(.hour, from: $0.periodStart) == 7 })
            let repeated = await ReportScheduler().generateDueReports(store: store, now: now, calendar: calendar)
            #expect(repeated.generated.isEmpty)
        }
    }

    @Test("Report scheduler falls back deterministically when the provider fails")
    func scheduledReportProviderFallback() async throws {
        try await withTemporaryStore { store in
            let now = try #require(try? Date("2026-08-04T10:23:00Z", strategy: .iso8601))
            let eventTime = try #require(try? Date("2026-08-04T09:20:00Z", strategy: .iso8601))
            let evidence = SourceEvidence(
                id: EvidenceID("fallback-evidence"),
                source: .simulation,
                ingestionPath: .fixture,
                sourceRecordID: "fallback",
                fingerprint: "fallback",
                occurredAt: eventTime,
                observedAt: now,
                adapterVersion: 1
            )
            _ = try store.ingest(
                evidence: evidence,
                event: LedgerEvent(
                    id: EventID("fallback-event"),
                    evidenceID: evidence.id,
                    occurredAt: eventTime,
                    observedAt: now,
                    source: .simulation,
                    kind: .buildFinished,
                    state: .completed
                )
            )
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

            let result = await ReportScheduler().generateDueReports(
                store: store,
                now: now,
                calendar: calendar,
                provider: AlwaysFailSummaryProvider()
            )

            #expect(result.generated.count == 2)
            #expect(result.issues.count == 1)
            #expect(result.generated.allSatisfy { $0.provider == nil && $0.model == nil })
            let active = try #require(result.generated.first { $0.state == .completed })
            let inactive = try #require(result.generated.first { $0.state == .noActivity })
            #expect(active.evidenceIDs == [evidence.id])
            #expect(active.summary.contains("completed state"))
            #expect(inactive.evidenceIDs.isEmpty)
        }
    }

    @Test("Report state distinguishes observed, unfinished, investigating, and completed evidence")
    func reportStates() async throws {
        let cases: [(EventKind, ObservedState?, [String: String], ReportPeriodState)] = [
            (.agentMessageObserved, nil, ["role": "user"], .observed),
            (.gitWorkingTreeChanged, nil, ["baseline": "false", "clean": "false", "changedFiles": "1"], .inProgress),
            (.buildFinished, .failed, [:], .investigating),
            (.gitCommitObserved, nil, [:], .completed),
        ]
        for (index, value) in cases.enumerated() {
            try await withTemporaryStore { store in
                let start = Date(timeIntervalSince1970: 1_754_294_400)
                let sessionID = SessionID("report-state-session-\(index)")
                try store.upsert(
                    session: ConversationSession(
                        id: sessionID,
                        source: .simulation,
                        sourceSessionID: sessionID.rawValue,
                        startedAt: start,
                        lastObservedAt: start.addingTimeInterval(3_600),
                        state: value.1 ?? .unknown
                    ))
                let evidence = SourceEvidence(
                    id: EvidenceID("report-state-evidence-\(index)"),
                    source: .simulation,
                    ingestionPath: .fixture,
                    sourceRecordID: "report-state-\(index)",
                    fingerprint: "report-state-\(index)",
                    occurredAt: start.addingTimeInterval(60),
                    observedAt: start.addingTimeInterval(60),
                    adapterVersion: 1
                )
                _ = try store.ingest(
                    evidence: evidence,
                    event: LedgerEvent(
                        id: EventID("report-state-event-\(index)"),
                        evidenceID: evidence.id,
                        occurredAt: evidence.occurredAt,
                        observedAt: evidence.observedAt,
                        source: .simulation,
                        kind: value.0,
                        sessionID: sessionID,
                        state: value.1,
                        payload: value.2
                    )
                )
                let packet = try ReportGenerator().evidencePacket(
                    store: store,
                    range: DateInterval(start: start, duration: 3_600),
                    cutoff: start.addingTimeInterval(3_600)
                )
                #expect(packet.state == value.3)
            }
        }
    }

    @Test("Optional lifecycle telemetry does not manufacture core activity")
    func lifecycleTelemetryIsNotCoreActivity() async throws {
        try await withTemporaryStore { store in
            let hour = Date(timeIntervalSince1970: 1_754_298_000)
            let startedAt = hour.addingTimeInterval(60)
            let sessionID = SessionID("cross-hour-session")
            try store.upsert(
                session: ConversationSession(
                    id: sessionID,
                    source: .codex,
                    sourceSessionID: sessionID.rawValue,
                    startedAt: startedAt,
                    lastObservedAt: hour.addingTimeInterval(3_600),
                    state: .inProgress
                ))
            let evidence = SourceEvidence(
                id: EvidenceID("cross-hour-evidence"),
                source: .codex,
                ingestionPath: .fixture,
                sourceRecordID: "cross-hour",
                fingerprint: "cross-hour",
                occurredAt: startedAt,
                observedAt: startedAt,
                adapterVersion: 1
            )
            _ = try store.ingest(
                evidence: evidence,
                event: LedgerEvent(
                    id: EventID("cross-hour-event"),
                    evidenceID: evidence.id,
                    occurredAt: startedAt,
                    observedAt: startedAt,
                    source: .codex,
                    kind: .agentRunStarted,
                    sessionID: sessionID,
                    state: .inProgress
                )
            )

            let packet = try ReportGenerator().evidencePacket(
                store: store,
                range: DateInterval(start: hour, duration: 3_600),
                cutoff: hour.addingTimeInterval(3_600)
            )

            #expect(packet.state == .noActivity)
            #expect(packet.activity.activeHours == 0)
            #expect(packet.activity.evidenceCount == 0)
            #expect(packet.events.isEmpty)
        }
    }

    @Test("Bootstrap recommends bounded folder-based primary groups")
    func bootstrapInspection() throws {
        try withTemporaryDirectory { home in
            let projects = home.appending(path: "Desktop/MyProjects")
            try makeGitRepository(at: projects.appending(path: "One"))
            try makeGitRepository(at: projects.appending(path: "Two"))
            let paths = TrackifyPaths(dataRoot: home.appending(path: "Data"))
            let store = try LedgerStore(databaseURL: paths.ledgerURL)
            let inspection = try BootstrapInspector().inspect(
                paths: paths,
                store: store,
                homeDirectory: home
            )

            #expect(inspection.recommendedRoots.count == 1)
            #expect(inspection.recommendedRoots.first?.suggestedName == "Personal")
            #expect(inspection.recommendedRoots.first?.repositoryCount == 2)
            #expect(
                inspection.backfillPlan.maximumInputTokens
                    == 14 * GenerationBudgets().maximumEstimatedInputTokensPerCall)
            #expect(inspection.backfillPlan.note.contains("provider CLI overhead"))
        }
    }

    @Test("Hook inbox is incremental and reconciles with durable Codex cache")
    func hookInboxReconciliation() async throws {
        try await withTemporaryStoreAndRoot { store, root in
            let inbox = root.appending(path: "events.jsonl")
            let start = try #require(try? Date("2026-08-04T09:00:02Z", strategy: .iso8601))
            try HookInboxWriter().append(
                HookEnvelope(
                    source: .codex,
                    sessionID: "01900000-0000-7000-8000-000000000001",
                    turnID: "01900000-0000-7000-8000-000000000002",
                    phase: .started,
                    occurredAt: start,
                    workingDirectory: "/Users/example/Developer/Work/sample-repo"
                ),
                to: inbox
            )
            let engine = CollectionEngine(store: store, clock: FixedWallClock(start.addingTimeInterval(60)))
            let hookFirst = try await engine.collect(from: HookInboxSource(fileURL: inbox))
            let hookSecond = try await engine.collect(from: HookInboxSource(fileURL: inbox))
            let cache = try await engine.collect(from: CodexJSONLSource(fileURL: fixtureURL("Codex/runtime-events-0.147.0.jsonl")))

            #expect(hookFirst.insertedEvents == 1)
            #expect(hookSecond.receivedRecords == 0)
            #expect(cache.insertedEvents == 3)
            #expect(try store.counts().events == 4)
            #expect(try store.counts().observations == 4)
        }
    }

    @Test("Hook inbox rejects an oversized envelope before creating storage")
    func hookInboxBound() throws {
        try withTemporaryDirectory { root in
            let inbox = root.appending(path: "events.jsonl")
            #expect(throws: HookInboxError.envelopeTooLarge(limit: HookInboxWriter.maximumEnvelopeBytes)) {
                try HookInboxWriter().append(
                    HookEnvelope(
                        source: .claude,
                        sessionID: "session",
                        turnID: "turn",
                        phase: .started,
                        occurredAt: Date(timeIntervalSince1970: 1_754_294_400),
                        workingDirectory: "/" + String(repeating: "x", count: HookInboxWriter.maximumEnvelopeBytes)
                    ),
                    to: inbox
                )
            }
            #expect(!FileManager.default.fileExists(atPath: inbox.path))
        }
    }

    @Test("Waiting hook closes active runtime without claiming completion")
    func waitingHook() {
        let start = Date(timeIntervalSince1970: 1_754_294_400)
        let sessionID = SessionID("waiting-session")
        let events = [
            lifecycleEvent(id: "waiting-start", sessionID: sessionID, date: start, kind: .agentRunStarted, state: .inProgress),
            lifecycleEvent(
                id: "waiting-end", sessionID: sessionID, date: start.addingTimeInterval(600), kind: .agentRunWaiting, state: .waiting),
        ]
        let intervals = IntervalDeriver().derive(events: events, cutoff: start.addingTimeInterval(3_600))
        #expect(intervals.count == 1)
        #expect(intervals.first?.duration == 600)
        #expect(intervals.first?.state == .waiting)
    }

    @Test("Codex and Claude report providers use structured non-persistent runs")
    func summaryProviders() async throws {
        let start = Date(timeIntervalSince1970: 1_754_294_400)
        let activity = ActivitySnapshot(
            rangeStart: start,
            rangeEnd: start.addingTimeInterval(60),
            activeHours: 1,
            llmTurns: 1,
            conversationMessages: 2,
            commits: 0,
            additions: 0,
            deletions: 0,
            filesChanged: 0,
            repositoryIDs: [],
            evidenceCount: 2,
            firstEvidenceAt: start,
            lastEvidenceAt: start.addingTimeInterval(60)
        )
        let packet = ReportEvidencePacket(
            schemaVersion: 2,
            periodStart: start,
            periodEnd: start.addingTimeInterval(60),
            state: .inProgress,
            activity: activity,
            events: [
                ReportEventDigest(
                    eventID: EventID("provider-event"),
                    evidenceID: EvidenceID("provider-evidence"),
                    occurredAt: start,
                    source: .codex,
                    kind: .agentRunStarted,
                    state: .inProgress,
                    payload: [:]
                )
            ]
        )
        let executable = URL(filePath: "/usr/bin/true")
        let codex = CodexSummaryProvider(executable: executable, runner: StubSummaryRunner(provider: "codex"))
        let claude = ClaudeSummaryProvider(executable: executable, runner: StubSummaryRunner(provider: "claude"))

        #expect(
            try await codex.summarize(packet)
                == ProviderSummary(
                    summary: "Codex summary", topics: [], evidenceAliases: ["provider-event"]))
        #expect(
            try await claude.summarize(packet)
                == ProviderSummary(
                    summary: "Claude summary", topics: [], evidenceAliases: ["provider-event"]))

        for invalidEvidence in [[], ["provider-event", "provider-event"], ["fabricated"]] {
            var rejected = false
            do {
                _ = try await CodexSummaryProvider(
                    executable: executable,
                    runner: StubSummaryRunner(provider: "codex", evidenceAliases: invalidEvidence)
                ).summarize(packet)
            } catch SummaryProviderError.invalidResponse {
                rejected = true
            }
            #expect(rejected)
        }

        do {
            _ = try await CodexSummaryProvider(
                executable: executable,
                runner: FailingSummaryRunner()
            ).summarize(packet)
            Issue.record("A nonzero provider exit should fail.")
        } catch let error as SummaryProviderError {
            #expect(error == .processFailed(provider: "Codex", status: 9))
            #expect(!String(describing: error).contains("private provider output"))
        }

        let classified: [(String, SummaryProviderError)] = [
            ("authentication required private-detail", .authenticationFailed("Claude")),
            ("rate limit exceeded private-detail", .rateLimited("Claude")),
            ("requested model is unavailable private-detail", .modelUnavailable("Claude")),
        ]
        for (output, expected) in classified {
            do {
                _ = try await ClaudeSummaryProvider(
                    executable: executable,
                    runner: ClassifiedFailureRunner(output: output)
                ).summarize(packet)
                Issue.record("A classified provider failure should fail.")
            } catch let error as SummaryProviderError {
                #expect(error == expected)
                #expect(!error.localizedDescription.contains("private-detail"))
            }
        }
    }

    @Test("Report generation is evidence-linked, revisioned, and redacts secrets")
    func reportGeneration() async throws {
        try await withTemporaryStore { store in
            let start = Date(timeIntervalSince1970: 1_754_294_400)
            let range = DateInterval(start: start, duration: 3_600)
            let first = try await ReportGenerator().generate(store: store, range: range, cutoff: range.end)
            let second = try await ReportGenerator().generate(store: store, range: range, cutoff: range.end)

            #expect(first.state == .noActivity)
            #expect(first.evidenceIDs.isEmpty)
            #expect(first.revision == 1)
            #expect(second.revision == 2)
            #expect(try store.reports(overlapping: range).count == 2)
            #expect(SecretRedactor.redact("token sk-example1234567890") == "token [REDACTED_OPENAI_KEY]")
        }
    }

    @Test("Report evidence joins bounded conversation context without duplicating transcript text in events")
    func reportConversationEvidence() async throws {
        try await withTemporaryStoreAndRoot { store, root in
            let start = Date(timeIntervalSince1970: 1_754_294_400)
            let repository = Repository(
                id: RepositoryID("report-context-repo"),
                displayName: "NarrativeKit",
                firstObservedAt: start,
                lastObservedAt: start
            )
            let copy = WorkingCopy(
                id: WorkingCopyID("report-context-copy"),
                repositoryID: repository.id,
                canonicalPath: root.path,
                firstObservedAt: start,
                lastObservedAt: start
            )
            try store.upsert(repository: repository, workingCopy: copy)

            let session = ConversationSession(
                id: SessionID("report-context-session"),
                source: .codex,
                sourceSessionID: "report-context-session",
                startedAt: start,
                lastObservedAt: start.addingTimeInterval(120),
                workingDirectory: root.path,
                state: .completed
            )
            let message = ConversationRecordFactory.message(
                source: .codex,
                sessionID: session.id,
                sourceMessageID: "report-context-message",
                role: .assistant,
                occurredAt: start.addingTimeInterval(120),
                text:
                    "Implemented repository discovery in \(root.path), checked /Users/privateperson/Client, and left the update verifier ready for tests."
            )
            let messageRecord = try #require(
                ConversationRecordFactory.messageRecord(
                    source: .codex,
                    message: message,
                    observedAt: start.addingTimeInterval(180)
                )
            )
            _ = try await CollectionEngine(
                store: store,
                clock: FixedWallClock(start.addingTimeInterval(180))
            ).ingest(
                CollectionBatch(
                    sourceKey: "report-context",
                    sessions: [session],
                    messages: [message],
                    records: [messageRecord]
                )
            )

            #expect(messageRecord.event.payload["message"] == nil)
            let packet = try ReportGenerator().evidencePacket(
                store: store,
                range: DateInterval(start: start, duration: 3_600),
                cutoff: start.addingTimeInterval(3_600)
            )
            let digest = try #require(packet.events.first)
            #expect(digest.kind == .agentMessageObserved)
            #expect(digest.messageRole == .assistant)
            #expect(digest.repositoryID == RepositoryID("r1"))
            #expect(digest.repositoryName == "NarrativeKit")
            #expect(digest.messageExcerpt?.contains("repository discovery") == true)
            #expect(digest.messageExcerpt?.contains(root.path) == false)
            #expect(digest.messageExcerpt?.contains("privateperson") == false)
            #expect(digest.messageExcerpt?.contains("[TEMP_PATH]") == true)
            #expect(digest.messageExcerpt?.contains("/Users/[REDACTED_USER]/Client") == true)
            #expect(digest.evidenceID == messageRecord.evidence.id)

            let report = try await ReportGenerator().generate(
                store: store,
                range: DateInterval(start: start, duration: 3_600),
                cutoff: start.addingTimeInterval(3_600)
            )
            #expect(report.summary.contains("Worked in NarrativeKit"))
            #expect(report.summary.contains("repository discovery"))
        }
    }

    @Test("Reports preserve user intent separately from assistant progress")
    func reportUserIntentAndAssistantProgress() async throws {
        try await withTemporaryStore { store in
            let start = Date(timeIntervalSince1970: 1_754_294_400)
            let session = ConversationSession(
                id: SessionID("role-aware-report-session"),
                source: .codex,
                sourceSessionID: "role-aware-report-session",
                startedAt: start,
                lastObservedAt: start.addingTimeInterval(120),
                state: .completed
            )
            let messages = [
                ConversationRecordFactory.message(
                    source: .codex,
                    sessionID: session.id,
                    sourceMessageID: "role-aware-user",
                    role: .user,
                    occurredAt: start.addingTimeInterval(60),
                    text: "Make user prompts visually distinct in the Activity timeline"
                ),
                ConversationRecordFactory.message(
                    source: .codex,
                    sessionID: session.id,
                    sourceMessageID: "role-aware-assistant",
                    role: .assistant,
                    occurredAt: start.addingTimeInterval(120),
                    text: "Added typed message roles and separate user and agent presentation"
                ),
            ]
            let records = messages.compactMap {
                ConversationRecordFactory.messageRecord(
                    source: .codex,
                    message: $0,
                    observedAt: start.addingTimeInterval(180)
                )
            }
            #expect(records.count == 2)
            _ = try await CollectionEngine(
                store: store,
                clock: FixedWallClock(start.addingTimeInterval(180))
            ).ingest(
                CollectionBatch(
                    sourceKey: "role-aware-report",
                    sessions: [session],
                    messages: messages,
                    records: records
                )
            )

            let range = DateInterval(start: start, duration: 3_600)
            let packet = try ReportGenerator().evidencePacket(
                store: store,
                range: range,
                cutoff: range.end
            )
            #expect(packet.schemaVersion == 4)
            #expect(Set(packet.events.compactMap(\.messageRole).map(\.rawValue)) == ["user", "assistant"])

            let report = try await ReportGenerator().generate(
                store: store,
                range: range,
                cutoff: range.end
            )
            #expect(report.generatorVersion == "report-v6")
            #expect(report.summary.contains("Requested"))
            #expect(report.summary.contains("Make user prompts visually distinct"))
            #expect(report.summary.contains("Latest agent update"))
            #expect(report.summary.contains("Added typed message roles"))
        }
    }

    @Test("Deterministic reports never pair intent with unrelated parallel work")
    func reportIntentStaysWithinItsWorkContext() {
        let start = Date(timeIntervalSince1970: 1_754_294_400)
        let trackifyID = RepositoryID("parallel-trackify")
        let clientID = RepositoryID("parallel-client")
        let sessionID = SessionID("parallel-trackify-session")
        let activity = ActivitySnapshot(
            rangeStart: start,
            rangeEnd: start.addingTimeInterval(3_600),
            activeHours: 1,
            llmTurns: 1,
            conversationMessages: 2,
            commits: 1,
            additions: 10,
            deletions: 2,
            filesChanged: 1,
            repositoryIDs: [trackifyID, clientID],
            evidenceCount: 4,
            firstEvidenceAt: start,
            lastEvidenceAt: start.addingTimeInterval(240)
        )
        let user = ReportEventDigest(
            eventID: EventID("parallel-user"),
            evidenceID: EvidenceID("parallel-user-evidence"),
            occurredAt: start.addingTimeInterval(120),
            source: .codex,
            kind: .agentMessageObserved,
            state: nil,
            repositoryID: trackifyID,
            repositoryName: "Trackify",
            sessionID: sessionID,
            messageRole: .user,
            messageExcerpt: "Differentiate user prompts from agent updates",
            payload: [:]
        )
        let unrelatedCommit = ReportEventDigest(
            eventID: EventID("parallel-commit"),
            evidenceID: EvidenceID("parallel-commit-evidence"),
            occurredAt: start.addingTimeInterval(180),
            source: .git,
            kind: .gitCommitObserved,
            state: .completed,
            repositoryID: clientID,
            repositoryName: "ClientApp",
            payload: ["message": "Fix client export"]
        )
        let completedPacket = ReportEvidencePacket(
            schemaVersion: 3,
            periodStart: start,
            periodEnd: start.addingTimeInterval(3_600),
            state: .completed,
            activity: activity,
            events: [user, unrelatedCommit]
        )
        let completedSummary = ReportGenerator().deterministicSummary(completedPacket)
        #expect(completedSummary.contains("Fix client export"))
        #expect(!completedSummary.contains("Differentiate user prompts"))

        let dirtyTree = ReportEventDigest(
            eventID: EventID("parallel-dirty"),
            evidenceID: EvidenceID("parallel-dirty-evidence"),
            occurredAt: start.addingTimeInterval(200),
            source: .git,
            kind: .gitWorkingTreeChanged,
            state: .inProgress,
            repositoryID: trackifyID,
            repositoryName: "Trackify",
            payload: ["clean": "false"]
        )
        let assistant = ReportEventDigest(
            eventID: EventID("parallel-assistant"),
            evidenceID: EvidenceID("parallel-assistant-evidence"),
            occurredAt: start.addingTimeInterval(240),
            source: .codex,
            kind: .agentMessageObserved,
            state: nil,
            repositoryID: trackifyID,
            repositoryName: "Trackify",
            sessionID: sessionID,
            messageRole: .assistant,
            messageExcerpt: "Implemented the role-aware timeline and started validation",
            payload: [:]
        )
        let inProgressPacket = ReportEvidencePacket(
            schemaVersion: 3,
            periodStart: start,
            periodEnd: start.addingTimeInterval(3_600),
            state: .inProgress,
            activity: activity,
            events: [unrelatedCommit, user, dirtyTree, assistant]
        )
        let inProgressSummary = ReportGenerator().deterministicSummary(inProgressPacket)
        #expect(inProgressSummary.contains("Differentiate user prompts"))
        #expect(inProgressSummary.contains("Implemented the role-aware timeline"))
        #expect(!inProgressSummary.contains("Fix client export"))
    }

    @Test("Context resolves the current repository and reports unfinished work")
    func repositoryContext() async throws {
        try await withTemporaryStoreAndRoot { store, root in
            let start = Date(timeIntervalSince1970: 1_754_294_400)
            let repository = Repository(
                id: RepositoryID("context-repo"),
                displayName: "ContextKit",
                firstObservedAt: start,
                lastObservedAt: start
            )
            let copyPath = root.appending(path: "ContextKit")
            try FileManager.default.createDirectory(at: copyPath, withIntermediateDirectories: true)
            let copy = WorkingCopy(
                id: WorkingCopyID("context-copy"),
                repositoryID: repository.id,
                canonicalPath: copyPath.path,
                branch: "main",
                headCommit: "abcdef1234567890",
                firstObservedAt: start,
                lastObservedAt: start
            )
            try store.upsert(repository: repository, workingCopy: copy)
            let session = ConversationSession(
                id: SessionID("context-session"),
                source: .codex,
                sourceSessionID: "context-session",
                startedAt: start,
                lastObservedAt: start,
                workingDirectory: copyPath.path,
                state: .inProgress
            )
            let event = lifecycleEvent(
                id: "context-start",
                sessionID: session.id,
                date: start,
                kind: .agentRunStarted,
                state: .inProgress
            )
            let evidence = SourceEvidence(
                id: event.evidenceID,
                source: .codex,
                ingestionPath: .fixture,
                sourceRecordID: event.id.rawValue,
                fingerprint: event.id.rawValue,
                occurredAt: start,
                observedAt: start,
                adapterVersion: 1
            )
            let treeEvent = LedgerEvent(
                id: EventID("context-tree"),
                evidenceID: EvidenceID("context-tree-evidence"),
                occurredAt: start.addingTimeInterval(60),
                observedAt: start.addingTimeInterval(60),
                source: .git,
                kind: .gitWorkingTreeChanged,
                repositoryID: repository.id,
                payload: ["clean": "false", "changedFiles": "3", "additions": "21", "deletions": "4"]
            )
            let treeEvidence = SourceEvidence(
                id: treeEvent.evidenceID,
                source: .git,
                ingestionPath: .fixture,
                sourceRecordID: treeEvent.id.rawValue,
                fingerprint: treeEvent.id.rawValue,
                occurredAt: treeEvent.occurredAt,
                observedAt: treeEvent.observedAt,
                adapterVersion: 1
            )
            _ = try await CollectionEngine(store: store, clock: FixedWallClock(start)).ingest(
                CollectionBatch(
                    sourceKey: "context",
                    sessions: [session],
                    records: [
                        CollectedRecord(evidence: evidence, event: event),
                        CollectedRecord(evidence: treeEvidence, event: treeEvent),
                    ]
                )
            )

            let cutoff = start.addingTimeInterval(1_800)
            let result = try ContextQueries().context(
                store: store,
                repository: "current",
                currentDirectory: copyPath.appending(path: "Sources"),
                since: start,
                cutoff: cutoff
            )

            #expect(result.repository.id == repository.id)
            #expect(result.activeHours == 1)
            #expect(result.llmTurns == 0)
            #expect(result.evidenceCount == 1)
            #expect(result.rendered.contains("1 clock hour(s)"))
            #expect(result.rendered.contains("3 changed files (+21/-4 uncommitted lines)"))

            let portfolio = try ContextQueries().portfolioContext(
                store: store,
                since: start,
                cutoff: cutoff,
                maximumCharacters: 4_000
            )
            #expect(portfolio.repositories.map(\.repository.id) == [repository.id])
            #expect(portfolio.rendered.contains("1 active project(s)"))
            #expect(portfolio.rendered.contains("Project: ContextKit"))
            #expect(portfolio.rendered.contains("Uncommitted: 3 files (+21/-4)"))

            let report = try await ReportGenerator().generate(
                store: store,
                range: DateInterval(start: start, duration: 3_600),
                cutoff: cutoff
            )
            #expect(report.state == .inProgress)
            #expect(report.evidenceIDs == [treeEvidence.id])
            #expect(report.summary.contains("remained in progress"))
            #expect(report.summary.contains("ContextKit"))
            #expect(!report.summary.contains("(s)"))
        }
    }

    @Test("Activity snapshot reports evidence hours, LLM turns, and commit totals")
    func activitySnapshot() async throws {
        try await withTemporaryStore { store in
            let start = Date(timeIntervalSince1970: 1_754_294_400)
            let sessionID = SessionID("snapshot-session")
            let session = ConversationSession(
                id: sessionID,
                source: .codex,
                sourceSessionID: "snapshot-session",
                startedAt: start,
                lastObservedAt: start.addingTimeInterval(1_800),
                state: .inProgress
            )
            let events = [
                lifecycleEvent(id: "snapshot-start", sessionID: sessionID, date: start, kind: .agentRunStarted, state: .inProgress),
                LedgerEvent(
                    id: EventID("snapshot-message"),
                    evidenceID: EvidenceID("evidence-snapshot-message"),
                    occurredAt: start.addingTimeInterval(60),
                    observedAt: start.addingTimeInterval(60),
                    source: .codex,
                    kind: .agentMessageObserved,
                    sessionID: sessionID,
                    payload: ["role": "user"]
                ),
                LedgerEvent(
                    id: EventID("snapshot-commit"),
                    evidenceID: EvidenceID("evidence-snapshot-commit"),
                    occurredAt: start.addingTimeInterval(900),
                    observedAt: start.addingTimeInterval(900),
                    source: .git,
                    kind: .gitCommitObserved,
                    payload: ["additions": "12", "deletions": "3"]
                ),
            ]
            let records = events.map { event in
                CollectedRecord(
                    evidence: SourceEvidence(
                        id: event.evidenceID,
                        source: event.source,
                        ingestionPath: .fixture,
                        sourceRecordID: event.id.rawValue,
                        fingerprint: event.id.rawValue,
                        occurredAt: event.occurredAt,
                        observedAt: event.observedAt,
                        adapterVersion: 1
                    ),
                    event: event
                )
            }
            _ = try await CollectionEngine(
                store: store,
                clock: FixedWallClock(start.addingTimeInterval(1_800))
            ).ingest(CollectionBatch(sourceKey: "snapshot", sessions: [session], records: records))

            let snapshot = try ActivityQueries().snapshot(
                store: store,
                range: DateInterval(start: start, duration: 3_600),
                cutoff: start.addingTimeInterval(1_800)
            )

            #expect(snapshot.activeHours == 1)
            #expect(snapshot.llmTurns == 1)
            #expect(snapshot.conversationMessages == 1)
            #expect(snapshot.evidenceCount == 2)
            #expect(snapshot.commits == 1)
            #expect(snapshot.additions == 12)
            #expect(snapshot.deletions == 3)
        }
    }

    @Test("Activity snapshots count equivalent message observations once")
    func duplicateMessageActivity() async throws {
        try await withTemporaryStore { store in
            let start = Date(timeIntervalSince1970: 1_754_294_400)
            let sessionID = SessionID("duplicate-activity-session")
            let session = ConversationSession(
                id: sessionID,
                source: .codex,
                sourceSessionID: sessionID.rawValue,
                startedAt: start,
                lastObservedAt: start,
                state: .completed
            )
            let messages = [
                ConversationMessage(
                    id: MessageID("duplicate-message-a"),
                    sessionID: sessionID,
                    role: .user,
                    occurredAt: start,
                    normalizedText: "Implement the same request",
                    fingerprint: "parser-a"
                ),
                ConversationMessage(
                    id: MessageID("duplicate-message-b"),
                    sessionID: sessionID,
                    sourceMessageID: "msg-source-id",
                    role: .user,
                    occurredAt: start,
                    normalizedText: "Implement the same request",
                    fingerprint: "parser-b"
                ),
            ]
            let records = messages.enumerated().map { index, message in
                let evidence = SourceEvidence(
                    id: EvidenceID("duplicate-activity-evidence-\(index)"),
                    source: .codex,
                    ingestionPath: .fixture,
                    sourceRecordID: "duplicate-record-\(index)",
                    fingerprint: "duplicate-record-\(index)",
                    occurredAt: start,
                    observedAt: start,
                    adapterVersion: 1
                )
                return CollectedRecord(
                    evidence: evidence,
                    event: LedgerEvent(
                        id: EventID("duplicate-activity-event-\(index)"),
                        evidenceID: evidence.id,
                        occurredAt: start,
                        observedAt: start,
                        source: .codex,
                        kind: .agentMessageObserved,
                        sessionID: sessionID,
                        payload: ["messageID": message.id.rawValue, "role": MessageRole.user.rawValue]
                    )
                )
            }
            _ = try await CollectionEngine(store: store).ingest(
                CollectionBatch(
                    sourceKey: "duplicate-activity",
                    sessions: [session],
                    messages: messages,
                    records: records
                ))

            let snapshot = try ActivityQueries().snapshot(
                store: store,
                range: DateInterval(start: start, duration: 3_600),
                cutoff: start.addingTimeInterval(3_600)
            )

            #expect(try store.counts().messages == 1)
            #expect(snapshot.llmTurns == 1)
            #expect(snapshot.conversationMessages == 1)
            #expect(snapshot.evidenceCount == 1)
        }
    }

    @Test("Unreachable commits remain auditable without inflating core activity")
    func unreachableCommitIsNotCoreActivity() async throws {
        try await withTemporaryStore { store in
            let start = Date(timeIntervalSince1970: 1_754_294_400)
            let repositoryID = RepositoryID("rewritten-activity-repo")
            try store.upsert(
                repository: Repository(
                    id: repositoryID,
                    displayName: "RewrittenActivity",
                    firstObservedAt: start,
                    lastObservedAt: start
                ),
                workingCopy: WorkingCopy(
                    id: WorkingCopyID("rewritten-activity-copy"),
                    repositoryID: repositoryID,
                    canonicalPath: "/tmp/RewrittenActivity",
                    firstObservedAt: start,
                    lastObservedAt: start
                )
            )
            try store.upsert(
                commit: GitCommit(
                    id: "rewritten-commit",
                    repositoryID: repositoryID,
                    hash: "rewritten",
                    authorTime: start.addingTimeInterval(60),
                    message: "Commit later removed by history rewrite",
                    additions: 20,
                    deletions: 4,
                    filesChanged: 2,
                    firstObservedAt: start,
                    lastObservedAt: start,
                    isReachable: false
                )
            )
            let event = LedgerEvent(
                id: EventID("rewritten-commit-event"),
                evidenceID: EvidenceID("rewritten-commit-evidence"),
                occurredAt: start.addingTimeInterval(60),
                observedAt: start.addingTimeInterval(60),
                source: .git,
                kind: .gitCommitObserved,
                repositoryID: repositoryID,
                payload: [
                    "hash": "rewritten",
                    "additions": "20",
                    "deletions": "4",
                    "filesChanged": "2",
                ]
            )
            _ = try store.ingest(
                evidence: SourceEvidence(
                    id: event.evidenceID,
                    source: .git,
                    ingestionPath: .fixture,
                    sourceRecordID: event.id.rawValue,
                    fingerprint: event.id.rawValue,
                    occurredAt: event.occurredAt,
                    observedAt: event.observedAt,
                    adapterVersion: 1
                ),
                event: event
            )

            let range = DateInterval(start: start, duration: 3_600)
            let snapshot = try ActivityQueries().snapshot(
                store: store,
                range: range,
                cutoff: range.end
            )
            let packet = try ReportGenerator().evidencePacket(
                store: store,
                range: range,
                cutoff: range.end
            )

            #expect(snapshot.evidenceCount == 0)
            #expect(snapshot.activeHours == 0)
            #expect(snapshot.commits == 0)
            #expect(packet.state == .noActivity)
            #expect(packet.events.isEmpty)
        }
    }

    @Test("Optional interval telemetry preserves parallel runtime math")
    func parallelIntervalMath() {
        let start = Date(timeIntervalSince1970: 1_754_294_400)
        let sessionA = SessionID("session-a")
        let sessionB = SessionID("session-b")
        let events = [
            lifecycleEvent(id: "a-start", sessionID: sessionA, date: start, kind: .agentRunStarted, state: .inProgress),
            lifecycleEvent(
                id: "b-start", sessionID: sessionB, date: start.addingTimeInterval(1_800), kind: .agentRunStarted, state: .inProgress),
            lifecycleEvent(
                id: "a-end", sessionID: sessionA, date: start.addingTimeInterval(3_600), kind: .agentRunFinished, state: .completed),
            lifecycleEvent(
                id: "b-end", sessionID: sessionB, date: start.addingTimeInterval(5_400), kind: .agentRunFinished, state: .completed),
        ]
        let deriver = IntervalDeriver()
        let intervals = deriver.derive(events: events, cutoff: start.addingTimeInterval(7_200))
        let summary = deriver.summarize(
            intervals,
            within: DateInterval(start: start, duration: 7_200)
        )

        #expect(intervals.count == 2)
        #expect(summary.agentSeconds == 7_200)
        #expect(summary.trackedSeconds == 5_400)
    }

    @Test("Batched snapshots ignore lifecycle-only telemetry")
    func batchedSnapshotCutoffs() async throws {
        try await withTemporaryStore { store in
            let dayOne = Date(timeIntervalSince1970: 1_754_284_800)
            let sessionID = SessionID("cross-day-session")
            let session = ConversationSession(
                id: sessionID,
                source: .codex,
                sourceSessionID: sessionID.rawValue,
                startedAt: dayOne.addingTimeInterval(23 * 3_600),
                lastObservedAt: dayOne.addingTimeInterval(25 * 3_600),
                state: .completed
            )
            let events = [
                lifecycleEvent(
                    id: "cross-day-start",
                    sessionID: sessionID,
                    date: dayOne.addingTimeInterval(23 * 3_600),
                    kind: .agentRunStarted,
                    state: .inProgress
                ),
                lifecycleEvent(
                    id: "cross-day-finish",
                    sessionID: sessionID,
                    date: dayOne.addingTimeInterval(25 * 3_600),
                    kind: .agentRunFinished,
                    state: .completed
                ),
            ]
            let records = events.map { event in
                CollectedRecord(
                    evidence: SourceEvidence(
                        id: event.evidenceID,
                        source: event.source,
                        ingestionPath: .fixture,
                        sourceRecordID: event.id.rawValue,
                        fingerprint: event.id.rawValue,
                        occurredAt: event.occurredAt,
                        observedAt: event.observedAt,
                        adapterVersion: 1
                    ),
                    event: event
                )
            }
            _ = try await CollectionEngine(
                store: store,
                clock: FixedWallClock(dayOne.addingTimeInterval(2 * 86_400))
            ).ingest(CollectionBatch(sourceKey: "cross-day", sessions: [session], records: records))

            let snapshots = try ActivityQueries().snapshots(
                store: store,
                ranges: [
                    DateInterval(start: dayOne, duration: 86_400),
                    DateInterval(start: dayOne.addingTimeInterval(86_400), duration: 86_400),
                ],
                cutoff: dayOne.addingTimeInterval(2 * 86_400)
            )

            #expect(snapshots.map(\.activeHours) == [0, 0])
            #expect(snapshots.map(\.evidenceCount) == [0, 0])
        }
    }

    @Test("A stale unmatched start does not manufacture historical active time")
    func staleUnmatchedStart() async throws {
        try await withTemporaryStore { store in
            let start = Date(timeIntervalSince1970: 1_754_284_800)
            let sessionID = SessionID("stale-session")
            let session = ConversationSession(
                id: sessionID,
                source: .codex,
                sourceSessionID: sessionID.rawValue,
                startedAt: start,
                lastObservedAt: start,
                state: .inProgress
            )
            let event = lifecycleEvent(
                id: "stale-start",
                sessionID: sessionID,
                date: start,
                kind: .agentRunStarted,
                state: .inProgress
            )
            let evidence = SourceEvidence(
                id: event.evidenceID,
                source: event.source,
                ingestionPath: .fixture,
                sourceRecordID: event.id.rawValue,
                fingerprint: event.id.rawValue,
                occurredAt: event.occurredAt,
                observedAt: event.observedAt,
                adapterVersion: 1
            )
            _ = try await CollectionEngine(
                store: store,
                clock: FixedWallClock(start.addingTimeInterval(4 * 86_400))
            ).ingest(
                CollectionBatch(
                    sourceKey: "stale-session",
                    sessions: [session],
                    records: [CollectedRecord(evidence: evidence, event: event)]
                )
            )

            let snapshot = try ActivityQueries().snapshot(
                store: store,
                range: DateInterval(start: start.addingTimeInterval(3 * 86_400), duration: 86_400),
                cutoff: start.addingTimeInterval(4 * 86_400)
            )

            #expect(snapshot.activeHours == 0)
            #expect(snapshot.evidenceCount == 0)
        }
    }

    @Test("An unmatched start remains honestly in progress through the cutoff")
    func openInterval() {
        let start = Date(timeIntervalSince1970: 1_754_294_400)
        let event = lifecycleEvent(
            id: "open",
            sessionID: SessionID("session"),
            date: start,
            kind: .agentRunStarted,
            state: .inProgress
        )
        let interval = IntervalDeriver().derive(
            events: [event],
            cutoff: start.addingTimeInterval(900)
        ).first

        #expect(interval?.duration == 900)
        #expect(interval?.state == .inProgress)
        #expect(interval?.sourceEventIDs == [event.id])
    }

    @Test("JSONL reader leaves an incomplete tail for retry")
    func partialJSONLTail() throws {
        let fixture = fixtureURL("Claude/session-partial-tail.jsonl")
        let result = try JSONLReader().read(fixture)

        #expect(!result.lines.isEmpty)
        #expect(result.ignoredPartialTailBytes > 0)
        let size = try FileManager.default.attributesOfItem(atPath: fixture.path)[.size] as? NSNumber
        #expect(result.cursor.offset < (size?.uint64Value ?? 0))
    }

    @Test("Bounded JSONL reading can skip an oversized record and continue")
    func oversizedJSONLRecord() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appending(path: "oversized.jsonl")
            let oversized = #"{"large":""# + String(repeating: "x", count: 100) + #""}"#
            try Data("\(oversized)\n{\"record\":2}\n".utf8).write(to: file)

            #expect(throws: JSONLReaderError.lineTooLarge(limit: 32)) {
                try JSONLReader(maximumLineBytes: 32, chunkBytes: 8).read(file)
            }
            let result = try JSONLReader(
                maximumLineBytes: 32,
                chunkBytes: 8,
                skipOversizedLines: true
            ).read(file)

            #expect(result.oversizedLineCount == 1)
            #expect(result.processedRecordCount == 2)
            #expect(result.lines.map { String(decoding: $0, as: UTF8.self) } == ["{\"record\":2}"])
            #expect(!result.hasMoreData)
        }
    }

    @Test("JSONL reader bounds a batch by bytes as well as records")
    func byteBoundedJSONLBatch() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appending(path: "byte-bounded.jsonl")
            let line = "{\"payload\":\"1234567890\"}\n"
            try Data(String(repeating: line, count: 20).utf8).write(to: file)

            let reader = JSONLReader(chunkBytes: 32)
            let first = try reader.read(file, maximumBytes: 80)
            #expect(first.hasMoreData)
            #expect(first.processedBytes >= 80)
            #expect(first.processedBytes < 80 + line.utf8.count)

            let second = try reader.read(file, after: first.cursor)
            #expect(second.lines.count + first.lines.count == 20)
            #expect(!second.hasMoreData)
        }
    }

    @Test("JSONL cursors recover from file replacement and in-place truncation")
    func jsonlRotationRecovery() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appending(path: "session.jsonl")
            try Data("{\"record\":1}\n{\"record\":2}\n".utf8).write(to: file)
            let reader = JSONLReader()
            let initial = try reader.read(file)
            #expect(initial.lines.count == 2)

            try Data("{\"record\":3}\n".utf8).write(to: file, options: .atomic)
            let replaced = try reader.read(file, after: initial.cursor)
            #expect(replaced.lines.map { String(decoding: $0, as: UTF8.self) } == ["{\"record\":3}"])

            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data("{}\n".utf8))
            try handle.close()
            let truncated = try reader.read(file, after: replaced.cursor)
            #expect(truncated.lines.map { String(decoding: $0, as: UTF8.self) } == ["{}"])
        }
    }

    @Test("Codex fixture normalizes session, messages, and lifecycle")
    func codexFixtureParser() throws {
        let lines = try JSONLReader().read(fixtureURL("Codex/runtime-events-0.147.0.jsonl")).lines
        let observedAt = Date(timeIntervalSince1970: 1_754_294_500)
        let result = try CodexConversationParser().parse(
            lines: lines,
            fallbackSessionID: "fallback",
            observedAt: observedAt
        )

        #expect(result.session.source == .codex)
        #expect(result.session.sourceSessionID == "01900000-0000-7000-8000-000000000001")
        #expect(result.session.state == .completed)
        #expect(result.messages.count == 2)
        #expect(result.records.compactMap(\.event.state) == [.inProgress, .completed])
    }

    @Test("Codex terminal fixture distinguishes interruption and failure")
    func codexTerminalFixture() throws {
        let lines = try JSONLReader().read(fixtureURL("Codex/terminal-failures-0.147.0.jsonl")).lines
        let result = try CodexConversationParser().parse(
            lines: lines,
            fallbackSessionID: "terminal-fixture",
            observedAt: Date(timeIntervalSince1970: 1_754_294_500)
        )

        #expect(result.session.state == .failed)
        #expect(result.records.map(\.event.state) == [.interrupted, .failed])
    }

    @Test("Claude fixture ignores private payloads and keeps honest open state")
    func claudeFixtureParser() throws {
        let lines = try JSONLReader().read(fixtureURL("Claude/session-2.1.29.jsonl")).lines
        let result = try ClaudeConversationParser().parse(
            lines: lines,
            fallbackSessionID: "fallback",
            observedAt: Date(timeIntervalSince1970: 1_754_294_500)
        )

        #expect(result.session.source == .claude)
        #expect(result.session.sourceSessionID == "01900000-0000-7000-8000-000000000001")
        #expect(result.session.state == .inProgress)
        #expect(result.messages.count == 4)
        #expect(result.messages.allSatisfy { !$0.normalizedText.contains("<fixture:data>") })
        #expect(result.records.compactMap(\.event.state) == [.inProgress, .completed, .inProgress])
    }

    @Test("Claude terminal API error is a failed lifecycle observation")
    func claudeTerminalFixture() throws {
        let lines = try JSONLReader().read(fixtureURL("Claude/terminal-failures-2.1.29.jsonl")).lines
        let result = try ClaudeConversationParser().parse(
            lines: lines,
            fallbackSessionID: "fallback",
            observedAt: Date(timeIntervalSince1970: 1_754_294_500)
        )

        #expect(result.session.state == .failed)
        #expect(result.records.map(\.event.state) == [.failed])
        #expect(result.messages.isEmpty)
    }

    @Test("Claude Desktop Code audit history imports through its own bounded source surface")
    func claudeDesktopFixture() async throws {
        try await withTemporaryStoreAndRoot { store, root in
            let sessionRoot = root.appending(path: "workspace/local_fixture")
            try FileManager.default.createDirectory(
                at: sessionRoot,
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(
                at: fixtureURL("ClaudeDesktop/local_fixture/audit.jsonl"),
                to: sessionRoot.appending(path: "audit.jsonl")
            )
            try FileManager.default.copyItem(
                at: fixtureURL("ClaudeDesktop/local_fixture.json"),
                to: sessionRoot.deletingLastPathComponent().appending(path: "local_fixture.json")
            )
            let source = ConversationDirectorySource(provider: .claudeDesktop, root: root)
            let now = Date(timeIntervalSince1970: 1_785_888_000)
            let engine = CollectionEngine(store: store, clock: FixedWallClock(now))

            let first = try await engine.collect(from: source)
            let second = try await engine.collect(from: source)
            let session = try #require(try store.sessions(limit: 10).first)
            let messages = try store.messages(sessionID: session.id, limit: 10)

            #expect(first.insertedEvents == 4)
            #expect(second.receivedRecords == 0)
            #expect(session.sourceSessionID == "desktop-session-fixture")
            #expect(session.workingDirectory == "/workspace/trackify")
            #expect(session.sourceVersion == "claude-desktop-code-audit-v1")
            #expect(messages.map(\.role) == [.user, .assistant])
            #expect(messages.allSatisfy { !$0.normalizedText.contains("private tool output") })
            #expect(
                try store.search("fixture-hmac", limit: 20).isEmpty,
                "Audit authentication material must never enter the ledger"
            )
        }
    }

    @Test("Conversation file sources import fixtures incrementally and idempotently")
    func conversationFileSources() async throws {
        try await withTemporaryStore { store in
            let now = Date(timeIntervalSince1970: 1_754_294_500)
            let engine = CollectionEngine(store: store, clock: FixedWallClock(now))

            let codex = CodexJSONLSource(fileURL: fixtureURL("Codex/runtime-events-0.147.0.jsonl"))
            let claude = ClaudeJSONLSource(fileURL: fixtureURL("Claude/session-2.1.29.jsonl"))
            let codexFirst = try await engine.collect(from: codex)
            let claudeFirst = try await engine.collect(from: claude)
            let codexSecond = try await engine.collect(from: codex)
            let claudeSecond = try await engine.collect(from: claude)

            #expect(codexFirst.insertedEvents == 4)
            #expect(claudeFirst.insertedEvents == 7)
            #expect(codexSecond.receivedRecords == 0)
            #expect(claudeSecond.receivedRecords == 0)
            #expect(try store.counts().sessions == 2)
            #expect(try store.counts().messages == 6)
            #expect(try store.counts().events == 11)
        }
    }

    @Test("Directory source streams a large history through bounded batches")
    func conversationDirectoryBatches() async throws {
        try await withTemporaryStoreAndRoot { store, root in
            let fixture = fixtureURL("Claude/session-2.1.29.jsonl")
            let destination = root.appending(path: "project/session.jsonl")
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: fixture, to: destination)

            let source = ConversationDirectorySource(
                provider: .claude,
                root: root,
                maximumRecordsPerCollection: 3
            )
            let engine = CollectionEngine(
                store: store,
                clock: FixedWallClock(Date(timeIntervalSince1970: 1_754_294_500))
            )

            var batches = 0
            while batches < 20 {
                let summary = try await engine.collect(from: source)
                batches += 1
                if summary.receivedRecords == 0,
                    try store.cursor(for: source.sourceKey) != nil,
                    batches > 6
                {
                    break
                }
            }

            #expect(batches > 6)
            #expect(try store.counts().sessions == 1)
            #expect(try store.counts().messages == 4)
            #expect(try store.counts().events == 7)
        }
    }

    @Test("Conversation collection prioritizes recently modified caches")
    func conversationDirectoryPrioritizesRecentFiles() async throws {
        try await withTemporaryStoreAndRoot { _, root in
            let old = root.appending(path: "old.jsonl")
            let recent = root.appending(path: "recent.jsonl")
            let rangeStart = Date(timeIntervalSince1970: 1_785_801_600)
            try FileManager.default.copyItem(
                at: fixtureURL("Codex/runtime-events-0.147.0.jsonl"),
                to: old
            )
            let recentLines = (0..<4).map {
                #"{"timestamp":"2026-08-06T09:00:0\#($0).000Z","type":"world_state","payload":{}}"#
            }
            try Data((recentLines.joined(separator: "\n") + "\n").utf8).write(to: recent)
            try FileManager.default.setAttributes(
                [.modificationDate: rangeStart.addingTimeInterval(100)],
                ofItemAtPath: old.path
            )
            try FileManager.default.setAttributes(
                [.modificationDate: rangeStart.addingTimeInterval(200)],
                ofItemAtPath: recent.path
            )

            let source = ConversationDirectorySource(
                provider: .codex,
                root: root,
                maximumRecordsPerCollection: 4
            )
            let request = CollectionRequest(
                range: DateInterval(
                    start: rangeStart,
                    duration: 86_400
                ),
                cutoff: Date(timeIntervalSince1970: 1_785_888_000)
            )
            let first = try await source.collect(
                request: request,
                cursor: nil
            )
            let cursor = try JSONDecoder().decode(
                ConversationDirectoryCursor.self,
                from: try #require(first.nextCursor)
            )
            let second = try await source.collect(request: request, cursor: first.nextCursor)

            #expect(Set(cursor.files.keys) == ["recent.jsonl"])
            #expect(first.processedSourceRecords == 4)
            #expect(first.records.isEmpty)
            #expect(second.processedSourceRecords == 4)
            #expect(!second.records.isEmpty)
        }
    }

    @Test("Legacy conversation cursors replay once when normalized evidence advances")
    func legacyConversationCursorReplay() async throws {
        struct LegacyCursor: Encodable {
            let files: [String: JSONLFileCursor]
        }

        try await withTemporaryStoreAndRoot { store, root in
            let history = root.appending(path: "session.jsonl")
            try FileManager.default.copyItem(
                at: fixtureURL("Codex/runtime-events-0.147.0.jsonl"),
                to: history
            )
            let source = ConversationDirectorySource(provider: .codex, root: root)
            let completeBatch = try await source.collect(
                request: CollectionRequest(cutoff: Date(timeIntervalSince1970: 1_785_888_000)),
                cursor: nil
            )
            let completeCursor = try JSONDecoder().decode(
                ConversationDirectoryCursor.self,
                from: try #require(completeBatch.nextCursor)
            )
            try store.setCursor(
                JSONEncoder().encode(LegacyCursor(files: completeCursor.files)),
                for: source.sourceKey,
                at: Date()
            )

            let summary = try await CollectionEngine(
                store: store,
                clock: FixedWallClock(Date(timeIntervalSince1970: 1_785_888_000))
            ).collect(from: source)
            #expect(summary.insertedEvents == 4)
            let upgradedData = try #require(try store.cursor(for: source.sourceKey))
            let upgraded = try JSONDecoder().decode(
                ConversationDirectoryCursor.self,
                from: upgradedData
            )
            #expect(upgraded.adapterVersion == 5)
        }
    }

    @Test("Persisted internal report sessions are excluded as feedback-loop defense")
    func internalReportSessionExclusion() async throws {
        try await withTemporaryStoreAndRoot { store, root in
            let history = root.appending(path: "internal.jsonl")
            let lines = [
                #"{"timestamp":"2026-08-04T09:00:00.000Z","type":"session_meta","payload":{"id":"internal-report","cwd":"/tmp/trackify-codex-report-fixture"}}"#,
                #"{"timestamp":"2026-08-04T09:00:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"internal-turn"}}"#,
            ]
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: history)
            let summary = try await CollectionEngine(
                store: store,
                clock: FixedWallClock(Date(timeIntervalSince1970: 1_785_888_000))
            ).collect(from: ConversationDirectorySource(provider: .codex, root: root))

            #expect(summary.receivedSessions == 0)
            #expect(summary.receivedMessages == 0)
            #expect(summary.receivedRecords == 0)
            #expect(try store.counts().events == 0)
        }
    }

    @Test("Conversation backfill uses its date range even after the live cursor reached EOF")
    func conversationBackfillRangeAndCursor() async throws {
        try await withTemporaryStoreAndRoot { store, root in
            let sessions = root.appending(path: ".codex/sessions")
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            let history = sessions.appending(path: "session.jsonl")
            try FileManager.default.copyItem(
                at: fixtureURL("Codex/runtime-events-0.147.0.jsonl"),
                to: history
            )

            let liveSource = ConversationDirectorySource(provider: .codex, root: sessions)
            let liveBatch = try await liveSource.collect(
                request: CollectionRequest(cutoff: Date(timeIntervalSince1970: 1_785_888_000)),
                cursor: nil
            )
            let liveCursor = try #require(liveBatch.nextCursor)
            try store.setCursor(liveCursor, for: liveSource.sourceKey, at: Date())

            let coordinator = LocalCollectionCoordinator(
                clock: FixedWallClock(Date(timeIntervalSince1970: 1_785_888_000))
            )
            let inactiveRange = DateInterval(
                start: Date(timeIntervalSince1970: 1_785_715_200),
                duration: 86_400
            )
            _ = try await coordinator.collect(
                store: store,
                gitRoots: [],
                includeCodex: true,
                includeClaude: false,
                range: inactiveRange,
                homeDirectory: root
            )
            #expect(try store.counts().events == 0)

            let activeRange = DateInterval(
                start: Date(timeIntervalSince1970: 1_785_801_600),
                duration: 86_400
            )
            _ = try await coordinator.collect(
                store: store,
                gitRoots: [],
                includeCodex: true,
                includeClaude: false,
                range: activeRange,
                homeDirectory: root
            )
            #expect(try store.counts().sessions == 1)
            #expect(try store.counts().events == 4)
            #expect(try store.cursor(for: liveSource.sourceKey) == liveCursor)

            _ = try await coordinator.collect(
                store: store,
                gitRoots: [],
                includeCodex: true,
                includeClaude: false,
                range: activeRange,
                homeDirectory: root
            )
            #expect(try store.counts().events == 4)
        }
    }

    @Test("Bounded conversation backfill seeds forward collection without replaying older files")
    func boundedBackfillSeedsForwardCursor() async throws {
        try await withTemporaryStoreAndRoot { store, root in
            let sessions = root.appending(path: ".codex/sessions")
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            let old = sessions.appending(path: "rollout-2026-07-01-old.jsonl")
            let recent = sessions.appending(path: "rollout-2026-08-07-recent.jsonl")
            try Data(
                """
                {"timestamp":"2026-07-01T08:00:00.000Z","type":"session_meta","payload":{"id":"old-session","cwd":"/workspace/old"}}
                {"timestamp":"2026-07-01T08:00:01.000Z","type":"event_msg","payload":{"type":"user_message","turn_id":"old-turn","message":"old work"}}

                """.utf8
            ).write(to: old)
            try Data(
                """
                {"timestamp":"2026-08-07T08:00:00.000Z","type":"session_meta","payload":{"id":"recent-session","cwd":"/workspace/recent"}}
                {"timestamp":"2026-08-07T08:00:01.000Z","type":"event_msg","payload":{"type":"user_message","turn_id":"recent-turn","message":"recent work"}}

                """.utf8
            ).write(to: recent)
            let range = DateInterval(
                start: try #require(ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z")),
                end: try #require(ISO8601DateFormatter().date(from: "2026-08-08T00:00:00Z")))
            try FileManager.default.setAttributes(
                [.modificationDate: range.start.addingTimeInterval(-1)],
                ofItemAtPath: old.path)
            try FileManager.default.setAttributes(
                [.modificationDate: range.start.addingTimeInterval(1)],
                ofItemAtPath: recent.path)

            let scoped = ConversationDirectorySource(
                provider: .codex, root: sessions,
                cursorScope: LocalCollectionCoordinator.backfillCursorScope(range))
            let engine = CollectionEngine(store: store, clock: FixedWallClock(range.end))
            while try await engine.collect(from: scoped, range: range).processedSourceRecords > 0 {}
            let boundedCursor = try #require(try store.cursor(for: scoped.sourceKey))
            let seed = try scoped.makeForwardCursorSeed(from: boundedCursor)
            try store.setCursor(seed.cursor, for: seed.sourceKey, at: range.end)

            let appended =
                #"{"timestamp":"2026-08-07T09:00:01.000Z","type":"event_msg","payload":{"type":"user_message","turn_id":"new-turn","message":"new work"}}"#
                + "\n"
            let handle = try FileHandle(forWritingTo: old)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(appended.utf8))
            try handle.close()

            let forward = ConversationDirectorySource(provider: .codex, root: sessions)
            let summary = try await engine.collect(from: forward)
            #expect(summary.receivedMessages == 1)
            #expect(summary.readMetrics.recordsObserved == 1)
            #expect(try store.counts().messages == 2)
            #expect(seed.audit.candidatesConsidered == 2)
            #expect(seed.audit.bytesRead == 0)
        }
    }

    @Test("Hook backfill accepts only records inside its requested interval")
    func hookBackfillRange() async throws {
        try await withTemporaryStoreAndRoot { _, root in
            let inbox = root.appending(path: "hooks.jsonl")
            let writer = HookInboxWriter()
            let start = Date(timeIntervalSince1970: 1_786_089_600)
            try writer.append(
                HookEnvelope(
                    source: .codex, sessionID: "old", turnID: "old", phase: .completed,
                    occurredAt: start.addingTimeInterval(-1), workingDirectory: nil),
                to: inbox)
            try writer.append(
                HookEnvelope(
                    source: .codex, sessionID: "current", turnID: "current",
                    phase: .completed, occurredAt: start.addingTimeInterval(1),
                    workingDirectory: nil),
                to: inbox)
            let batch = try await HookInboxSource(fileURL: inbox).collect(
                request: CollectionRequest(
                    range: DateInterval(start: start, duration: 3_600),
                    cutoff: start.addingTimeInterval(3_600)),
                cursor: nil)
            #expect(batch.records.count == 1)
            #expect(batch.readMetrics.recordsObserved == 2)
            #expect(batch.readMetrics.recordsAccepted == 1)
        }
    }

    @Test("Discovery finds repositories and skips dependency trees")
    func repositoryDiscovery() throws {
        try withTemporaryDirectory { directory in
            let visible = directory.appending(path: "Visible")
            let ignored = directory.appending(path: "node_modules/Dependency")
            try makeGitRepository(at: visible)
            try makeGitRepository(at: ignored)

            let candidates = try RepositoryDiscovery().discover(under: directory)
            #expect(candidates.map(\.path) == [visible.standardizedFileURL])
            #expect(candidates.first?.kind == .regular)
        }
    }

    @Test("Git inspection reads branch, changes, and line counts without a shell")
    func gitInspection() throws {
        try withTemporaryDirectory { directory in
            let repository = directory.appending(path: "Repository")
            try makeGitRepository(at: repository)
            try Data("second line\n".utf8).append(to: repository.appending(path: "README.md"))

            let inspection = try GitClient().inspect(RepositoryCandidate(path: repository, kind: .regular))
            #expect(inspection.root.path == repository.standardizedFileURL.path)
            #expect(inspection.state.branch == "main")
            #expect(inspection.state.headCommit != nil)
            #expect(inspection.state.changedFiles == ["README.md"])
            #expect(inspection.state.additions == 1)
            #expect(inspection.state.deletions == 0)
            #expect(!inspection.state.isClean)

            let commits = try GitClient().commits(at: repository, in: nil)
            #expect(commits.count == 1)
            #expect(commits.first?.message == "Initial commit")
            #expect(commits.first?.additions == 1)
        }
    }

    @Test("Git adapter imports real repository state idempotently")
    func gitAdapter() async throws {
        try await withTemporaryStoreAndRoot { store, root in
            let repository = root.appending(path: "Repository")
            try makeGitRepository(at: repository)
            let now = Date(timeIntervalSince1970: 1_754_294_400)
            let engine = CollectionEngine(store: store, clock: FixedWallClock(now))
            let adapter = GitSourceAdapter(root: root)

            let first = try await engine.collect(from: adapter)
            let second = try await engine.collect(from: adapter)

            #expect(first.receivedCommits == 1)
            #expect(first.insertedEvents == 3)
            #expect(second.insertedEvents == 0)
            #expect(try store.counts().repositories == 1)
            #expect(try store.counts().events == 3)
        }
    }

    @Test("Git backfill honors its date range independently from the live cursor")
    func gitRangeBackfill() async throws {
        try await withTemporaryStoreAndRoot { store, root in
            let repository = root.appending(path: "Repository")
            try makeGitRepository(at: repository, commitDate: "2026-08-03T09:00:00Z")
            let dayOne = try #require(try? Date("2026-08-03T00:00:00Z", strategy: .iso8601))
            let dayTwo = try #require(try? Date("2026-08-04T00:00:00Z", strategy: .iso8601))
            let dayThree = try #require(try? Date("2026-08-05T00:00:00Z", strategy: .iso8601))
            let engine = CollectionEngine(store: store, clock: FixedWallClock(dayThree))
            let adapter = GitSourceAdapter(root: root)

            let outside = try await engine.collect(
                from: adapter,
                range: DateInterval(start: dayTwo, end: dayThree)
            )
            let inside = try await engine.collect(
                from: adapter,
                range: DateInterval(start: dayOne, end: dayTwo)
            )
            let repeated = try await engine.collect(
                from: adapter,
                range: DateInterval(start: dayOne, end: dayTwo)
            )

            #expect(outside.receivedCommits == 0)
            #expect(inside.receivedCommits == 1)
            #expect(repeated.insertedEvents == 0)
            #expect(try store.counts().commits == 1)
        }
    }

    @Test("Git working-tree transitions retain repeated states without noisy unchanged polls")
    func gitWorkingTreeTransitions() async throws {
        try await withTemporaryStoreAndRoot { store, root in
            let repository = root.appending(path: "Repository")
            try makeGitRepository(at: repository)
            let readme = repository.appending(path: "README.md")
            let clock = MutableWallClock(Date(timeIntervalSince1970: 1_754_294_400))
            let engine = CollectionEngine(store: store, clock: clock)
            let adapter = GitSourceAdapter(root: root)

            _ = try await engine.collect(from: adapter)
            clock.advance(by: 60)
            try Data("first line\nchanged\n".utf8).write(to: readme)
            _ = try await engine.collect(from: adapter)
            clock.advance(by: 60)
            _ = try await engine.collect(from: adapter)
            clock.advance(by: 60)
            try Data("first line\n".utf8).write(to: readme)
            _ = try await engine.collect(from: adapter)
            clock.advance(by: 60)
            try Data("first line\nchanged\n".utf8).write(to: readme)
            _ = try await engine.collect(from: adapter)

            let transitions = try store.events(
                from: Date(timeIntervalSince1970: 1_754_294_400),
                through: clock.now()
            ).filter { $0.kind == .gitWorkingTreeChanged }
            #expect(transitions.count == 4)
            #expect(transitions.map { $0.payload["clean"] } == ["true", "false", "true", "false"])
            #expect(transitions.map { $0.payload["baseline"] } == ["true", "false", "false", "false"])
            #expect(Set(transitions.map(\.id)).count == 4)
        }
    }

    @Test("Git cursor remains compatible with the pre-transition-revision format")
    func legacyGitCursor() throws {
        struct LegacyCursor: Encodable {
            let lastCollectedAt: Date
            let lastFullHistoryAt: Date
        }

        let now = Date(timeIntervalSince1970: 1_754_294_400)
        let data = try JSONEncoder().encode(
            LegacyCursor(lastCollectedAt: now, lastFullHistoryAt: now)
        )
        let cursor = try JSONDecoder().decode(GitSourceCursor.self, from: data)

        #expect(cursor.lastCollectedAt == now)
        #expect(cursor.lastFullHistoryAt == now)
        #expect(cursor.stateFingerprints.isEmpty)
        #expect(cursor.stateRevisions.isEmpty)
    }

    @Test("Collection persists records before advancing its cursor")
    func collectionAndCursor() async throws {
        try await withTemporaryStore { store in
            let now = Date(timeIntervalSince1970: 1_754_294_400)
            let adapter = StubAdapter(now: now)
            let engine = CollectionEngine(store: store, clock: FixedWallClock(now))

            let first = try await engine.collect(from: adapter)
            let second = try await engine.collect(from: adapter)

            #expect(first.insertedEvents == 1)
            #expect(second.insertedEvents == 0)
            #expect(try store.cursor(for: adapter.sourceKey) == Data("next".utf8))
            #expect(try store.counts().events == 1)
        }
    }

    @Test("Two-day simulation is deterministic and isolated")
    func simulation() async throws {
        try await withTemporaryStore { store in
            let start = Date(timeIntervalSince1970: 1_754_294_400)
            let simulation = FoundationSimulation()
            let first = try await simulation.run(store: store, start: start)
            let second = try await simulation.run(store: store, start: start)

            #expect(first.generatedEvents == 9)
            #expect(first.counts.events == 9)
            #expect(first.counts.repositories == 2)
            #expect(first.counts.commits == 2)
            #expect(second.counts.events == 9)
            #expect(first.startedAt == start)
            #expect(first.endedAt == start.addingTimeInterval(172_800))
            #expect(first.days.count == 2)
            #expect(first.days[0].activeHours == 3)
            #expect(first.days[0].llmTurns == 2)
            #expect(first.days[0].conversationMessages == 4)
            #expect(first.days[0].evidenceCount == 5)
            #expect(first.days[0].commits == 1)
            #expect(first.days[1].activeHours == 3)
            #expect(first.days[1].llmTurns == 2)
            #expect(first.days[1].conversationMessages == 3)
            #expect(first.days[1].evidenceCount == 4)
            #expect(first == second)

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
            let dashboard = try ActivityQueries().dashboard(
                store: store,
                range: DateInterval(start: start.addingTimeInterval(86_400), duration: 86_400),
                cutoff: first.endedAt,
                calendar: calendar,
                activeDayWindow: 14
            )
            #expect(dashboard.comparison.activeDays == 1)
            #expect(dashboard.comparison.activeHours.movingAverage == 3)
            #expect(dashboard.comparison.activeHours.percentChange == 0)
        }
    }

    @Test("Showcase simulation exercises rich history and unfinished work")
    func showcaseSimulation() async throws {
        try await withTemporaryStore { store in
            let start = Date(timeIntervalSince1970: 1_754_294_400)
            let result = try await ShowcaseSimulation().run(store: store, start: start, days: 12)

            #expect(result.days.count == 12)
            #expect(result.counts.repositories == 4)
            #expect(result.counts.events > 40)
            #expect(result.counts.messages > 20)
            #expect(try store.discoveryRoots().map(\.displayName) == ["Work", "Personal"])
            #expect(try store.reports(overlapping: DateInterval(start: start, end: result.endedAt)).count > 8)
            #expect(try store.reports(overlapping: DateInterval(start: start, end: result.endedAt)).contains { $0.state == .inProgress })
            #expect(result.days.contains { $0.evidenceCount == 0 })
            #expect(result.days.contains { $0.repositoryIDs.count > 1 })
        }
    }
}

private struct StubAdapter: SourceAdapter {
    let sourceKey = "stub"
    let now: Date

    func collect(request: CollectionRequest, cursor: Data?) async throws -> CollectionBatch {
        let evidence = SourceEvidence(
            id: EvidenceID("stub-evidence"),
            source: .simulation,
            ingestionPath: .fixture,
            sourceRecordID: "stub-record",
            fingerprint: "stub-fingerprint",
            occurredAt: now,
            observedAt: request.cutoff,
            adapterVersion: 1
        )
        let event = LedgerEvent(
            id: EventID("stub-event"),
            evidenceID: evidence.id,
            occurredAt: now,
            observedAt: request.cutoff,
            source: .simulation,
            kind: .agentRunStarted,
            state: .inProgress
        )
        return CollectionBatch(
            sourceKey: sourceKey,
            records: [CollectedRecord(evidence: evidence, event: event)],
            nextCursor: Data("next".utf8)
        )
    }
}

private struct StubSummaryRunner: InputCommandRunning {
    let provider: String
    var evidenceAliases = ["provider-event"]

    func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        input: Data,
        outputLimit: Int
    ) throws -> ProcessOutput {
        guard environment?["TRACKIFY_INTERNAL_RUN"] == "1", !input.isEmpty else {
            return ProcessOutput(status: 2, data: Data("missing marker".utf8))
        }
        let evidence = evidenceAliases.map { "\"\($0)\"" }.joined(separator: ",")
        let response = Data(
            "{\"summary\":\"\(provider == "codex" ? "Codex" : "Claude") summary\",\"topics\":[],\"evidenceAliases\":[\(evidence)]}"
                .utf8)
        if provider == "codex",
            let index = arguments.firstIndex(of: "--output-last-message"),
            arguments.indices.contains(index + 1)
        {
            try response.write(to: URL(filePath: arguments[index + 1]))
            return ProcessOutput(status: 0, data: Data())
        }
        let envelope = Data("{\"structured_output\":\(String(decoding: response, as: UTF8.self))}".utf8)
        return ProcessOutput(status: 0, data: envelope)
    }
}

private struct FailingSummaryRunner: InputCommandRunning {
    func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        input: Data,
        outputLimit: Int
    ) throws -> ProcessOutput {
        ProcessOutput(status: 9, data: Data("private provider output".utf8))
    }
}

private struct ClassifiedFailureRunner: InputCommandRunning {
    let output: String

    func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        input: Data,
        outputLimit: Int
    ) throws -> ProcessOutput {
        ProcessOutput(status: 1, data: Data(output.utf8))
    }
}

private struct AlwaysFailSummaryProvider: SummaryProvider {
    let id = "always-fail"
    let model = "test"

    func summarize(_ packet: ReportEvidencePacket) async throws -> ProviderSummary {
        throw SummaryProviderError.processFailed(provider: id, status: 9)
    }
}

private struct StubCommandRunner: CommandRunning {
    let status: Int32

    func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        outputLimit: Int
    ) throws -> ProcessOutput {
        ProcessOutput(status: status, data: Data())
    }
}

private final class InvocationCountingRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var invocationCount: Int {
        lock.withLock { count }
    }

    func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        outputLimit: Int
    ) throws -> ProcessOutput {
        lock.withLock { count += 1 }
        return ProcessOutput(status: 0, data: Data())
    }
}

private func withTemporaryStore(
    _ body: (LedgerStore) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "trackify-engine-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(LedgerStore(databaseURL: directory.appending(path: "ledger.sqlite")))
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "trackify-git-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

private func withTemporaryStoreAndRoot(
    _ body: (LedgerStore, URL) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "trackify-git-store-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appending(path: "root", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try LedgerStore(databaseURL: directory.appending(path: "data/ledger.sqlite"))
    try await body(store, root)
}

private func makeGitRepository(at url: URL, commitDate: String? = nil) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let runner = ProcessRunner()
    let git = URL(filePath: "/usr/bin/git")
    var environment = [
        "HOME": FileManager.default.temporaryDirectory.path,
        "PATH": "/usr/bin:/bin",
        "GIT_AUTHOR_NAME": "Trackify Test",
        "GIT_AUTHOR_EMAIL": "trackify@example.invalid",
        "GIT_COMMITTER_NAME": "Trackify Test",
        "GIT_COMMITTER_EMAIL": "trackify@example.invalid",
    ]
    if let commitDate {
        environment["GIT_AUTHOR_DATE"] = commitDate
        environment["GIT_COMMITTER_DATE"] = commitDate
    }

    func run(_ arguments: [String]) throws {
        let output = try runner.run(
            executable: git,
            arguments: arguments,
            workingDirectory: url,
            environment: environment,
            outputLimit: 1_024 * 1_024
        )
        guard output.status == 0 else {
            throw ProcessRunnerError.failed(executable: git.path, status: output.status, output: output.utf8)
        }
    }

    try run(["init", "--initial-branch=main"])
    try Data("first line\n".utf8).write(to: url.appending(path: "README.md"))
    try run(["add", "README.md"])
    try run(["commit", "-m", "Initial commit"])
}

extension Data {
    fileprivate func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}

private func fixtureURL(_ relativePath: String) -> URL {
    URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/\(relativePath)")
}

private func lifecycleEvent(
    id: String,
    sessionID: SessionID,
    date: Date,
    kind: EventKind,
    state: ObservedState
) -> LedgerEvent {
    LedgerEvent(
        id: EventID(id),
        evidenceID: EvidenceID("evidence-\(id)"),
        occurredAt: date,
        observedAt: date,
        source: .codex,
        kind: kind,
        sessionID: sessionID,
        state: state
    )
}
