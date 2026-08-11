import Foundation
import TrackifyDomain
import TrackifyStore

public enum DiagnosticState: String, Codable, Sendable {
    case healthy
    case degraded
    case failed
}

public struct DiagnosticReport: Codable, Equatable, Sendable {
    public let state: DiagnosticState
    public let databasePath: String
    public let migrations: [String]
    public let counts: LedgerCounts
    public let health: LedgerHealth
    public let evidence: EvidenceQualitySnapshot
    public let coverage: EvidenceLedgerCoverage?
    public let liveCollector: LiveCollectorRuntimeStatus?
    public let lastFullReconciliation: Date?
    public let problems: [String]
    public let warnings: [String]

    public init(
        state: DiagnosticState,
        databasePath: String,
        migrations: [String],
        counts: LedgerCounts,
        health: LedgerHealth,
        evidence: EvidenceQualitySnapshot,
        coverage: EvidenceLedgerCoverage?,
        liveCollector: LiveCollectorRuntimeStatus?,
        lastFullReconciliation: Date?,
        problems: [String],
        warnings: [String]
    ) {
        self.state = state
        self.databasePath = databasePath
        self.migrations = migrations
        self.counts = counts
        self.health = health
        self.evidence = evidence
        self.coverage = coverage
        self.liveCollector = liveCollector
        self.lastFullReconciliation = lastFullReconciliation
        self.problems = problems
        self.warnings = warnings
    }
}

public struct Doctor {
    public init() {}

    public func inspect(store: LedgerStore, now: Date = Date()) throws -> DiagnosticReport {
        let migrations = try store.appliedMigrations()
        let counts = try store.counts()
        let health = try store.health()
        let evidence = try store.refreshEvidenceQualityAudit(at: now)
        let coverage = try store.evidenceCoverage()
        let liveCollector = try store.liveCollectorStatus()
        let recordedReconciliation = try store.heartbeatObservedAt(service: "reconciliation")
        let lastFullReconciliation = recordedReconciliation ?? health.collectorObservedAt
        var problems: [String] = []
        var warnings: [String] = []

        if migrations.isEmpty {
            problems.append("No database migration has been applied.")
        }
        if health.integrity != "ok" {
            problems.append("SQLite integrity check returned: \(health.integrity)")
        }
        problems.append(contentsOf: health.collectorIssues)
        problems.append(
            contentsOf: evidence.issues.filter(\.affectsWorkMetrics).map {
                "Evidence \($0.code): \($0.detail) (\($0.count))"
            })
        warnings.append(
            contentsOf: evidence.issues.filter { !$0.affectsWorkMetrics }.map {
                "Evidence \($0.code): \($0.detail) (\($0.count))"
            })
        if let liveCollector {
            if liveCollector.mode == .degraded {
                problems.append(
                    liveCollector.lastError
                        ?? "Live collection is degraded; restart Trackify or inspect source diagnostics.")
            }
            if liveCollector.mode == .pending,
                let lastTriggerAt = liveCollector.lastTriggerAt,
                now.timeIntervalSince(lastTriggerAt) > 60
            {
                problems.append("Live collection has pending evidence older than one minute.")
            }
            if liveCollector.mode == .collecting,
                let startedAt = liveCollector.lastCollectionStartedAt,
                now.timeIntervalSince(startedAt) > 15 * 60
            {
                problems.append("Live collection has remained active for more than fifteen minutes.")
            }
        } else {
            warnings.append("The live collector has not recorded status yet; open Trackify to start it.")
        }
        if let lastFullReconciliation,
            now.timeIntervalSince(lastFullReconciliation) > 60 * 60
        {
            warnings.append("The last full evidence reconciliation is more than one hour old.")
        }

        return DiagnosticReport(
            state: health.integrity == "ok" ? (problems.isEmpty ? .healthy : .degraded) : .failed,
            databasePath: store.databaseURL.path,
            migrations: migrations,
            counts: counts,
            health: health,
            evidence: evidence,
            coverage: coverage,
            liveCollector: liveCollector,
            lastFullReconciliation: lastFullReconciliation,
            problems: problems,
            warnings: warnings
        )
    }
}
