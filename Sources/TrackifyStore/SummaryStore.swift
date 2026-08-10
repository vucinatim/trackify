import Foundation
import GRDB
import TrackifyDomain

extension LedgerStore {
    public func save(summary: WorkSummary) throws {
        let content = try encoder.encode(summary.content)
        let statistics = try encoder.encode(summary.statistics)
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO work_summaries (
                        id, kind, period_start, period_end, generated_at, state,
                        narrative, content_json, statistics_json, generation_source,
                        provider, model, generator_version, prompt_version,
                        schema_version, source_fingerprint, eligible_event_count,
                        covered_event_count, truncated_assistant_count, chunk_count,
                        coverage_known, revision, revises_summary_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    summary.id.rawValue, summary.kind.rawValue,
                    summary.periodStart.timeIntervalSince1970,
                    summary.periodEnd.timeIntervalSince1970,
                    summary.generatedAt.timeIntervalSince1970, summary.state.rawValue,
                    summary.content.narrative, content, statistics,
                    summary.generationSource.rawValue, summary.provider?.rawValue,
                    summary.model, summary.generatorVersion, summary.promptVersion,
                    summary.schemaVersion, summary.sourceFingerprint,
                    summary.coverage.eligibleEventCount, summary.coverage.coveredEventCount,
                    summary.coverage.truncatedAssistantCount, summary.coverage.chunkCount,
                    summary.coverage.isKnown, summary.revision,
                    summary.revisesSummaryID?.rawValue,
                ])
            for evidenceID in summary.evidenceIDs {
                try db.execute(
                    sql: "INSERT INTO summary_evidence (summary_id, evidence_id) VALUES (?, ?)",
                    arguments: [summary.id.rawValue, evidenceID.rawValue])
            }
            for (ordinal, childID) in summary.childSummaryIDs.enumerated() {
                try db.execute(
                    sql: "INSERT INTO summary_children (summary_id, child_summary_id, ordinal) VALUES (?, ?, ?)",
                    arguments: [summary.id.rawValue, childID.rawValue, ordinal])
            }
            try db.execute(
                sql: """
                    DELETE FROM search_documents
                    WHERE entity_type = 'summary' AND entity_id IN (
                        SELECT id FROM work_summaries
                        WHERE kind = ? AND period_start = ? AND period_end = ? AND id <> ?
                    )
                    """,
                arguments: [
                    summary.kind.rawValue, summary.periodStart.timeIntervalSince1970,
                    summary.periodEnd.timeIntervalSince1970, summary.id.rawValue,
                ])
            try db.execute(
                sql: """
                    INSERT INTO search_documents (
                        entity_type, entity_id, repository_id, occurred_at, content)
                    VALUES ('summary', ?, NULL, ?, ?)
                    """,
                arguments: [
                    summary.id.rawValue, summary.periodEnd.timeIntervalSince1970,
                    summary.content.narrative,
                ])
        }
    }

    public func summary(id: SummaryID) throws -> WorkSummary? {
        try database.read { db in
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM work_summaries WHERE id = ?",
                    arguments: [id.rawValue])
            else { return nil }
            return try Self.decodeSummary(db, row: row)
        }
    }

    public func summaries(
        overlapping range: DateInterval? = nil,
        kinds: Set<WorkSummaryKind>? = nil,
        includeSuperseded: Bool = false,
        limit: Int = 500
    ) throws -> [WorkSummary] {
        precondition((1...5_000).contains(limit))
        return try database.read { db in
            var clauses: [String] = []
            var arguments = StatementArguments()
            if let range {
                clauses.append("period_start < ? AND period_end > ?")
                arguments += [range.end.timeIntervalSince1970, range.start.timeIntervalSince1970]
            }
            if let kinds, !kinds.isEmpty {
                let values = kinds.map(\.rawValue).sorted()
                clauses.append("kind IN (\(Array(repeating: "?", count: values.count).joined(separator: ",")))")
                arguments += StatementArguments(values)
            }
            if !includeSuperseded {
                clauses.append(
                    """
                    NOT EXISTS (
                        SELECT 1 FROM work_summaries newer
                        WHERE newer.kind = work_summaries.kind
                          AND newer.period_start = work_summaries.period_start
                          AND newer.period_end = work_summaries.period_end
                          AND newer.revision > work_summaries.revision
                    )
                    """)
            }
            let predicate = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            arguments += [limit]
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM work_summaries
                    \(predicate)
                    ORDER BY period_end DESC, generated_at DESC, revision DESC, id DESC
                    LIMIT ?
                    """,
                arguments: arguments
            ).map { try Self.decodeSummary(db, row: $0) }
        }
    }

    public func latestSummary(
        kind: WorkSummaryKind,
        overlapping range: DateInterval? = nil
    ) throws -> WorkSummary? {
        try database.read { db in
            var predicate = "kind = ?"
            var arguments: StatementArguments = [kind.rawValue]
            if let range {
                predicate += " AND period_start < ? AND period_end > ?"
                arguments += [range.end.timeIntervalSince1970, range.start.timeIntervalSince1970]
            }
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT * FROM work_summaries summary
                        WHERE \(predicate)
                          AND NOT EXISTS (
                              SELECT 1 FROM work_summaries newer
                              WHERE newer.kind = summary.kind
                                AND newer.period_start = summary.period_start
                                AND newer.period_end = summary.period_end
                                AND newer.revision > summary.revision
                          )
                        ORDER BY period_end DESC, generated_at DESC, revision DESC, id DESC
                        LIMIT 1
                        """,
                    arguments: arguments)
            else { return nil }
            return try Self.decodeSummary(db, row: row)
        }
    }

    public func hasSummary(
        kind: WorkSummaryKind,
        period: DateInterval,
        sourceFingerprint: String
    ) throws -> Bool {
        try database.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT 1 FROM work_summaries
                    WHERE kind = ? AND period_start = ? AND period_end = ?
                      AND source_fingerprint = ? LIMIT 1
                    """,
                arguments: [
                    kind.rawValue, period.start.timeIntervalSince1970,
                    period.end.timeIntervalSince1970, sourceFingerprint,
                ]) != nil
        }
    }

    public func save(summaryRun: SummaryRun) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO summary_runs (
                        id, kind, period_start, period_end, selection_mode,
                        requested_provider, requested_model, effective_provider,
                        effective_model, source_fingerprint, input_bytes,
                        estimated_input_tokens, input_tokens, cached_input_tokens,
                        output_tokens, reasoning_tokens, cost_value, cost_currency,
                        cost_kind, billing_context, queued_at, started_at, finished_at,
                        state, failure_class, failure_detail, summary_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        requested_provider = excluded.requested_provider,
                        requested_model = excluded.requested_model,
                        effective_provider = excluded.effective_provider,
                        effective_model = excluded.effective_model,
                        input_bytes = excluded.input_bytes,
                        estimated_input_tokens = excluded.estimated_input_tokens,
                        input_tokens = excluded.input_tokens,
                        cached_input_tokens = excluded.cached_input_tokens,
                        output_tokens = excluded.output_tokens,
                        reasoning_tokens = excluded.reasoning_tokens,
                        cost_value = excluded.cost_value,
                        cost_currency = excluded.cost_currency,
                        cost_kind = excluded.cost_kind,
                        billing_context = excluded.billing_context,
                        started_at = excluded.started_at,
                        finished_at = excluded.finished_at,
                        state = excluded.state,
                        failure_class = excluded.failure_class,
                        failure_detail = excluded.failure_detail,
                        summary_id = excluded.summary_id
                    """,
                arguments: Self.summaryRunArguments(summaryRun))
        }
    }

    public func summaryRuns(since: Date? = nil, limit: Int = 200) throws -> [SummaryRun] {
        precondition((1...1_000).contains(limit))
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM summary_runs
                    WHERE (? IS NULL OR queued_at >= ?)
                    ORDER BY queued_at DESC, id DESC LIMIT ?
                    """,
                arguments: [
                    since?.timeIntervalSince1970, since?.timeIntervalSince1970, limit,
                ]
            ).map(Self.decodeSummaryRun)
        }
    }

    private static func decodeSummary(_ db: Database, row: Row) throws -> WorkSummary {
        let evidence = try String.fetchAll(
            db,
            sql: "SELECT evidence_id FROM summary_evidence WHERE summary_id = ? ORDER BY evidence_id",
            arguments: [row["id"] as String])
        let children = try String.fetchAll(
            db,
            sql: "SELECT child_summary_id FROM summary_children WHERE summary_id = ? ORDER BY ordinal",
            arguments: [row["id"] as String])
        let contentData: Data = row["content_json"]
        let statisticsData: Data = row["statistics_json"]
        let kind: WorkSummaryKind = try summaryEnum(WorkSummaryKind.self, row["kind"] as String)
        let state: ReportPeriodState = try summaryEnum(ReportPeriodState.self, row["state"] as String)
        let source: SummaryGenerationSource = try summaryEnum(
            SummaryGenerationSource.self, row["generation_source"] as String)
        let provider: SummaryProviderID? = try optionalSummaryEnum(
            SummaryProviderID.self, row["provider"] as String?)
        let revises = (row["revises_summary_id"] as String?).map { SummaryID($0) }
        let coverage = SummaryCoverage(
            eligibleEventCount: row["eligible_event_count"],
            coveredEventCount: row["covered_event_count"],
            truncatedAssistantCount: row["truncated_assistant_count"],
            chunkCount: row["chunk_count"], isKnown: row["coverage_known"])
        let id = SummaryID(row["id"] as String)
        let periodStart = Date(timeIntervalSince1970: row["period_start"] as Double)
        let periodEnd = Date(timeIntervalSince1970: row["period_end"] as Double)
        let generatedAt = Date(timeIntervalSince1970: row["generated_at"] as Double)
        let decodedContent = try JSONDecoder().decode(SummaryContent.self, from: contentData)
        let decodedStatistics = try JSONDecoder().decode(SummaryStatistics.self, from: statisticsData)
        let evidenceIDs = evidence.map { EvidenceID($0) }
        let childIDs = children.map { SummaryID($0) }
        let model: String? = row["model"]
        let generatorVersion: String = row["generator_version"]
        let promptVersion: String = row["prompt_version"]
        let schemaVersion: String = row["schema_version"]
        let sourceFingerprint: String = row["source_fingerprint"]
        let revision: Int = row["revision"]
        return WorkSummary(
            id: id, kind: kind, periodStart: periodStart, periodEnd: periodEnd,
            generatedAt: generatedAt, state: state, content: decodedContent,
            statistics: decodedStatistics, evidenceIDs: evidenceIDs,
            childSummaryIDs: childIDs, generationSource: source, provider: provider,
            model: model, generatorVersion: generatorVersion,
            promptVersion: promptVersion, schemaVersion: schemaVersion,
            sourceFingerprint: sourceFingerprint, coverage: coverage,
            revision: revision, revisesSummaryID: revises)
    }

    private static func summaryRunArguments(_ run: SummaryRun) -> StatementArguments {
        let values: [(any DatabaseValueConvertible)?] = [
            run.id.rawValue, run.kind.rawValue,
            run.periodStart.timeIntervalSince1970, run.periodEnd.timeIntervalSince1970,
            run.selectionMode.rawValue, run.requestedProvider?.rawValue,
            run.requestedModel, run.effectiveProvider?.rawValue, run.effectiveModel,
            run.sourceFingerprint, run.inputBytes, run.estimatedInputTokens,
            run.usage.inputTokens, run.usage.cachedInputTokens, run.usage.outputTokens,
            run.usage.reasoningTokens, run.usage.cost.map(String.init(describing:)),
            run.usage.currency, run.usage.costKind.rawValue, run.usage.billingContext,
            run.queuedAt.timeIntervalSince1970, run.startedAt?.timeIntervalSince1970,
            run.finishedAt?.timeIntervalSince1970, run.state.rawValue,
            run.failureClass?.rawValue, run.failureDetail, run.summaryID?.rawValue,
        ]
        return StatementArguments(values)
    }

    private static func decodeSummaryRun(_ row: Row) throws -> SummaryRun {
        let costString: String? = row["cost_value"]
        return SummaryRun(
            id: SummaryRunID(row["id"] as String),
            kind: try summaryEnum(WorkSummaryKind.self, row["kind"] as String),
            periodStart: Date(timeIntervalSince1970: row["period_start"] as Double),
            periodEnd: Date(timeIntervalSince1970: row["period_end"] as Double),
            selectionMode: try summaryEnum(
                ProviderSelectionMode.self, row["selection_mode"] as String),
            requestedProvider: try optionalSummaryEnum(
                SummaryProviderID.self, row["requested_provider"] as String?),
            requestedModel: row["requested_model"],
            effectiveProvider: try optionalSummaryEnum(
                SummaryProviderID.self, row["effective_provider"] as String?),
            effectiveModel: row["effective_model"],
            sourceFingerprint: row["source_fingerprint"], inputBytes: row["input_bytes"],
            estimatedInputTokens: row["estimated_input_tokens"],
            usage: ProviderUsage(
                inputTokens: row["input_tokens"], cachedInputTokens: row["cached_input_tokens"],
                outputTokens: row["output_tokens"], reasoningTokens: row["reasoning_tokens"],
                cost: costString.flatMap { Decimal(string: $0) },
                currency: row["cost_currency"],
                costKind: try summaryEnum(CostKind.self, row["cost_kind"] as String),
                billingContext: row["billing_context"]),
            queuedAt: Date(timeIntervalSince1970: row["queued_at"] as Double),
            startedAt: (row["started_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            finishedAt: (row["finished_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            state: try summaryEnum(ReportRunState.self, row["state"] as String),
            failureClass: try optionalSummaryEnum(
                GenerationFailureClass.self, row["failure_class"] as String?),
            failureDetail: row["failure_detail"],
            summaryID: (row["summary_id"] as String?).map { SummaryID($0) })
    }
}

private func summaryEnum<Value: RawRepresentable>(
    _ type: Value.Type,
    _ rawValue: String
) throws -> Value where Value.RawValue == String {
    guard let value = Value(rawValue: rawValue) else {
        throw LedgerStoreError.unsupportedValue(
            type: String(describing: type), value: rawValue)
    }
    return value
}

private func optionalSummaryEnum<Value: RawRepresentable>(
    _ type: Value.Type,
    _ rawValue: String?
) throws -> Value? where Value.RawValue == String {
    try rawValue.map { try summaryEnum(type, $0) }
}
