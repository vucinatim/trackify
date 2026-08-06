import Foundation
import TrackifyDomain
import TrackifyStore

public struct SafeProviderDiagnostic: Codable, Equatable, Sendable {
    public let providerID: String
    public let state: ProviderHealthState
}

public struct DiagnosticExport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let state: DiagnosticState
    public let migrations: [String]
    public let counts: LedgerCounts
    public let integrity: String
    public let databaseBytes: Int64
    public let migrationBackupCount: Int
    public let migrationBackupBytes: Int64
    public let collectorState: String?
    public let collectorHeartbeatPresent: Bool
    public let collectorIssueCount: Int
    public let providers: [SafeProviderDiagnostic]
    public let workIntelligence: WorkIntelligenceCounts
}

public struct DiagnosticExporter: Sendable {
    public init() {}

    public func make(store: LedgerStore, generatedAt: Date = Date()) throws -> DiagnosticExport {
        let report = try Doctor().inspect(store: store)
        return DiagnosticExport(
            schemaVersion: 1,
            generatedAt: generatedAt,
            state: report.state,
            migrations: report.migrations,
            counts: report.counts,
            integrity: report.health.integrity,
            databaseBytes: report.health.databaseBytes,
            migrationBackupCount: report.health.migrationBackupCount,
            migrationBackupBytes: report.health.migrationBackupBytes,
            collectorState: report.health.collectorState,
            collectorHeartbeatPresent: report.health.collectorObservedAt != nil,
            collectorIssueCount: report.health.collectorIssues.count,
            providers: SummaryProviderFactory.health().map {
                SafeProviderDiagnostic(providerID: $0.providerID, state: $0.state)
            },
            workIntelligence: try store.workIntelligenceCounts()
        )
    }

    public func write(_ export: DiagnosticExport, to destinationURL: URL) throws {
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(export)
        data.append(0x0A)
        try data.write(to: destination, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}
