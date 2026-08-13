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
    static let configurableReportsMigration = "0007_configurable_reports"
    static let reportSchedulesMigration = "0008_report_schedules"
    static let canonicalSummariesMigration = "0009_canonical_summaries"
    static let canonicalEvidenceMigration = "0010_canonical_evidence"
    static let canonicalEvidenceLookupMigration = "0011_canonical_evidence_lookups"
    static let evidenceCoverageMigration = "0012_evidence_coverage"
    static let providerAllowanceMigration = "0013_provider_allowance_attribution"
    static let liveCollectorMigration = "0014_live_collector_status"
    static let codexThreadRollbackMigration = "0015_codex_thread_rollback"
    static let codexMultiAgentControlMigration = "0016_codex_multi_agent_control"
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
        migrator.registerMigration(configurableReportsMigration) { db in
            // Rebuild the run/artifact graph once to remove the V1 period-level
            // uniqueness rule. Manual regeneration is history, not an overwrite.
            try db.execute(
                sql: """
                    CREATE TABLE report_runs_new (
                        id TEXT PRIMARY KEY NOT NULL,
                        recipe_id TEXT NOT NULL REFERENCES report_recipes(id) ON DELETE RESTRICT,
                        recipe_version_id TEXT NOT NULL REFERENCES report_recipe_versions(id) ON DELETE RESTRICT,
                        period_start REAL NOT NULL, period_end REAL NOT NULL, intent TEXT NOT NULL,
                        selection_mode TEXT NOT NULL, requested_provider TEXT, requested_model TEXT,
                        effective_provider TEXT, effective_model TEXT, compiler_version TEXT NOT NULL,
                        prompt_version TEXT NOT NULL, invocation_version TEXT,
                        output_schema_version TEXT NOT NULL, configuration_json BLOB,
                        input_bytes INTEGER, estimated_input_tokens INTEGER, input_tokens INTEGER,
                        cached_input_tokens INTEGER, output_tokens INTEGER, reasoning_tokens INTEGER,
                        cost_value TEXT, cost_currency TEXT, cost_kind TEXT NOT NULL,
                        billing_context TEXT, queued_at REAL NOT NULL, started_at REAL,
                        finished_at REAL, state TEXT NOT NULL, failure_class TEXT,
                        failure_detail TEXT, artifact_id TEXT
                    );
                    INSERT INTO report_runs_new (
                        id, recipe_id, recipe_version_id, period_start, period_end, intent,
                        selection_mode, requested_provider, requested_model, effective_provider,
                        effective_model, compiler_version, prompt_version, invocation_version,
                        output_schema_version, input_bytes, estimated_input_tokens, input_tokens,
                        cached_input_tokens, output_tokens, reasoning_tokens, cost_value,
                        cost_currency, cost_kind, billing_context, queued_at, started_at,
                        finished_at, state, failure_class, failure_detail, artifact_id)
                    SELECT id, recipe_id, recipe_version_id, period_start, period_end, intent,
                        selection_mode, requested_provider, requested_model, effective_provider,
                        effective_model, compiler_version, prompt_version, invocation_version,
                        output_schema_version, input_bytes, estimated_input_tokens, input_tokens,
                        cached_input_tokens, output_tokens, reasoning_tokens, cost_value,
                        cost_currency, cost_kind, billing_context, queued_at, started_at,
                        finished_at, state, failure_class, failure_detail, artifact_id
                    FROM report_runs;

                    CREATE TABLE artifacts_new (
                        id TEXT PRIMARY KEY NOT NULL, type TEXT NOT NULL, format TEXT NOT NULL,
                        created_at REAL NOT NULL,
                        recipe_id TEXT NOT NULL REFERENCES report_recipes(id) ON DELETE RESTRICT,
                        recipe_version_id TEXT NOT NULL REFERENCES report_recipe_versions(id) ON DELETE RESTRICT,
                        report_run_id TEXT REFERENCES report_runs(id) ON DELETE RESTRICT,
                        legacy_report_id TEXT UNIQUE REFERENCES reports(id) ON DELETE CASCADE,
                        period_start REAL NOT NULL, period_end REAL NOT NULL,
                        repository_ids_json BLOB NOT NULL, group_names_json BLOB NOT NULL,
                        privacy_profile TEXT NOT NULL, state TEXT NOT NULL, content TEXT NOT NULL,
                        revision INTEGER NOT NULL,
                        revises_artifact_id TEXT REFERENCES artifacts(id) ON DELETE RESTRICT
                    );
                    INSERT INTO artifacts_new SELECT * FROM artifacts;

                    CREATE TEMP TABLE artifact_evidence_backup AS SELECT * FROM artifact_evidence;
                    CREATE TEMP TABLE report_run_evidence_backup AS SELECT * FROM report_run_evidence;
                    CREATE TEMP TABLE delivery_attempts_backup AS SELECT * FROM delivery_attempts;

                    DROP TRIGGER artifacts_immutable_update;
                    DROP TABLE delivery_attempts;
                    DROP TABLE artifact_evidence;
                    DROP TABLE report_run_evidence;
                    DROP TABLE artifacts;
                    DROP TABLE report_runs;
                    ALTER TABLE report_runs_new RENAME TO report_runs;
                    ALTER TABLE artifacts_new RENAME TO artifacts;

                    CREATE TABLE artifact_evidence (
                        artifact_id TEXT NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,
                        evidence_id TEXT NOT NULL REFERENCES source_observations(id) ON DELETE RESTRICT,
                        PRIMARY KEY(artifact_id, evidence_id)
                    );
                    INSERT INTO artifact_evidence SELECT * FROM artifact_evidence_backup;
                    CREATE TABLE report_run_evidence (
                        report_run_id TEXT NOT NULL REFERENCES report_runs(id) ON DELETE CASCADE,
                        alias TEXT NOT NULL,
                        evidence_id TEXT NOT NULL REFERENCES source_observations(id) ON DELETE RESTRICT,
                        selection_reason TEXT NOT NULL,
                        PRIMARY KEY(report_run_id, alias, evidence_id)
                    );
                    INSERT INTO report_run_evidence SELECT * FROM report_run_evidence_backup;
                    CREATE TABLE delivery_attempts (
                        id TEXT PRIMARY KEY NOT NULL,
                        artifact_id TEXT NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,
                        destination_id TEXT NOT NULL REFERENCES destinations(id) ON DELETE CASCADE,
                        idempotency_key TEXT NOT NULL UNIQUE, state TEXT NOT NULL,
                        attempted_at REAL NOT NULL, finished_at REAL, retry_count INTEGER NOT NULL,
                        external_identifier TEXT, failure_detail TEXT
                    );
                    INSERT INTO delivery_attempts SELECT * FROM delivery_attempts_backup;

                    CREATE INDEX report_runs_state_queue ON report_runs(state, queued_at);
                    CREATE INDEX report_runs_finished_at ON report_runs(finished_at);
                    CREATE INDEX artifacts_period ON artifacts(period_start, period_end);
                    CREATE INDEX artifacts_recipe ON artifacts(recipe_id, created_at);
                    CREATE TRIGGER artifacts_immutable_update
                    BEFORE UPDATE ON artifacts
                    BEGIN SELECT RAISE(ABORT, 'artifacts are immutable'); END;
                    """)
        }
        migrator.registerMigration(reportSchedulesMigration) { db in
            try db.execute(
                sql: """
                    CREATE TABLE report_schedules (
                        id TEXT PRIMARY KEY NOT NULL,
                        name TEXT NOT NULL,
                        recipe_id TEXT NOT NULL REFERENCES report_recipes(id) ON DELETE RESTRICT,
                        cadence TEXT NOT NULL,
                        repository_ids_json BLOB NOT NULL,
                        group_names_json BLOB NOT NULL,
                        provider_mode_override TEXT,
                        is_enabled INTEGER NOT NULL,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL
                    );
                    CREATE INDEX report_schedules_enabled_cadence
                        ON report_schedules(is_enabled, cadence);
                    ALTER TABLE report_runs ADD COLUMN schedule_id TEXT
                        REFERENCES report_schedules(id) ON DELETE SET NULL;
                    CREATE INDEX report_runs_schedule ON report_runs(schedule_id, queued_at);
                    """)

            let now = Date().timeIntervalSince1970
            let instructions: [(String, String)] = [
                (
                    "hourly-work-note",
                    "Summarize what changed during this hour and state clearly whether the work is complete, ongoing, blocked, or quiet."
                ),
                (
                    "daily-work-summary",
                    "Summarize outcomes, decisions, parallel projects, blockers, and clearly unfinished work from this day."
                ),
                (
                    "stand-up-draft",
                    "Write a concise stand-up update organized around completed work, work in progress, and blockers."
                ),
                (
                    "timesheet-description",
                    "Write a concise project-scoped work description suitable for a timesheet. Do not invent duration."
                ),
            ]
            for (recipeID, focus) in instructions {
                guard
                    let version = try Int.fetchOne(
                        db,
                        sql: "SELECT MAX(version) FROM report_recipe_versions WHERE recipe_id = ?",
                        arguments: [recipeID])
                else { continue }
                let next = version + 1
                let versionID = "\(recipeID):v\(next)"
                try db.execute(
                    sql: """
                        INSERT INTO report_recipe_versions (
                            id, recipe_id, version, purpose, audience, cadence,
                            repository_ids_json, group_names_json, custom_focus, tone,
                            output_format, maximum_characters, privacy_profile,
                            provider_mode_override, created_at)
                        SELECT ?, recipe_id, ?, purpose, audience, cadence,
                               repository_ids_json, group_names_json, ?, tone,
                               output_format, maximum_characters, privacy_profile,
                               provider_mode_override, ?
                        FROM report_recipe_versions
                        WHERE id = (SELECT current_version_id FROM report_recipes WHERE id = ?)
                        """,
                    arguments: [versionID, next, focus, now, recipeID])
                try db.execute(
                    sql: "UPDATE report_recipes SET current_version_id = ? WHERE id = ?",
                    arguments: [versionID, recipeID])
            }

            try db.execute(
                sql: """
                    INSERT INTO report_schedules (
                        id, name, recipe_id, cadence, repository_ids_json,
                        group_names_json, provider_mode_override, is_enabled,
                        created_at, updated_at)
                    SELECT 'schedule:' || recipes.id,
                           recipes.name,
                           recipes.id,
                           versions.cadence,
                           versions.repository_ids_json,
                           versions.group_names_json,
                           versions.provider_mode_override,
                           recipes.is_enabled,
                           ?, ?
                    FROM report_recipes AS recipes
                    JOIN report_recipe_versions AS versions
                      ON versions.id = recipes.current_version_id
                    WHERE versions.cadence IN ('hourly', 'daily')
                    """,
                arguments: [now, now])
        }
        migrator.registerMigration(canonicalSummariesMigration) { db in
            try db.execute(
                sql: """
                    CREATE TABLE work_summaries (
                        id TEXT PRIMARY KEY NOT NULL,
                        kind TEXT NOT NULL,
                        period_start REAL NOT NULL,
                        period_end REAL NOT NULL,
                        generated_at REAL NOT NULL,
                        state TEXT NOT NULL,
                        narrative TEXT NOT NULL,
                        content_json BLOB NOT NULL,
                        statistics_json BLOB NOT NULL,
                        generation_source TEXT NOT NULL,
                        provider TEXT,
                        model TEXT,
                        generator_version TEXT NOT NULL,
                        prompt_version TEXT NOT NULL,
                        schema_version TEXT NOT NULL,
                        source_fingerprint TEXT NOT NULL,
                        eligible_event_count INTEGER NOT NULL,
                        covered_event_count INTEGER NOT NULL,
                        truncated_assistant_count INTEGER NOT NULL,
                        chunk_count INTEGER NOT NULL,
                        coverage_known INTEGER NOT NULL,
                        revision INTEGER NOT NULL,
                        revises_summary_id TEXT REFERENCES work_summaries(id) ON DELETE RESTRICT
                    );

                    CREATE INDEX work_summaries_kind_period
                        ON work_summaries(kind, period_start, period_end, revision);
                    CREATE INDEX work_summaries_generated
                        ON work_summaries(generated_at DESC);
                    CREATE INDEX work_summaries_fingerprint
                        ON work_summaries(kind, period_start, period_end, source_fingerprint);

                    CREATE TABLE summary_evidence (
                        summary_id TEXT NOT NULL REFERENCES work_summaries(id) ON DELETE CASCADE,
                        evidence_id TEXT NOT NULL REFERENCES source_observations(id) ON DELETE RESTRICT,
                        PRIMARY KEY(summary_id, evidence_id)
                    );

                    CREATE TABLE summary_children (
                        summary_id TEXT NOT NULL REFERENCES work_summaries(id) ON DELETE CASCADE,
                        child_summary_id TEXT NOT NULL REFERENCES work_summaries(id) ON DELETE RESTRICT,
                        ordinal INTEGER NOT NULL,
                        PRIMARY KEY(summary_id, child_summary_id),
                        UNIQUE(summary_id, ordinal)
                    );

                    CREATE TABLE summary_runs (
                        id TEXT PRIMARY KEY NOT NULL,
                        kind TEXT NOT NULL,
                        period_start REAL NOT NULL,
                        period_end REAL NOT NULL,
                        selection_mode TEXT NOT NULL,
                        requested_provider TEXT,
                        requested_model TEXT,
                        effective_provider TEXT,
                        effective_model TEXT,
                        source_fingerprint TEXT NOT NULL,
                        input_bytes INTEGER NOT NULL,
                        estimated_input_tokens INTEGER NOT NULL,
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
                        summary_id TEXT REFERENCES work_summaries(id) ON DELETE SET NULL
                    );

                    CREATE INDEX summary_runs_state_queue ON summary_runs(state, queued_at);
                    CREATE INDEX summary_runs_finished_at ON summary_runs(finished_at);

                    CREATE TABLE report_run_summaries (
                        report_run_id TEXT NOT NULL REFERENCES report_runs(id) ON DELETE CASCADE,
                        alias TEXT NOT NULL,
                        summary_id TEXT NOT NULL REFERENCES work_summaries(id) ON DELETE RESTRICT,
                        PRIMARY KEY(report_run_id, alias, summary_id)
                    );
                    CREATE INDEX report_run_summaries_summary ON report_run_summaries(summary_id);

                    CREATE TRIGGER work_summaries_immutable_update
                    BEFORE UPDATE ON work_summaries
                    BEGIN SELECT RAISE(ABORT, 'work summaries are immutable'); END;

                    INSERT INTO work_summaries (
                        id, kind, period_start, period_end, generated_at, state,
                        narrative, content_json, statistics_json, generation_source,
                        provider, model, generator_version, prompt_version,
                        schema_version, source_fingerprint, eligible_event_count,
                        covered_event_count, truncated_assistant_count, chunk_count,
                        coverage_known, revision, revises_summary_id)
                    SELECT
                        'migrated:' || id,
                        CASE WHEN period_end - period_start >= 72000 THEN 'day' ELSE 'segment' END,
                        period_start, period_end, period_end, state, summary,
                        CAST(json_object(
                            'narrative', summary,
                            'projects', json('[]'),
                            'intents', json('[]'),
                            'outcomes', json('[]'),
                            'openWork', json('[]'),
                            'blockers', json('[]'),
                            'topics', json('[]')) AS BLOB),
                        CAST(json_object(
                            'activeHours', 0, 'llmTurns', 0,
                            'conversationMessages', 0, 'commits', 0,
                            'additions', 0, 'deletions', 0, 'filesChanged', 0,
                            'repositoryIDs', json('[]'), 'evidenceCount', 0) AS BLOB),
                        'migrated',
                        CASE
                            WHEN lower(provider) LIKE '%codex%' THEN 'codex'
                            WHEN lower(provider) LIKE '%claude%' THEN 'claude'
                            ELSE NULL
                        END,
                        model, generator_version,
                        'legacy', 'work-summary-v1', 'legacy:' || id,
                        0, 0, 0, 1, 0, revision, NULL
                    FROM reports;

                    INSERT OR IGNORE INTO summary_evidence (summary_id, evidence_id)
                    SELECT 'migrated:' || reports.id, value
                    FROM reports, json_each(reports.evidence_ids_json)
                    WHERE value IN (SELECT id FROM source_observations);

                    INSERT INTO search_documents (
                        entity_type, entity_id, repository_id, occurred_at, content)
                    SELECT 'summary', id, NULL, period_end, narrative
                    FROM work_summaries summary
                    WHERE NOT EXISTS (
                        SELECT 1 FROM work_summaries newer
                        WHERE newer.kind = summary.kind
                          AND newer.period_start = summary.period_start
                          AND newer.period_end = summary.period_end
                          AND newer.revision > summary.revision
                    );

                    UPDATE report_schedules
                    SET is_enabled = 0, updated_at = strftime('%s', 'now')
                    WHERE id IN ('schedule:hourly-work-note', 'schedule:daily-work-summary');
                    """)
        }
        migrator.registerMigration(canonicalEvidenceMigration) { db in
            try db.execute(
                sql: """
                    ALTER TABLE session_messages ADD COLUMN source_record_id TEXT;
                    ALTER TABLE session_messages ADD COLUMN source_record_type TEXT NOT NULL DEFAULT 'legacy';
                    ALTER TABLE session_messages ADD COLUMN source_turn_id TEXT;
                    ALTER TABLE session_messages ADD COLUMN parent_source_record_id TEXT;
                    ALTER TABLE session_messages ADD COLUMN source_response_id TEXT;
                    ALTER TABLE session_messages ADD COLUMN entrypoint TEXT;
                    ALTER TABLE session_messages ADD COLUMN message_working_directory TEXT;
                    ALTER TABLE session_messages ADD COLUMN is_meta INTEGER NOT NULL DEFAULT 0;
                    ALTER TABLE session_messages ADD COLUMN is_sidechain INTEGER NOT NULL DEFAULT 0;
                    ALTER TABLE session_messages ADD COLUMN origin TEXT NOT NULL DEFAULT 'unknown';
                    ALTER TABLE session_messages ADD COLUMN semantic_kind TEXT NOT NULL DEFAULT 'unknown';
                    ALTER TABLE session_messages ADD COLUMN disposition TEXT NOT NULL DEFAULT 'work';
                    ALTER TABLE session_messages ADD COLUMN canonical_state TEXT NOT NULL DEFAULT 'primary';
                    ALTER TABLE session_messages ADD COLUMN classification_version INTEGER NOT NULL DEFAULT 0;
                    ALTER TABLE session_messages ADD COLUMN classification_reason TEXT NOT NULL DEFAULT 'legacy-compatible';
                    ALTER TABLE session_messages ADD COLUMN logical_turn_id TEXT;
                    ALTER TABLE session_messages ADD COLUMN logical_message_id TEXT;
                    ALTER TABLE session_messages ADD COLUMN message_repository_id TEXT REFERENCES repositories(id) ON DELETE SET NULL;

                    CREATE INDEX session_messages_logical_turn ON session_messages(logical_turn_id);
                    CREATE INDEX session_messages_logical_message ON session_messages(logical_message_id);
                    CREATE INDEX session_messages_disposition_time ON session_messages(disposition, occurred_at);

                    CREATE TABLE logical_turns (
                        id TEXT PRIMARY KEY NOT NULL,
                        source TEXT NOT NULL,
                        source_turn_id TEXT NOT NULL,
                        session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                        origin TEXT NOT NULL,
                        started_at REAL,
                        last_observed_at REAL,
                        state TEXT NOT NULL DEFAULT 'unknown',
                        repository_id TEXT REFERENCES repositories(id) ON DELETE SET NULL,
                        repository_method TEXT,
                        repository_confidence REAL,
                        classification_version INTEGER NOT NULL,
                        UNIQUE(source, source_turn_id)
                    );

                    CREATE INDEX logical_turns_time ON logical_turns(started_at, last_observed_at);
                    CREATE INDEX logical_turns_repository ON logical_turns(repository_id, started_at);

                    CREATE TABLE logical_messages (
                        id TEXT PRIMARY KEY NOT NULL,
                        logical_turn_id TEXT REFERENCES logical_turns(id) ON DELETE SET NULL,
                        source TEXT NOT NULL,
                        role TEXT NOT NULL,
                        occurred_at REAL,
                        normalized_text TEXT NOT NULL,
                        text_fingerprint TEXT NOT NULL,
                        origin TEXT NOT NULL,
                        semantic_kind TEXT NOT NULL,
                        disposition TEXT NOT NULL,
                        repository_id TEXT REFERENCES repositories(id) ON DELETE SET NULL,
                        classification_version INTEGER NOT NULL,
                        classification_reason TEXT NOT NULL
                    );

                    CREATE INDEX logical_messages_turn ON logical_messages(logical_turn_id, occurred_at);
                    CREATE INDEX logical_messages_disposition_time ON logical_messages(disposition, occurred_at);

                    CREATE TABLE conversation_records (
                        id TEXT PRIMARY KEY NOT NULL,
                        source TEXT NOT NULL,
                        session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                        source_record_id TEXT,
                        source_record_type TEXT NOT NULL,
                        source_turn_id TEXT,
                        parent_source_record_id TEXT,
                        source_response_id TEXT,
                        role TEXT,
                        occurred_at REAL,
                        observed_at REAL NOT NULL,
                        normalized_text TEXT,
                        text_fingerprint TEXT,
                        entrypoint TEXT,
                        working_directory TEXT,
                        is_meta INTEGER NOT NULL,
                        is_sidechain INTEGER NOT NULL,
                        origin TEXT NOT NULL,
                        semantic_kind TEXT NOT NULL,
                        disposition TEXT NOT NULL,
                        canonical_state TEXT NOT NULL,
                        logical_turn_id TEXT REFERENCES logical_turns(id) ON DELETE SET NULL,
                        logical_message_id TEXT REFERENCES logical_messages(id) ON DELETE SET NULL,
                        repository_id TEXT REFERENCES repositories(id) ON DELETE SET NULL,
                        classification_version INTEGER NOT NULL,
                        classification_reason TEXT NOT NULL,
                        adapter_version INTEGER NOT NULL
                    );

                    CREATE INDEX conversation_records_session_time
                        ON conversation_records(session_id, occurred_at);
                    CREATE INDEX conversation_records_turn
                        ON conversation_records(logical_turn_id, occurred_at);
                    CREATE INDEX conversation_records_disposition
                        ON conversation_records(disposition, occurred_at);
                    CREATE INDEX conversation_records_source_identity
                        ON conversation_records(source, source_record_id);

                    CREATE TABLE evidence_quality_issues (
                        id TEXT PRIMARY KEY NOT NULL,
                        source TEXT,
                        source_key TEXT NOT NULL,
                        code TEXT NOT NULL,
                        detail TEXT NOT NULL,
                        issue_count INTEGER NOT NULL,
                        first_observed_at REAL NOT NULL,
                        last_observed_at REAL NOT NULL,
                        affects_work_metrics INTEGER NOT NULL,
                        UNIQUE(source_key, code)
                    );

                    CREATE INDEX evidence_quality_issues_last_observed
                        ON evidence_quality_issues(last_observed_at DESC);

                    CREATE TABLE internal_provider_operations (
                        id TEXT PRIMARY KEY NOT NULL,
                        provider TEXT NOT NULL,
                        purpose TEXT NOT NULL,
                        working_directory TEXT NOT NULL,
                        started_at REAL NOT NULL,
                        finished_at REAL,
                        state TEXT NOT NULL
                    );

                    INSERT INTO logical_messages (
                        id, logical_turn_id, source, role, occurred_at,
                        normalized_text, text_fingerprint, origin, semantic_kind,
                        disposition, classification_version, classification_reason)
                    SELECT session_messages.id, NULL, sessions.source,
                           session_messages.role, session_messages.occurred_at,
                           session_messages.normalized_text, session_messages.fingerprint,
                           'unknown', 'unknown',
                           'work', 0, 'legacy-compatible'
                    FROM session_messages
                    JOIN sessions ON sessions.id = session_messages.session_id;

                    UPDATE session_messages SET logical_message_id = id;
                    """)
        }
        migrator.registerMigration(canonicalEvidenceLookupMigration) { db in
            try db.execute(
                sql: """
                    CREATE INDEX IF NOT EXISTS conversation_records_logical_message
                        ON conversation_records(logical_message_id);
                    """)
        }
        migrator.registerMigration(evidenceCoverageMigration) { db in
            try db.execute(
                sql: """
                    CREATE TABLE evidence_ledger_coverage (
                        id INTEGER PRIMARY KEY NOT NULL CHECK (id = 1),
                        calendar_days INTEGER NOT NULL,
                        coverage_start REAL NOT NULL,
                        coverage_cutoff REAL NOT NULL,
                        recorded_at REAL NOT NULL,
                        canonical_fingerprint TEXT NOT NULL
                    );

                    CREATE TABLE evidence_source_read_audits (
                        source_key TEXT PRIMARY KEY NOT NULL,
                        unit TEXT NOT NULL,
                        candidates_considered INTEGER NOT NULL,
                        units_opened INTEGER NOT NULL,
                        bytes_read INTEGER,
                        records_observed INTEGER NOT NULL,
                        records_accepted INTEGER NOT NULL
                    );
                    """)
        }
        migrator.registerMigration(providerAllowanceMigration) { db in
            try db.execute(
                sql: """
                    CREATE TABLE provider_allowance_attributions (
                        operation_id TEXT PRIMARY KEY NOT NULL,
                        provider TEXT NOT NULL,
                        purpose TEXT NOT NULL,
                        started_at REAL NOT NULL,
                        finished_at REAL,
                        limit_id TEXT,
                        window_duration_minutes INTEGER,
                        resets_at REAL,
                        used_percent_before INTEGER,
                        used_percent_after INTEGER
                    );

                    CREATE INDEX provider_allowance_window
                        ON provider_allowance_attributions(provider, resets_at, started_at);
                    """)
        }
        migrator.registerMigration(liveCollectorMigration) { db in
            try db.execute(
                sql: """
                    CREATE TABLE live_collector_status (
                        id INTEGER PRIMARY KEY NOT NULL CHECK (id = 1),
                        mode TEXT NOT NULL,
                        pending_trigger_count INTEGER NOT NULL,
                        pending_path_count INTEGER NOT NULL,
                        last_trigger_at REAL,
                        last_collection_started_at REAL,
                        last_collection_finished_at REAL,
                        last_mutation_at REAL,
                        last_latency_seconds REAL,
                        median_latency_seconds REAL,
                        p95_latency_seconds REAL,
                        consecutive_failures INTEGER NOT NULL,
                        last_error TEXT,
                        recorded_at REAL NOT NULL
                    );
                    """)
            // Before live collection existed, every collector heartbeat represented
            // a complete pass. Preserve that authority before incremental passes
            // begin recording their independent heartbeat.
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO service_heartbeats (
                        service, process_id, observed_at, state
                    )
                    SELECT 'reconciliation', process_id, observed_at, state
                    FROM service_heartbeats
                    WHERE service = 'collector';
                    """)
        }
        migrator.registerMigration(codexThreadRollbackMigration) { db in
            try migrateCodexThreadRollbacks(db)
        }
        migrator.registerMigration(codexMultiAgentControlMigration) { db in
            try migrateCodexMultiAgentControlRecords(db)
        }
        return migrator
    }

    private static func migrateCodexThreadRollbacks(_ db: Database) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, session_id, source_record_id, source_turn_id, occurred_at
                FROM conversation_records
                WHERE source = 'codex'
                  AND source_record_type = 'event_msg.unknown:thread_rolled_back'
                """)
        for row in rows {
            let oldID: String = row["id"]
            let sessionID: String = row["session_id"]
            let sourceRecordID: String? = row["source_record_id"]
            let sourceIdentity: String
            if let sourceRecordID {
                sourceIdentity = "event_msg.thread_rolled_back\u{1f}\(sourceRecordID)"
            } else {
                let sourceTurnID: String? = row["source_turn_id"]
                let occurredAt: Double? = row["occurred_at"]
                sourceIdentity = [
                    "event_msg.thread_rolled_back", sourceTurnID ?? "", "",
                    occurredAt.map { String($0) } ?? "", "",
                ].joined(separator: "\u{1f}")
            }
            let newID = StableHash.sha256(
                "conversation-record:codex:\(sessionID):\(sourceIdentity)")
            if try String.fetchOne(
                db, sql: "SELECT id FROM conversation_records WHERE id = ?",
                arguments: [newID]) != nil
            {
                try db.execute(
                    sql: "DELETE FROM conversation_records WHERE id = ?",
                    arguments: [oldID])
            } else {
                try db.execute(
                    sql: """
                        UPDATE conversation_records
                        SET id = ?, source_record_type = 'event_msg.thread_rolled_back',
                            origin = 'system', semantic_kind = 'control',
                            disposition = 'control', canonical_state = 'primary',
                            classification_reason = 'codex-known-transport-event',
                            adapter_version = 6
                        WHERE id = ?
                        """,
                    arguments: [newID, oldID])
            }
        }
        try clearResolvedCodexAdapterIssue(db)
    }

    private static func migrateCodexMultiAgentControlRecords(_ db: Database) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, session_id, source_turn_id, occurred_at, source_record_type
                FROM conversation_records
                WHERE source = 'codex' AND source_record_type IN (
                    'event_msg.unknown:sub_agent_activity',
                    'unknown:inter_agent_communication_metadata'
                  )
                """)
        for row in rows {
            let oldID: String = row["id"]
            let sessionID: String = row["session_id"]
            let sourceTurnID: String? = row["source_turn_id"]
            let occurredAt: Double? = row["occurred_at"]
            let oldType: String = row["source_record_type"]
            let newType: String
            let reason: String
            switch oldType {
            case "event_msg.unknown:sub_agent_activity":
                newType = "event_msg.sub_agent_activity"
                reason = "codex-sub-agent-activity"
            default:
                newType = "inter_agent_communication_metadata"
                reason = "codex-inter-agent-communication-metadata"
            }
            let sourceIdentity = [
                newType, sourceTurnID ?? "", "",
                occurredAt.map { String($0) } ?? "", "",
            ].joined(separator: "\u{1f}")
            let newID = StableHash.sha256(
                "conversation-record:codex:\(sessionID):\(sourceIdentity)")
            if try String.fetchOne(
                db, sql: "SELECT id FROM conversation_records WHERE id = ?",
                arguments: [newID]) != nil
            {
                try db.execute(
                    sql: "DELETE FROM conversation_records WHERE id = ?",
                    arguments: [oldID])
            } else {
                try db.execute(
                    sql: """
                        UPDATE conversation_records
                        SET id = ?, source_record_id = NULL, source_record_type = ?,
                            origin = 'system', semantic_kind = 'control',
                            disposition = 'control', canonical_state = 'primary',
                            classification_reason = ?, adapter_version = 7
                        WHERE id = ?
                        """,
                    arguments: [newID, newType, reason, oldID])
            }
        }
        try clearResolvedCodexAdapterIssue(db)
    }

    private static func clearResolvedCodexAdapterIssue(_ db: Database) throws {
        try db.execute(
            sql: """
                DELETE FROM evidence_quality_issues
                WHERE source_key = 'adapter:codex' AND code = 'unresolved-record'
                  AND NOT EXISTS (
                      SELECT 1 FROM conversation_records
                      WHERE source = 'codex' AND disposition = 'unresolved'
                  )
                """)
    }

    private static func areDuplicateTimes(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case (.some(let lhs), .some(let rhs)): abs(lhs - rhs) <= messageDuplicateTolerance
        default: false
        }
    }
}
