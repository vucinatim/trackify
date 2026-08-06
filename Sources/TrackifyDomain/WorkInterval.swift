import Foundation

public enum WorkIntervalKind: String, Codable, Sendable {
    case agent
    case build
    case test
    case repository
}

public struct WorkInterval: Codable, Equatable, Sendable {
    public let id: WorkIntervalID
    public let kind: WorkIntervalKind
    public let startedAt: Date
    public let endedAt: Date
    public let repositoryID: RepositoryID?
    public let sessionID: SessionID?
    public let state: ObservedState
    public let sourceEventIDs: [EventID]
    public let derivationVersion: Int

    public init(
        id: WorkIntervalID,
        kind: WorkIntervalKind,
        startedAt: Date,
        endedAt: Date,
        repositoryID: RepositoryID? = nil,
        sessionID: SessionID? = nil,
        state: ObservedState,
        sourceEventIDs: [EventID],
        derivationVersion: Int
    ) {
        precondition(endedAt >= startedAt)
        self.id = id
        self.kind = kind
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.repositoryID = repositoryID
        self.sessionID = sessionID
        self.state = state
        self.sourceEventIDs = sourceEventIDs
        self.derivationVersion = derivationVersion
    }

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

public struct TimeSummary: Codable, Equatable, Sendable {
    public let trackedSeconds: TimeInterval
    public let agentSeconds: TimeInterval

    public init(trackedSeconds: TimeInterval, agentSeconds: TimeInterval) {
        self.trackedSeconds = trackedSeconds
        self.agentSeconds = agentSeconds
    }
}
