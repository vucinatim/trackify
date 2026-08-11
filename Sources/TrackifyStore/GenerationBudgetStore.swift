import Foundation
import GRDB
import TrackifyDomain

extension LedgerStore {
    public func saveProviderAllowanceAttribution(
        operationID: String,
        provider: SummaryProviderID,
        purpose: String,
        startedAt: Date,
        finishedAt: Date,
        before: ProviderAllowanceSnapshot?,
        after: ProviderAllowanceSnapshot?
    ) throws {
        let snapshot = after ?? before
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO provider_allowance_attributions
                        (operation_id, provider, purpose, started_at, finished_at,
                         limit_id, window_duration_minutes, resets_at,
                         used_percent_before, used_percent_after)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(operation_id) DO UPDATE SET
                        finished_at = excluded.finished_at,
                        limit_id = excluded.limit_id,
                        window_duration_minutes = excluded.window_duration_minutes,
                        resets_at = excluded.resets_at,
                        used_percent_before = excluded.used_percent_before,
                        used_percent_after = excluded.used_percent_after
                    """,
                arguments: [
                    operationID, provider.rawValue, purpose,
                    startedAt.timeIntervalSince1970, finishedAt.timeIntervalSince1970,
                    snapshot?.limitID, snapshot?.windowDurationMinutes,
                    snapshot?.resetsAt?.timeIntervalSince1970,
                    before?.usedPercent, after?.usedPercent,
                ])
        }
    }

    public func attributedAllowancePercent(
        provider: SummaryProviderID,
        resetsAt: Date
    ) throws -> Int {
        try database.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(SUM(
                        CASE
                            WHEN used_percent_before IS NOT NULL
                             AND used_percent_after IS NOT NULL
                             AND used_percent_after > used_percent_before
                            THEN used_percent_after - used_percent_before
                            ELSE 0
                        END
                    ), 0)
                    FROM provider_allowance_attributions
                    WHERE provider = ? AND resets_at = ?
                    """,
                arguments: [provider.rawValue, resetsAt.timeIntervalSince1970]) ?? 0
        }
    }

    public func generationUsageRecords(from start: Date, through end: Date) throws
        -> [GenerationUsageRecord]
    {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT effective_provider, effective_model, estimated_input_tokens,
                           input_tokens, cached_input_tokens, output_tokens, reasoning_tokens,
                           cost_value, cost_currency, cost_kind, billing_context
                    FROM report_runs
                    WHERE queued_at >= ? AND queued_at < ? AND effective_provider IS NOT NULL
                    UNION ALL
                    SELECT effective_provider, effective_model, estimated_input_tokens,
                           input_tokens, cached_input_tokens, output_tokens, reasoning_tokens,
                           cost_value, cost_currency, cost_kind, billing_context
                    FROM summary_runs
                    WHERE queued_at >= ? AND queued_at < ? AND effective_provider IS NOT NULL
                    """,
                arguments: [
                    start.timeIntervalSince1970, end.timeIntervalSince1970,
                    start.timeIntervalSince1970, end.timeIntervalSince1970,
                ])
            return rows.compactMap { row -> GenerationUsageRecord? in
                guard let rawProvider = row["effective_provider"] as String?,
                    let provider = SummaryProviderID(rawValue: rawProvider)
                else { return nil }
                let rawCost = row["cost_value"] as String?
                return GenerationUsageRecord(
                    provider: provider,
                    model: row["effective_model"],
                    estimatedInputTokens: row["estimated_input_tokens"],
                    usage: ProviderUsage(
                        inputTokens: row["input_tokens"],
                        cachedInputTokens: row["cached_input_tokens"],
                        outputTokens: row["output_tokens"],
                        reasoningTokens: row["reasoning_tokens"],
                        cost: rawCost.flatMap { Decimal(string: $0) },
                        currency: row["cost_currency"],
                        costKind: (row["cost_kind"] as String?).flatMap(CostKind.init(rawValue:))
                            ?? .unknown,
                        billingContext: row["billing_context"])
                )
            }
        }
    }
}
