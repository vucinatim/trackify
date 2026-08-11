import Foundation

public enum SourceKind: String, Codable, CaseIterable, Sendable {
    case git
    case codex
    case claude
    case process
    case simulation
}

public enum IngestionPath: String, Codable, Sendable {
    case cache
    case hook
    case observation
    case fixture
}

public enum ObservedState: String, Codable, CaseIterable, Sendable {
    case inProgress = "in_progress"
    case completed
    case failed
    case interrupted
    case waiting
    case unknown
}

public struct SourceEvidence: Codable, Equatable, Sendable {
    public let id: EvidenceID
    public let source: SourceKind
    public let ingestionPath: IngestionPath
    public let sourceRecordID: String?
    public let fingerprint: String
    public let occurredAt: Date
    public let observedAt: Date
    public let adapterVersion: Int

    public init(
        id: EvidenceID,
        source: SourceKind,
        ingestionPath: IngestionPath,
        sourceRecordID: String? = nil,
        fingerprint: String,
        occurredAt: Date,
        observedAt: Date,
        adapterVersion: Int
    ) {
        self.id = id
        self.source = source
        self.ingestionPath = ingestionPath
        self.sourceRecordID = sourceRecordID
        self.fingerprint = fingerprint
        self.occurredAt = occurredAt
        self.observedAt = observedAt
        self.adapterVersion = adapterVersion
    }
}
