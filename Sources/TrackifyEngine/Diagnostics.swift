import Foundation
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
    public let problems: [String]

    public init(
        state: DiagnosticState,
        databasePath: String,
        migrations: [String],
        counts: LedgerCounts,
        health: LedgerHealth,
        problems: [String]
    ) {
        self.state = state
        self.databasePath = databasePath
        self.migrations = migrations
        self.counts = counts
        self.health = health
        self.problems = problems
    }
}

public struct Doctor {
    public init() {}

    public func inspect(store: LedgerStore) throws -> DiagnosticReport {
        let migrations = try store.appliedMigrations()
        let counts = try store.counts()
        let health = try store.health()
        var problems: [String] = []

        if migrations.isEmpty {
            problems.append("No database migration has been applied.")
        }
        if health.integrity != "ok" {
            problems.append("SQLite integrity check returned: \(health.integrity)")
        }
        problems.append(contentsOf: health.collectorIssues)

        return DiagnosticReport(
            state: health.integrity == "ok" ? (problems.isEmpty ? .healthy : .degraded) : .failed,
            databasePath: store.databaseURL.path,
            migrations: migrations,
            counts: counts,
            health: health,
            problems: problems
        )
    }
}
