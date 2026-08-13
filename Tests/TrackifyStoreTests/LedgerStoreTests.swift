import Foundation
import GRDB
import Testing
import TrackifyDomain

@testable import TrackifyStore

@Suite("Ledger store")
struct LedgerStoreTests {
    @Test("Interrupted summary runs recover to an explicit terminal state")
    func interruptedSummaryRunRecovery() throws {
        try withTemporaryStore { store in
            let started = Date(timeIntervalSince1970: 1_754_294_400)
            let run = SummaryRun(
                id: SummaryRunID("interrupted-summary"), kind: .segment,
                periodStart: started, periodEnd: started.addingTimeInterval(1_800),
                selectionMode: .codex, requestedProvider: .codex,
                effectiveProvider: .codex, sourceFingerprint: "source",
                queuedAt: started, startedAt: started, state: .running)
            try store.save(summaryRun: run)

            let finished = started.addingTimeInterval(60)
            let recovered = try store.recoverInterruptedSummaryRuns(at: finished)

            #expect(recovered.count == 1)
            #expect(recovered[0].state == .failed)
            #expect(recovered[0].failureClass == .cancelled)
            #expect(recovered[0].finishedAt == finished)
            #expect(try store.recoverInterruptedSummaryRuns(at: finished).isEmpty)
        }
    }

    @Test("Live collector status round-trips without watched path content")
    func liveCollectorStatus() throws {
        try withTemporaryStore { store in
            let now = Date(timeIntervalSince1970: 1_785_888_000)
            let status = LiveCollectorRuntimeStatus(
                mode: .collecting,
                pendingTriggerCount: 12,
                pendingPathCount: 4,
                lastTriggerAt: now.addingTimeInterval(-2),
                lastCollectionStartedAt: now.addingTimeInterval(-1),
                lastMutationAt: now.addingTimeInterval(-30),
                lastLatencySeconds: 1.25,
                consecutiveFailures: 0)
            try store.recordLiveCollectorStatus(status, at: now)

            #expect(try store.liveCollectorStatus() == status)

            try store.recordHeartbeat(
                service: "reconciliation", processID: 42,
                observedAt: now, state: "healthy")
            #expect(try store.heartbeatObservedAt(service: "reconciliation") == now)
            #expect(try store.heartbeatObservedAt(service: "missing") == nil)

            try store.replaceCollectorIssues(
                [(sourceKey: "codex", message: "old"), (sourceKey: "git", message: "keep")],
                at: now)
            try store.replaceCollectorIssues(
                [(sourceKey: "codex", message: "new")],
                forSourceKeys: ["codex"], at: now.addingTimeInterval(1))
            #expect(try store.collectorStatus().issueCount == 2)
        }
    }

    @Test("A ledger snapshot is consistent, private, and never overwrites an export")
    func ledgerExport() throws {
        try withTemporaryStore { store in
            let now = Date(timeIntervalSince1970: 1_754_294_400)
            try store.upsert(
                repository: Repository(
                    id: RepositoryID("export-repo"),
                    displayName: "ExportRepo",
                    firstObservedAt: now,
                    lastObservedAt: now
                ),
                workingCopy: WorkingCopy(
                    id: WorkingCopyID("export-copy"),
                    repositoryID: RepositoryID("export-repo"),
                    canonicalPath: "/tmp/ExportRepo",
                    firstObservedAt: now,
                    lastObservedAt: now
                )
            )
            let destination = store.databaseURL.deletingLastPathComponent().appending(path: "export.sqlite")

            try store.exportSnapshot(to: destination)

            #expect(try LedgerStore(databaseURL: destination).counts() == store.counts())
            let permissions = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o600)
            var refusedOverwrite = false
            do {
                try store.exportSnapshot(to: destination)
            } catch {
                refusedOverwrite = true
            }
            #expect(refusedOverwrite)
        }
    }

    @Test("Deleting reports also removes their search documents")
    func reportDeletion() throws {
        try withTemporaryStore { store in
            let start = Date(timeIntervalSince1970: 1_754_294_400)
            try store.save(
                report: WorkReport(
                    id: ReportID("report-to-delete"),
                    periodStart: start,
                    periodEnd: start.addingTimeInterval(3_600),
                    state: .completed,
                    summary: "Unique generated summary",
                    evidenceIDs: [],
                    provider: nil,
                    model: nil,
                    generatorVersion: "test",
                    revision: 1
                ))

            #expect(try store.search("Unique generated").count == 1)
            #expect(try store.deleteAllReports() == 1)
            #expect(try store.search("Unique generated").isEmpty)
            #expect(
                try store.reports(
                    overlapping: DateInterval(start: start, duration: 3_600)
                ).isEmpty)
        }
    }

    @Test("A private recoverable backup is created before a pending migration")
    func migrationBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "trackify-migration-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appending(path: "trackify.sqlite")
        do { _ = try LedgerStore(databaseURL: databaseURL) }
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = '0003_message_aliases'")
            try db.execute(sql: "DROP TABLE message_aliases")
        }

        let migrated = try LedgerStore(databaseURL: databaseURL)
        let health = try migrated.health()
        #expect(health.migrationBackupCount == 1)
        #expect(health.migrationBackupBytes > 0)
        let backup = try #require(
            FileManager.default.contentsOfDirectory(
                at: directory.appending(path: "Backups"),
                includingPropertiesForKeys: nil
            ).first)
        let permissions = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test("Codex rollback migration repairs the legacy unresolved projection")
    func codexRollbackMigrationRepair() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "trackify-rollback-migration-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appending(path: "trackify.sqlite")
        do { _ = try LedgerStore(databaseURL: databaseURL) }

        let occurredAt = Date(timeIntervalSince1970: 1_786_470_400).timeIntervalSince1970
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = '0015_codex_thread_rollback'")
            try db.execute(
                sql: """
                    INSERT INTO sessions
                        (id, source, source_session_id, started_at, last_observed_at, state)
                    VALUES ('rollback-session', 'codex', 'rollback-session', ?, ?, 'completed')
                    """,
                arguments: [occurredAt, occurredAt])
            try db.execute(
                sql: """
                    INSERT INTO conversation_records (
                        id, source, session_id, source_record_id, source_record_type,
                        source_turn_id, occurred_at, observed_at, is_meta, is_sidechain,
                        origin, semantic_kind, disposition, canonical_state,
                        classification_version, classification_reason, adapter_version)
                    VALUES (
                        'legacy-rollback', 'codex', 'rollback-session', 'turn-1',
                        'event_msg.unknown:thread_rolled_back', 'turn-1', ?, ?, 0, 0,
                        'system', 'unknown', 'unresolved', 'unresolved', 1,
                        'codex-unknown-event-message', 5)
                    """,
                arguments: [occurredAt, occurredAt])
            try db.execute(
                sql: """
                    INSERT INTO evidence_quality_issues (
                        id, source, source_key, code, detail, issue_count,
                        first_observed_at, last_observed_at, affects_work_metrics)
                    VALUES (
                        'rollback-issue', 'codex', 'adapter:codex', 'unresolved-record',
                        'fixture', 1, ?, ?, 1)
                    """,
                arguments: [occurredAt, occurredAt])
        }

        let migrated = try LedgerStore(databaseURL: databaseURL)
        let expectedID = StableHash.sha256(
            "conversation-record:codex:rollback-session:event_msg.thread_rolled_back\u{1f}turn-1")
        let repaired = try DatabaseQueue(path: databaseURL.path).read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT id, source_record_type, semantic_kind, disposition,
                           canonical_state, classification_reason, adapter_version
                    FROM conversation_records WHERE id = ?
                    """,
                arguments: [expectedID])
        }
        #expect(repaired?["source_record_type"] as String? == "event_msg.thread_rolled_back")
        #expect(repaired?["semantic_kind"] as String? == "control")
        #expect(repaired?["disposition"] as String? == "control")
        #expect(repaired?["canonical_state"] as String? == "primary")
        #expect(repaired?["classification_reason"] as String? == "codex-known-transport-event")
        #expect(repaired?["adapter_version"] as Int? == 6)
        #expect(try migrated.evidenceQuality().unresolvedRecordCount == 0)
        #expect(try migrated.evidenceQuality().state == .healthy)
    }

    @Test("Codex multi-agent migration repairs legacy unresolved control records")
    func codexMultiAgentMigrationRepair() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "trackify-multi-agent-migration-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appending(path: "trackify.sqlite")
        do { _ = try LedgerStore(databaseURL: databaseURL) }

        let occurredAt = Date(timeIntervalSince1970: 1_786_647_600).timeIntervalSince1970
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = '0016_codex_multi_agent_control'")
            try db.execute(
                sql: """
                    INSERT INTO sessions
                        (id, source, source_session_id, started_at, last_observed_at, state)
                    VALUES ('multi-agent-session', 'codex', 'multi-agent-session', ?, ?, 'completed')
                    """,
                arguments: [occurredAt, occurredAt])
            for (id, type, turnID, timestamp) in [
                ("legacy-sub-agent", "event_msg.unknown:sub_agent_activity", "turn-1", occurredAt),
                ("legacy-inter-agent", "unknown:inter_agent_communication_metadata", nil, occurredAt + 1),
            ] as [(String, String, String?, Double)] {
                try db.execute(
                    sql: """
                        INSERT INTO conversation_records (
                            id, source, session_id, source_record_id, source_record_type,
                            source_turn_id, occurred_at, observed_at, is_meta, is_sidechain,
                            origin, semantic_kind, disposition, canonical_state,
                            classification_version, classification_reason, adapter_version)
                        VALUES (?, 'codex', 'multi-agent-session', ?, ?, ?, ?, ?, 0, 0,
                                'system', 'unknown', 'unresolved', 'unresolved', 1,
                                'codex-unknown-record', 6)
                        """,
                    arguments: [id, turnID, type, turnID, timestamp, timestamp])
            }
            try db.execute(
                sql: """
                    INSERT INTO evidence_quality_issues (
                        id, source, source_key, code, detail, issue_count,
                        first_observed_at, last_observed_at, affects_work_metrics)
                    VALUES ('multi-agent-issue', 'codex', 'adapter:codex',
                            'unresolved-record', 'fixture', 2, ?, ?, 1)
                    """,
                arguments: [occurredAt, occurredAt + 1])
        }

        let migrated = try LedgerStore(databaseURL: databaseURL)
        let repaired = try DatabaseQueue(path: databaseURL.path).read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT source_record_type, source_record_id, semantic_kind,
                           disposition, canonical_state, classification_reason,
                           adapter_version
                    FROM conversation_records
                    WHERE session_id = 'multi-agent-session'
                    ORDER BY source_record_type
                    """)
        }
        #expect(repaired.count == 2)
        #expect(repaired.allSatisfy { ($0["source_record_id"] as String?) == nil })
        #expect(repaired.allSatisfy { ($0["semantic_kind"] as String) == "control" })
        #expect(repaired.allSatisfy { ($0["disposition"] as String) == "control" })
        #expect(repaired.allSatisfy { ($0["canonical_state"] as String) == "primary" })
        #expect(repaired.allSatisfy { ($0["adapter_version"] as Int) == 7 })
        #expect(
            Set(repaired.map { $0["source_record_type"] as String })
                == ["event_msg.sub_agent_activity", "inter_agent_communication_metadata"])
        #expect(try migrated.evidenceQuality().unresolvedRecordCount == 0)
        #expect(try migrated.evidenceQuality().state == .healthy)
    }

    @Test("Message-alias migration repairs legacy duplicate normalized messages")
    func messageAliasMigrationRepair() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "trackify-message-migration-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appending(path: "trackify.sqlite")
        do { _ = try LedgerStore(databaseURL: databaseURL) }

        let occurredAt = Date(timeIntervalSince1970: 1_754_294_400).timeIntervalSince1970
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = '0003_message_aliases'")
            try db.execute(sql: "DROP TABLE message_aliases")
            try db.execute(
                sql: """
                    INSERT INTO sessions
                        (id, source, source_session_id, started_at, last_observed_at, state)
                    VALUES ('legacy-session', 'codex', 'legacy-session', ?, ?, 'completed')
                    """,
                arguments: [occurredAt, occurredAt]
            )
            try db.execute(
                sql: """
                    INSERT INTO session_messages
                        (id, session_id, source_message_id, role, occurred_at, normalized_text, fingerprint)
                    VALUES
                        ('legacy-with-source', 'legacy-session', 'source-1', 'assistant', ?, 'Same legacy update', 'fingerprint-a'),
                        ('legacy-without-source', 'legacy-session', NULL, 'assistant', ?, 'Same legacy update', 'fingerprint-b')
                    """,
                arguments: [occurredAt, occurredAt]
            )
            try db.execute(
                sql: """
                    INSERT INTO search_documents (entity_type, entity_id, occurred_at, content)
                    VALUES
                        ('message', 'legacy-with-source', ?, 'Same legacy update'),
                        ('message', 'legacy-without-source', ?, 'Same legacy update')
                    """,
                arguments: [occurredAt, occurredAt]
            )
        }

        let migrated = try LedgerStore(databaseURL: databaseURL)
        #expect(try migrated.counts().messages == 1)
        #expect(try migrated.search("Same legacy update").count == 1)
        let resolved = try migrated.messagesResolvingAliases(
            ids: [MessageID("legacy-with-source"), MessageID("legacy-without-source")]
        )
        #expect(resolved[MessageID("legacy-with-source")]?.id == MessageID("legacy-with-source"))
        #expect(resolved[MessageID("legacy-without-source")]?.id == MessageID("legacy-with-source"))
    }

    @Test("Near-duplicate migration repairs dual Codex cache representations")
    func nearDuplicateMessageMigrationRepair() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "trackify-near-message-migration-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appending(path: "trackify.sqlite")
        do { _ = try LedgerStore(databaseURL: databaseURL) }

        let occurredAt = Date(timeIntervalSince1970: 1_754_294_400).timeIntervalSince1970
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = '0004_near_duplicate_messages'")
            try db.execute(
                sql: """
                    INSERT INTO sessions
                        (id, source, source_session_id, started_at, last_observed_at, state)
                    VALUES ('near-session', 'codex', 'near-session', ?, ?, 'completed')
                    """,
                arguments: [occurredAt, occurredAt]
            )
            try db.execute(
                sql: """
                    INSERT INTO session_messages
                        (id, session_id, source_message_id, role, occurred_at, normalized_text, fingerprint)
                    VALUES
                        ('near-canonical', 'near-session', NULL, 'assistant', ?, 'Same dual-cache update', 'near-a'),
                        ('near-alias', 'near-session', 'msg-source-id', 'assistant', ?, 'Same dual-cache update', 'near-b')
                    """,
                arguments: [occurredAt, occurredAt + 0.008]
            )
            try db.execute(
                sql: """
                    INSERT INTO search_documents (entity_type, entity_id, occurred_at, content)
                    VALUES
                        ('message', 'near-canonical', ?, 'Same dual-cache update'),
                        ('message', 'near-alias', ?, 'Same dual-cache update')
                    """,
                arguments: [occurredAt, occurredAt + 0.008]
            )
        }

        let migrated = try LedgerStore(databaseURL: databaseURL)
        let resolved = try migrated.messagesResolvingAliases(
            ids: [MessageID("near-canonical"), MessageID("near-alias")]
        )
        #expect(try migrated.counts().messages == 1)
        #expect(try migrated.search("dual-cache").count == 1)
        #expect(resolved[MessageID("near-canonical")]?.id == MessageID("near-canonical"))
        #expect(resolved[MessageID("near-alias")]?.id == MessageID("near-canonical"))
        #expect(resolved[MessageID("near-alias")]?.sourceMessageID == "msg-source-id")
    }

    @Test("Privacy migration redacts secrets and merges attachment variants")
    func messagePrivacyMigrationRepair() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "trackify-message-privacy-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appending(path: "trackify.sqlite")
        do { _ = try LedgerStore(databaseURL: databaseURL) }

        let occurredAt = Date(timeIntervalSince1970: 1_754_294_400).timeIntervalSince1970
        let secret = "example-secret-value-123"
        let plain = "token: \(secret)\n\nPlease fix the calendar."
        let attached = plain + "\n\n<image name=[Image #1] path=\"/tmp/calendar.png\">\n</image>"
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = '0005_message_privacy'")
            try db.execute(
                sql: """
                    INSERT INTO sessions
                        (id, source, source_session_id, started_at, last_observed_at, state)
                    VALUES ('privacy-session', 'codex', 'privacy-session', ?, ?, 'completed')
                    """,
                arguments: [occurredAt, occurredAt]
            )
            try db.execute(
                sql: """
                    INSERT INTO session_messages
                        (id, session_id, source_message_id, role, occurred_at, normalized_text, fingerprint)
                    VALUES
                        ('privacy-plain', 'privacy-session', NULL, 'user', ?, ?, 'privacy-a'),
                        ('privacy-attached', 'privacy-session', 'source-message', 'user', ?, ?, 'privacy-b')
                    """,
                arguments: [occurredAt, plain, occurredAt + 0.01, attached]
            )
            try db.execute(
                sql: """
                    INSERT INTO search_documents (entity_type, entity_id, occurred_at, content)
                    VALUES
                        ('message', 'privacy-plain', ?, ?),
                        ('message', 'privacy-attached', ?, ?)
                    """,
                arguments: [occurredAt, plain, occurredAt + 0.01, attached]
            )
        }

        let migrated = try LedgerStore(databaseURL: databaseURL)
        let resolved = try migrated.messagesResolvingAliases(
            ids: [MessageID("privacy-plain"), MessageID("privacy-attached")]
        )
        let message = try #require(resolved[MessageID("privacy-attached")])
        #expect(try migrated.counts().messages == 1)
        #expect(message.id == MessageID("privacy-plain"))
        #expect(message.sourceMessageID == "source-message")
        #expect(!message.normalizedText.contains(secret))
        #expect(!message.normalizedText.contains("<image"))
        #expect(message.normalizedText.contains("[REDACTED_SECRET]"))
        #expect(try migrated.search(secret).isEmpty)
        #expect(try migrated.search("calendar").count == 1)
    }

    @Test("Session message limits select the latest messages chronologically")
    func latestSessionMessages() throws {
        try withTemporaryStore { store in
            let start = Date(timeIntervalSince1970: 1_754_294_400)
            let session = ConversationSession(
                id: SessionID("recent-session"),
                source: .codex,
                sourceSessionID: "recent-session",
                startedAt: start,
                lastObservedAt: start.addingTimeInterval(4),
                state: .completed
            )
            try store.upsert(session: session)
            for index in 0..<4 {
                try store.upsert(
                    message: ConversationMessage(
                        id: MessageID("recent-\(index)"),
                        sessionID: session.id,
                        sourceMessageID: "source-\(index)",
                        role: .assistant,
                        occurredAt: start.addingTimeInterval(Double(index)),
                        normalizedText: "Message \(index)",
                        fingerprint: "fingerprint-\(index)"
                    ))
            }

            #expect(try store.messages(sessionID: session.id, limit: 2).map(\.normalizedText) == ["Message 2", "Message 3"])
        }
    }

    @Test("Discovery roots persist labels, exclusions, and scan state")
    func discoveryRoots() throws {
        try withTemporaryStore { store in
            let createdAt = Date(timeIntervalSince1970: 1_754_294_400)
            let scannedAt = createdAt.addingTimeInterval(60)
            let root = DiscoveryRoot(
                id: DiscoveryRootID("work-root"),
                canonicalPath: "/tmp/Work",
                displayName: "Work",
                sortOrder: 2,
                excludedPaths: ["archive"],
                createdAt: createdAt
            )

            try store.upsert(discoveryRoot: root)
            try store.markDiscoveryRootScanned(id: root.id, at: scannedAt)

            let stored = try #require(store.discoveryRoots().first)
            #expect(stored.id == root.id)
            #expect(stored.displayName == "Work")
            #expect(stored.excludedPaths == ["archive"])
            #expect(stored.lastScannedAt == scannedAt)
        }
    }

    @Test("Migration creates a private usable ledger")
    func migrationAndPermissions() throws {
        try withTemporaryStore { store in
            #expect(
                try store.appliedMigrations()
                    == [
                        "0001_initial", "0002_collector_diagnostics", "0003_message_aliases",
                        "0004_near_duplicate_messages", "0005_message_privacy",
                        "0006_work_intelligence", "0007_configurable_reports",
                        "0008_report_schedules", "0009_canonical_summaries",
                        "0010_canonical_evidence", "0011_canonical_evidence_lookups",
                        "0012_evidence_coverage", "0013_provider_allowance_attribution",
                        "0014_live_collector_status", "0015_codex_thread_rollback",
                        "0016_codex_multi_agent_control",
                    ])
            #expect(try store.counts() == LedgerCounts(repositories: 0, commits: 0, sessions: 0, messages: 0, events: 0, observations: 0))
            #expect(try store.health().integrity == "ok")

            let attributes = try FileManager.default.attributesOfItem(atPath: store.databaseURL.path)
            let permissions = attributes[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o600)

            for suffix in ["-wal", "-shm"] {
                let path = store.databaseURL.path + suffix
                guard FileManager.default.fileExists(atPath: path) else { continue }
                let sidecarAttributes = try FileManager.default.attributesOfItem(atPath: path)
                let sidecarPermissions = sidecarAttributes[.posixPermissions] as? NSNumber
                #expect(sidecarPermissions?.intValue == 0o600)
            }
        }
    }

    @Test("Settings remain compatible and private as fields evolve")
    func settingsCompatibility() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "trackify-settings-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "settings.json")
        try Data(#"{"automaticUpdateChecks":true,"collectionPaused":false,"movingAverageActiveDays":14}"#.utf8).write(to: url)
        let store = SettingsStore(fileURL: url)
        var settings = try store.load()
        #expect(settings.launchAtLoginEnabled == nil)
        #expect(settings.providerSelection == .automatic)
        #expect(settings.automaticSummariesUseLLM == false)
        #expect(settings.generationBudgets.weeklyAllowancePercentLimit == 3)
        #expect(settings.generationBudgets.maximumCallsPerDay == 48)
        #expect(settings.generationBudgets.dailyTokenLimit == 2_000_000)

        let legacy =
            #"{"generationBudgets":{"maximumInputBytesPerCall":20480,"maximumEstimatedInputTokensPerCall":24000,"maximumCallsPerDay":8,"dailyTokenLimit":50000,"monthlyTokenLimit":1000000,"processDeadlineSeconds":180}}"#
        try Data(legacy.utf8).write(to: url, options: .atomic)
        settings = try store.load()
        #expect(settings.generationBudgets.maximumCallsPerDay == 48)
        #expect(settings.generationBudgets.weeklyCreditLimit == 500)

        let previousDefaults =
            #"{"generationBudgets":{"version":2,"maximumInputBytesPerCall":262144,"maximumEstimatedInputTokensPerCall":100000,"maximumCallsPerDay":30,"dailyTokenLimit":1000000,"monthlyTokenLimit":20000000,"weeklyCreditLimit":500,"weeklyAllowancePercentLimit":3,"minimumProviderAllowanceRemainingPercent":5,"estimatedOutputTokensPerCall":2000,"processDeadlineSeconds":180}}"#
        try Data(previousDefaults.utf8).write(to: url, options: .atomic)
        settings = try store.load()
        #expect(settings.generationBudgets.maximumCallsPerDay == 48)
        #expect(settings.generationBudgets.dailyTokenLimit == 2_000_000)
        #expect(settings.generationBudgets.monthlyTokenLimit == 30_000_000)

        let customPreviousPolicy =
            #"{"generationBudgets":{"version":2,"maximumInputBytesPerCall":262144,"maximumEstimatedInputTokensPerCall":100000,"maximumCallsPerDay":12,"dailyTokenLimit":700000,"monthlyTokenLimit":9000000,"weeklyCreditLimit":250,"weeklyAllowancePercentLimit":2,"minimumProviderAllowanceRemainingPercent":10,"estimatedOutputTokensPerCall":1000,"processDeadlineSeconds":120}}"#
        try Data(customPreviousPolicy.utf8).write(to: url, options: .atomic)
        settings = try store.load()
        #expect(settings.generationBudgets.maximumCallsPerDay == 12)
        #expect(settings.generationBudgets.dailyTokenLimit == 700_000)
        #expect(settings.generationBudgets.monthlyTokenLimit == 9_000_000)
        #expect(settings.generationBudgets.weeklyAllowancePercentLimit == 2)
        settings.launchAtLoginEnabled = false
        try store.save(settings)
        #expect(try store.load().launchAtLoginEnabled == false)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test("Hook and cache observations reconcile idempotently")
    func dualPathDeduplication() throws {
        try withTemporaryStore { store in
            let occurredAt = Date(timeIntervalSince1970: 1_754_294_400)
            let hookEvidence = SourceEvidence(
                id: EvidenceID("hook-evidence"),
                source: .codex,
                ingestionPath: .hook,
                sourceRecordID: "session-1:turn-1:started",
                fingerprint: "hook-shape",
                occurredAt: occurredAt,
                observedAt: occurredAt,
                adapterVersion: 1
            )
            let event = LedgerEvent(
                id: EventID("codex-session-1-turn-1-started"),
                evidenceID: hookEvidence.id,
                occurredAt: occurredAt,
                observedAt: occurredAt,
                source: .codex,
                kind: .agentRunStarted,
                state: .inProgress
            )

            let first = try store.ingest(evidence: hookEvidence, event: event)
            #expect(first.insertedObservation)
            #expect(first.insertedEvent)

            let cacheEvidence = SourceEvidence(
                id: EvidenceID("cache-evidence"),
                source: .codex,
                ingestionPath: .cache,
                sourceRecordID: "session-1:turn-1:started",
                fingerprint: "cache-shape",
                occurredAt: occurredAt,
                observedAt: occurredAt.addingTimeInterval(5),
                adapterVersion: 2
            )
            let second = try store.ingest(evidence: cacheEvidence, event: event)
            #expect(!second.insertedObservation)
            #expect(!second.insertedEvent)
            #expect(second.canonicalEvidenceID == hookEvidence.id)
            #expect(try store.counts().observations == 1)
            #expect(try store.counts().events == 1)
        }
    }

    @Test("Equivalent messages resolve to one canonical searchable record")
    func canonicalMessageDeduplication() throws {
        try withTemporaryStore { store in
            let now = Date(timeIntervalSince1970: 1_754_294_400)
            let session = ConversationSession(
                id: SessionID("canonical-session"),
                source: .codex,
                sourceSessionID: "canonical-session",
                startedAt: now,
                lastObservedAt: now,
                state: .completed
            )
            try store.upsert(session: session)
            let canonical = ConversationMessage(
                id: MessageID("canonical-message"),
                sessionID: session.id,
                role: .assistant,
                occurredAt: now,
                normalizedText: "One normalized assistant update",
                fingerprint: "canonical-fingerprint"
            )
            let alias = ConversationMessage(
                id: MessageID("alias-message"),
                sessionID: session.id,
                sourceMessageID: "msg-source-id",
                role: .assistant,
                occurredAt: now.addingTimeInterval(0.008),
                normalizedText: canonical.normalizedText,
                fingerprint: "alternate-parser-fingerprint"
            )

            try store.upsert(message: canonical)
            try store.upsert(message: alias)

            #expect(try store.counts().messages == 1)
            let resolved = try store.messagesResolvingAliases(ids: [canonical.id, alias.id, alias.id])
            #expect(resolved[canonical.id]?.normalizedText == canonical.normalizedText)
            #expect(resolved[alias.id]?.id == canonical.id)
            #expect(try store.search("normalized assistant").count == 1)
        }
    }

    @Test("Repository and cursor upserts are stable")
    func repositoryAndCursorUpsert() throws {
        try withTemporaryStore { store in
            let now = Date(timeIntervalSince1970: 1_754_294_400)
            let repository = Repository(
                id: RepositoryID("repo"),
                displayName: "Trackify",
                firstObservedAt: now,
                lastObservedAt: now
            )
            let workingCopy = WorkingCopy(
                id: WorkingCopyID("copy"),
                repositoryID: repository.id,
                canonicalPath: "/tmp/trackify",
                branch: "main",
                headCommit: "abc123",
                firstObservedAt: now,
                lastObservedAt: now
            )

            try store.upsert(repository: repository, workingCopy: workingCopy)
            try store.upsert(repository: repository, workingCopy: workingCopy)
            try store.setCursor(Data("cursor".utf8), for: "git:/tmp/trackify", at: now)

            #expect(try store.counts().repositories == 1)
            #expect(try store.cursor(for: "git:/tmp/trackify") == Data("cursor".utf8))
        }
    }

    @Test("Full-text search indexes repositories, commits, and associated messages")
    func fullTextSearch() throws {
        try withTemporaryStore { store in
            let now = Date(timeIntervalSince1970: 1_754_294_400)
            let repository = Repository(
                id: RepositoryID("search-repo"),
                displayName: "LedgerKit",
                firstObservedAt: now,
                lastObservedAt: now
            )
            let copy = WorkingCopy(
                id: WorkingCopyID("search-copy"),
                repositoryID: repository.id,
                canonicalPath: "/tmp/SearchableFolder/Repo",
                firstObservedAt: now,
                lastObservedAt: now
            )
            let session = ConversationSession(
                id: SessionID("search-session"),
                source: .codex,
                sourceSessionID: "search-session",
                startedAt: now,
                lastObservedAt: now,
                workingDirectory: "/tmp/SearchableFolder/Repo/Sources",
                state: .completed
            )
            let message = ConversationMessage(
                id: MessageID("search-message"),
                sessionID: session.id,
                role: .assistant,
                occurredAt: now,
                normalizedText: "Implemented deterministic cursor recovery",
                fingerprint: "search-message"
            )

            try store.upsert(repository: repository, workingCopy: copy)
            try store.upsert(session: session)
            try store.upsert(message: message)

            let results = try store.search("cursor recov")
            #expect(results.count == 1)
            #expect(results.first?.kind == .message)
            #expect(results.first?.repositoryID == repository.id)

            let pathResults = try store.search("SearchableFolder Repo")
            #expect(pathResults.contains { $0.kind == .repository && $0.repositoryID == repository.id })
        }
    }

    @Test("A repository discovered after a session repairs its association and search index")
    func lateRepositoryAssociation() throws {
        try withTemporaryStore { store in
            let now = Date(timeIntervalSince1970: 1_754_294_400)
            let session = ConversationSession(
                id: SessionID("late-session"),
                source: .claude,
                sourceSessionID: "late-session",
                startedAt: now,
                lastObservedAt: now,
                workingDirectory: "/tmp/LateRepo/Sources",
                state: .inProgress
            )
            let message = ConversationMessage(
                id: MessageID("late-message"),
                sessionID: session.id,
                role: .assistant,
                occurredAt: now,
                normalizedText: "Built a delayed association",
                fingerprint: "late-message"
            )
            try store.upsert(session: session)
            try store.upsert(message: message)
            let evidence = SourceEvidence(
                id: EvidenceID("late-evidence"),
                source: .claude,
                ingestionPath: .fixture,
                sourceRecordID: "late-event",
                fingerprint: "late-event",
                occurredAt: now,
                observedAt: now,
                adapterVersion: 1
            )
            _ = try store.ingest(
                evidence: evidence,
                event: LedgerEvent(
                    id: EventID("late-event"),
                    evidenceID: evidence.id,
                    occurredAt: now,
                    observedAt: now,
                    source: .claude,
                    kind: .agentMessageObserved,
                    sessionID: session.id,
                    payload: ["messageID": message.id.rawValue]
                )
            )

            let repository = Repository(
                id: RepositoryID("late-repo"),
                displayName: "LateRepo",
                firstObservedAt: now,
                lastObservedAt: now
            )
            try store.upsert(
                repository: repository,
                workingCopy: WorkingCopy(
                    id: WorkingCopyID("late-copy"),
                    repositoryID: repository.id,
                    canonicalPath: "/tmp/LateRepo",
                    firstObservedAt: now,
                    lastObservedAt: now
                )
            )

            #expect(try store.messages(repositoryID: repository.id, since: now.addingTimeInterval(-1)).count == 1)
            #expect(try store.search("delayed").first?.repositoryID == repository.id)
            #expect(
                try store.events(from: now, through: now).first(where: { $0.id == EventID("late-event") })?.repositoryID
                    == repository.id)
        }
    }

    @Test("Commit reachability is reconciled without deleting historical evidence")
    func commitReachability() throws {
        try withTemporaryStore { store in
            let now = Date(timeIntervalSince1970: 1_754_294_400)
            let repositoryID = RepositoryID("rewrite-repo")
            try store.upsert(
                repository: Repository(
                    id: repositoryID,
                    displayName: "RewriteRepo",
                    firstObservedAt: now,
                    lastObservedAt: now
                ),
                workingCopy: WorkingCopy(
                    id: WorkingCopyID("rewrite-copy"),
                    repositoryID: repositoryID,
                    canonicalPath: "/tmp/RewriteRepo",
                    firstObservedAt: now,
                    lastObservedAt: now
                )
            )
            for hash in ["kept", "rewritten"] {
                try store.upsert(
                    commit: GitCommit(
                        id: "commit-\(hash)",
                        repositoryID: repositoryID,
                        hash: hash,
                        authorTime: now,
                        message: hash,
                        additions: nil,
                        deletions: nil,
                        filesChanged: nil,
                        firstObservedAt: now,
                        lastObservedAt: now,
                        isReachable: true
                    ))
            }

            try store.reconcileCommitReachability(
                repositoryID: repositoryID,
                reachableHashes: ["kept"],
                observedAt: now.addingTimeInterval(60)
            )

            #expect(try store.commits(repositoryID: repositoryID, since: now.addingTimeInterval(-1)).count == 2)
            #expect(
                try store.reachableCommitKeys(from: now.addingTimeInterval(-1), through: now.addingTimeInterval(1)) == ["rewrite-repo:kept"]
            )
        }
    }

    @Test("Derived intervals replace an overlapping range deterministically")
    func workIntervalReplacement() throws {
        try withTemporaryStore { store in
            let start = Date(timeIntervalSince1970: 1_754_294_400)
            let range = DateInterval(start: start, duration: 3_600)
            let first = WorkInterval(
                id: WorkIntervalID("interval"),
                kind: .agent,
                startedAt: start,
                endedAt: start.addingTimeInterval(600),
                state: .completed,
                sourceEventIDs: [EventID("start"), EventID("end")],
                derivationVersion: 1
            )
            let replacement = WorkInterval(
                id: WorkIntervalID("replacement"),
                kind: .agent,
                startedAt: start,
                endedAt: start.addingTimeInterval(900),
                state: .interrupted,
                sourceEventIDs: [EventID("start")],
                derivationVersion: 2
            )

            try store.replaceWorkIntervals(overlapping: range, with: [first])
            try store.replaceWorkIntervals(overlapping: range, with: [replacement])

            #expect(try store.workIntervals(overlapping: range) == [replacement])
        }
    }

    @Test("Collection lease has one owner and can be reclaimed after expiry")
    func collectionLease() throws {
        try withTemporaryStore { store in
            let now = Date(timeIntervalSince1970: 1_754_294_400)
            #expect(try store.acquireLease(name: "collection", ownerID: "app", now: now, duration: 30))
            #expect(!(try store.acquireLease(name: "collection", ownerID: "cli", now: now, duration: 30)))
            #expect(try store.acquireLease(name: "collection", ownerID: "app", now: now.addingTimeInterval(5), duration: 30))
            #expect(try store.acquireLease(name: "collection", ownerID: "cli", now: now.addingTimeInterval(36), duration: 30))

            try store.releaseLease(name: "collection", ownerID: "app")
            #expect(!(try store.acquireLease(name: "collection", ownerID: "app", now: now.addingTimeInterval(40), duration: 30)))
            try store.releaseLease(name: "collection", ownerID: "cli")
            #expect(try store.acquireLease(name: "collection", ownerID: "app", now: now.addingTimeInterval(40), duration: 30))
        }
    }

    @Test("Collector status exposes issue counts without running full diagnostics")
    func collectorStatus() throws {
        try withTemporaryStore { store in
            let now = Date(timeIntervalSince1970: 1_754_294_400)
            try store.replaceCollectorIssues(
                [(sourceKey: "codex", message: "unsupported fixture")],
                at: now
            )
            try store.recordHeartbeat(service: "collector", processID: 42, observedAt: now, state: "degraded")

            let status = try store.collectorStatus()
            #expect(status.state == "degraded")
            #expect(status.observedAt == now)
            #expect(status.issueCount == 1)
        }
    }

    @Test("Recent events are bounded, filtered, and newest first")
    func recentEvents() throws {
        try withTemporaryStore { store in
            let start = Date(timeIntervalSince1970: 1_754_294_400)
            for (index, kind) in [EventKind.agentMessageObserved, .gitWorkingTreeChanged, .gitCommitObserved].enumerated() {
                let date = start.addingTimeInterval(TimeInterval(index * 60))
                let evidence = SourceEvidence(
                    id: EvidenceID("recent-evidence-\(index)"),
                    source: .simulation,
                    ingestionPath: .fixture,
                    sourceRecordID: "recent-\(index)",
                    fingerprint: "recent-\(index)",
                    occurredAt: date,
                    observedAt: date,
                    adapterVersion: 1
                )
                _ = try store.ingest(
                    evidence: evidence,
                    event: LedgerEvent(
                        id: EventID("recent-event-\(index)"),
                        evidenceID: evidence.id,
                        occurredAt: date,
                        observedAt: date,
                        source: .simulation,
                        kind: kind
                    ))
            }

            let events = try store.recentEvents(
                from: start,
                through: start.addingTimeInterval(180),
                kinds: [.agentMessageObserved, .gitCommitObserved],
                limit: 2
            )

            #expect(events.map(\.kind) == [.gitCommitObserved, .agentMessageObserved])
            #expect(events.map(\.id.rawValue) == ["recent-event-2", "recent-event-0"])
            #expect(try store.recentEvents(from: start, through: start, kinds: [], limit: 1).isEmpty)
        }
    }
}

private func withTemporaryStore(_ body: (LedgerStore) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "trackify-store-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(LedgerStore(databaseURL: directory.appending(path: "ledger.sqlite")))
}
