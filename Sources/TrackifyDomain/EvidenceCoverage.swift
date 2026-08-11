import Foundation

public enum EvidenceSourceUnit: String, Codable, Sendable {
    case file
    case repository
    case unknown
}

public struct EvidenceSourceReadAudit: Codable, Equatable, Sendable {
    public let sourceKey: String
    public let unit: EvidenceSourceUnit
    public let candidatesConsidered: Int
    public let unitsOpened: Int
    public let bytesRead: Int?
    public let recordsObserved: Int
    public let recordsAccepted: Int

    public init(
        sourceKey: String,
        unit: EvidenceSourceUnit,
        candidatesConsidered: Int,
        unitsOpened: Int,
        bytesRead: Int?,
        recordsObserved: Int,
        recordsAccepted: Int
    ) {
        self.sourceKey = sourceKey
        self.unit = unit
        self.candidatesConsidered = candidatesConsidered
        self.unitsOpened = unitsOpened
        self.bytesRead = bytesRead
        self.recordsObserved = recordsObserved
        self.recordsAccepted = recordsAccepted
    }
}

public struct EvidenceLedgerCoverage: Codable, Equatable, Sendable {
    public let calendarDays: Int
    public let start: Date
    public let cutoff: Date
    public let recordedAt: Date
    public let canonicalFingerprint: String
    public let sourceReads: [EvidenceSourceReadAudit]

    public init(
        calendarDays: Int,
        start: Date,
        cutoff: Date,
        recordedAt: Date,
        canonicalFingerprint: String,
        sourceReads: [EvidenceSourceReadAudit]
    ) {
        self.calendarDays = calendarDays
        self.start = start
        self.cutoff = cutoff
        self.recordedAt = recordedAt
        self.canonicalFingerprint = canonicalFingerprint
        self.sourceReads = sourceReads
    }
}
