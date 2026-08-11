import Foundation
import GRDB
import TrackifyDomain

public enum LedgerStoreError: Error, Equatable {
    case unsupportedValue(type: String, value: String)
}

public struct LedgerCounts: Codable, Equatable, Sendable {
    public let repositories: Int
    public let commits: Int
    public let sessions: Int
    public let messages: Int
    public let events: Int
    public let observations: Int

    public init(repositories: Int, commits: Int, sessions: Int, messages: Int, events: Int, observations: Int) {
        self.repositories = repositories
        self.commits = commits
        self.sessions = sessions
        self.messages = messages
        self.events = events
        self.observations = observations
    }
}

public struct IngestResult: Equatable, Sendable {
    public let canonicalEvidenceID: EvidenceID
    public let insertedObservation: Bool
    public let insertedEvent: Bool

    public init(canonicalEvidenceID: EvidenceID, insertedObservation: Bool, insertedEvent: Bool) {
        self.canonicalEvidenceID = canonicalEvidenceID
        self.insertedObservation = insertedObservation
        self.insertedEvent = insertedEvent
    }
}

/// One canonical observation and its projected ledger event. Keeping this
/// persistence DTO in the store layer lets collection commit a source batch
/// atomically without making the store depend on an engine adapter type.
public struct LedgerEvidenceRecord: Equatable, Sendable {
    public let evidence: SourceEvidence
    public let event: LedgerEvent

    public init(evidence: SourceEvidence, event: LedgerEvent) {
        self.evidence = evidence
        self.event = event
    }
}

public struct LedgerEvidenceBatchResult: Equatable, Sendable {
    public let insertedObservations: Int
    public let insertedEvents: Int

    public init(insertedObservations: Int, insertedEvents: Int) {
        self.insertedObservations = insertedObservations
        self.insertedEvents = insertedEvents
    }
}

public struct LedgerHealth: Codable, Equatable, Sendable {
    public let integrity: String
    public let databaseBytes: Int64
    public let collectorState: String?
    public let collectorObservedAt: Date?
    public let collectorIssues: [String]
    public let migrationBackupCount: Int
    public let migrationBackupBytes: Int64
}

public struct CollectorStatus: Codable, Equatable, Sendable {
    public let state: String?
    public let observedAt: Date?
    public let issueCount: Int

    public init(state: String?, observedAt: Date?, issueCount: Int) {
        self.state = state
        self.observedAt = observedAt
        self.issueCount = issueCount
    }
}

public struct SourceStatistics: Codable, Equatable, Sendable {
    public let records: Int
    public let lastObservedAt: Date?

    public init(records: Int, lastObservedAt: Date?) {
        self.records = records
        self.lastObservedAt = lastObservedAt
    }
}

public enum LedgerDurability: Equatable, Sendable {
    case standard
    /// A shadow rebuild is disposable until it is verified and exported into
    /// a fully durable standalone SQLite snapshot.
    case disposableShadow
}

public final class LedgerStore: @unchecked Sendable {
    public let databaseURL: URL
    let database: DatabasePool
    let encoder: JSONEncoder
    private let indexesSearchIncrementally: Bool

    public init(
        databaseURL: URL,
        durability: LedgerDurability = .standard
    ) throws {
        self.databaseURL = databaseURL.standardizedFileURL
        let parent = self.databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        if FileManager.default.fileExists(atPath: self.databaseURL.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.databaseURL.path)
        } else {
            let created = FileManager.default.createFile(
                atPath: self.databaseURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
            guard created else {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        var configuration = Configuration()
        configuration.label = "TrackifyLedger"
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            if durability == .disposableShadow {
                try db.execute(sql: "PRAGMA synchronous = OFF")
            }
        }

        database = try DatabasePool(path: self.databaseURL.path, configuration: configuration)
        indexesSearchIncrementally = durability == .standard

        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        try createMigrationBackupIfNeeded()
        try LedgerSchema.migrator.migrate(database)
        secureDatabaseFiles()
    }

    public func appliedMigrations() throws -> [String] {
        try database.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
    }

    public func counts() throws -> LedgerCounts {
        try database.read { db in
            LedgerCounts(
                repositories: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM repositories") ?? 0,
                commits: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM commits") ?? 0,
                sessions: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions") ?? 0,
                messages: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_messages") ?? 0,
                events: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events") ?? 0,
                observations: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source_observations") ?? 0
            )
        }
    }

    public func sourceStatistics(source: String) throws -> SourceStatistics {
        try database.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) AS records, MAX(last_observed_at) AS last_observed_at
                    FROM source_observations WHERE source = ?
                    """,
                arguments: [source])!
            return SourceStatistics(
                records: row["records"],
                lastObservedAt: (row["last_observed_at"] as Double?).map(Date.init(timeIntervalSince1970:)))
        }
    }

    public func exportSnapshot(to destinationURL: URL) throws {
        let destination = destinationURL.standardizedFileURL
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let writer = try DatabaseQueue(path: destination.path)
        do {
            try database.backup(to: writer)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    @discardableResult
    public func deleteAllReports() throws -> Int {
        try database.write { db in
            let reportCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM reports") ?? 0
            let artifactCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artifacts") ?? 0
            try db.execute(sql: "DELETE FROM search_documents WHERE entity_type = 'report'")
            try db.execute(sql: "DELETE FROM artifacts")
            try db.execute(sql: "DELETE FROM report_runs")
            try db.execute(sql: "DELETE FROM reports")
            return max(reportCount, artifactCount)
        }
    }

    public func ingest(evidence: SourceEvidence, event: LedgerEvent) throws -> IngestResult {
        return try database.write { db in
            try ingest(evidence: evidence, event: event, db: db)
        }
    }

    private func ingest(
        evidence: SourceEvidence,
        event: LedgerEvent,
        db: Database
    ) throws -> IngestResult {
        let canonicalKey = Self.canonicalKey(for: evidence)
        var canonicalPayload = event.payload
        if let messageID = canonicalPayload["messageID"],
            let canonicalID = try String.fetchOne(
                db,
                sql: "SELECT canonical_id FROM message_aliases WHERE alias_id = ?",
                arguments: [messageID]
            )
        {
            canonicalPayload["messageID"] = canonicalID
        }
        let payload = try encoder.encode(canonicalPayload)
        let existingID = try String.fetchOne(
            db,
            sql: "SELECT id FROM source_observations WHERE canonical_key = ?",
            arguments: [canonicalKey]
        )

        let canonicalID: EvidenceID
        let insertedObservation: Bool

        if let existingID {
            canonicalID = EvidenceID(existingID)
            insertedObservation = false
            try db.execute(
                sql: """
                    UPDATE source_observations
                    SET last_observed_at = MAX(last_observed_at, ?),
                        adapter_version = MAX(adapter_version, ?)
                    WHERE canonical_key = ?
                    """,
                arguments: [evidence.observedAt.timeIntervalSince1970, evidence.adapterVersion, canonicalKey]
            )
        } else {
            canonicalID = evidence.id
            insertedObservation = true
            try db.execute(
                sql: """
                    INSERT INTO source_observations (
                        id, canonical_key, source, ingestion_path, source_record_id,
                        fingerprint, occurred_at, first_observed_at, last_observed_at, adapter_version
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    evidence.id.rawValue,
                    canonicalKey,
                    evidence.source.rawValue,
                    evidence.ingestionPath.rawValue,
                    evidence.sourceRecordID,
                    evidence.fingerprint,
                    evidence.occurredAt.timeIntervalSince1970,
                    evidence.observedAt.timeIntervalSince1970,
                    evidence.observedAt.timeIntervalSince1970,
                    evidence.adapterVersion,
                ]
            )
        }

        let resolvedRepositoryID: RepositoryID?
        if let repositoryID = event.repositoryID {
            resolvedRepositoryID = repositoryID
        } else if event.kind == .agentMessageObserved,
            let messageID = event.payload["messageID"],
            let messageRepositoryID = try String.fetchOne(
                db,
                sql: """
                    SELECT message_repository_id
                    FROM session_messages
                    WHERE id = COALESCE(
                        (SELECT canonical_id FROM message_aliases WHERE alias_id = ?), ?)
                    """,
                arguments: [messageID, messageID])
        {
            resolvedRepositoryID = RepositoryID(messageRepositoryID)
        } else if let sessionID = event.sessionID {
            resolvedRepositoryID = try String.fetchOne(
                db,
                sql: "SELECT repository_id FROM session_repositories WHERE session_id = ? ORDER BY confidence DESC LIMIT 1",
                arguments: [sessionID.rawValue]
            ).map { RepositoryID($0) }
        } else {
            resolvedRepositoryID = nil
        }

        try db.execute(
            sql: """
                INSERT INTO events (
                    id, evidence_id, occurred_at, observed_at, source, kind,
                    repository_id, working_copy_id, session_id, state, payload_json, schema_version
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """,
            arguments: [
                event.id.rawValue,
                canonicalID.rawValue,
                event.occurredAt.timeIntervalSince1970,
                event.observedAt.timeIntervalSince1970,
                event.source.rawValue,
                event.kind.rawValue,
                resolvedRepositoryID?.rawValue,
                event.workingCopyID?.rawValue,
                event.sessionID?.rawValue,
                event.state?.rawValue,
                payload,
                event.schemaVersion,
            ]
        )
        let insertedEvent = db.changesCount == 1

        if insertedEvent,
            event.kind == .agentRunStarted || event.kind == .agentRunFinished,
            let sourceTurnID = canonicalPayload["turnID"]
        {
            let logicalTurnID = StableHash.sha256(
                "logical-turn:\(event.source.rawValue):\(sourceTurnID)")
            if let nextState = event.state?.rawValue {
                let existingState = try String.fetchOne(
                    db, sql: "SELECT state FROM logical_turns WHERE id = ?",
                    arguments: [logicalTurnID])
                let terminal = Set([
                    ObservedState.completed.rawValue,
                    ObservedState.failed.rawValue,
                    ObservedState.interrupted.rawValue,
                ])
                if let existingState,
                    terminal.contains(existingState), terminal.contains(nextState),
                    existingState != nextState
                {
                    try Self.recordQualityIssue(
                        db: db, source: event.source,
                        sourceKey: "logical-turn:\(logicalTurnID)",
                        code: "conflicting-terminal-state",
                        detail: "One authoritative logical turn has incompatible terminal states.",
                        observedAt: event.observedAt, affectsWorkMetrics: true)
                }
                try db.execute(
                    sql: """
                        UPDATE logical_turns
                        SET state = ?,
                            started_at = CASE
                                WHEN ? = 'in_progress' THEN COALESCE(started_at, ?)
                                ELSE started_at END,
                            last_observed_at = MAX(COALESCE(last_observed_at, ?), ?)
                        WHERE id = ?
                        """,
                    arguments: [
                        nextState, nextState, event.occurredAt.timeIntervalSince1970,
                        event.observedAt.timeIntervalSince1970,
                        event.observedAt.timeIntervalSince1970, logicalTurnID,
                    ])
            }
        }

        return IngestResult(
            canonicalEvidenceID: canonicalID,
            insertedObservation: insertedObservation,
            insertedEvent: insertedEvent
        )
    }

    public func upsert(
        repository: Repository,
        workingCopy: WorkingCopy,
        discoveryRootID: DiscoveryRootID? = nil,
        relativePath: String? = nil
    ) throws {
        precondition(workingCopy.repositoryID == repository.id)
        try database.write { db in
            let existingRepository = try Row.fetchOne(
                db,
                sql: "SELECT display_name, remote_identity FROM repositories WHERE id = ?",
                arguments: [repository.id.rawValue])
            let existingWorkingCopy = try Row.fetchOne(
                db,
                sql: "SELECT repository_id, canonical_path FROM working_copies WHERE id = ?",
                arguments: [workingCopy.id.rawValue])
            let repositoryMetadataChanged =
                existingRepository.map { row in
                    (row["display_name"] as String) != repository.displayName
                        || (repository.remoteIdentity != nil
                            && (row["remote_identity"] as String?) != repository.remoteIdentity)
                } ?? true
            let workingCopyMappingChanged =
                existingWorkingCopy.map { row in
                    (row["repository_id"] as String) != workingCopy.repositoryID.rawValue
                        || (row["canonical_path"] as String) != workingCopy.canonicalPath
                } ?? true
            try db.execute(
                sql: """
                    INSERT INTO repositories (
                        id, display_name, remote_identity, first_observed_at, last_observed_at
                    ) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        display_name = excluded.display_name,
                        remote_identity = COALESCE(excluded.remote_identity, repositories.remote_identity),
                        last_observed_at = MAX(repositories.last_observed_at, excluded.last_observed_at)
                    """,
                arguments: [
                    repository.id.rawValue,
                    repository.displayName,
                    repository.remoteIdentity,
                    repository.firstObservedAt.timeIntervalSince1970,
                    repository.lastObservedAt.timeIntervalSince1970,
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO working_copies (
                        id, repository_id, canonical_path, branch, head_commit,
                        first_observed_at, last_observed_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        canonical_path = excluded.canonical_path,
                        branch = excluded.branch,
                        head_commit = excluded.head_commit,
                        last_observed_at = MAX(working_copies.last_observed_at, excluded.last_observed_at)
                    """,
                arguments: [
                    workingCopy.id.rawValue,
                    workingCopy.repositoryID.rawValue,
                    workingCopy.canonicalPath,
                    workingCopy.branch,
                    workingCopy.headCommit,
                    workingCopy.firstObservedAt.timeIntervalSince1970,
                    workingCopy.lastObservedAt.timeIntervalSince1970,
                ]
            )
            var locationChanged = false
            if discoveryRootID != nil || relativePath != nil {
                let current = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT id, path, discovery_root_id, relative_path
                        FROM working_copy_locations
                        WHERE working_copy_id = ? AND valid_until IS NULL
                        ORDER BY valid_from DESC LIMIT 1
                        """,
                    arguments: [workingCopy.id.rawValue]
                )
                let unchanged =
                    current.map { row in
                        (row["path"] as String) == workingCopy.canonicalPath
                            && (row["discovery_root_id"] as String?) == discoveryRootID?.rawValue
                            && (row["relative_path"] as String?) == relativePath
                    } ?? false
                if !unchanged {
                    locationChanged = true
                    try db.execute(
                        sql: "UPDATE working_copy_locations SET valid_until = ? WHERE working_copy_id = ? AND valid_until IS NULL",
                        arguments: [workingCopy.lastObservedAt.timeIntervalSince1970, workingCopy.id.rawValue]
                    )
                    try db.execute(
                        sql: """
                            INSERT INTO working_copy_locations (
                                working_copy_id, discovery_root_id, path, relative_path, valid_from
                            ) VALUES (?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            workingCopy.id.rawValue,
                            discoveryRootID?.rawValue,
                            workingCopy.canonicalPath,
                            relativePath,
                            workingCopy.lastObservedAt.timeIntervalSince1970,
                        ]
                    )
                }
            }

            if workingCopyMappingChanged {
                try Self.associateSessions(db: db, with: workingCopy)
            }
            if repositoryMetadataChanged || workingCopyMappingChanged || locationChanged {
                let canonicalPaths = try String.fetchAll(
                    db,
                    sql: "SELECT canonical_path FROM working_copies WHERE repository_id = ? ORDER BY canonical_path",
                    arguments: [repository.id.rawValue]
                )
                let relativePaths = try String.fetchAll(
                    db,
                    sql: """
                        SELECT relative_path
                        FROM working_copy_locations
                        WHERE valid_until IS NULL
                          AND relative_path IS NOT NULL
                          AND working_copy_id IN (SELECT id FROM working_copies WHERE repository_id = ?)
                        ORDER BY relative_path
                        """,
                    arguments: [repository.id.rawValue]
                )
                try Self.index(
                    db: db,
                    kind: .repository,
                    entityID: repository.id.rawValue,
                    repositoryID: repository.id,
                    occurredAt: repository.lastObservedAt,
                    content: ([repository.displayName, repository.remoteIdentity].compactMap { $0 }
                        + canonicalPaths + relativePaths).joined(separator: " ")
                )
            }
        }
    }

    public func upsert(session: ConversationSession) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sessions (
                        id, source, source_session_id, started_at, last_observed_at,
                        working_directory, source_version, state
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(source, source_session_id) DO UPDATE SET
                        started_at = COALESCE(sessions.started_at, excluded.started_at),
                        last_observed_at = MAX(sessions.last_observed_at, excluded.last_observed_at),
                        working_directory = COALESCE(excluded.working_directory, sessions.working_directory),
                        source_version = COALESCE(excluded.source_version, sessions.source_version),
                        state = CASE
                            WHEN excluded.state = 'unknown' THEN sessions.state
                            ELSE excluded.state
                        END
                    """,
                arguments: [
                    session.id.rawValue,
                    session.source.rawValue,
                    session.sourceSessionID,
                    session.startedAt?.timeIntervalSince1970,
                    session.lastObservedAt.timeIntervalSince1970,
                    session.workingDirectory,
                    session.sourceVersion,
                    session.state.rawValue,
                ]
            )
            if let workingDirectory = session.workingDirectory {
                let candidates = try Row.fetchAll(
                    db,
                    sql: "SELECT id, repository_id, canonical_path FROM working_copies ORDER BY LENGTH(canonical_path) DESC"
                )
                if let match = candidates.first(where: { row in
                    let path: String = row["canonical_path"]
                    return workingDirectory == path || workingDirectory.hasPrefix(path + "/")
                }) {
                    try db.execute(
                        sql: """
                            INSERT INTO session_repositories (
                                session_id, repository_id, working_copy_id, method, confidence, valid_from
                            ) VALUES (?, ?, ?, 'working_directory', 1.0, ?)
                            ON CONFLICT(session_id, repository_id, method) DO UPDATE SET
                                working_copy_id = excluded.working_copy_id,
                                confidence = excluded.confidence
                            """,
                        arguments: [
                            session.id.rawValue,
                            match["repository_id"] as String,
                            match["id"] as String,
                            session.startedAt?.timeIntervalSince1970,
                        ]
                    )
                }
            }
        }
    }

    public func upsert(message: ConversationMessage) throws {
        try database.write { db in
            try upsert(
                message: message, db: db,
                indexSearch: indexesSearchIncrementally)
        }
    }

    private func upsert(
        message: ConversationMessage,
        db: Database,
        indexSearch: Bool
    ) throws {
        let sanitizedText = MessageTextSanitizer.sanitize(message.normalizedText)
        let occurredAt = message.occurredAt?.timeIntervalSince1970
        let source =
            try String.fetchOne(
                db, sql: "SELECT source FROM sessions WHERE id = ?",
                arguments: [message.sessionID.rawValue]) ?? SourceKind.simulation.rawValue
        let association = try Self.repositoryAssociation(
            db: db, workingDirectory: message.provenance.workingDirectory)
        try Self.upsertLogicalProjection(
            db: db, message: message, source: source,
            sanitizedText: sanitizedText, association: association)
        if let existingLogicalID = try String.fetchOne(
            db, sql: "SELECT id FROM session_messages WHERE id = ?",
            arguments: [message.id.rawValue])
        {
            if indexSearch && ConversationMessageVisibility.isWorkEvidence(message) {
                let repositoryID: RepositoryID?
                if let association {
                    repositoryID = RepositoryID(association.repositoryID)
                } else {
                    repositoryID = try Self.repositoryID(
                        db: db, sessionID: message.sessionID)
                }
                try Self.index(
                    db: db, kind: .message, entityID: existingLogicalID,
                    repositoryID: repositoryID,
                    occurredAt: message.occurredAt, content: sanitizedText)
            }
            return
        }
        // Timestamp/text proximity is only a compatibility bridge for
        // pre-provenance records. Authoritative provider identities must
        // remain distinct even when two messages happen to be identical.
        if message.provenance.classificationReason == "legacy-compatible",
            let canonical = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, source_message_id
                    FROM session_messages
                    WHERE session_id = ? AND role = ?
                      AND normalized_text = ?
                      AND (
                          (occurred_at IS NULL AND ? IS NULL)
                          OR (occurred_at IS NOT NULL AND ? IS NOT NULL
                              AND ABS(occurred_at - ?) <= ?)
                      )
                    ORDER BY ABS(COALESCE(occurred_at, 0) - COALESCE(?, 0)), id
                    LIMIT 1
                    """,
                arguments: [
                    message.sessionID.rawValue,
                    message.role.rawValue,
                    sanitizedText,
                    occurredAt,
                    occurredAt,
                    occurredAt,
                    LedgerSchema.messageDuplicateTolerance,
                    occurredAt,
                ]
            )
        {
            let canonicalID: String = canonical["id"]
            if canonicalID != message.id.rawValue {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO message_aliases (alias_id, canonical_id) VALUES (?, ?)",
                    arguments: [message.id.rawValue, canonicalID]
                )
            }
            if (canonical["source_message_id"] as String?) == nil, let sourceID = message.sourceMessageID {
                try db.execute(
                    sql: "UPDATE session_messages SET source_message_id = ? WHERE id = ?",
                    arguments: [sourceID, canonicalID]
                )
            }
            if indexSearch && ConversationMessageVisibility.isWorkEvidence(message) {
                let repositoryID: RepositoryID?
                if let association {
                    repositoryID = RepositoryID(association.repositoryID)
                } else {
                    repositoryID = try Self.repositoryID(
                        db: db, sessionID: message.sessionID)
                }
                try Self.index(
                    db: db, kind: .message, entityID: canonicalID,
                    repositoryID: repositoryID,
                    occurredAt: message.occurredAt, content: sanitizedText)
            } else if indexSearch {
                try Self.removeIndex(db: db, kind: .message, entityID: canonicalID)
            }
            return
        }

        try db.execute(
            sql: """
                INSERT INTO session_messages (
                    id, session_id, source_message_id, role, occurred_at, normalized_text, fingerprint,
                    source_record_id, source_record_type, source_turn_id,
                    parent_source_record_id, source_response_id, entrypoint,
                    message_working_directory, is_meta, is_sidechain, origin,
                    semantic_kind, disposition, canonical_state,
                    classification_version, classification_reason,
                    logical_turn_id, logical_message_id, message_repository_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(session_id, fingerprint) DO NOTHING
                """,
            arguments: [
                message.id.rawValue,
                message.sessionID.rawValue,
                message.sourceMessageID,
                message.role.rawValue,
                occurredAt,
                sanitizedText,
                message.fingerprint,
                message.provenance.sourceRecordID,
                message.provenance.sourceRecordType,
                message.provenance.sourceTurnID,
                message.provenance.parentSourceRecordID,
                message.provenance.sourceResponseID,
                message.provenance.entrypoint,
                message.provenance.workingDirectory,
                message.provenance.isMeta,
                message.provenance.isSidechain,
                message.provenance.origin.rawValue,
                message.provenance.semanticKind.rawValue,
                message.provenance.disposition.rawValue,
                message.provenance.canonicalState.rawValue,
                message.provenance.classificationVersion,
                message.provenance.classificationReason,
                message.provenance.logicalTurnID?.rawValue,
                message.provenance.logicalMessageID?.rawValue,
                association?.repositoryID,
            ]
        )
        let canonicalID =
            try String.fetchOne(
                db,
                sql: "SELECT id FROM session_messages WHERE session_id = ? AND fingerprint = ?",
                arguments: [message.sessionID.rawValue, message.fingerprint]
            ) ?? message.id.rawValue
        if canonicalID != message.id.rawValue {
            try db.execute(
                sql: "INSERT OR REPLACE INTO message_aliases (alias_id, canonical_id) VALUES (?, ?)",
                arguments: [message.id.rawValue, canonicalID]
            )
        }
        let repositoryID: RepositoryID?
        if let association {
            repositoryID = RepositoryID(association.repositoryID)
        } else {
            repositoryID = try Self.repositoryID(
                db: db, sessionID: message.sessionID)
        }
        if indexSearch && ConversationMessageVisibility.isWorkEvidence(message) {
            try Self.index(
                db: db, kind: .message, entityID: canonicalID,
                repositoryID: repositoryID,
                occurredAt: message.occurredAt, content: sanitizedText)
        } else if indexSearch {
            try Self.removeIndex(db: db, kind: .message, entityID: canonicalID)
        }
    }

    public func upsert(conversationRecord record: NormalizedConversationRecord) throws {
        try database.write { db in
            try upsert(conversationRecord: record, db: db)
        }
    }

    private func upsert(
        conversationRecord record: NormalizedConversationRecord,
        db: Database
    ) throws {
        let isNewRecord =
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM conversation_records WHERE id = ?",
                arguments: [record.id.rawValue]) == 0
        let association = try Self.repositoryAssociation(
            db: db, workingDirectory: record.provenance.workingDirectory)
        if let turnID = record.provenance.logicalTurnID,
            let sourceTurnID = record.provenance.sourceTurnID
        {
            try db.execute(
                sql: """
                    INSERT INTO logical_turns (
                        id, source, source_turn_id, session_id, origin,
                        started_at, last_observed_at, state, repository_id,
                        repository_method, repository_confidence, classification_version)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 'unknown', ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        last_observed_at = MAX(logical_turns.last_observed_at, excluded.last_observed_at),
                        origin = CASE
                            WHEN (CASE excluded.origin
                                WHEN 'human' THEN 70 WHEN 'agent' THEN 60
                                WHEN 'trackify' THEN 50 WHEN 'assistant' THEN 40
                                WHEN 'provider' THEN 30 WHEN 'hook' THEN 20
                                WHEN 'tool' THEN 10 WHEN 'system' THEN 5 ELSE 0 END)
                               > (CASE logical_turns.origin
                                WHEN 'human' THEN 70 WHEN 'agent' THEN 60
                                WHEN 'trackify' THEN 50 WHEN 'assistant' THEN 40
                                WHEN 'provider' THEN 30 WHEN 'hook' THEN 20
                                WHEN 'tool' THEN 10 WHEN 'system' THEN 5 ELSE 0 END)
                            THEN excluded.origin ELSE logical_turns.origin END,
                        repository_id = COALESCE(logical_turns.repository_id, excluded.repository_id),
                        repository_method = COALESCE(logical_turns.repository_method, excluded.repository_method),
                        repository_confidence = MAX(
                            COALESCE(logical_turns.repository_confidence, 0),
                            COALESCE(excluded.repository_confidence, 0))
                    """,
                arguments: [
                    turnID.rawValue, record.source.rawValue, sourceTurnID,
                    record.sessionID.rawValue, record.provenance.origin.rawValue,
                    record.occurredAt?.timeIntervalSince1970,
                    record.observedAt.timeIntervalSince1970,
                    association?.repositoryID, association?.method,
                    association?.confidence,
                    record.provenance.classificationVersion,
                ])
        }

        var canonicalState = record.provenance.canonicalState
        if canonicalState == .primary,
            let logicalMessageID = record.provenance.logicalMessageID,
            let existingSession = try String.fetchOne(
                db,
                sql: "SELECT session_id FROM conversation_records WHERE logical_message_id = ? LIMIT 1",
                arguments: [logicalMessageID.rawValue])
        {
            canonicalState = existingSession == record.sessionID.rawValue ? .alias : .replay
        }

        try db.execute(
            sql: """
                INSERT INTO conversation_records (
                    id, source, session_id, source_record_id, source_record_type,
                    source_turn_id, parent_source_record_id, source_response_id,
                    role, occurred_at, observed_at, normalized_text,
                    text_fingerprint, entrypoint, working_directory, is_meta,
                    is_sidechain, origin, semantic_kind, disposition,
                    canonical_state, logical_turn_id, logical_message_id,
                    repository_id, classification_version,
                    classification_reason, adapter_version)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    observed_at = MAX(conversation_records.observed_at, excluded.observed_at)
                """,
            arguments: [
                record.id.rawValue, record.source.rawValue,
                record.sessionID.rawValue, record.provenance.sourceRecordID,
                record.provenance.sourceRecordType,
                record.provenance.sourceTurnID,
                record.provenance.parentSourceRecordID,
                record.provenance.sourceResponseID,
                record.role?.rawValue,
                record.occurredAt?.timeIntervalSince1970,
                record.observedAt.timeIntervalSince1970,
                // Canonical content lives in session_messages and
                // logical_messages. Source records retain provenance and a
                // fingerprint without duplicating private text for every
                // transport alias, replay, or diagnostic envelope.
                Optional<String>.none,
                record.textFingerprint,
                record.provenance.entrypoint,
                record.provenance.workingDirectory,
                record.provenance.isMeta,
                record.provenance.isSidechain,
                record.provenance.origin.rawValue,
                record.provenance.semanticKind.rawValue,
                record.provenance.disposition.rawValue,
                canonicalState.rawValue,
                record.provenance.logicalTurnID?.rawValue,
                record.provenance.logicalMessageID?.rawValue,
                association?.repositoryID,
                record.provenance.classificationVersion,
                record.provenance.classificationReason,
                record.adapterVersion,
            ])

        if isNewRecord, record.provenance.disposition == .unresolved {
            try Self.recordQualityIssue(
                db: db, source: record.source,
                sourceKey: "adapter:\(record.source.rawValue)",
                code: "unresolved-record",
                detail: "One or more provider records have semantics not understood by the active adapter.",
                observedAt: record.observedAt,
                affectsWorkMetrics: true)
        } else if isNewRecord, record.provenance.disposition == .work,
            record.provenance.logicalMessageID == nil,
            record.role != nil
        {
            try Self.recordQualityIssue(
                db: db, source: record.source,
                sourceKey: "projection:\(record.source.rawValue)",
                code: "work-message-without-logical-identity",
                detail: "A work-classified message has no canonical logical identity.",
                observedAt: record.observedAt,
                affectsWorkMetrics: true)
        }
    }

    /// Commits the high-volume conversation projection and its source cursor
    /// as one unit. A failed batch is fully rolled back, so a cursor can never
    /// acknowledge evidence that was only partially persisted.
    public func ingestConversationEvidenceBatch(
        messages: [ConversationMessage],
        conversationRecords: [NormalizedConversationRecord],
        evidenceRecords: [LedgerEvidenceRecord],
        sourceKey: String,
        nextCursor: Data?,
        observedAt: Date
    ) throws -> LedgerEvidenceBatchResult {
        try database.write { db in
            for message in messages {
                try upsert(
                    message: message, db: db,
                    indexSearch: indexesSearchIncrementally)
            }
            for record in conversationRecords {
                try upsert(conversationRecord: record, db: db)
            }

            var observations = 0
            var events = 0
            for record in evidenceRecords {
                let result = try ingest(
                    evidence: record.evidence, event: record.event, db: db)
                if result.insertedObservation { observations += 1 }
                if result.insertedEvent { events += 1 }
            }
            if let nextCursor {
                try Self.setCursor(
                    nextCursor, for: sourceKey, at: observedAt, db: db)
            }
            return LedgerEvidenceBatchResult(
                insertedObservations: observations,
                insertedEvents: events)
        }
    }

    public func upsert(commit: GitCommit) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO commits (
                        id, repository_id, hash, author_time, message, additions, deletions, files_changed,
                        first_observed_at, last_observed_at, is_reachable
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(repository_id, hash) DO UPDATE SET
                        message = excluded.message,
                        additions = COALESCE(excluded.additions, commits.additions),
                        deletions = COALESCE(excluded.deletions, commits.deletions),
                        files_changed = COALESCE(excluded.files_changed, commits.files_changed),
                        last_observed_at = MAX(commits.last_observed_at, excluded.last_observed_at),
                        is_reachable = excluded.is_reachable
                    """,
                arguments: [
                    commit.id,
                    commit.repositoryID.rawValue,
                    commit.hash,
                    commit.authorTime.timeIntervalSince1970,
                    commit.message,
                    commit.additions,
                    commit.deletions,
                    commit.filesChanged,
                    commit.firstObservedAt.timeIntervalSince1970,
                    commit.lastObservedAt.timeIntervalSince1970,
                    commit.isReachable,
                ]
            )
            try Self.index(
                db: db,
                kind: .commit,
                entityID: commit.id,
                repositoryID: commit.repositoryID,
                occurredAt: commit.authorTime,
                content: "\(commit.hash) \(commit.message)"
            )
        }
    }

    public func reconcileCommitReachability(
        repositoryID: RepositoryID,
        reachableHashes: Set<String>,
        observedAt: Date
    ) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE commits SET is_reachable = 0, last_observed_at = MAX(last_observed_at, ?) WHERE repository_id = ?",
                arguments: [observedAt.timeIntervalSince1970, repositoryID.rawValue]
            )
            guard !reachableHashes.isEmpty else { return }
            let sortedHashes = reachableHashes.sorted()
            for offset in stride(from: 0, to: sortedHashes.count, by: 400) {
                let hashes = Array(sortedHashes[offset..<min(offset + 400, sortedHashes.count)])
                let placeholders = Array(repeating: "?", count: hashes.count).joined(separator: ",")
                var arguments: StatementArguments = [repositoryID.rawValue]
                arguments += StatementArguments(hashes)
                try db.execute(
                    sql: "UPDATE commits SET is_reachable = 1 WHERE repository_id = ? AND hash IN (\(placeholders))",
                    arguments: arguments
                )
            }
        }
    }

    public func reachableCommitKeys(from start: Date, through end: Date) throws -> Set<String> {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT repository_id, hash FROM commits WHERE is_reachable = 1 AND author_time >= ? AND author_time <= ?",
                arguments: [start.timeIntervalSince1970, end.timeIntervalSince1970]
            )
            return Set(
                rows.map { row in
                    let repositoryID: String = row["repository_id"]
                    let hash: String = row["hash"]
                    return "\(repositoryID):\(hash)"
                })
        }
    }

    public func search(_ query: String, limit: Int = 50) throws -> [SearchResult] {
        precondition(limit > 0 && limit <= 500)
        let expression = Self.ftsExpression(query)
        guard !expression.isEmpty else { return [] }
        return try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT entity_type, entity_id, repository_id, occurred_at,
                           snippet(search_documents, 4, '', '', '…', 24) AS excerpt
                    FROM search_documents
                    WHERE search_documents MATCH ?
                    ORDER BY rank, occurred_at DESC
                    LIMIT ?
                    """,
                arguments: [expression, limit]
            )
            return try rows.map { row in
                let rawKind: String = row["entity_type"]
                guard let kind = SearchDocumentKind(rawValue: rawKind) else {
                    throw LedgerStoreError.unsupportedValue(type: "SearchDocumentKind", value: rawKind)
                }
                return SearchResult(
                    kind: kind,
                    entityID: row["entity_id"],
                    repositoryID: (row["repository_id"] as String?).map { RepositoryID($0) },
                    occurredAt: (row["occurred_at"] as Double?).map { Date(timeIntervalSince1970: $0) },
                    excerpt: row["excerpt"]
                )
            }
        }
    }

    /// Rebuilds message search from the canonical projection in one set-based
    /// operation. Shadow backfills defer incremental FTS writes and call this
    /// after source verification; normal collection continues to index each
    /// newly observed canonical message immediately.
    public func rebuildCanonicalMessageSearchIndex() throws {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM search_documents WHERE entity_type = 'message'")
            try db.execute(
                sql: """
                    INSERT INTO search_documents (
                        entity_type, entity_id, repository_id, occurred_at, content)
                    SELECT 'message', message.id, message.message_repository_id,
                           message.occurred_at, message.normalized_text
                    FROM session_messages message
                    WHERE message.disposition = 'work'
                      AND message.canonical_state = 'primary'
                      AND message.role != 'system'
                      AND NOT EXISTS (
                          SELECT 1 FROM message_aliases alias
                          WHERE alias.alias_id = message.id)
                    """)
        }
    }

    public func save(report: WorkReport) throws {
        let evidenceIDs = try encoder.encode(report.evidenceIDs.map(\.rawValue))
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reports (
                        id, period_start, period_end, state, summary, evidence_ids_json,
                        provider, model, generator_version, revision
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        state = excluded.state,
                        summary = excluded.summary,
                        evidence_ids_json = excluded.evidence_ids_json,
                        provider = excluded.provider,
                        model = excluded.model,
                        generator_version = excluded.generator_version,
                        revision = excluded.revision
                    """,
                arguments: [
                    report.id.rawValue,
                    report.periodStart.timeIntervalSince1970,
                    report.periodEnd.timeIntervalSince1970,
                    report.state.rawValue,
                    report.summary,
                    evidenceIDs,
                    report.provider,
                    report.model,
                    report.generatorVersion,
                    report.revision,
                ]
            )
            try Self.index(
                db: db,
                kind: .report,
                entityID: report.id.rawValue,
                repositoryID: nil,
                occurredAt: report.periodEnd,
                content: report.summary
            )
        }
    }

    public func reports(overlapping range: DateInterval) throws -> [WorkReport] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, period_start, period_end, state, summary, evidence_ids_json,
                           provider, model, generator_version, revision
                    FROM reports
                    WHERE period_start < ? AND period_end > ?
                    ORDER BY period_start, revision
                    """,
                arguments: [range.end.timeIntervalSince1970, range.start.timeIntervalSince1970]
            )
            return try rows.map { row in
                let stateValue: String = row["state"]
                guard let state = ReportPeriodState(rawValue: stateValue) else {
                    throw LedgerStoreError.unsupportedValue(type: "ReportPeriodState", value: stateValue)
                }
                let evidenceData: Data = row["evidence_ids_json"]
                return WorkReport(
                    id: ReportID(row["id"] as String),
                    periodStart: Date(timeIntervalSince1970: row["period_start"] as Double),
                    periodEnd: Date(timeIntervalSince1970: row["period_end"] as Double),
                    state: state,
                    summary: row["summary"],
                    evidenceIDs: try JSONDecoder().decode([String].self, from: evidenceData).map { EvidenceID($0) },
                    provider: row["provider"],
                    model: row["model"],
                    generatorVersion: row["generator_version"],
                    revision: row["revision"]
                )
            }
        }
    }

    public func hasReport(exactly range: DateInterval) throws -> Bool {
        try database.read { db in
            (try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM reports WHERE period_start = ? AND period_end = ? LIMIT 1",
                arguments: [range.start.timeIntervalSince1970, range.end.timeIntervalSince1970]
            )) != nil
        }
    }

    public func setCursor(_ data: Data, for sourceKey: String, at date: Date) throws {
        try database.write { db in
            try Self.setCursor(data, for: sourceKey, at: date, db: db)
        }
    }

    private static func setCursor(
        _ data: Data,
        for sourceKey: String,
        at date: Date,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO collector_cursors (source_key, cursor_json, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(source_key) DO UPDATE SET
                    cursor_json = excluded.cursor_json,
                    updated_at = excluded.updated_at
                """,
            arguments: [sourceKey, data, date.timeIntervalSince1970]
        )
    }

    public func cursor(for sourceKey: String) throws -> Data? {
        try database.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT cursor_json FROM collector_cursors WHERE source_key = ?",
                arguments: [sourceKey]
            )
        }
    }

    public func acquireLease(
        name: String,
        ownerID: String,
        now: Date,
        duration: TimeInterval
    ) throws -> Bool {
        precondition(duration > 0)
        let acquired = try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO collector_leases (name, owner_id, acquired_at, expires_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(name) DO UPDATE SET
                        owner_id = excluded.owner_id,
                        acquired_at = excluded.acquired_at,
                        expires_at = excluded.expires_at
                    WHERE collector_leases.expires_at <= excluded.acquired_at
                       OR collector_leases.owner_id = excluded.owner_id
                    """,
                arguments: [
                    name,
                    ownerID,
                    now.timeIntervalSince1970,
                    now.addingTimeInterval(duration).timeIntervalSince1970,
                ]
            )
            return db.changesCount == 1
        }
        secureDatabaseFiles()
        return acquired
    }

    public func releaseLease(name: String, ownerID: String) throws {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM collector_leases WHERE name = ? AND owner_id = ?",
                arguments: [name, ownerID]
            )
        }
    }

    public func leaseOwner(name: String) throws -> String? {
        try database.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT owner_id FROM collector_leases WHERE name = ?",
                arguments: [name]
            )
        }
    }

    public func recordHeartbeat(
        service: String,
        processID: Int32,
        observedAt: Date,
        state: String
    ) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO service_heartbeats (service, process_id, observed_at, state)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(service) DO UPDATE SET
                        process_id = excluded.process_id,
                        observed_at = excluded.observed_at,
                        state = excluded.state
                    """,
                arguments: [service, processID, observedAt.timeIntervalSince1970, state]
            )
        }
    }

    public func heartbeatObservedAt(service: String) throws -> Date? {
        try database.read { db in
            try Double.fetchOne(
                db,
                sql: "SELECT observed_at FROM service_heartbeats WHERE service = ?",
                arguments: [service]
            ).map(Date.init(timeIntervalSince1970:))
        }
    }

    public func replaceCollectorIssues(_ issues: [(sourceKey: String, message: String)], at date: Date) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM collector_issues")
            for issue in issues {
                try db.execute(
                    sql: "INSERT INTO collector_issues (source_key, message, observed_at) VALUES (?, ?, ?)",
                    arguments: [issue.sourceKey, issue.message, date.timeIntervalSince1970]
                )
            }
        }
    }

    public func replaceCollectorIssues(
        _ issues: [(sourceKey: String, message: String)],
        forSourceKeys sourceKeys: Set<String>,
        at date: Date
    ) throws {
        guard !sourceKeys.isEmpty else { return }
        try database.write { db in
            for sourceKey in sourceKeys {
                try db.execute(
                    sql: "DELETE FROM collector_issues WHERE source_key = ?",
                    arguments: [sourceKey])
            }
            for issue in issues where sourceKeys.contains(issue.sourceKey) {
                try db.execute(
                    sql: "INSERT INTO collector_issues (source_key, message, observed_at) VALUES (?, ?, ?)",
                    arguments: [issue.sourceKey, issue.message, date.timeIntervalSince1970])
            }
        }
    }

    public func collectorStatus() throws -> CollectorStatus {
        try database.read { db in
            let heartbeat = try Row.fetchOne(
                db,
                sql: "SELECT state, observed_at FROM service_heartbeats WHERE service = 'collector'"
            )
            return try CollectorStatus(
                state: heartbeat?["state"],
                observedAt: (heartbeat?["observed_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
                issueCount: Int.fetchOne(db, sql: "SELECT COUNT(*) FROM collector_issues") ?? 0
            )
        }
    }

    public func recordLiveCollectorStatus(
        _ status: LiveCollectorRuntimeStatus,
        at recordedAt: Date
    ) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO live_collector_status (
                        id, mode, pending_trigger_count, pending_path_count,
                        last_trigger_at, last_collection_started_at,
                        last_collection_finished_at, last_mutation_at,
                        last_latency_seconds, median_latency_seconds, p95_latency_seconds,
                        consecutive_failures, last_error, recorded_at
                    ) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        mode = excluded.mode,
                        pending_trigger_count = excluded.pending_trigger_count,
                        pending_path_count = excluded.pending_path_count,
                        last_trigger_at = excluded.last_trigger_at,
                        last_collection_started_at = excluded.last_collection_started_at,
                        last_collection_finished_at = excluded.last_collection_finished_at,
                        last_mutation_at = excluded.last_mutation_at,
                        last_latency_seconds = excluded.last_latency_seconds,
                        median_latency_seconds = excluded.median_latency_seconds,
                        p95_latency_seconds = excluded.p95_latency_seconds,
                        consecutive_failures = excluded.consecutive_failures,
                        last_error = excluded.last_error,
                        recorded_at = excluded.recorded_at
                    """,
                arguments: [
                    status.mode.rawValue,
                    status.pendingTriggerCount,
                    status.pendingPathCount,
                    status.lastTriggerAt?.timeIntervalSince1970,
                    status.lastCollectionStartedAt?.timeIntervalSince1970,
                    status.lastCollectionFinishedAt?.timeIntervalSince1970,
                    status.lastMutationAt?.timeIntervalSince1970,
                    status.lastLatencySeconds,
                    status.medianLatencySeconds,
                    status.p95LatencySeconds,
                    status.consecutiveFailures,
                    status.lastError,
                    recordedAt.timeIntervalSince1970,
                ])
        }
    }

    public func liveCollectorStatus() throws -> LiveCollectorRuntimeStatus? {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM live_collector_status WHERE id = 1"),
                let mode = LiveCollectorMode(rawValue: row["mode"] as String)
            else { return nil }
            return LiveCollectorRuntimeStatus(
                mode: mode,
                pendingTriggerCount: row["pending_trigger_count"],
                pendingPathCount: row["pending_path_count"],
                lastTriggerAt: (row["last_trigger_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
                lastCollectionStartedAt: (row["last_collection_started_at"] as Double?)
                    .map(Date.init(timeIntervalSince1970:)),
                lastCollectionFinishedAt: (row["last_collection_finished_at"] as Double?)
                    .map(Date.init(timeIntervalSince1970:)),
                lastMutationAt: (row["last_mutation_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
                lastLatencySeconds: row["last_latency_seconds"],
                medianLatencySeconds: row["median_latency_seconds"],
                p95LatencySeconds: row["p95_latency_seconds"],
                consecutiveFailures: row["consecutive_failures"],
                lastError: row["last_error"])
        }
    }

    public func health() throws -> LedgerHealth {
        let values = try database.read { db -> (String, String?, Date?, [String]) in
            let integrity = try String.fetchOne(db, sql: "PRAGMA quick_check") ?? "unknown"
            let heartbeat = try Row.fetchOne(
                db,
                sql: "SELECT state, observed_at FROM service_heartbeats WHERE service = 'collector'"
            )
            let issues = try Row.fetchAll(
                db,
                sql: "SELECT source_key, message FROM collector_issues ORDER BY source_key"
            ).map { row in
                let source: String = row["source_key"]
                let message: String = row["message"]
                return "\(source): \(message)"
            }
            return (
                integrity,
                heartbeat?["state"] as String?,
                (heartbeat?["observed_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
                issues
            )
        }
        var bytes: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            let path = databaseURL.path + suffix
            if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber {
                bytes += size.int64Value
            }
        }
        let backupStats = migrationBackupStats()
        return LedgerHealth(
            integrity: values.0,
            databaseBytes: bytes,
            collectorState: values.1,
            collectorObservedAt: values.2,
            collectorIssues: values.3,
            migrationBackupCount: backupStats.count,
            migrationBackupBytes: backupStats.bytes
        )
    }

    public func events(from start: Date, through end: Date) throws -> [LedgerEvent] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, evidence_id, occurred_at, observed_at, source, kind,
                           repository_id, working_copy_id, session_id, state, payload_json, schema_version
                    FROM events
                    WHERE occurred_at >= ? AND occurred_at <= ?
                    ORDER BY occurred_at, id
                    """,
                arguments: [start.timeIntervalSince1970, end.timeIntervalSince1970]
            )
            return try rows.map { try Self.decodeEvent($0) }
        }
    }

    public func events(from start: Date, through end: Date, kinds: Set<EventKind>) throws -> [LedgerEvent] {
        guard !kinds.isEmpty else { return [] }
        let values = kinds.map(\.rawValue).sorted()
        let placeholders = Array(repeating: "?", count: values.count).joined(separator: ", ")
        var arguments: StatementArguments = [start.timeIntervalSince1970, end.timeIntervalSince1970]
        arguments += StatementArguments(values)
        return try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, evidence_id, occurred_at, observed_at, source, kind,
                           repository_id, working_copy_id, session_id, state, payload_json, schema_version
                    FROM events
                    WHERE occurred_at >= ? AND occurred_at <= ?
                      AND kind IN (\(placeholders))
                    ORDER BY occurred_at, id
                    """,
                arguments: arguments
            )
            return try rows.map { try Self.decodeEvent($0) }
        }
    }

    public func recentEvents(
        from start: Date,
        through end: Date,
        kinds: Set<EventKind>,
        limit: Int = 500
    ) throws -> [LedgerEvent] {
        precondition(limit > 0 && limit <= 2_000)
        guard !kinds.isEmpty else { return [] }
        let values = kinds.map(\.rawValue).sorted()
        let placeholders = Array(repeating: "?", count: values.count).joined(separator: ", ")
        var arguments: StatementArguments = [start.timeIntervalSince1970, end.timeIntervalSince1970]
        arguments += StatementArguments(values)
        arguments += [limit]
        return try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, evidence_id, occurred_at, observed_at, source, kind,
                           repository_id, working_copy_id, session_id, state, payload_json, schema_version
                    FROM events
                    WHERE occurred_at >= ? AND occurred_at <= ?
                      AND kind IN (\(placeholders))
                    ORDER BY occurred_at DESC, id DESC
                    LIMIT ?
                    """,
                arguments: arguments
            )
            return try rows.map { try Self.decodeEvent($0) }
        }
    }

    public func repositories() throws -> [Repository] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, display_name, remote_identity, first_observed_at, last_observed_at
                    FROM repositories
                    ORDER BY display_name COLLATE NOCASE, id
                    """
            )
            return rows.map { row in
                Repository(
                    id: RepositoryID(row["id"] as String),
                    displayName: row["display_name"] as String,
                    remoteIdentity: row["remote_identity"] as String?,
                    firstObservedAt: Date(timeIntervalSince1970: row["first_observed_at"] as Double),
                    lastObservedAt: Date(timeIntervalSince1970: row["last_observed_at"] as Double)
                )
            }
        }
    }

    public func sessions(limit: Int = 100) throws -> [ConversationSession] {
        precondition(limit > 0 && limit <= 1_000)
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, source, source_session_id, started_at, last_observed_at,
                           working_directory, source_version, state
                    FROM sessions ORDER BY last_observed_at DESC, id LIMIT ?
                    """,
                arguments: [limit]
            ).map(Self.decodeSession)
        }
    }

    public func session(identifier: String) throws -> ConversationSession? {
        try database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT id, source, source_session_id, started_at, last_observed_at,
                           working_directory, source_version, state
                    FROM sessions WHERE id = ? OR source_session_id = ? LIMIT 1
                    """,
                arguments: [identifier, identifier]
            ).map(Self.decodeSession)
        }
    }

    public func messages(sessionID: SessionID, limit: Int = 500) throws -> [ConversationMessage] {
        precondition(limit > 0 && limit <= 1_000)
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT *
                    FROM (
                        SELECT *
                        FROM session_messages
                        WHERE session_id = ?
                        ORDER BY occurred_at DESC, id DESC
                        LIMIT ?
                    )
                    ORDER BY occurred_at, id
                    """,
                arguments: [sessionID.rawValue, limit]
            ).map(Self.decodeMessage)
        }
    }

    public func commit(identifier: String) throws -> GitCommit? {
        try database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT id, repository_id, hash, author_time, message, additions, deletions, files_changed,
                           first_observed_at, last_observed_at, is_reachable
                    FROM commits WHERE id = ? OR hash = ? LIMIT 1
                    """,
                arguments: [identifier, identifier]
            ).map(Self.decodeCommit)
        }
    }

    public func report(identifier: String) throws -> WorkReport? {
        try database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT id, period_start, period_end, state, summary, evidence_ids_json,
                           provider, model, generator_version, revision
                    FROM reports WHERE id = ? LIMIT 1
                    """,
                arguments: [identifier]
            ).map(Self.decodeReport)
        }
    }

    public func workingCopies(repositoryID: RepositoryID? = nil) throws -> [WorkingCopy] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, repository_id, canonical_path, branch, head_commit,
                           first_observed_at, last_observed_at
                    FROM working_copies
                    WHERE (? IS NULL OR repository_id = ?)
                    ORDER BY canonical_path
                    """,
                arguments: [repositoryID?.rawValue, repositoryID?.rawValue]
            )
            return rows.map { row in
                WorkingCopy(
                    id: WorkingCopyID(row["id"] as String),
                    repositoryID: RepositoryID(row["repository_id"] as String),
                    canonicalPath: row["canonical_path"],
                    branch: row["branch"],
                    headCommit: row["head_commit"],
                    firstObservedAt: Date(timeIntervalSince1970: row["first_observed_at"] as Double),
                    lastObservedAt: Date(timeIntervalSince1970: row["last_observed_at"] as Double)
                )
            }
        }
    }

    public func repositoryCatalog() throws -> [RepositoryCatalogItem] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT r.id AS repository_id, r.display_name, r.remote_identity,
                           r.first_observed_at AS repository_first_observed_at,
                           r.last_observed_at AS repository_last_observed_at,
                           w.id AS working_copy_id, w.canonical_path, w.branch, w.head_commit,
                           w.first_observed_at AS copy_first_observed_at,
                           w.last_observed_at AS copy_last_observed_at,
                           l.discovery_root_id, l.relative_path, d.display_name AS root_name
                    FROM repositories r
                    JOIN working_copies w ON w.repository_id = r.id
                    LEFT JOIN working_copy_locations l
                      ON l.working_copy_id = w.id AND l.valid_until IS NULL
                    LEFT JOIN discovery_roots d ON d.id = l.discovery_root_id
                    ORDER BY COALESCE(d.sort_order, 999999), d.display_name COLLATE NOCASE,
                             l.relative_path COLLATE NOCASE, r.display_name COLLATE NOCASE
                    """
            )
            return rows.map { row in
                let repositoryID = RepositoryID(row["repository_id"] as String)
                return RepositoryCatalogItem(
                    repository: Repository(
                        id: repositoryID,
                        displayName: row["display_name"],
                        remoteIdentity: row["remote_identity"],
                        firstObservedAt: Date(timeIntervalSince1970: row["repository_first_observed_at"] as Double),
                        lastObservedAt: Date(timeIntervalSince1970: row["repository_last_observed_at"] as Double)
                    ),
                    workingCopy: WorkingCopy(
                        id: WorkingCopyID(row["working_copy_id"] as String),
                        repositoryID: repositoryID,
                        canonicalPath: row["canonical_path"],
                        branch: row["branch"],
                        headCommit: row["head_commit"],
                        firstObservedAt: Date(timeIntervalSince1970: row["copy_first_observed_at"] as Double),
                        lastObservedAt: Date(timeIntervalSince1970: row["copy_last_observed_at"] as Double)
                    ),
                    discoveryRootID: (row["discovery_root_id"] as String?).map { DiscoveryRootID($0) },
                    discoveryRootName: row["root_name"],
                    relativePath: row["relative_path"]
                )
            }
        }
    }

    public func commits(repositoryID: RepositoryID, since: Date, limit: Int = 100) throws -> [GitCommit] {
        precondition(limit > 0 && limit <= 1_000)
        return try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, repository_id, hash, author_time, message, additions, deletions, files_changed,
                           first_observed_at, last_observed_at, is_reachable
                    FROM commits
                    WHERE repository_id = ? AND author_time >= ?
                    ORDER BY author_time DESC, hash
                    LIMIT ?
                    """,
                arguments: [repositoryID.rawValue, since.timeIntervalSince1970, limit]
            )
            return rows.map(Self.decodeCommit)
        }
    }

    public func messages(repositoryID: RepositoryID, since: Date, limit: Int = 100) throws -> [ConversationMessage] {
        precondition(limit > 0 && limit <= 1_000)
        return try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT m.*
                    FROM session_messages m
                    LEFT JOIN session_repositories sr ON sr.session_id = m.session_id
                    WHERE COALESCE(m.message_repository_id, sr.repository_id) = ?
                      AND COALESCE(m.occurred_at, 0) >= ?
                    ORDER BY m.occurred_at DESC, m.id
                    LIMIT ?
                    """,
                arguments: [repositoryID.rawValue, since.timeIntervalSince1970, limit]
            )
            return try rows.map(Self.decodeMessage)
        }
    }

    public func messages(ids: [MessageID]) throws -> [ConversationMessage] {
        let resolved = try messagesResolvingAliases(ids: ids)
        var unique: [MessageID: ConversationMessage] = [:]
        for message in resolved.values { unique[message.id] = message }
        return Array(unique.values)
    }

    public func canonicalMessageIDs(_ ids: [MessageID]) throws -> [MessageID: MessageID] {
        guard !ids.isEmpty else { return [:] }
        precondition(ids.count <= 2_000)
        return try database.read { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT alias_id, canonical_id FROM message_aliases WHERE alias_id IN (\(placeholders))",
                arguments: StatementArguments(ids.map(\.rawValue))
            )
            var result: [MessageID: MessageID] = [:]
            for id in ids { result[id] = id }
            for row in rows {
                result[MessageID(row["alias_id"] as String)] = MessageID(row["canonical_id"] as String)
            }
            return result
        }
    }

    public func messagesResolvingAliases(ids: [MessageID]) throws -> [MessageID: ConversationMessage] {
        guard !ids.isEmpty else { return [:] }
        precondition(ids.count <= 500)
        let mapping = try canonicalMessageIDs(ids)
        let canonicalIDs = Array(Set(mapping.values))
        return try database.read { db in
            let placeholders = Array(repeating: "?", count: canonicalIDs.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT *
                    FROM session_messages
                    WHERE id IN (\(placeholders))
                    """,
                arguments: StatementArguments(canonicalIDs.map(\.rawValue))
            )
            let messages = try Dictionary(
                uniqueKeysWithValues: rows.map {
                    let message = try Self.decodeMessage($0)
                    return (message.id, message)
                })
            var resolved: [MessageID: ConversationMessage] = [:]
            for requested in ids {
                guard let canonical = mapping[requested], let message = messages[canonical] else { continue }
                resolved[requested] = message
            }
            return resolved
        }
    }

    public func events(
        repositoryID: RepositoryID,
        from start: Date,
        through end: Date
    ) throws -> [LedgerEvent] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT e.id, e.evidence_id, e.occurred_at, e.observed_at, e.source, e.kind,
                           e.repository_id, e.working_copy_id, e.session_id, e.state,
                           e.payload_json, e.schema_version
                    FROM events e
                    WHERE e.occurred_at >= ? AND e.occurred_at <= ?
                      AND (
                        e.repository_id = ?
                        OR EXISTS (
                            SELECT 1 FROM session_repositories sr
                            WHERE sr.session_id = e.session_id AND sr.repository_id = ?
                        )
                      )
                    ORDER BY e.occurred_at, e.id
                    """,
                arguments: [
                    start.timeIntervalSince1970,
                    end.timeIntervalSince1970,
                    repositoryID.rawValue,
                    repositoryID.rawValue,
                ]
            )
            return try rows.map { try Self.decodeEvent($0) }
        }
    }

    public func upsert(discoveryRoot: DiscoveryRoot) throws {
        let excludedPaths = try encoder.encode(discoveryRoot.excludedPaths)
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO discovery_roots (
                        id, path, display_name, created_at, is_enabled, sort_order,
                        excluded_paths_json, last_scanned_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(path) DO UPDATE SET
                        display_name = excluded.display_name,
                        is_enabled = excluded.is_enabled,
                        sort_order = excluded.sort_order,
                        excluded_paths_json = excluded.excluded_paths_json,
                        last_scanned_at = COALESCE(excluded.last_scanned_at, discovery_roots.last_scanned_at)
                    """,
                arguments: [
                    discoveryRoot.id.rawValue,
                    discoveryRoot.canonicalPath,
                    discoveryRoot.displayName,
                    discoveryRoot.createdAt.timeIntervalSince1970,
                    discoveryRoot.isEnabled,
                    discoveryRoot.sortOrder,
                    excludedPaths,
                    discoveryRoot.lastScannedAt?.timeIntervalSince1970,
                ]
            )
        }
        TrackifyChangeSignal.post(for: databaseURL, kind: .ledger)
    }

    public func discoveryRoots(enabledOnly: Bool = false) throws -> [DiscoveryRoot] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, path, display_name, created_at, is_enabled, sort_order,
                           excluded_paths_json, last_scanned_at
                    FROM discovery_roots
                    WHERE (? = 0 OR is_enabled = 1)
                    ORDER BY sort_order, display_name COLLATE NOCASE, path
                    """,
                arguments: [enabledOnly]
            )
            return try rows.map { row in
                let excludedData: Data = row["excluded_paths_json"]
                return DiscoveryRoot(
                    id: DiscoveryRootID(row["id"] as String),
                    canonicalPath: row["path"],
                    displayName: row["display_name"],
                    isEnabled: row["is_enabled"],
                    sortOrder: row["sort_order"],
                    excludedPaths: try JSONDecoder().decode([String].self, from: excludedData),
                    createdAt: Date(timeIntervalSince1970: row["created_at"] as Double),
                    lastScannedAt: (row["last_scanned_at"] as Double?).map(Date.init(timeIntervalSince1970:))
                )
            }
        }
    }

    public func markDiscoveryRootScanned(id: DiscoveryRootID, at date: Date) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE discovery_roots SET last_scanned_at = ? WHERE id = ?",
                arguments: [date.timeIntervalSince1970, id.rawValue]
            )
        }
    }

    public func replaceWorkIntervals(
        overlapping range: DateInterval,
        with intervals: [WorkInterval]
    ) throws {
        let eventEncoder = JSONEncoder()
        eventEncoder.outputFormatting = [.sortedKeys]
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM work_intervals WHERE started_at < ? AND ended_at > ?",
                arguments: [range.end.timeIntervalSince1970, range.start.timeIntervalSince1970]
            )
            for interval in intervals {
                try db.execute(
                    sql: """
                        INSERT INTO work_intervals (
                            id, kind, started_at, ended_at, repository_id, session_id,
                            state, source_event_ids_json, derivation_version
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        interval.id.rawValue,
                        interval.kind.rawValue,
                        interval.startedAt.timeIntervalSince1970,
                        interval.endedAt.timeIntervalSince1970,
                        interval.repositoryID?.rawValue,
                        interval.sessionID?.rawValue,
                        interval.state.rawValue,
                        try eventEncoder.encode(interval.sourceEventIDs.map(\.rawValue)),
                        interval.derivationVersion,
                    ]
                )
            }
        }
    }

    public func workIntervals(overlapping range: DateInterval) throws -> [WorkInterval] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, kind, started_at, ended_at, repository_id, session_id,
                           state, source_event_ids_json, derivation_version
                    FROM work_intervals
                    WHERE started_at < ? AND ended_at > ?
                    ORDER BY started_at, id
                    """,
                arguments: [range.end.timeIntervalSince1970, range.start.timeIntervalSince1970]
            )
            return try rows.map { try Self.decodeWorkInterval($0) }
        }
    }

    private static func canonicalKey(for evidence: SourceEvidence) -> String {
        if let sourceRecordID = evidence.sourceRecordID, !sourceRecordID.isEmpty {
            return "\(evidence.source.rawValue):id:\(sourceRecordID)"
        }
        return "\(evidence.source.rawValue):fingerprint:\(evidence.fingerprint)"
    }

    private static func associateSessions(db: Database, with workingCopy: WorkingCopy) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT DISTINCT sessions.id, sessions.started_at
                FROM sessions
                LEFT JOIN session_messages ON session_messages.session_id = sessions.id
                WHERE sessions.working_directory = ? OR sessions.working_directory LIKE ?
                   OR session_messages.message_working_directory = ?
                   OR session_messages.message_working_directory LIKE ?
                """,
            arguments: [
                workingCopy.canonicalPath, workingCopy.canonicalPath + "/%",
                workingCopy.canonicalPath, workingCopy.canonicalPath + "/%",
            ]
        )
        for row in rows {
            let sessionID: String = row["id"]
            try db.execute(
                sql: """
                    INSERT INTO session_repositories (
                        session_id, repository_id, working_copy_id, method, confidence, valid_from
                    ) VALUES (?, ?, ?, 'working_directory', 1.0, ?)
                    ON CONFLICT(session_id, repository_id, method) DO UPDATE SET
                        working_copy_id = excluded.working_copy_id,
                        confidence = excluded.confidence
                    """,
                arguments: [sessionID, workingCopy.repositoryID.rawValue, workingCopy.id.rawValue, row["started_at"] as Double?]
            )
            try db.execute(
                sql: """
                    UPDATE session_messages SET message_repository_id = ?
                    WHERE session_id = ? AND message_repository_id IS NULL
                      AND (
                        message_working_directory = ?
                        OR message_working_directory LIKE ?
                        OR (message_working_directory IS NULL AND EXISTS (
                            SELECT 1 FROM sessions
                            WHERE sessions.id = session_messages.session_id
                              AND (sessions.working_directory = ?
                                   OR sessions.working_directory LIKE ?)))
                      )
                    """,
                arguments: [
                    workingCopy.repositoryID.rawValue, sessionID,
                    workingCopy.canonicalPath, workingCopy.canonicalPath + "/%",
                    workingCopy.canonicalPath, workingCopy.canonicalPath + "/%",
                ])
            try db.execute(
                sql: """
                    UPDATE logical_messages SET repository_id = ?
                    WHERE repository_id IS NULL AND id IN (
                        SELECT COALESCE(logical_message_id, id)
                        FROM session_messages
                        WHERE session_id = ? AND message_repository_id = ?)
                    """,
                arguments: [
                    workingCopy.repositoryID.rawValue, sessionID,
                    workingCopy.repositoryID.rawValue,
                ])
            try db.execute(
                sql: """
                    UPDATE search_documents SET repository_id = ?
                    WHERE entity_type = 'message' AND repository_id IS NULL
                      AND entity_id IN (
                        SELECT id FROM session_messages
                        WHERE session_id = ? AND message_repository_id = ?)
                    """,
                arguments: [
                    workingCopy.repositoryID.rawValue, sessionID,
                    workingCopy.repositoryID.rawValue,
                ])
            try db.execute(
                sql: """
                    UPDATE events SET repository_id = ?
                    WHERE session_id = ? AND repository_id IS NULL
                      AND kind = 'agent.message.observed'
                      AND json_extract(payload_json, '$.messageID') IN (
                        SELECT id FROM session_messages
                        WHERE session_id = ? AND message_repository_id = ?)
                    """,
                arguments: [
                    workingCopy.repositoryID.rawValue, sessionID, sessionID,
                    workingCopy.repositoryID.rawValue,
                ])
        }
    }

    private static func index(
        db: Database,
        kind: SearchDocumentKind,
        entityID: String,
        repositoryID: RepositoryID?,
        occurredAt: Date?,
        content: String
    ) throws {
        try db.execute(
            sql: "DELETE FROM search_documents WHERE entity_type = ? AND entity_id = ?",
            arguments: [kind.rawValue, entityID]
        )
        try db.execute(
            sql: """
                INSERT INTO search_documents (entity_type, entity_id, repository_id, occurred_at, content)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [kind.rawValue, entityID, repositoryID?.rawValue, occurredAt?.timeIntervalSince1970, content]
        )
    }

    private static func removeIndex(
        db: Database,
        kind: SearchDocumentKind,
        entityID: String
    ) throws {
        try db.execute(
            sql: "DELETE FROM search_documents WHERE entity_type = ? AND entity_id = ?",
            arguments: [kind.rawValue, entityID])
    }

    private static func repositoryID(db: Database, sessionID: SessionID) throws -> RepositoryID? {
        try String.fetchOne(
            db,
            sql: "SELECT repository_id FROM session_repositories WHERE session_id = ? ORDER BY confidence DESC LIMIT 1",
            arguments: [sessionID.rawValue]
        ).map { RepositoryID($0) }
    }

    private static func repositoryAssociation(
        db: Database,
        workingDirectory: String?
    ) throws -> (repositoryID: String, method: String, confidence: Double)? {
        guard let workingDirectory, !workingDirectory.isEmpty else { return nil }
        guard
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT repository_id
                    FROM working_copies
                    WHERE ? = canonical_path OR ? LIKE canonical_path || '/%'
                    ORDER BY LENGTH(canonical_path) DESC
                    LIMIT 1
                    """,
                arguments: [workingDirectory, workingDirectory])
        else { return nil }
        return (row["repository_id"], "record_working_directory", 1.0)
    }

    private static func upsertLogicalProjection(
        db: Database,
        message: ConversationMessage,
        source: String,
        sanitizedText: String,
        association: (repositoryID: String, method: String, confidence: Double)?
    ) throws {
        if let turnID = message.provenance.logicalTurnID,
            let sourceTurnID = message.provenance.sourceTurnID
        {
            try db.execute(
                sql: """
                    INSERT INTO logical_turns (
                        id, source, source_turn_id, session_id, origin,
                        started_at, last_observed_at, state, repository_id,
                        repository_method, repository_confidence,
                        classification_version)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 'unknown', ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        started_at = MIN(
                            COALESCE(logical_turns.started_at, excluded.started_at),
                            COALESCE(excluded.started_at, logical_turns.started_at)),
                        last_observed_at = MAX(
                            COALESCE(logical_turns.last_observed_at, excluded.last_observed_at),
                            COALESCE(excluded.last_observed_at, logical_turns.last_observed_at)),
                        origin = CASE
                            WHEN (CASE excluded.origin
                                WHEN 'human' THEN 70 WHEN 'agent' THEN 60
                                WHEN 'trackify' THEN 50 WHEN 'assistant' THEN 40
                                WHEN 'provider' THEN 30 WHEN 'hook' THEN 20
                                WHEN 'tool' THEN 10 WHEN 'system' THEN 5 ELSE 0 END)
                               > (CASE logical_turns.origin
                                WHEN 'human' THEN 70 WHEN 'agent' THEN 60
                                WHEN 'trackify' THEN 50 WHEN 'assistant' THEN 40
                                WHEN 'provider' THEN 30 WHEN 'hook' THEN 20
                                WHEN 'tool' THEN 10 WHEN 'system' THEN 5 ELSE 0 END)
                            THEN excluded.origin ELSE logical_turns.origin END,
                        repository_id = COALESCE(logical_turns.repository_id, excluded.repository_id),
                        repository_method = COALESCE(logical_turns.repository_method, excluded.repository_method),
                        repository_confidence = MAX(
                            COALESCE(logical_turns.repository_confidence, 0),
                            COALESCE(excluded.repository_confidence, 0))
                    """,
                arguments: [
                    turnID.rawValue, source, sourceTurnID,
                    message.sessionID.rawValue, message.provenance.origin.rawValue,
                    message.occurredAt?.timeIntervalSince1970,
                    message.occurredAt?.timeIntervalSince1970,
                    association?.repositoryID, association?.method,
                    association?.confidence,
                    message.provenance.classificationVersion,
                ])
        }

        let logicalMessageID =
            message.provenance.logicalMessageID?.rawValue
            ?? message.id.rawValue
        let textFingerprint = StableHash.sha256(sanitizedText)
        if let existing = try Row.fetchOne(
            db,
            sql: "SELECT role, text_fingerprint, origin, semantic_kind, disposition FROM logical_messages WHERE id = ?",
            arguments: [logicalMessageID])
        {
            let existingRole: String = existing["role"]
            let existingFingerprint: String = existing["text_fingerprint"]
            let existingOrigin: String = existing["origin"]
            let existingKind: String = existing["semantic_kind"]
            let existingDisposition: String = existing["disposition"]
            if existingRole != message.role.rawValue
                || existingFingerprint != textFingerprint
                || existingOrigin != message.provenance.origin.rawValue
                || existingKind != message.provenance.semanticKind.rawValue
                || existingDisposition != message.provenance.disposition.rawValue
            {
                try recordQualityIssue(
                    db: db, source: SourceKind(rawValue: source),
                    sourceKey: "logical-message:\(logicalMessageID)",
                    code: "conflicting-logical-message",
                    detail: "One authoritative logical message identity mapped to conflicting content or classification.",
                    observedAt: message.occurredAt
                        ?? Date(
                            timeIntervalSince1970: try Double.fetchOne(
                                db, sql: "SELECT last_observed_at FROM sessions WHERE id = ?",
                                arguments: [message.sessionID.rawValue]) ?? 0),
                    affectsWorkMetrics: true)
            }
            return
        }
        try db.execute(
            sql: """
                INSERT INTO logical_messages (
                    id, logical_turn_id, source, role, occurred_at,
                    normalized_text, text_fingerprint, origin, semantic_kind,
                    disposition, repository_id, classification_version,
                    classification_reason)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                logicalMessageID,
                message.provenance.logicalTurnID?.rawValue,
                source, message.role.rawValue,
                message.occurredAt?.timeIntervalSince1970,
                sanitizedText, textFingerprint,
                message.provenance.origin.rawValue,
                message.provenance.semanticKind.rawValue,
                message.provenance.disposition.rawValue,
                association?.repositoryID,
                message.provenance.classificationVersion,
                message.provenance.classificationReason,
            ])
    }

    private static func recordQualityIssue(
        db: Database,
        source: SourceKind?,
        sourceKey: String,
        code: String,
        detail: String,
        observedAt: Date,
        affectsWorkMetrics: Bool
    ) throws {
        let id = StableHash.sha256("evidence-quality:\(sourceKey):\(code)")
        try db.execute(
            sql: """
                INSERT INTO evidence_quality_issues (
                    id, source, source_key, code, detail, issue_count,
                    first_observed_at, last_observed_at, affects_work_metrics)
                VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?)
                ON CONFLICT(source_key, code) DO UPDATE SET
                    detail = excluded.detail,
                    issue_count = evidence_quality_issues.issue_count + 1,
                    last_observed_at = MAX(
                        evidence_quality_issues.last_observed_at,
                        excluded.last_observed_at),
                    affects_work_metrics = MAX(
                        evidence_quality_issues.affects_work_metrics,
                        excluded.affects_work_metrics)
                """,
            arguments: [
                id, source?.rawValue, sourceKey, code, detail,
                observedAt.timeIntervalSince1970,
                observedAt.timeIntervalSince1970,
                affectsWorkMetrics,
            ])
    }

    public func evidenceQuality() throws -> EvidenceQualitySnapshot {
        try database.read { db in
            let issues = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, source, source_key, code, detail, issue_count,
                           first_observed_at, last_observed_at, affects_work_metrics
                    FROM evidence_quality_issues
                    ORDER BY affects_work_metrics DESC, last_observed_at DESC, code
                    """
            ).map { row in
                EvidenceQualityIssue(
                    id: EvidenceQualityIssueID(row["id"] as String),
                    source: (row["source"] as String?).flatMap(SourceKind.init(rawValue:)),
                    sourceKey: row["source_key"], code: row["code"],
                    detail: row["detail"], count: row["issue_count"],
                    firstObservedAt: Date(
                        timeIntervalSince1970: row["first_observed_at"] as Double),
                    lastObservedAt: Date(
                        timeIntervalSince1970: row["last_observed_at"] as Double),
                    affectsWorkMetrics: row["affects_work_metrics"])
            }
            let unresolved =
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM conversation_records WHERE disposition = 'unresolved'") ?? 0
            let diagnostics =
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM conversation_records WHERE disposition = 'diagnostic'") ?? 0
            let aliases =
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM conversation_records WHERE canonical_state = 'alias'") ?? 0
            let replays =
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM conversation_records WHERE canonical_state = 'replay'") ?? 0
            let leakedInternal =
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*)
                        FROM session_messages
                        JOIN internal_provider_operations
                          ON internal_provider_operations.working_directory = session_messages.message_working_directory
                        WHERE session_messages.disposition = 'work'
                        """) ?? 0
            var allIssues = issues
            if leakedInternal > 0 {
                let observedAt = Date(timeIntervalSince1970: 0)
                allIssues.insert(
                    EvidenceQualityIssue(
                        id: EvidenceQualityIssueID(
                            StableHash.sha256("evidence-quality:internal-provider-leak")),
                        sourceKey: "internal-provider-operations",
                        code: "internal-provider-operation-reached-work",
                        detail: "Trackify-internal provider activity reached the work projection.",
                        count: leakedInternal, firstObservedAt: observedAt,
                        lastObservedAt: observedAt, affectsWorkMetrics: true),
                    at: 0)
            }
            return EvidenceQualitySnapshot(
                state: allIssues.contains(where: \.affectsWorkMetrics) || unresolved > 0
                    ? .degraded : .healthy,
                projectionVersion: ConversationProvenance.currentClassificationVersion,
                unresolvedRecordCount: unresolved,
                diagnosticRecordCount: diagnostics,
                aliasRecordCount: aliases,
                replayRecordCount: replays,
                issues: allIssues)
        }
    }

    @discardableResult
    public func refreshEvidenceQualityAudit(at observedAt: Date) throws -> EvidenceQualitySnapshot {
        try database.write { db in
            let missingTurn =
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM logical_messages
                        WHERE disposition = 'work'
                          AND origin IN ('human', 'agent')
                          AND logical_turn_id IS NULL
                          AND classification_reason != 'legacy-compatible'
                        """) ?? 0
            try Self.setAuditIssue(
                db: db, code: "work-message-without-logical-turn",
                count: missingTurn,
                detail: "One or more work intents lack a canonical logical turn.",
                observedAt: observedAt, affectsWorkMetrics: true)

            let incompatibleOrigins =
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM (
                            SELECT logical_turn_id
                            FROM logical_messages
                            WHERE logical_turn_id IS NOT NULL
                              AND disposition = 'work'
                              AND origin IN ('human', 'agent')
                            GROUP BY logical_turn_id
                            HAVING COUNT(DISTINCT origin) > 1
                        )
                        """) ?? 0
            try Self.setAuditIssue(
                db: db, code: "conflicting-logical-turn-origin",
                count: incompatibleOrigins,
                detail: "One or more logical turns have incompatible work origins.",
                observedAt: observedAt, affectsWorkMetrics: true)

            let aliasCycles =
                try Int.fetchOne(
                    db,
                    sql: """
                        WITH RECURSIVE alias_chain(start_id, current_id, depth) AS (
                            SELECT alias_id, canonical_id, 1 FROM message_aliases
                            UNION ALL
                            SELECT alias_chain.start_id, message_aliases.canonical_id,
                                   alias_chain.depth + 1
                            FROM alias_chain
                            JOIN message_aliases
                              ON message_aliases.alias_id = alias_chain.current_id
                            WHERE alias_chain.depth < 100
                        )
                        SELECT COUNT(DISTINCT start_id)
                        FROM alias_chain
                        WHERE start_id = current_id
                        """) ?? 0
            try Self.setAuditIssue(
                db: db, code: "message-alias-cycle", count: aliasCycles,
                detail: "One or more canonical message aliases form a cycle.",
                observedAt: observedAt, affectsWorkMetrics: true)

            let internalLeaks =
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*)
                        FROM logical_messages
                        WHERE disposition = 'work' AND origin = 'trackify'
                        """) ?? 0
            try Self.setAuditIssue(
                db: db, code: "internal-provider-operation-reached-work",
                count: internalLeaks,
                detail: "Trackify-internal provider activity reached the work projection.",
                observedAt: observedAt, affectsWorkMetrics: true)

            let missingRepository =
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM logical_messages
                        WHERE disposition = 'work' AND repository_id IS NULL
                          AND classification_reason != 'legacy-compatible'
                        """) ?? 0
            try Self.setAuditIssue(
                db: db, code: "work-repository-unresolved", count: missingRepository,
                detail: "Some work evidence has no supported contemporaneous repository association.",
                observedAt: observedAt, affectsWorkMetrics: false)

            let highRatioSessions =
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM (
                            SELECT session_id
                            FROM conversation_records
                            GROUP BY session_id
                            HAVING COUNT(*) > 200
                               AND COUNT(*) > 100 * CASE
                                   WHEN COUNT(DISTINCT logical_turn_id) > 0
                                   THEN COUNT(DISTINCT logical_turn_id)
                                   ELSE 1 END
                        )
                        """) ?? 0
            try Self.setAuditIssue(
                db: db, code: "unusual-records-per-logical-turn",
                count: highRatioSessions,
                detail: "One or more sessions have an unusual source-record to logical-turn ratio.",
                observedAt: observedAt, affectsWorkMetrics: false)
        }
        return try evidenceQuality()
    }

    public func beginInternalProviderOperation(
        id: String,
        provider: String,
        purpose: String,
        workingDirectory: URL,
        startedAt: Date
    ) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO internal_provider_operations (
                        id, provider, purpose, working_directory, started_at,
                        finished_at, state)
                    VALUES (?, ?, ?, ?, ?, NULL, 'running')
                    """,
                arguments: [
                    id, provider, purpose, workingDirectory.standardizedFileURL.path,
                    startedAt.timeIntervalSince1970,
                ])
        }
    }

    public func finishInternalProviderOperation(
        id: String,
        state: String,
        finishedAt: Date
    ) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE internal_provider_operations
                    SET state = ?, finished_at = ?
                    WHERE id = ?
                    """,
                arguments: [state, finishedAt.timeIntervalSince1970, id])
        }
    }

    @discardableResult
    public func recoverInterruptedInternalProviderOperations(at date: Date) throws -> Int {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE internal_provider_operations
                    SET state = 'failed', finished_at = ?
                    WHERE state = 'running'
                    """,
                arguments: [date.timeIntervalSince1970])
            return db.changesCount
        }
    }

    private static func setAuditIssue(
        db: Database,
        code: String,
        count: Int,
        detail: String,
        observedAt: Date,
        affectsWorkMetrics: Bool
    ) throws {
        let sourceKey = "semantic-audit"
        guard count > 0 else {
            try db.execute(
                sql: "DELETE FROM evidence_quality_issues WHERE source_key = ? AND code = ?",
                arguments: [sourceKey, code])
            return
        }
        let id = StableHash.sha256("evidence-quality:\(sourceKey):\(code)")
        try db.execute(
            sql: """
                INSERT INTO evidence_quality_issues (
                    id, source, source_key, code, detail, issue_count,
                    first_observed_at, last_observed_at, affects_work_metrics)
                VALUES (?, NULL, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source_key, code) DO UPDATE SET
                    detail = excluded.detail,
                    issue_count = excluded.issue_count,
                    last_observed_at = excluded.last_observed_at,
                    affects_work_metrics = excluded.affects_work_metrics
                """,
            arguments: [
                id, sourceKey, code, detail, count,
                observedAt.timeIntervalSince1970,
                observedAt.timeIntervalSince1970,
                affectsWorkMetrics,
            ])
    }

    private static func ftsExpression(_ query: String) -> String {
        query
            .split(whereSeparator: { $0.isWhitespace })
            .map { token in
                let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\"*"
            }
            .joined(separator: " AND ")
    }

    private func secureDatabaseFiles() {
        for suffix in ["", "-wal", "-shm"] {
            let path = databaseURL.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { continue }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

    private func createMigrationBackupIfNeeded() throws {
        let migrator = LedgerSchema.migrator
        let state = try database.read { db in
            (try migrator.hasCompletedMigrations(db), try migrator.appliedIdentifiers(db))
        }
        guard !state.0, !state.1.isEmpty else { return }
        let directory = databaseURL.deletingLastPathComponent().appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let destination = directory.appending(path: "trackify-pre-migration-\(UUID().uuidString).sqlite")
        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
        let writer = try DatabaseQueue(path: destination.path, configuration: configuration)
        try database.backup(to: writer)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private func migrationBackupStats() -> (count: Int, bytes: Int64) {
        let directory = databaseURL.deletingLastPathComponent().appending(path: "Backups", directoryHint: .isDirectory)
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else { return (0, 0) }
        var count = 0
        var bytes: Int64 = 0
        for url in urls where url.pathExtension == "sqlite" {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                values.isRegularFile == true
            else { continue }
            count += 1
            bytes += Int64(values.fileSize ?? 0)
        }
        return (count, bytes)
    }

    private static func requiredEnum<Value: RawRepresentable>(
        _ type: Value.Type,
        value: String
    ) throws -> Value where Value.RawValue == String {
        guard let result = Value(rawValue: value) else {
            throw LedgerStoreError.unsupportedValue(type: String(describing: Value.self), value: value)
        }
        return result
    }

    private static func decodeEvent(_ row: Row) throws -> LedgerEvent {
        let payloadData: Data = row["payload_json"]
        let sourceValue: String = row["source"]
        let kindValue: String = row["kind"]
        let stateValue: String? = row["state"]
        let repositoryValue: String? = row["repository_id"]
        let workingCopyValue: String? = row["working_copy_id"]
        let sessionValue: String? = row["session_id"]
        let state = try stateValue.map { try requiredEnum(ObservedState.self, value: $0) }
        return LedgerEvent(
            id: EventID(row["id"] as String),
            evidenceID: EvidenceID(row["evidence_id"] as String),
            occurredAt: Date(timeIntervalSince1970: row["occurred_at"] as Double),
            observedAt: Date(timeIntervalSince1970: row["observed_at"] as Double),
            source: try requiredEnum(SourceKind.self, value: sourceValue),
            kind: try requiredEnum(EventKind.self, value: kindValue),
            repositoryID: repositoryValue.map { RepositoryID($0) },
            workingCopyID: workingCopyValue.map { WorkingCopyID($0) },
            sessionID: sessionValue.map { SessionID($0) },
            state: state,
            payload: try JSONDecoder().decode([String: String].self, from: payloadData),
            schemaVersion: row["schema_version"] as Int
        )
    }

    private static func decodeSession(_ row: Row) throws -> ConversationSession {
        ConversationSession(
            id: SessionID(row["id"] as String),
            source: try requiredEnum(SourceKind.self, value: row["source"] as String),
            sourceSessionID: row["source_session_id"],
            startedAt: (row["started_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            lastObservedAt: Date(timeIntervalSince1970: row["last_observed_at"] as Double),
            workingDirectory: row["working_directory"],
            sourceVersion: row["source_version"],
            state: try requiredEnum(ObservedState.self, value: row["state"] as String)
        )
    }

    private static func decodeMessage(_ row: Row) throws -> ConversationMessage {
        func string(_ name: String) -> String? {
            guard row.columnNames.contains(name) else { return nil }
            return row[name]
        }
        func bool(_ name: String) -> Bool {
            guard row.columnNames.contains(name) else { return false }
            return row[name] as Bool
        }
        func int(_ name: String) -> Int? {
            guard row.columnNames.contains(name) else { return nil }
            return row[name]
        }
        let origin = string("origin").flatMap(ConversationOrigin.init(rawValue:)) ?? .unknown
        let semanticKind =
            string("semantic_kind")
            .flatMap(ConversationSemanticKind.init(rawValue:)) ?? .unknown
        let disposition = string("disposition").flatMap(EvidenceDisposition.init(rawValue:)) ?? .work
        let canonicalState =
            string("canonical_state")
            .flatMap(CanonicalRecordState.init(rawValue:)) ?? .primary
        let logicalTurnID = string("logical_turn_id").map { LogicalTurnID($0) }
        let logicalMessageID = string("logical_message_id").map { LogicalMessageID($0) }
        let provenance = ConversationProvenance(
            sourceRecordID: string("source_record_id"),
            sourceRecordType: string("source_record_type") ?? "legacy",
            sourceTurnID: string("source_turn_id"),
            parentSourceRecordID: string("parent_source_record_id"),
            sourceResponseID: string("source_response_id"),
            entrypoint: string("entrypoint"),
            workingDirectory: string("message_working_directory"),
            isMeta: bool("is_meta"), isSidechain: bool("is_sidechain"),
            origin: origin, semanticKind: semanticKind,
            disposition: disposition, canonicalState: canonicalState,
            classificationVersion: int("classification_version") ?? 0,
            classificationReason: string("classification_reason") ?? "legacy-compatible",
            logicalTurnID: logicalTurnID,
            logicalMessageID: logicalMessageID)
        return ConversationMessage(
            id: MessageID(row["id"] as String),
            sessionID: SessionID(row["session_id"] as String),
            sourceMessageID: row["source_message_id"],
            role: try requiredEnum(MessageRole.self, value: row["role"] as String),
            occurredAt: (row["occurred_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            normalizedText: MessageTextSanitizer.sanitize(row["normalized_text"] as String),
            fingerprint: row["fingerprint"],
            provenance: provenance
        )
    }

    private static func decodeCommit(_ row: Row) -> GitCommit {
        GitCommit(
            id: row["id"],
            repositoryID: RepositoryID(row["repository_id"] as String),
            hash: row["hash"],
            authorTime: Date(timeIntervalSince1970: row["author_time"] as Double),
            message: row["message"],
            additions: row["additions"],
            deletions: row["deletions"],
            filesChanged: row["files_changed"],
            firstObservedAt: Date(timeIntervalSince1970: row["first_observed_at"] as Double),
            lastObservedAt: Date(timeIntervalSince1970: row["last_observed_at"] as Double),
            isReachable: row["is_reachable"]
        )
    }

    private static func decodeReport(_ row: Row) throws -> WorkReport {
        let evidenceData: Data = row["evidence_ids_json"]
        return WorkReport(
            id: ReportID(row["id"] as String),
            periodStart: Date(timeIntervalSince1970: row["period_start"] as Double),
            periodEnd: Date(timeIntervalSince1970: row["period_end"] as Double),
            state: try requiredEnum(ReportPeriodState.self, value: row["state"] as String),
            summary: row["summary"],
            evidenceIDs: try JSONDecoder().decode([String].self, from: evidenceData).map { EvidenceID($0) },
            provider: row["provider"],
            model: row["model"],
            generatorVersion: row["generator_version"],
            revision: row["revision"]
        )
    }

    private static func decodeWorkInterval(_ row: Row) throws -> WorkInterval {
        let eventData: Data = row["source_event_ids_json"]
        let eventIDs = try JSONDecoder().decode([String].self, from: eventData).map { EventID($0) }
        let kindValue: String = row["kind"]
        let stateValue: String = row["state"]
        let repositoryValue: String? = row["repository_id"]
        let sessionValue: String? = row["session_id"]
        return WorkInterval(
            id: WorkIntervalID(row["id"] as String),
            kind: try requiredEnum(WorkIntervalKind.self, value: kindValue),
            startedAt: Date(timeIntervalSince1970: row["started_at"] as Double),
            endedAt: Date(timeIntervalSince1970: row["ended_at"] as Double),
            repositoryID: repositoryValue.map { RepositoryID($0) },
            sessionID: sessionValue.map { SessionID($0) },
            state: try requiredEnum(ObservedState.self, value: stateValue),
            sourceEventIDs: eventIDs,
            derivationVersion: row["derivation_version"] as Int
        )
    }
}
