import Foundation
import GRDB
import TrackifyDomain

enum LedgerSchema {
    static let initialMigration = "0001_initial"
    static let diagnosticsMigration = "0002_collector_diagnostics"
    static let messageAliasesMigration = "0003_message_aliases"
    static let nearDuplicateMessagesMigration = "0004_near_duplicate_messages"
    static let messagePrivacyMigration = "0005_message_privacy"
    static let workIntelligenceMigration = "0006_work_intelligence"
    static let messageDuplicateTolerance = 0.5

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(initialMigration) { db in
            // Development builds used the same schema under 0001_v1_draft.
            // Treat it as the frozen V1 schema without destructively recreating it.
            if try db.tableExists("repositories") { return }
            try db.execute(
                sql: """
                    CREATE TABLE discovery_roots (
                        id TEXT PRIMARY KEY NOT NULL,
                        path TEXT NOT NULL UNIQUE,
                        display_name TEXT NOT NULL,
                        created_at REAL NOT NULL,
                        is_enabled INTEGER NOT NULL DEFAULT 1,
                        sort_order INTEGER NOT NULL DEFAULT 0,
                        excluded_paths_json BLOB NOT NULL,
                        last_scanned_at REAL
                    );

                    CREATE TABLE repositories (
                        id TEXT PRIMARY KEY NOT NULL,
                        display_name TEXT NOT NULL,
                        remote_identity TEXT,
                        first_observed_at REAL NOT NULL,
                        last_observed_at REAL NOT NULL
                    );

                    CREATE TABLE working_copies (
                        id TEXT PRIMARY KEY NOT NULL,
                        repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
                        canonical_path TEXT NOT NULL UNIQUE,
                        branch TEXT,
                        head_commit TEXT,
                        first_observed_at REAL NOT NULL,
                        last_observed_at REAL NOT NULL
                    );

                    CREATE TABLE working_copy_locations (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        working_copy_id TEXT NOT NULL REFERENCES working_copies(id) ON DELETE CASCADE,
                        discovery_root_id TEXT REFERENCES discovery_roots(id) ON DELETE SET NULL,
                        path TEXT NOT NULL,
                        relative_path TEXT,
                        valid_from REAL NOT NULL,
                        valid_until REAL
                    );

                    CREATE TABLE sessions (
                        id TEXT PRIMARY KEY NOT NULL,
                        source TEXT NOT NULL,
                        source_session_id TEXT NOT NULL,
                        started_at REAL,
                        last_observed_at REAL NOT NULL,
                        working_directory TEXT,
                        source_version TEXT,
                        state TEXT NOT NULL,
                        UNIQUE(source, source_session_id)
                    );

                    CREATE TABLE session_repositories (
                        session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                        repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
                        working_copy_id TEXT REFERENCES working_copies(id) ON DELETE SET NULL,
                        method TEXT NOT NULL,
                        confidence REAL NOT NULL,
                        valid_from REAL,
                        valid_until REAL,
                        PRIMARY KEY(session_id, repository_id, method)
                    );

                    CREATE TABLE session_messages (
                        id TEXT PRIMARY KEY NOT NULL,
                        session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                        source_message_id TEXT,
                        role TEXT NOT NULL,
                        occurred_at REAL,
                        normalized_text TEXT NOT NULL,
                        fingerprint TEXT NOT NULL,
                        UNIQUE(session_id, fingerprint)
                    );

                    CREATE TABLE commits (
                        id TEXT PRIMARY KEY NOT NULL,
                        repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
                        hash TEXT NOT NULL,
                        author_time REAL NOT NULL,
                        message TEXT NOT NULL,
                        additions INTEGER,
                        deletions INTEGER,
                        files_changed INTEGER,
                        first_observed_at REAL NOT NULL,
                        last_observed_at REAL NOT NULL,
                        is_reachable INTEGER NOT NULL,
                        UNIQUE(repository_id, hash)
                    );

                    CREATE TABLE working_tree_snapshots (
                        id TEXT PRIMARY KEY NOT NULL,
                        working_copy_id TEXT NOT NULL REFERENCES working_copies(id) ON DELETE CASCADE,
                        observed_at REAL NOT NULL,
                        fingerprint TEXT NOT NULL,
                        changed_files INTEGER NOT NULL,
                        additions INTEGER,
                        deletions INTEGER,
                        is_clean INTEGER NOT NULL,
                        UNIQUE(working_copy_id, fingerprint)
                    );

                    CREATE TABLE process_runs (
                        id TEXT PRIMARY KEY NOT NULL,
                        session_id TEXT REFERENCES sessions(id) ON DELETE CASCADE,
                        source_turn_id TEXT,
                        parent_run_id TEXT REFERENCES process_runs(id) ON DELETE SET NULL,
                        kind TEXT NOT NULL,
                        started_at REAL NOT NULL,
                        ended_at REAL,
                        state TEXT NOT NULL
                    );

                    CREATE TABLE source_observations (
                        id TEXT PRIMARY KEY NOT NULL,
                        canonical_key TEXT NOT NULL UNIQUE,
                        source TEXT NOT NULL,
                        ingestion_path TEXT NOT NULL,
                        source_record_id TEXT,
                        fingerprint TEXT NOT NULL,
                        occurred_at REAL NOT NULL,
                        first_observed_at REAL NOT NULL,
                        last_observed_at REAL NOT NULL,
                        adapter_version INTEGER NOT NULL
                    );

                    CREATE TABLE events (
                        id TEXT PRIMARY KEY NOT NULL,
                        evidence_id TEXT NOT NULL REFERENCES source_observations(id) ON DELETE RESTRICT,
                        occurred_at REAL NOT NULL,
                        observed_at REAL NOT NULL,
                        source TEXT NOT NULL,
                        kind TEXT NOT NULL,
                        repository_id TEXT REFERENCES repositories(id) ON DELETE SET NULL,
                        working_copy_id TEXT REFERENCES working_copies(id) ON DELETE SET NULL,
                        session_id TEXT REFERENCES sessions(id) ON DELETE SET NULL,
                        state TEXT,
                        payload_json BLOB NOT NULL,
                        schema_version INTEGER NOT NULL
                    );

                    CREATE INDEX events_occurred_at ON events(occurred_at);
                    CREATE INDEX events_repository_time ON events(repository_id, occurred_at);
                    CREATE INDEX events_session_time ON events(session_id, occurred_at);

                    CREATE TABLE work_intervals (
                        id TEXT PRIMARY KEY NOT NULL,
                        kind TEXT NOT NULL,
                        started_at REAL NOT NULL,
                        ended_at REAL NOT NULL,
                        repository_id TEXT REFERENCES repositories(id) ON DELETE CASCADE,
                        session_id TEXT REFERENCES sessions(id) ON DELETE CASCADE,
                        state TEXT NOT NULL,
                        source_event_ids_json BLOB NOT NULL,
                        derivation_version INTEGER NOT NULL
                    );

                    CREATE TABLE hourly_rollups (
                        period_start REAL NOT NULL,
                        timezone_id TEXT NOT NULL,
                        tracked_seconds REAL NOT NULL,
                        agent_seconds REAL NOT NULL,
                        commits INTEGER NOT NULL,
                        files_touched INTEGER NOT NULL,
                        additions INTEGER NOT NULL,
                        deletions INTEGER NOT NULL,
                        derivation_version INTEGER NOT NULL,
                        PRIMARY KEY(period_start, timezone_id)
                    );

                    CREATE TABLE daily_rollups (
                        local_date TEXT NOT NULL,
                        timezone_id TEXT NOT NULL,
                        tracked_seconds REAL NOT NULL,
                        agent_seconds REAL NOT NULL,
                        commits INTEGER NOT NULL,
                        files_touched INTEGER NOT NULL,
                        additions INTEGER NOT NULL,
                        deletions INTEGER NOT NULL,
                        derivation_version INTEGER NOT NULL,
                        PRIMARY KEY(local_date, timezone_id)
                    );

                    CREATE TABLE reports (
                        id TEXT PRIMARY KEY NOT NULL,
                        period_start REAL NOT NULL,
                        period_end REAL NOT NULL,
                        state TEXT NOT NULL,
                        summary TEXT NOT NULL,
                        evidence_ids_json BLOB NOT NULL,
                        provider TEXT,
                        model TEXT,
                        generator_version TEXT NOT NULL,
                        revision INTEGER NOT NULL
                    );

                    CREATE TABLE collector_cursors (
                        source_key TEXT PRIMARY KEY NOT NULL,
                        cursor_json BLOB NOT NULL,
                        updated_at REAL NOT NULL
                    );

                    CREATE TABLE collector_leases (
                        name TEXT PRIMARY KEY NOT NULL,
                        owner_id TEXT NOT NULL,
                        acquired_at REAL NOT NULL,
                        expires_at REAL NOT NULL
                    );

                    CREATE TABLE service_heartbeats (
                        service TEXT PRIMARY KEY NOT NULL,
                        process_id INTEGER NOT NULL,
                        observed_at REAL NOT NULL,
                        state TEXT NOT NULL
                    );

                    CREATE VIRTUAL TABLE search_documents USING fts5(
                        entity_type UNINDEXED,
                        entity_id UNINDEXED,
                        repository_id UNINDEXED,
                        occurred_at UNINDEXED,
                        content,
                        tokenize = 'unicode61 remove_diacritics 2'
                    );
                    """)
        }
        migrator.registerMigration(diagnosticsMigration) { db in
            try db.execute(
                sql: """
                    CREATE TABLE IF NOT EXISTS collector_issues (
                        source_key TEXT PRIMARY KEY NOT NULL,
                        message TEXT NOT NULL,
                        observed_at REAL NOT NULL
                    );
                    """)
        }
        migrator.registerMigration(messageAliasesMigration) { db in
            try db.execute(
                sql: """
                    CREATE TABLE message_aliases (
                        alias_id TEXT PRIMARY KEY NOT NULL,
                        canonical_id TEXT NOT NULL REFERENCES session_messages(id) ON DELETE CASCADE
                    );

                    CREATE INDEX message_aliases_canonical ON message_aliases(canonical_id);

                    INSERT INTO message_aliases (alias_id, canonical_id)
                    SELECT id, canonical_id
                    FROM (
                        SELECT id,
                               FIRST_VALUE(id) OVER (
                                   PARTITION BY session_id, role, occurred_at, normalized_text
                                   ORDER BY CASE WHEN source_message_id IS NULL THEN 1 ELSE 0 END, id
                               ) AS canonical_id
                        FROM session_messages
                    )
                    WHERE id != canonical_id;

                    DELETE FROM search_documents
                    WHERE entity_type = 'message'
                      AND entity_id IN (SELECT alias_id FROM message_aliases);

                    DELETE FROM session_messages
                    WHERE id IN (SELECT alias_id FROM message_aliases);
                    """)
        }
        migrator.registerMigration(nearDuplicateMessagesMigration) { db in
            struct Candidate {
                let id: String
                let occurredAt: Double?
            }
            struct Alias {
                let id: String
                let canonicalID: String
                let sourceMessageID: String?
            }

            var aliases: [Alias] = []
            do {
                let cursor = try Row.fetchCursor(
                    db,
                    sql: """
                        SELECT id, session_id, source_message_id, role, occurred_at, normalized_text
                        FROM session_messages
                        ORDER BY session_id, role, occurred_at, id
                        """)
                var group: (sessionID: String, role: String)?
                var candidates: [String: Candidate] = [:]
                while let row = try cursor.next() {
                    let sessionID: String = row["session_id"]
                    let role: String = row["role"]
                    if group?.sessionID != sessionID || group?.role != role {
                        group = (sessionID, role)
                        candidates.removeAll(keepingCapacity: true)
                    }

                    let id: String = row["id"]
                    let occurredAt: Double? = row["occurred_at"]
                    let text: String = row["normalized_text"]
                    if let candidate = candidates[text],
                        Self.areDuplicateTimes(candidate.occurredAt, occurredAt)
                    {
                        aliases.append(
                            Alias(
                                id: id,
                                canonicalID: candidate.id,
                                sourceMessageID: row["source_message_id"]
                            ))
                    } else {
                        candidates[text] = Candidate(id: id, occurredAt: occurredAt)
                    }
                }
            }

            for alias in aliases {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO message_aliases (alias_id, canonical_id) VALUES (?, ?)",
                    arguments: [alias.id, alias.canonicalID]
                )
                if let sourceMessageID = alias.sourceMessageID {
                    try db.execute(
                        sql: "UPDATE session_messages SET source_message_id = COALESCE(source_message_id, ?) WHERE id = ?",
                        arguments: [sourceMessageID, alias.canonicalID]
                    )
                }
            }
            if !aliases.isEmpty {
                try db.execute(
                    sql: """
                        DELETE FROM search_documents
                        WHERE entity_type = 'message'
                          AND entity_id IN (SELECT alias_id FROM message_aliases)
                        """)
                try db.execute(
                    sql: "DELETE FROM session_messages WHERE id IN (SELECT alias_id FROM message_aliases)"
                )
            }
        }
        migrator.registerMigration(messagePrivacyMigration) { db in
            struct Candidate {
                let id: String
                let occurredAt: Double?
            }
            struct MessageUpdate {
                let id: String
                let text: String
            }
            struct Alias {
                let id: String
                let canonicalID: String
                let sourceMessageID: String?
            }

            var updates: [MessageUpdate] = []
            var aliases: [Alias] = []
            do {
                let cursor = try Row.fetchCursor(
                    db,
                    sql: """
                        SELECT id, session_id, source_message_id, role, occurred_at, normalized_text
                        FROM session_messages
                        ORDER BY session_id, role, occurred_at, id
                        """)
                var group: (sessionID: String, role: String)?
                var candidates: [String: Candidate] = [:]
                while let row = try cursor.next() {
                    let sessionID: String = row["session_id"]
                    let role: String = row["role"]
                    if group?.sessionID != sessionID || group?.role != role {
                        group = (sessionID, role)
                        candidates.removeAll(keepingCapacity: true)
                    }

                    let id: String = row["id"]
                    let occurredAt: Double? = row["occurred_at"]
                    let originalText: String = row["normalized_text"]
                    let sanitizedText = MessageTextSanitizer.sanitize(originalText)
                    if sanitizedText != originalText {
                        updates.append(MessageUpdate(id: id, text: sanitizedText))
                    }

                    let key = MessageTextSanitizer.canonicalKey(sanitizedText)
                    if let candidate = candidates[key],
                        Self.areDuplicateTimes(candidate.occurredAt, occurredAt)
                    {
                        aliases.append(
                            Alias(
                                id: id,
                                canonicalID: candidate.id,
                                sourceMessageID: row["source_message_id"]
                            ))
                    } else {
                        candidates[key] = Candidate(id: id, occurredAt: occurredAt)
                    }
                }
            }

            for update in updates {
                try db.execute(
                    sql: "UPDATE session_messages SET normalized_text = ? WHERE id = ?",
                    arguments: [update.text, update.id]
                )
            }
            for alias in aliases {
                try db.execute(
                    sql: "UPDATE message_aliases SET canonical_id = ? WHERE canonical_id = ?",
                    arguments: [alias.canonicalID, alias.id]
                )
                try db.execute(
                    sql: "INSERT OR REPLACE INTO message_aliases (alias_id, canonical_id) VALUES (?, ?)",
                    arguments: [alias.id, alias.canonicalID]
                )
                if let sourceMessageID = alias.sourceMessageID {
                    try db.execute(
                        sql: "UPDATE session_messages SET source_message_id = COALESCE(source_message_id, ?) WHERE id = ?",
                        arguments: [sourceMessageID, alias.canonicalID]
                    )
                }
            }
            if !aliases.isEmpty {
                try db.execute(
                    sql: "DELETE FROM session_messages WHERE id IN (SELECT alias_id FROM message_aliases)"
                )
            }

            let reports = try Row.fetchAll(db, sql: "SELECT id, summary FROM reports")
            for report in reports {
                let id: String = report["id"]
                let summary: String = report["summary"]
                let redacted = SensitiveText.redact(summary)
                if redacted != summary {
                    try db.execute(
                        sql: "UPDATE reports SET summary = ? WHERE id = ?",
                        arguments: [redacted, id]
                    )
                }
            }

            try db.execute(
                sql: "DELETE FROM search_documents WHERE entity_type IN ('message', 'report')"
            )
            try db.execute(
                sql: """
                    INSERT INTO search_documents (entity_type, entity_id, repository_id, occurred_at, content)
                    SELECT 'message', m.id,
                           (SELECT sr.repository_id
                            FROM session_repositories sr
                            WHERE sr.session_id = m.session_id
                            ORDER BY sr.confidence DESC
                            LIMIT 1),
                           m.occurred_at, m.normalized_text
                    FROM session_messages m
                    """)
            try db.execute(
                sql: """
                    INSERT INTO search_documents (entity_type, entity_id, repository_id, occurred_at, content)
                    SELECT 'report', id, NULL, period_end, summary
                    FROM reports
                    """)
        }
        migrator.registerMigration(workIntelligenceMigration) { db in
            try db.execute(
                sql: """
                    CREATE TABLE report_recipes (
                        id TEXT PRIMARY KEY NOT NULL,
                        name TEXT NOT NULL,
                        is_builtin INTEGER NOT NULL,
                        is_enabled INTEGER NOT NULL,
                        current_version_id TEXT NOT NULL,
                        created_at REAL NOT NULL
                    );

                    CREATE TABLE report_recipe_versions (
                        id TEXT PRIMARY KEY NOT NULL,
                        recipe_id TEXT NOT NULL REFERENCES report_recipes(id) ON DELETE RESTRICT,
                        version INTEGER NOT NULL,
                        purpose TEXT NOT NULL,
                        audience TEXT NOT NULL,
                        cadence TEXT NOT NULL,
                        repository_ids_json BLOB NOT NULL,
                        group_names_json BLOB NOT NULL,
                        custom_focus TEXT,
                        tone TEXT NOT NULL,
                        output_format TEXT NOT NULL,
                        maximum_characters INTEGER NOT NULL,
                        privacy_profile TEXT NOT NULL,
                        provider_mode_override TEXT,
                        created_at REAL NOT NULL,
                        UNIQUE(recipe_id, version)
                    );

                    CREATE TABLE report_runs (
                        id TEXT PRIMARY KEY NOT NULL,
                        recipe_id TEXT NOT NULL REFERENCES report_recipes(id) ON DELETE RESTRICT,
                        recipe_version_id TEXT NOT NULL REFERENCES report_recipe_versions(id) ON DELETE RESTRICT,
                        period_start REAL NOT NULL,
                        period_end REAL NOT NULL,
                        intent TEXT NOT NULL,
                        selection_mode TEXT NOT NULL,
                        requested_provider TEXT,
                        requested_model TEXT,
                        effective_provider TEXT,
                        effective_model TEXT,
                        compiler_version TEXT NOT NULL,
                        prompt_version TEXT NOT NULL,
                        invocation_version TEXT,
                        output_schema_version TEXT NOT NULL,
                        input_bytes INTEGER,
                        estimated_input_tokens INTEGER,
                        input_tokens INTEGER,
                        cached_input_tokens INTEGER,
                        output_tokens INTEGER,
                        reasoning_tokens INTEGER,
                        cost_value TEXT,
                        cost_currency TEXT,
                        cost_kind TEXT NOT NULL,
                        billing_context TEXT,
                        queued_at REAL NOT NULL,
                        started_at REAL,
                        finished_at REAL,
                        state TEXT NOT NULL,
                        failure_class TEXT,
                        failure_detail TEXT,
                        artifact_id TEXT,
                        UNIQUE(period_start, period_end, recipe_version_id, intent)
                    );

                    CREATE INDEX report_runs_state_queue ON report_runs(state, queued_at);
                    CREATE INDEX report_runs_finished_at ON report_runs(finished_at);

                    CREATE TABLE artifacts (
                        id TEXT PRIMARY KEY NOT NULL,
                        type TEXT NOT NULL,
                        format TEXT NOT NULL,
                        created_at REAL NOT NULL,
                        recipe_id TEXT NOT NULL REFERENCES report_recipes(id) ON DELETE RESTRICT,
                        recipe_version_id TEXT NOT NULL REFERENCES report_recipe_versions(id) ON DELETE RESTRICT,
                        report_run_id TEXT REFERENCES report_runs(id) ON DELETE RESTRICT,
                        legacy_report_id TEXT UNIQUE REFERENCES reports(id) ON DELETE CASCADE,
                        period_start REAL NOT NULL,
                        period_end REAL NOT NULL,
                        repository_ids_json BLOB NOT NULL,
                        group_names_json BLOB NOT NULL,
                        privacy_profile TEXT NOT NULL,
                        state TEXT NOT NULL,
                        content TEXT NOT NULL,
                        revision INTEGER NOT NULL,
                        revises_artifact_id TEXT REFERENCES artifacts(id) ON DELETE RESTRICT
                    );

                    CREATE INDEX artifacts_period ON artifacts(period_start, period_end);
                    CREATE INDEX artifacts_recipe ON artifacts(recipe_id, created_at);

                    CREATE TABLE artifact_evidence (
                        artifact_id TEXT NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,
                        evidence_id TEXT NOT NULL REFERENCES source_observations(id) ON DELETE RESTRICT,
                        PRIMARY KEY(artifact_id, evidence_id)
                    );

                    CREATE TABLE report_run_evidence (
                        report_run_id TEXT NOT NULL REFERENCES report_runs(id) ON DELETE CASCADE,
                        alias TEXT NOT NULL,
                        evidence_id TEXT NOT NULL REFERENCES source_observations(id) ON DELETE RESTRICT,
                        selection_reason TEXT NOT NULL,
                        PRIMARY KEY(report_run_id, alias, evidence_id)
                    );

                    CREATE TABLE destinations (
                        id TEXT PRIMARY KEY NOT NULL,
                        kind TEXT NOT NULL,
                        name TEXT NOT NULL,
                        privacy_profile TEXT NOT NULL,
                        permission TEXT NOT NULL,
                        configuration_json BLOB NOT NULL,
                        is_enabled INTEGER NOT NULL,
                        created_at REAL NOT NULL
                    );

                    CREATE TABLE delivery_attempts (
                        id TEXT PRIMARY KEY NOT NULL,
                        artifact_id TEXT NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,
                        destination_id TEXT NOT NULL REFERENCES destinations(id) ON DELETE CASCADE,
                        idempotency_key TEXT NOT NULL UNIQUE,
                        state TEXT NOT NULL,
                        attempted_at REAL NOT NULL,
                        finished_at REAL,
                        retry_count INTEGER NOT NULL,
                        external_identifier TEXT,
                        failure_detail TEXT
                    );

                    CREATE TRIGGER artifacts_immutable_update
                    BEFORE UPDATE ON artifacts
                    BEGIN
                        SELECT RAISE(ABORT, 'artifacts are immutable');
                    END;
                    """)

            let now = Date().timeIntervalSince1970
            let builtins: [(String, String, String, String, String, Int, String)] = [
                ("hourly-work-note", "Hourly work note", "Compact evidence-backed work note", "private", "hourly", 1_200, "plain_text"),
                (
                    "daily-work-summary", "Daily work summary", "Outcomes, parallel projects, and unfinished state", "private", "daily",
                    2_000, "markdown"
                ),
                ("stand-up-draft", "Stand-up draft", "Completed, current, and blocked work", "team", "on_demand", 1_500, "markdown"),
                (
                    "timesheet-description", "Timesheet description", "Project-scoped description without invented duration", "team",
                    "on_demand", 800, "plain_text"
                ),
                (
                    "legacy-v1-report", "Legacy V1 report", "Preserved report created before Goal 2", "private", "on_demand", 2_000,
                    "plain_text"
                ),
            ]
            for item in builtins {
                let versionID = "\(item.0):v1"
                try db.execute(
                    sql: """
                        INSERT INTO report_recipes
                            (id, name, is_builtin, is_enabled, current_version_id, created_at)
                        VALUES (?, ?, 1, 1, ?, ?)
                        """,
                    arguments: [item.0, item.1, versionID, now]
                )
                try db.execute(
                    sql: """
                        INSERT INTO report_recipe_versions
                            (id, recipe_id, version, purpose, audience, cadence,
                             repository_ids_json, group_names_json, custom_focus, tone,
                             output_format, maximum_characters, privacy_profile,
                             provider_mode_override, created_at)
                        VALUES (?, ?, 1, ?, ?, ?, json('[]'), json('[]'), NULL,
                                'concise and factual', ?, ?, ?, NULL, ?)
                        """,
                    arguments: [
                        versionID, item.0, item.2,
                        item.3 == "private" ? "self" : "development team",
                        item.4, item.6, item.5, item.3, now,
                    ]
                )
            }

            try db.execute(
                sql: """
                    INSERT INTO artifacts
                        (id, type, format, created_at, recipe_id, recipe_version_id,
                         report_run_id, legacy_report_id, period_start, period_end,
                         repository_ids_json, group_names_json, privacy_profile,
                         state, content, revision, revises_artifact_id)
                    SELECT 'legacy:' || id, 'report', 'plain_text', period_end,
                           'legacy-v1-report', 'legacy-v1-report:v1', NULL, id,
                           period_start, period_end, json('[]'), json('[]'), 'private',
                           state, summary, revision, NULL
                    FROM reports
                    """)
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO artifact_evidence (artifact_id, evidence_id)
                    SELECT 'legacy:' || reports.id, value
                    FROM reports, json_each(reports.evidence_ids_json)
                    WHERE value IN (SELECT id FROM source_observations)
                    """)
        }
        return migrator
    }

    private static func areDuplicateTimes(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case (.some(let lhs), .some(let rhs)): abs(lhs - rhs) <= messageDuplicateTolerance
        default: false
        }
    }
}
