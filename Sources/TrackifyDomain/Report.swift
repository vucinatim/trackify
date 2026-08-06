import Foundation

public enum ReportPeriodState: String, Codable, CaseIterable, Sendable {
    case observed
    case inProgress = "in_progress"
    case completed
    case investigating
    case waiting
    case noActivity = "no_activity"
}

public struct WorkReport: Codable, Equatable, Sendable {
    public let id: ReportID
    public let periodStart: Date
    public let periodEnd: Date
    public let state: ReportPeriodState
    public let summary: String
    public let evidenceIDs: [EvidenceID]
    public let provider: String?
    public let model: String?
    public let generatorVersion: String
    public let revision: Int

    public init(
        id: ReportID,
        periodStart: Date,
        periodEnd: Date,
        state: ReportPeriodState,
        summary: String,
        evidenceIDs: [EvidenceID],
        provider: String?,
        model: String?,
        generatorVersion: String,
        revision: Int
    ) {
        self.id = id
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.state = state
        self.summary = summary
        self.evidenceIDs = evidenceIDs
        self.provider = provider
        self.model = model
        self.generatorVersion = generatorVersion
        self.revision = revision
    }
}
