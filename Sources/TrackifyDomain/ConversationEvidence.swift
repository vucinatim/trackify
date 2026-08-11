import Foundation

public enum ConversationOrigin: String, Codable, CaseIterable, Sendable {
    case human
    case agent
    case assistant
    case tool
    case hook
    case provider
    case system
    case trackify
    case unknown
}

public enum ConversationSemanticKind: String, Codable, CaseIterable, Sendable {
    case intent
    case steering
    case progress
    case outcome
    case lifecycle
    case control
    case failure
    case diagnostic
    case unknown
}

public enum EvidenceDisposition: String, Codable, CaseIterable, Sendable {
    case work
    case diagnostic
    case control
    case unresolved
}

public enum CanonicalRecordState: String, Codable, CaseIterable, Sendable {
    case primary
    case alias
    case replay
    case unresolved
}

public struct ConversationProvenance: Codable, Equatable, Sendable {
    public static let currentClassificationVersion = 1

    public let sourceRecordID: String?
    public let sourceRecordType: String
    public let sourceTurnID: String?
    public let parentSourceRecordID: String?
    public let sourceResponseID: String?
    public let entrypoint: String?
    public let workingDirectory: String?
    public let isMeta: Bool
    public let isSidechain: Bool
    public let origin: ConversationOrigin
    public let semanticKind: ConversationSemanticKind
    public let disposition: EvidenceDisposition
    public let canonicalState: CanonicalRecordState
    public let classificationVersion: Int
    public let classificationReason: String
    public let logicalTurnID: LogicalTurnID?
    public let logicalMessageID: LogicalMessageID?

    public init(
        sourceRecordID: String? = nil,
        sourceRecordType: String = "legacy",
        sourceTurnID: String? = nil,
        parentSourceRecordID: String? = nil,
        sourceResponseID: String? = nil,
        entrypoint: String? = nil,
        workingDirectory: String? = nil,
        isMeta: Bool = false,
        isSidechain: Bool = false,
        origin: ConversationOrigin = .unknown,
        semanticKind: ConversationSemanticKind = .unknown,
        disposition: EvidenceDisposition = .work,
        canonicalState: CanonicalRecordState = .primary,
        classificationVersion: Int = ConversationProvenance.currentClassificationVersion,
        classificationReason: String = "legacy-compatible",
        logicalTurnID: LogicalTurnID? = nil,
        logicalMessageID: LogicalMessageID? = nil
    ) {
        self.sourceRecordID = sourceRecordID
        self.sourceRecordType = sourceRecordType
        self.sourceTurnID = sourceTurnID
        self.parentSourceRecordID = parentSourceRecordID
        self.sourceResponseID = sourceResponseID
        self.entrypoint = entrypoint
        self.workingDirectory = workingDirectory
        self.isMeta = isMeta
        self.isSidechain = isSidechain
        self.origin = origin
        self.semanticKind = semanticKind
        self.disposition = disposition
        self.canonicalState = canonicalState
        self.classificationVersion = classificationVersion
        self.classificationReason = classificationReason
        self.logicalTurnID = logicalTurnID
        self.logicalMessageID = logicalMessageID
    }
}

/// One allowlisted provider record. Text is optional because structural,
/// diagnostic, and unknown records remain observable without copying unsafe
/// provider payloads into Trackify.
public struct NormalizedConversationRecord: Codable, Equatable, Sendable {
    public let id: ConversationRecordID
    public let source: SourceKind
    public let sessionID: SessionID
    public let occurredAt: Date?
    public let observedAt: Date
    public let role: MessageRole?
    public let normalizedText: String?
    public let textFingerprint: String?
    public let provenance: ConversationProvenance
    public let adapterVersion: Int

    public init(
        id: ConversationRecordID,
        source: SourceKind,
        sessionID: SessionID,
        occurredAt: Date?,
        observedAt: Date,
        role: MessageRole? = nil,
        normalizedText: String? = nil,
        textFingerprint: String? = nil,
        provenance: ConversationProvenance,
        adapterVersion: Int
    ) {
        self.id = id
        self.source = source
        self.sessionID = sessionID
        self.occurredAt = occurredAt
        self.observedAt = observedAt
        self.role = role
        self.normalizedText = normalizedText
        self.textFingerprint = textFingerprint
        self.provenance = provenance
        self.adapterVersion = adapterVersion
    }
}

public enum EvidenceQualityState: String, Codable, Sendable {
    case healthy
    case degraded
}

public struct EvidenceQualityIssue: Codable, Equatable, Sendable {
    public let id: EvidenceQualityIssueID
    public let source: SourceKind?
    public let sourceKey: String
    public let code: String
    public let detail: String
    public let count: Int
    public let firstObservedAt: Date
    public let lastObservedAt: Date
    public let affectsWorkMetrics: Bool

    public init(
        id: EvidenceQualityIssueID,
        source: SourceKind? = nil,
        sourceKey: String,
        code: String,
        detail: String,
        count: Int,
        firstObservedAt: Date,
        lastObservedAt: Date,
        affectsWorkMetrics: Bool
    ) {
        self.id = id
        self.source = source
        self.sourceKey = sourceKey
        self.code = code
        self.detail = detail
        self.count = count
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
        self.affectsWorkMetrics = affectsWorkMetrics
    }
}

public struct EvidenceQualitySnapshot: Codable, Equatable, Sendable {
    public let state: EvidenceQualityState
    public let projectionVersion: Int
    public let unresolvedRecordCount: Int
    public let diagnosticRecordCount: Int
    public let aliasRecordCount: Int
    public let replayRecordCount: Int
    public let issues: [EvidenceQualityIssue]

    public init(
        state: EvidenceQualityState,
        projectionVersion: Int,
        unresolvedRecordCount: Int,
        diagnosticRecordCount: Int,
        aliasRecordCount: Int,
        replayRecordCount: Int,
        issues: [EvidenceQualityIssue]
    ) {
        self.state = state
        self.projectionVersion = projectionVersion
        self.unresolvedRecordCount = unresolvedRecordCount
        self.diagnosticRecordCount = diagnosticRecordCount
        self.aliasRecordCount = aliasRecordCount
        self.replayRecordCount = replayRecordCount
        self.issues = issues
    }
}
