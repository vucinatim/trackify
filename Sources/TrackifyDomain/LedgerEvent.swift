import Foundation

public enum EventKind: String, Codable, CaseIterable, Sendable {
    case repositoryDiscovered = "repository.discovered"
    case repositoryChanged = "repository.changed"
    case gitCommitObserved = "git.commit.observed"
    case gitWorkingTreeChanged = "git.working_tree.changed"
    case agentSessionObserved = "agent.session.observed"
    case agentMessageObserved = "agent.message.observed"
    case agentRunStarted = "agent.run.started"
    case agentRunWaiting = "agent.run.waiting"
    case agentRunFinished = "agent.run.finished"
    case buildStarted = "build.started"
    case buildFinished = "build.finished"
    case testFinished = "test.finished"
}

public struct LedgerEvent: Codable, Equatable, Sendable {
    public let id: EventID
    public let evidenceID: EvidenceID
    public let occurredAt: Date
    public let observedAt: Date
    public let source: SourceKind
    public let kind: EventKind
    public let repositoryID: RepositoryID?
    public let workingCopyID: WorkingCopyID?
    public let sessionID: SessionID?
    public let state: ObservedState?
    public let payload: [String: String]
    public let schemaVersion: Int

    public init(
        id: EventID,
        evidenceID: EvidenceID,
        occurredAt: Date,
        observedAt: Date,
        source: SourceKind,
        kind: EventKind,
        repositoryID: RepositoryID? = nil,
        workingCopyID: WorkingCopyID? = nil,
        sessionID: SessionID? = nil,
        state: ObservedState? = nil,
        payload: [String: String] = [:],
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.evidenceID = evidenceID
        self.occurredAt = occurredAt
        self.observedAt = observedAt
        self.source = source
        self.kind = kind
        self.repositoryID = repositoryID
        self.workingCopyID = workingCopyID
        self.sessionID = sessionID
        self.state = state
        self.payload = payload
        self.schemaVersion = schemaVersion
    }
}
