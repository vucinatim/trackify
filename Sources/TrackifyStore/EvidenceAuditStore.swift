import Foundation
import GRDB
import TrackifyDomain

public struct CanonicalLedgerAudit: Codable, Equatable, Sendable {
    public let sourceObservations: Int
    public let normalizedRecords: Int
    public let logicalTurns: Int
    public let logicalMessages: Int
    public let workTurns: Int
    public let workMessages: Int
    public let diagnosticRecords: Int
    public let controlRecords: Int
    public let unresolvedRecords: Int
    public let aliases: Int
    public let replays: Int
    public let canonicalFingerprint: String
    public let evidenceFingerprint: String

    public init(
        sourceObservations: Int, normalizedRecords: Int,
        logicalTurns: Int, logicalMessages: Int,
        workTurns: Int, workMessages: Int,
        diagnosticRecords: Int, controlRecords: Int,
        unresolvedRecords: Int, aliases: Int, replays: Int,
        canonicalFingerprint: String,
        evidenceFingerprint: String
    ) {
        self.sourceObservations = sourceObservations
        self.normalizedRecords = normalizedRecords
        self.logicalTurns = logicalTurns
        self.logicalMessages = logicalMessages
        self.workTurns = workTurns
        self.workMessages = workMessages
        self.diagnosticRecords = diagnosticRecords
        self.controlRecords = controlRecords
        self.unresolvedRecords = unresolvedRecords
        self.aliases = aliases
        self.replays = replays
        self.canonicalFingerprint = canonicalFingerprint
        self.evidenceFingerprint = evidenceFingerprint
    }
}

extension LedgerStore {
    public func replaceEvidenceCoverage(_ coverage: EvidenceLedgerCoverage) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO evidence_ledger_coverage (
                        id, calendar_days, coverage_start, coverage_cutoff,
                        recorded_at, canonical_fingerprint)
                    VALUES (1, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        calendar_days = excluded.calendar_days,
                        coverage_start = excluded.coverage_start,
                        coverage_cutoff = excluded.coverage_cutoff,
                        recorded_at = excluded.recorded_at,
                        canonical_fingerprint = excluded.canonical_fingerprint
                    """,
                arguments: [
                    coverage.calendarDays,
                    coverage.start.timeIntervalSince1970,
                    coverage.cutoff.timeIntervalSince1970,
                    coverage.recordedAt.timeIntervalSince1970,
                    coverage.canonicalFingerprint,
                ])
            try db.execute(sql: "DELETE FROM evidence_source_read_audits")
            for source in coverage.sourceReads {
                try db.execute(
                    sql: """
                        INSERT INTO evidence_source_read_audits (
                            source_key, unit, candidates_considered, units_opened,
                            bytes_read, records_observed, records_accepted)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        source.sourceKey, source.unit.rawValue,
                        source.candidatesConsidered, source.unitsOpened,
                        source.bytesRead, source.recordsObserved, source.recordsAccepted,
                    ])
            }
        }
    }

    public func evidenceCoverage() throws -> EvidenceLedgerCoverage? {
        try database.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT calendar_days, coverage_start, coverage_cutoff,
                               recorded_at, canonical_fingerprint
                        FROM evidence_ledger_coverage WHERE id = 1
                        """)
            else { return nil }
            let sources = try Row.fetchAll(
                db,
                sql: """
                    SELECT source_key, unit, candidates_considered, units_opened,
                           bytes_read, records_observed, records_accepted
                    FROM evidence_source_read_audits ORDER BY source_key
                    """
            ).compactMap { source -> EvidenceSourceReadAudit? in
                guard let unit = EvidenceSourceUnit(rawValue: source["unit"] as String)
                else { return nil }
                return EvidenceSourceReadAudit(
                    sourceKey: source["source_key"], unit: unit,
                    candidatesConsidered: source["candidates_considered"],
                    unitsOpened: source["units_opened"],
                    bytesRead: source["bytes_read"],
                    recordsObserved: source["records_observed"],
                    recordsAccepted: source["records_accepted"])
            }
            return EvidenceLedgerCoverage(
                calendarDays: row["calendar_days"],
                start: Date(timeIntervalSince1970: row["coverage_start"] as Double),
                cutoff: Date(timeIntervalSince1970: row["coverage_cutoff"] as Double),
                recordedAt: Date(timeIntervalSince1970: row["recorded_at"] as Double),
                canonicalFingerprint: row["canonical_fingerprint"],
                sourceReads: sources)
        }
    }

    public func canonicalAudit() throws -> CanonicalLedgerAudit {
        try database.read { db in
            func count(_ sql: String) throws -> Int {
                try Int.fetchOne(db, sql: sql) ?? 0
            }
            let rows = try String.fetchAll(
                db,
                sql: """
                    SELECT value FROM (
                        SELECT 't|' || id || '|' || source || '|' || source_turn_id
                            || '|' || origin || '|' || state
                            || '|' || COALESCE(repository_id, '') AS value
                        FROM logical_turns
                        UNION ALL
                        SELECT 'm|' || id || '|' || COALESCE(logical_turn_id, '')
                            || '|' || source || '|' || role || '|' || text_fingerprint
                            || '|' || origin || '|' || semantic_kind || '|' || disposition
                            || '|' || COALESCE(repository_id, '') AS value
                        FROM logical_messages
                        UNION ALL
                        SELECT 'c|' || repository_id || '|' || hash || '|'
                            || CAST(author_time AS TEXT) AS value
                        FROM commits WHERE is_reachable = 1
                    ) ORDER BY value
                    """)
            let evidenceRows = try String.fetchAll(
                db,
                sql: """
                    SELECT id || '|' || source || '|' || source_record_type || '|'
                        || COALESCE(source_turn_id, '') || '|' || origin || '|'
                        || semantic_kind || '|' || disposition || '|'
                        || canonical_state || '|' || COALESCE(logical_turn_id, '') || '|'
                        || COALESCE(logical_message_id, '') || '|'
                        || COALESCE(repository_id, '')
                    FROM conversation_records ORDER BY id
                    """)
            return CanonicalLedgerAudit(
                sourceObservations: try count("SELECT COUNT(*) FROM source_observations"),
                normalizedRecords: try count("SELECT COUNT(*) FROM conversation_records"),
                logicalTurns: try count("SELECT COUNT(*) FROM logical_turns"),
                logicalMessages: try count("SELECT COUNT(*) FROM logical_messages"),
                workTurns: try count(
                    """
                    SELECT COUNT(DISTINCT logical_turn_id) FROM logical_messages
                    WHERE disposition = 'work' AND origin IN ('human', 'agent')
                      AND semantic_kind IN ('intent', 'steering')
                    """),
                workMessages: try count(
                    "SELECT COUNT(*) FROM logical_messages WHERE disposition = 'work'"),
                diagnosticRecords: try count(
                    "SELECT COUNT(*) FROM conversation_records WHERE disposition = 'diagnostic'"),
                controlRecords: try count(
                    "SELECT COUNT(*) FROM conversation_records WHERE disposition = 'control'"),
                unresolvedRecords: try count(
                    "SELECT COUNT(*) FROM conversation_records WHERE disposition = 'unresolved'"),
                aliases: try count(
                    "SELECT COUNT(*) FROM conversation_records WHERE canonical_state = 'alias'"),
                replays: try count(
                    "SELECT COUNT(*) FROM conversation_records WHERE canonical_state = 'replay'"),
                canonicalFingerprint: StableHash.sha256(rows.joined(separator: "\n")),
                evidenceFingerprint: StableHash.sha256(
                    evidenceRows.joined(separator: "\n")))
        }
    }

    public func evidenceDateBounds() throws -> DateInterval? {
        try database.read { db in
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT MIN(occurred_at) AS first, MAX(occurred_at) AS last FROM events"),
                let first = row["first"] as Double?, let last = row["last"] as Double?
            else { return nil }
            return DateInterval(
                start: Date(timeIntervalSince1970: first),
                end: Date(timeIntervalSince1970: max(first + 0.001, last + 0.001)))
        }
    }

    public func evidenceCoverageViolationCount(in range: DateInterval) throws -> Int {
        try database.read { db in
            let arguments: StatementArguments = [
                range.start.timeIntervalSince1970, range.end.timeIntervalSince1970,
            ]
            let records =
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM conversation_records
                        WHERE occurred_at IS NOT NULL
                          AND (occurred_at < ? OR occurred_at >= ?)
                        """,
                    arguments: arguments) ?? 0
            let messages =
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM logical_messages
                        WHERE occurred_at IS NOT NULL
                          AND (occurred_at < ? OR occurred_at >= ?)
                        """,
                    arguments: arguments) ?? 0
            let commits =
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM commits
                        WHERE author_time < ? OR author_time >= ?
                        """,
                    arguments: arguments) ?? 0
            return records + messages + commits
        }
    }

    public func checkpoint() throws {
        try database.writeWithoutTransaction { db in
            _ = try Row.fetchAll(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    public func internalProviderOperationStates() throws -> [String: Int] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT state, COUNT(*) AS count FROM internal_provider_operations GROUP BY state")
            return Dictionary(
                uniqueKeysWithValues: rows.map {
                    ($0["state"] as String, $0["count"] as Int)
                })
        }
    }
}
