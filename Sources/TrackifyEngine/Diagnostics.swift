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

        return DiagnosticReport(
            state: health.integrity == "ok" ? (problems.isEmpty ? .healthy : .degraded) : .failed,
            databasePath: store.databaseURL.path,
            migrations: migrations,
            counts: counts,
            health: health,
            evidence: evidence,
            coverage: coverage,
            problems: problems,
            warnings: warnings
        )
    }
}
