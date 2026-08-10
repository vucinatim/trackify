import Foundation
import GRDB
import TrackifyDomain

public struct EnqueueReportRun: Sendable {
    public let run: ReportRun
    public let evidence: [(alias: String, evidenceID: EvidenceID, reason: String)]
    public let summaries: [(alias: String, summaryID: SummaryID)]

    public init(
        run: ReportRun,
        evidence: [(alias: String, evidenceID: EvidenceID, reason: String)] = [],
        summaries: [(alias: String, summaryID: SummaryID)] = []
    ) {
        self.run = run
        self.evidence = evidence
        self.summaries = summaries
    }
}

extension LedgerStore {
    public func workIntelligenceCounts() throws -> WorkIntelligenceCounts {
        try database.read { db in
            WorkIntelligenceCounts(
                recipes: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM report_recipes") ?? 0,
                schedules: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM report_schedules") ?? 0,
                runs: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM report_runs") ?? 0,
                pendingRuns: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM report_runs WHERE state = 'pending'") ?? 0,
                runningRuns: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM report_runs WHERE state = 'running'") ?? 0,
                failedRuns: try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM report_runs WHERE state IN ('failed', 'timed_out')") ?? 0,
                artifacts: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artifacts") ?? 0,
                deliveryAttempts: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM delivery_attempts") ?? 0)
        }
    }

    public func recipes() throws -> [ReportRecipe] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, name, is_builtin, is_enabled, current_version_id
                    FROM report_recipes ORDER BY is_builtin DESC, name
                    """
            )
            .map(Self.decodeRecipe)
        }
    }

    public func reportTemplates() throws -> [ReportTemplate] {
        try recipes().compactMap { recipe in
            try recipeVersion(id: recipe.currentVersionID).map {
                ReportTemplate(recipe: recipe, version: $0)
            }
        }
    }

    public func reportSchedules(enabledOnly: Bool = false) throws -> [ReportSchedule] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM report_schedules
                    WHERE (? = 0 OR is_enabled = 1)
                    ORDER BY is_enabled DESC, name COLLATE NOCASE, id
                    """,
                arguments: [enabledOnly]
            )
            .map(Self.decodeSchedule)
        }
    }

    public func reportSchedule(id: ReportScheduleID) throws -> ReportSchedule? {
        try database.read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM report_schedules WHERE id = ?",
                arguments: [id.rawValue]
            )
            .map(Self.decodeSchedule)
        }
    }

    @discardableResult
    public func saveReportSchedule(
        id: ReportScheduleID,
        draft: ReportScheduleDraft,
        now: Date
    ) throws -> ReportSchedule {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw LedgerStoreError.unsupportedValue(type: "ReportSchedule", value: "name is required")
        }
        let repositories = try encoder.encode(draft.repositoryIDs.map(\.rawValue))
        let groups = try encoder.encode(draft.groupNames)
        return try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO report_schedules (
                        id, name, recipe_id, cadence, repository_ids_json,
                        group_names_json, provider_mode_override, is_enabled,
                        created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        recipe_id = excluded.recipe_id,
                        cadence = excluded.cadence,
                        repository_ids_json = excluded.repository_ids_json,
                        group_names_json = excluded.group_names_json,
                        provider_mode_override = excluded.provider_mode_override,
                        is_enabled = excluded.is_enabled,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    id.rawValue, name, draft.recipeID.rawValue, draft.cadence.rawValue,
                    repositories, groups, draft.providerModeOverride?.rawValue,
                    draft.isEnabled, now.timeIntervalSince1970, now.timeIntervalSince1970,
                ])
            return try Self.fetchSchedule(db, id: id)!
        }
    }

    public func setReportScheduleEnabled(_ enabled: Bool, id: ReportScheduleID, now: Date) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE report_schedules SET is_enabled = ?, updated_at = ? WHERE id = ?",
                arguments: [enabled, now.timeIntervalSince1970, id.rawValue])
            guard db.changesCount == 1 else {
                throw LedgerStoreError.unsupportedValue(type: "ReportSchedule", value: id.rawValue)
            }
        }
    }

    public func deleteReportSchedule(id: ReportScheduleID) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM report_schedules WHERE id = ?", arguments: [id.rawValue])
            guard db.changesCount == 1 else {
                throw LedgerStoreError.unsupportedValue(type: "ReportSchedule", value: id.rawValue)
            }
        }
    }

    public func setRecipeEnabled(_ enabled: Bool, id: RecipeID) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE report_recipes SET is_enabled = ? WHERE id = ?",
                arguments: [enabled, id.rawValue])
            guard db.changesCount == 1 else {
                throw LedgerStoreError.unsupportedValue(type: "ReportRecipe", value: id.rawValue)
            }
        }
    }

    public func recipe(id: RecipeID) throws -> (ReportRecipe, ReportRecipeVersion)? {
        try database.read { db in
            guard
                let recipeRow = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT id, name, is_builtin, is_enabled, current_version_id
                        FROM report_recipes WHERE id = ?
                        """,
                    arguments: [id.rawValue]
                )
            else { return nil }
            let recipe = Self.decodeRecipe(recipeRow)
            guard let version = try Self.fetchRecipeVersion(db, id: recipe.currentVersionID) else { return nil }
            return (recipe, version)
        }
    }

    public func recipeVersion(id: RecipeVersionID) throws -> ReportRecipeVersion? {
        try database.read { db in try Self.fetchRecipeVersion(db, id: id) }
    }

    @discardableResult
    public func createRecipeVersion(
        recipeID: RecipeID,
        name: String,
        purpose: String,
        audience: String,
        cadence: RecipeCadence,
        repositoryIDs: [RepositoryID] = [],
        groupNames: [String] = [],
        customFocus: String? = nil,
        tone: String,
        outputFormat: RecipeOutputFormat,
        maximumCharacters: Int,
        privacyProfile: PrivacyProfile,
        providerModeOverride: ProviderSelectionMode? = nil,
        now: Date
    ) throws -> ReportRecipeVersion {
        guard (100...2_000).contains(maximumCharacters) else {
            throw RecipeValidationError.invalidMaximumCharacters
        }
        let sanitizedFocus = try customFocus.map(ReportRecipeValidator.customFocus)
        let repositories = try encoder.encode(repositoryIDs.map(\.rawValue))
        let groups = try encoder.encode(groupNames)
        return try database.write { db in
            let existing = try Row.fetchOne(
                db,
                sql: "SELECT is_builtin FROM report_recipes WHERE id = ?",
                arguments: [recipeID.rawValue]
            )
            if let existing, existing["is_builtin"] as Bool {
                throw LedgerStoreError.unsupportedValue(type: "ReportRecipe", value: "built-in recipes cannot be edited")
            }
            let version =
                (try Int.fetchOne(
                    db,
                    sql: "SELECT MAX(version) FROM report_recipe_versions WHERE recipe_id = ?",
                    arguments: [recipeID.rawValue]
                ) ?? 0) + 1
            let versionID = RecipeVersionID("\(recipeID.rawValue):v\(version)")
            if existing == nil {
                try db.execute(
                    sql: """
                        INSERT INTO report_recipes
                            (id, name, is_builtin, is_enabled, current_version_id, created_at)
                        VALUES (?, ?, 0, 1, ?, ?)
                        """,
                    arguments: [recipeID.rawValue, name, versionID.rawValue, now.timeIntervalSince1970]
                )
            }
            try db.execute(
                sql: """
                    INSERT INTO report_recipe_versions
                        (id, recipe_id, version, purpose, audience, cadence,
                         repository_ids_json, group_names_json, custom_focus, tone,
                         output_format, maximum_characters, privacy_profile,
                         provider_mode_override, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    versionID.rawValue, recipeID.rawValue, version, purpose, audience,
                    cadence.rawValue, repositories, groups, sanitizedFocus, tone,
                    outputFormat.rawValue, maximumCharacters, privacyProfile.rawValue,
                    providerModeOverride?.rawValue, now.timeIntervalSince1970,
                ]
            )
            try db.execute(
                sql: "UPDATE report_recipes SET name = ?, current_version_id = ? WHERE id = ?",
                arguments: [name, versionID.rawValue, recipeID.rawValue]
            )
            return ReportRecipeVersion(
                id: versionID, recipeID: recipeID, version: version, purpose: purpose,
                audience: audience, cadence: cadence, repositoryIDs: repositoryIDs,
                groupNames: groupNames, customFocus: sanitizedFocus, tone: tone,
                outputFormat: outputFormat, maximumCharacters: maximumCharacters,
                privacyProfile: privacyProfile, providerModeOverride: providerModeOverride,
                createdAt: now)
        }
    }

    @discardableResult
    public func enqueue(_ request: EnqueueReportRun) throws -> ReportRun {
        try database.write { db in
            try Self.insertRun(db, run: request.run)
            for item in request.evidence {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO report_run_evidence
                            (report_run_id, alias, evidence_id, selection_reason)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [
                        request.run.id.rawValue, item.alias, item.evidenceID.rawValue, item.reason,
                    ]
                )
            }
            for item in request.summaries {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO report_run_summaries
                            (report_run_id, alias, summary_id)
                        VALUES (?, ?, ?)
                        """,
                    arguments: [
                        request.run.id.rawValue, item.alias, item.summaryID.rawValue,
                    ])
            }
            return try Self.fetchRun(db, id: request.run.id)!
        }
    }

    public func reportRunSummaryIDs(id: ReportRunID) throws -> [SummaryID] {
        try database.read { db in
            let values = try String.fetchAll(
                db,
                sql: """
                    SELECT summary_id FROM report_run_summaries
                    WHERE report_run_id = ? ORDER BY alias, summary_id
                    """,
                arguments: [id.rawValue])
            return values.map { SummaryID($0) }
        }
    }

    public func claimNextReportRun(now: Date) throws -> ReportRun? {
        try database.write { db in
            guard
                let id = try String.fetchOne(
                    db,
                    sql: "SELECT id FROM report_runs WHERE state = 'pending' ORDER BY queued_at LIMIT 1"
                )
            else { return nil }
            try db.execute(
                sql: "UPDATE report_runs SET state = 'running', started_at = ? WHERE id = ? AND state = 'pending'",
                arguments: [now.timeIntervalSince1970, id]
            )
            guard db.changesCount == 1 else { return nil }
            return try Self.fetchRun(db, id: ReportRunID(id))
        }
    }

    public func beginReportRun(id: ReportRunID, now: Date) throws -> ReportRun? {
        try database.write { db in
            try db.execute(
                sql: "UPDATE report_runs SET state = 'running', started_at = ? WHERE id = ? AND state = 'pending'",
                arguments: [now.timeIntervalSince1970, id.rawValue]
            )
            guard db.changesCount == 1 else { return try Self.fetchRun(db, id: id) }
            return try Self.fetchRun(db, id: id)
        }
    }

    public func updateReportRun(_ run: ReportRun) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE report_runs SET
                        requested_provider = ?, requested_model = ?, effective_provider = ?,
                        effective_model = ?, invocation_version = ?, input_bytes = ?,
                        estimated_input_tokens = ?, input_tokens = ?, cached_input_tokens = ?,
                        output_tokens = ?, reasoning_tokens = ?, cost_value = ?,
                        cost_currency = ?, cost_kind = ?, billing_context = ?, started_at = ?,
                        finished_at = ?, state = ?, failure_class = ?, failure_detail = ?, artifact_id = ?
                    WHERE id = ?
                    """,
                arguments: [
                    run.requestedProvider?.rawValue, run.requestedModel,
                    run.effectiveProvider?.rawValue, run.effectiveModel,
                    run.invocationVersion, run.inputBytes, run.estimatedInputTokens,
                    run.usage.inputTokens, run.usage.cachedInputTokens, run.usage.outputTokens,
                    run.usage.reasoningTokens, run.usage.cost.map(String.init(describing:)),
                    run.usage.currency, run.usage.costKind.rawValue, run.usage.billingContext,
                    run.startedAt?.timeIntervalSince1970, run.finishedAt?.timeIntervalSince1970,
                    run.state.rawValue, run.failureClass?.rawValue, run.failureDetail,
                    run.artifactID?.rawValue, run.id.rawValue,
                ]
            )
        }
    }

    public func reportRuns(
        since: Date? = nil,
        before: Date? = nil,
        beforeID: ReportRunID? = nil,
        limit: Int = 200
    ) throws -> [ReportRun] {
        precondition((1...1_000).contains(limit))
        precondition((before == nil) == (beforeID == nil))
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM report_runs
                    WHERE (? IS NULL OR queued_at >= ?)
                      AND (
                        ? IS NULL OR queued_at < ?
                        OR (queued_at = ? AND id < ?)
                      )
                    ORDER BY queued_at DESC, id DESC LIMIT ?
                    """,
                arguments: [
                    since?.timeIntervalSince1970, since?.timeIntervalSince1970,
                    before?.timeIntervalSince1970, before?.timeIntervalSince1970,
                    before?.timeIntervalSince1970, beforeID?.rawValue, limit,
                ]
            ).map(Self.decodeRun)
        }
    }

    public func reportRun(id: ReportRunID) throws -> ReportRun? {
        try database.read { db in try Self.fetchRun(db, id: id) }
    }

    /// Returns only durable authentication evidence: a successful invocation
    /// proves readiness, while an explicitly classified authentication failure
    /// proves the opposite. Timeouts and generic provider failures do not guess.
    public func latestProviderAuthentication(
        _ provider: SummaryProviderID
    ) throws -> (state: AuthenticationState, observedAt: Date)? {
        try database.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT state, failure_class, observed_at FROM (
                            SELECT id, state, failure_class,
                                   COALESCE(finished_at, started_at, queued_at) AS observed_at
                            FROM report_runs WHERE requested_provider = ?
                            UNION ALL
                            SELECT id, state, failure_class,
                                   COALESCE(finished_at, started_at, queued_at) AS observed_at
                            FROM summary_runs WHERE requested_provider = ?
                        )
                        WHERE state = 'succeeded' OR failure_class = 'authentication'
                        ORDER BY observed_at DESC, id DESC
                        LIMIT 1
                        """,
                    arguments: [provider.rawValue, provider.rawValue])
            else { return nil }
            let state = row["state"] as String
            let authentication: AuthenticationState =
                state == ReportRunState.succeeded.rawValue
                ? .ready : .unavailable
            return (authentication, Date(timeIntervalSince1970: row["observed_at"] as Double))
        }
    }

    public func usage(from start: Date, through end: Date) throws -> UsageSummary {
        try database.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) AS runs,
                           COALESCE(SUM(CASE WHEN state = 'succeeded' THEN 1 ELSE 0 END), 0) AS succeeded,
                           COALESCE(SUM(CASE WHEN state IN ('failed', 'timed_out') THEN 1 ELSE 0 END), 0) AS failed,
                           COALESCE(SUM(input_tokens), 0) AS input_tokens,
                           COALESCE(SUM(cached_input_tokens), 0) AS cached_input_tokens,
                           COALESCE(SUM(output_tokens), 0) AS output_tokens,
                           COALESCE(SUM(reasoning_tokens), 0) AS reasoning_tokens,
                           COALESCE(SUM(CASE WHEN finished_at IS NOT NULL AND started_at IS NOT NULL
                                       THEN finished_at - started_at ELSE 0 END), 0) AS duration,
                           COALESCE(SUM(CASE WHEN cost_value IS NOT NULL
                                       THEN CAST(cost_value AS REAL) ELSE 0 END), 0) AS cost,
                           MAX(cost_currency) AS currency,
                           COALESCE(MAX(CASE WHEN effective_provider IS NOT NULL AND cost_value IS NULL THEN 1 ELSE 0 END), 0) AS unknown_cost
                    FROM (
                        SELECT input_tokens, cached_input_tokens, output_tokens,
                               reasoning_tokens, cost_value, cost_currency,
                               effective_provider, queued_at, started_at, finished_at, state
                        FROM report_runs
                        UNION ALL
                        SELECT input_tokens, cached_input_tokens, output_tokens,
                               reasoning_tokens, cost_value, cost_currency,
                               effective_provider, queued_at, started_at, finished_at, state
                        FROM summary_runs
                    ) generation_runs
                    WHERE queued_at >= ? AND queued_at < ? AND effective_provider IS NOT NULL
                    """,
                arguments: [start.timeIntervalSince1970, end.timeIntervalSince1970]
            )!
            return UsageSummary(
                runs: row["runs"], succeeded: row["succeeded"], failed: row["failed"],
                inputTokens: row["input_tokens"], cachedInputTokens: row["cached_input_tokens"],
                outputTokens: row["output_tokens"], reasoningTokens: row["reasoning_tokens"],
                durationSeconds: row["duration"],
                knownCost: Decimal(row["cost"] as Double), currency: row["currency"],
                hasUnknownCost: (row["unknown_cost"] as Int) != 0)
        }
    }

    public func saveArtifact(_ artifact: Artifact) throws {
        let repositories = try encoder.encode(artifact.repositoryIDs.map(\.rawValue))
        let groups = try encoder.encode(artifact.groupNames)
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO artifacts
                        (id, type, format, created_at, recipe_id, recipe_version_id,
                         report_run_id, legacy_report_id, period_start, period_end,
                         repository_ids_json, group_names_json, privacy_profile, state,
                         content, revision, revises_artifact_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    artifact.id.rawValue, artifact.type.rawValue, artifact.format.rawValue,
                    artifact.createdAt.timeIntervalSince1970, artifact.recipeID.rawValue,
                    artifact.recipeVersionID.rawValue, artifact.reportRunID?.rawValue,
                    artifact.legacyReportID?.rawValue, artifact.periodStart.timeIntervalSince1970,
                    artifact.periodEnd.timeIntervalSince1970, repositories, groups,
                    artifact.privacyProfile.rawValue, artifact.state.rawValue,
                    artifact.content, artifact.revision, artifact.revisesArtifactID?.rawValue,
                ]
            )
            for evidenceID in artifact.evidenceIDs {
                try db.execute(
                    sql: "INSERT INTO artifact_evidence (artifact_id, evidence_id) VALUES (?, ?)",
                    arguments: [artifact.id.rawValue, evidenceID.rawValue]
                )
            }
        }
    }

    public func artifacts(
        since: Date? = nil,
        before: Date? = nil,
        beforeID: ArtifactID? = nil,
        limit: Int = 200
    ) throws -> [Artifact] {
        precondition((1...1_000).contains(limit))
        precondition((before == nil) == (beforeID == nil))
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM artifacts
                    WHERE (? IS NULL OR created_at >= ?)
                      AND (
                        ? IS NULL OR created_at < ?
                        OR (created_at = ? AND id < ?)
                      )
                    ORDER BY created_at DESC, id DESC LIMIT ?
                    """,
                arguments: [
                    since?.timeIntervalSince1970, since?.timeIntervalSince1970,
                    before?.timeIntervalSince1970, before?.timeIntervalSince1970,
                    before?.timeIntervalSince1970, beforeID?.rawValue, limit,
                ]
            ).map { try Self.decodeArtifact(db, row: $0) }
        }
    }

    public func artifact(id: ArtifactID) throws -> Artifact? {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM artifacts WHERE id = ?", arguments: [id.rawValue])
            else { return nil }
            return try Self.decodeArtifact(db, row: row)
        }
    }

    public func hasArtifact(
        period: DateInterval,
        recipeVersionID: RecipeVersionID,
        intent: ReportRunIntent
    ) throws -> Bool {
        try database.read { db in
            (try Int.fetchOne(
                db,
                sql: """
                    SELECT 1 FROM report_runs
                    WHERE period_start = ? AND period_end = ?
                      AND recipe_version_id = ? AND intent = ?
                      AND state IN ('succeeded', 'fallback')
                    LIMIT 1
                    """,
                arguments: [
                    period.start.timeIntervalSince1970, period.end.timeIntervalSince1970,
                    recipeVersionID.rawValue, intent.rawValue,
                ])) != nil
        }
    }

    public func hasArtifact(period: DateInterval, scheduleID: ReportScheduleID) throws -> Bool {
        try database.read { db in
            (try Int.fetchOne(
                db,
                sql: """
                    SELECT 1 FROM report_runs
                    WHERE period_start = ? AND period_end = ?
                      AND schedule_id = ? AND state IN ('succeeded', 'fallback')
                    LIMIT 1
                    """,
                arguments: [
                    period.start.timeIntervalSince1970, period.end.timeIntervalSince1970,
                    scheduleID.rawValue,
                ])) != nil
        }
    }

    public func hasReportRun(period: DateInterval, scheduleID: ReportScheduleID) throws -> Bool {
        try database.read { db in
            (try Int.fetchOne(
                db,
                sql: """
                    SELECT 1 FROM report_runs
                    WHERE period_start = ? AND period_end = ? AND schedule_id = ?
                    LIMIT 1
                    """,
                arguments: [
                    period.start.timeIntervalSince1970, period.end.timeIntervalSince1970,
                    scheduleID.rawValue,
                ])) != nil
        }
    }

    public func providerInvocationCount(from start: Date, through end: Date) throws -> Int {
        try database.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT SUM(count) FROM (
                        SELECT COUNT(*) AS count FROM report_runs
                        WHERE started_at >= ? AND started_at < ? AND effective_provider IS NOT NULL
                        UNION ALL
                        SELECT COUNT(*) AS count FROM summary_runs
                        WHERE started_at >= ? AND started_at < ? AND effective_provider IS NOT NULL
                    )
                    """,
                arguments: [
                    start.timeIntervalSince1970, end.timeIntervalSince1970,
                    start.timeIntervalSince1970, end.timeIntervalSince1970,
                ]) ?? 0
        }
    }

    public func generationTokenCommitment(from start: Date, through end: Date) throws -> Int {
        try database.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(SUM(tokens), 0) FROM (
                        SELECT CASE
                            WHEN effective_provider = 'codex'
                            THEN COALESCE(input_tokens, estimated_input_tokens, 0)
                                 + COALESCE(output_tokens, reasoning_tokens, 0)
                            ELSE COALESCE(input_tokens, estimated_input_tokens, 0)
                                 + COALESCE(cached_input_tokens, 0)
                                 + COALESCE(output_tokens, 0)
                                 + COALESCE(reasoning_tokens, 0)
                        END AS tokens
                        FROM report_runs
                        WHERE queued_at >= ? AND queued_at < ? AND effective_provider IS NOT NULL
                        UNION ALL
                        SELECT CASE
                            WHEN effective_provider = 'codex'
                            THEN COALESCE(input_tokens, estimated_input_tokens, 0)
                                 + COALESCE(output_tokens, reasoning_tokens, 0)
                            ELSE COALESCE(input_tokens, estimated_input_tokens, 0)
                                 + COALESCE(cached_input_tokens, 0)
                                 + COALESCE(output_tokens, 0)
                                 + COALESCE(reasoning_tokens, 0)
                        END AS tokens
                        FROM summary_runs
                        WHERE queued_at >= ? AND queued_at < ? AND effective_provider IS NOT NULL
                    )
                    """,
                arguments: [
                    start.timeIntervalSince1970, end.timeIntervalSince1970,
                    start.timeIntervalSince1970, end.timeIntervalSince1970,
                ]) ?? 0
        }
    }

    public func cancelReportRun(id: ReportRunID, at date: Date) throws -> Bool {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE report_runs
                    SET state = 'cancelled', finished_at = ?, failure_class = 'cancelled',
                        failure_detail = 'Cancelled by user'
                    WHERE id = ? AND state IN ('pending', 'running')
                    """,
                arguments: [date.timeIntervalSince1970, id.rawValue]
            )
            return db.changesCount == 1
        }
    }

    public func recoverInterruptedReportRuns(at date: Date) throws -> [ReportRun] {
        try database.write { db in
            let ids = try String.fetchAll(
                db, sql: "SELECT id FROM report_runs WHERE state = 'running' ORDER BY queued_at")
            guard !ids.isEmpty else { return [] }
            for id in ids {
                try db.execute(
                    sql: """
                        UPDATE report_runs SET state = 'failed', finished_at = ?,
                            failure_class = 'cancelled',
                            failure_detail = 'Interrupted before a validated provider result was stored'
                        WHERE id = ? AND state = 'running'
                        """,
                    arguments: [date.timeIntervalSince1970, id]
                )
            }
            return try ids.compactMap { try Self.fetchRun(db, id: ReportRunID($0)) }
        }
    }

    public func saveDestination(_ destination: Destination, now: Date) throws {
        let configuration = try encoder.encode(destination.configuration)
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO destinations
                        (id, kind, name, privacy_profile, permission, configuration_json, is_enabled, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET name = excluded.name,
                        privacy_profile = excluded.privacy_profile, permission = excluded.permission,
                        configuration_json = excluded.configuration_json, is_enabled = excluded.is_enabled
                    """,
                arguments: [
                    destination.id.rawValue, destination.kind.rawValue, destination.name,
                    destination.privacyProfile.rawValue, destination.permission.rawValue,
                    configuration, destination.isEnabled, now.timeIntervalSince1970,
                ]
            )
        }
    }

    public func destination(id: DestinationID) throws -> Destination? {
        try database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM destinations WHERE id = ?", arguments: [id.rawValue])
                .map(Self.decodeDestination)
        }
    }

    public func destinations() throws -> [Destination] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM destinations ORDER BY name COLLATE NOCASE, id")
                .map(Self.decodeDestination)
        }
    }

    @discardableResult
    public func recordDelivery(_ attempt: DeliveryAttempt) throws -> DeliveryAttempt {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO delivery_attempts
                        (id, artifact_id, destination_id, idempotency_key, state, attempted_at,
                         finished_at, retry_count, external_identifier, failure_detail)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    attempt.id.rawValue, attempt.artifactID.rawValue, attempt.destinationID.rawValue,
                    attempt.idempotencyKey, attempt.state.rawValue, attempt.attemptedAt.timeIntervalSince1970,
                    attempt.finishedAt?.timeIntervalSince1970, attempt.retryCount,
                    attempt.externalIdentifier, attempt.failureDetail,
                ]
            )
            let row = try Row.fetchOne(
                db, sql: "SELECT * FROM delivery_attempts WHERE idempotency_key = ?",
                arguments: [attempt.idempotencyKey])!
            return Self.decodeDelivery(row)
        }
    }

    public func updateDelivery(_ attempt: DeliveryAttempt) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE delivery_attempts SET state = ?, finished_at = ?, retry_count = ?,
                        external_identifier = ?, failure_detail = ?
                    WHERE id = ?
                    """,
                arguments: [
                    attempt.state.rawValue, attempt.finishedAt?.timeIntervalSince1970,
                    attempt.retryCount, attempt.externalIdentifier, attempt.failureDetail,
                    attempt.id.rawValue,
                ]
            )
        }
    }

    private static func decodeRecipe(_ row: Row) -> ReportRecipe {
        ReportRecipe(
            id: RecipeID(row["id"] as String),
            currentVersionID: RecipeVersionID(row["current_version_id"] as String),
            name: row["name"], isBuiltIn: row["is_builtin"], isEnabled: row["is_enabled"])
    }

    private static func fetchRecipeVersion(_ db: Database, id: RecipeVersionID) throws -> ReportRecipeVersion? {
        try Row.fetchOne(db, sql: "SELECT * FROM report_recipe_versions WHERE id = ?", arguments: [id.rawValue])
            .map(decodeRecipeVersion)
    }

    private static func decodeRecipeVersion(_ row: Row) throws -> ReportRecipeVersion {
        let repositoryData: Data = row["repository_ids_json"]
        let groupData: Data = row["group_names_json"]
        return ReportRecipeVersion(
            id: RecipeVersionID(row["id"] as String), recipeID: RecipeID(row["recipe_id"] as String),
            version: row["version"], purpose: row["purpose"], audience: row["audience"],
            cadence: try decodeEnum(row["cadence"], as: RecipeCadence.self),
            repositoryIDs: try JSONDecoder().decode([String].self, from: repositoryData).map { RepositoryID($0) },
            groupNames: try JSONDecoder().decode([String].self, from: groupData),
            customFocus: row["custom_focus"], tone: row["tone"],
            outputFormat: try decodeEnum(row["output_format"], as: RecipeOutputFormat.self),
            maximumCharacters: row["maximum_characters"],
            privacyProfile: try decodeEnum(row["privacy_profile"], as: PrivacyProfile.self),
            providerModeOverride: try optionalEnum(row["provider_mode_override"], as: ProviderSelectionMode.self),
            createdAt: Date(timeIntervalSince1970: row["created_at"]))
    }

    private static func insertRun(_ db: Database, run: ReportRun) throws {
        let configuration = try run.configuration.map { try JSONEncoder().encode($0) }
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO report_runs
                    (id, recipe_id, recipe_version_id, period_start, period_end, intent,
                     selection_mode, requested_provider, requested_model, effective_provider,
                     effective_model, compiler_version, prompt_version, invocation_version,
                     output_schema_version, configuration_json, schedule_id, input_bytes, estimated_input_tokens, input_tokens,
                     cached_input_tokens, output_tokens, reasoning_tokens, cost_value,
                     cost_currency, cost_kind, billing_context, queued_at, started_at,
                     finished_at, state, failure_class, failure_detail, artifact_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: runArguments(run, configuration: configuration))
    }

    private static func runArguments(_ run: ReportRun, configuration: Data?) -> StatementArguments {
        let values: [(any DatabaseValueConvertible)?] = [
            run.id.rawValue, run.recipeID.rawValue, run.recipeVersionID.rawValue,
            run.periodStart.timeIntervalSince1970, run.periodEnd.timeIntervalSince1970,
            run.intent.rawValue, run.selectionMode.rawValue, run.requestedProvider?.rawValue,
            run.requestedModel, run.effectiveProvider?.rawValue, run.effectiveModel,
            run.compilerVersion, run.promptVersion, run.invocationVersion,
            run.outputSchemaVersion, configuration, run.scheduleID?.rawValue,
            run.inputBytes, run.estimatedInputTokens,
            run.usage.inputTokens, run.usage.cachedInputTokens, run.usage.outputTokens,
            run.usage.reasoningTokens, run.usage.cost.map(String.init(describing:)),
            run.usage.currency, run.usage.costKind.rawValue, run.usage.billingContext,
            run.queuedAt.timeIntervalSince1970, run.startedAt?.timeIntervalSince1970,
            run.finishedAt?.timeIntervalSince1970, run.state.rawValue,
            run.failureClass?.rawValue, run.failureDetail, run.artifactID?.rawValue,
        ]
        return StatementArguments(values)
    }

    private static func fetchRun(_ db: Database, id: ReportRunID) throws -> ReportRun? {
        try Row.fetchOne(db, sql: "SELECT * FROM report_runs WHERE id = ?", arguments: [id.rawValue])
            .map(decodeRun)
    }

    private static func decodeRun(_ row: Row) throws -> ReportRun {
        let costString: String? = row["cost_value"]
        let configurationData: Data? = row["configuration_json"]
        return ReportRun(
            id: ReportRunID(row["id"] as String), recipeID: RecipeID(row["recipe_id"] as String),
            recipeVersionID: RecipeVersionID(row["recipe_version_id"] as String),
            periodStart: Date(timeIntervalSince1970: row["period_start"]),
            periodEnd: Date(timeIntervalSince1970: row["period_end"]),
            intent: try decodeEnum(row["intent"], as: ReportRunIntent.self),
            selectionMode: try decodeEnum(row["selection_mode"], as: ProviderSelectionMode.self),
            requestedProvider: try optionalEnum(row["requested_provider"], as: SummaryProviderID.self),
            requestedModel: row["requested_model"],
            effectiveProvider: try optionalEnum(row["effective_provider"], as: SummaryProviderID.self),
            effectiveModel: row["effective_model"], compilerVersion: row["compiler_version"],
            promptVersion: row["prompt_version"], invocationVersion: row["invocation_version"],
            outputSchemaVersion: row["output_schema_version"], inputBytes: row["input_bytes"],
            estimatedInputTokens: row["estimated_input_tokens"],
            usage: ProviderUsage(
                inputTokens: row["input_tokens"], cachedInputTokens: row["cached_input_tokens"],
                outputTokens: row["output_tokens"], reasoningTokens: row["reasoning_tokens"],
                cost: costString.flatMap { Decimal(string: $0) }, currency: row["cost_currency"],
                costKind: try decodeEnum(row["cost_kind"], as: CostKind.self),
                billingContext: row["billing_context"]),
            queuedAt: Date(timeIntervalSince1970: row["queued_at"]),
            startedAt: (row["started_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            finishedAt: (row["finished_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            state: try decodeEnum(row["state"], as: ReportRunState.self),
            failureClass: try optionalEnum(row["failure_class"], as: GenerationFailureClass.self),
            failureDetail: row["failure_detail"],
            artifactID: (row["artifact_id"] as String?).map { ArtifactID($0) },
            configuration: try configurationData.map {
                try JSONDecoder().decode(ReportRunConfiguration.self, from: $0)
            },
            scheduleID: (row["schedule_id"] as String?).map { ReportScheduleID($0) }
        )
    }

    private static func fetchSchedule(_ db: Database, id: ReportScheduleID) throws -> ReportSchedule? {
        try Row.fetchOne(
            db, sql: "SELECT * FROM report_schedules WHERE id = ?", arguments: [id.rawValue]
        ).map(decodeSchedule)
    }

    private static func decodeSchedule(_ row: Row) throws -> ReportSchedule {
        let repositoryData: Data = row["repository_ids_json"]
        let groupData: Data = row["group_names_json"]
        return ReportSchedule(
            id: ReportScheduleID(row["id"] as String), name: row["name"],
            recipeID: RecipeID(row["recipe_id"] as String),
            cadence: try decodeEnum(row["cadence"], as: ReportScheduleCadence.self),
            repositoryIDs: try JSONDecoder().decode([String].self, from: repositoryData).map {
                RepositoryID($0)
            },
            groupNames: try JSONDecoder().decode([String].self, from: groupData),
            providerModeOverride: try optionalEnum(
                row["provider_mode_override"], as: ProviderSelectionMode.self),
            isEnabled: row["is_enabled"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
    }

    private static func decodeArtifact(_ db: Database, row: Row) throws -> Artifact {
        let repositories: Data = row["repository_ids_json"]
        let groups: Data = row["group_names_json"]
        let id = ArtifactID(row["id"] as String)
        let type = try decodeEnum(row["type"] as String, as: ArtifactType.self)
        let format = try decodeEnum(row["format"] as String, as: RecipeOutputFormat.self)
        let privacy = try decodeEnum(row["privacy_profile"] as String, as: PrivacyProfile.self)
        let state = try decodeEnum(row["state"] as String, as: ReportPeriodState.self)
        let repositoryIDs = try JSONDecoder().decode([String].self, from: repositories).map { RepositoryID($0) }
        let groupNames = try JSONDecoder().decode([String].self, from: groups)
        let createdAt = Date(timeIntervalSince1970: row["created_at"] as Double)
        let recipeID = RecipeID(row["recipe_id"] as String)
        let recipeVersionID = RecipeVersionID(row["recipe_version_id"] as String)
        let reportRunID = (row["report_run_id"] as String?).map { ReportRunID($0) }
        let legacyReportID = (row["legacy_report_id"] as String?).map { ReportID($0) }
        let periodStart = Date(timeIntervalSince1970: row["period_start"] as Double)
        let periodEnd = Date(timeIntervalSince1970: row["period_end"] as Double)
        let content: String = row["content"]
        let revision: Int = row["revision"]
        let revisesArtifactID = (row["revises_artifact_id"] as String?).map { ArtifactID($0) }
        let evidence = try String.fetchAll(
            db, sql: "SELECT evidence_id FROM artifact_evidence WHERE artifact_id = ? ORDER BY evidence_id",
            arguments: [id.rawValue])
        return Artifact(
            id: id, type: type, format: format,
            createdAt: createdAt, recipeID: recipeID, recipeVersionID: recipeVersionID,
            reportRunID: reportRunID, legacyReportID: legacyReportID,
            periodStart: periodStart, periodEnd: periodEnd,
            repositoryIDs: repositoryIDs, groupNames: groupNames,
            privacyProfile: privacy, state: state, content: content,
            evidenceIDs: evidence.map { EvidenceID($0) }, revision: revision,
            revisesArtifactID: revisesArtifactID)
    }

    private static func decodeDestination(_ row: Row) throws -> Destination {
        let configuration: Data = row["configuration_json"]
        return Destination(
            id: DestinationID(row["id"] as String), kind: try decodeEnum(row["kind"], as: DestinationKind.self),
            name: row["name"], privacyProfile: try decodeEnum(row["privacy_profile"], as: PrivacyProfile.self),
            permission: try decodeEnum(row["permission"], as: DeliveryPermission.self),
            configuration: try JSONDecoder().decode([String: String].self, from: configuration),
            isEnabled: row["is_enabled"])
    }

    private static func decodeDelivery(_ row: Row) -> DeliveryAttempt {
        DeliveryAttempt(
            id: DeliveryAttemptID(row["id"] as String), artifactID: ArtifactID(row["artifact_id"] as String),
            destinationID: DestinationID(row["destination_id"] as String),
            idempotencyKey: row["idempotency_key"], state: DeliveryState(rawValue: row["state"])!,
            attemptedAt: Date(timeIntervalSince1970: row["attempted_at"]),
            finishedAt: (row["finished_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            retryCount: row["retry_count"], externalIdentifier: row["external_identifier"],
            failureDetail: row["failure_detail"])
    }

    private static func decodeEnum<T: RawRepresentable>(_ value: String, as _: T.Type) throws -> T
    where T.RawValue == String {
        guard let result = T(rawValue: value) else {
            throw LedgerStoreError.unsupportedValue(type: String(describing: T.self), value: value)
        }
        return result
    }

    private static func optionalEnum<T: RawRepresentable>(_ value: String?, as type: T.Type) throws -> T?
    where T.RawValue == String {
        guard let value else { return nil }
        return try decodeEnum(value, as: type)
    }
}
