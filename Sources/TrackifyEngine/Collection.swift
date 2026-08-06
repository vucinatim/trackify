import Foundation
import TrackifyDomain
import TrackifyStore

public struct CollectionRequest: Equatable, Sendable {
    public let range: DateInterval?
    public let cutoff: Date

    public init(range: DateInterval? = nil, cutoff: Date) {
        self.range = range
        self.cutoff = cutoff
    }
}

public struct CollectedRecord: Equatable, Sendable {
    public let evidence: SourceEvidence
    public let event: LedgerEvent

    public init(evidence: SourceEvidence, event: LedgerEvent) {
        self.evidence = evidence
        self.event = event
    }
}

public struct CollectionBatch: Equatable, Sendable {
    public let sourceKey: String
    public let repositories: [CollectedRepository]
    public let sessions: [ConversationSession]
    public let messages: [ConversationMessage]
    public let commits: [GitCommit]
    public let reachableCommitHashesByRepository: [RepositoryID: Set<String>]
    public let records: [CollectedRecord]
    public let processedSourceRecords: Int
    public let nextCursor: Data?

    public init(
        sourceKey: String,
        repositories: [CollectedRepository] = [],
        sessions: [ConversationSession] = [],
        messages: [ConversationMessage] = [],
        commits: [GitCommit] = [],
        reachableCommitHashesByRepository: [RepositoryID: Set<String>] = [:],
        records: [CollectedRecord],
        processedSourceRecords: Int = 0,
        nextCursor: Data? = nil
    ) {
        self.sourceKey = sourceKey
        self.repositories = repositories
        self.sessions = sessions
        self.messages = messages
        self.commits = commits
        self.reachableCommitHashesByRepository = reachableCommitHashesByRepository
        self.records = records
        self.processedSourceRecords = processedSourceRecords
        self.nextCursor = nextCursor
    }
}

public struct CollectedRepository: Equatable, Sendable {
    public let repository: Repository
    public let workingCopy: WorkingCopy
    public let discoveryRootID: DiscoveryRootID?
    public let relativePath: String?

    public init(
        repository: Repository,
        workingCopy: WorkingCopy,
        discoveryRootID: DiscoveryRootID? = nil,
        relativePath: String? = nil
    ) {
        self.repository = repository
        self.workingCopy = workingCopy
        self.discoveryRootID = discoveryRootID
        self.relativePath = relativePath
    }
}

public protocol SourceAdapter: Sendable {
    var sourceKey: String { get }
    func collect(request: CollectionRequest, cursor: Data?) async throws -> CollectionBatch
}

public struct CollectionSummary: Codable, Equatable, Sendable {
    public let sourceKey: String
    public let receivedRepositories: Int
    public let receivedSessions: Int
    public let receivedMessages: Int
    public let receivedCommits: Int
    public let receivedRecords: Int
    public let processedSourceRecords: Int
    public let insertedObservations: Int
    public let insertedEvents: Int

    public init(
        sourceKey: String,
        receivedRepositories: Int,
        receivedSessions: Int,
        receivedMessages: Int,
        receivedCommits: Int,
        receivedRecords: Int,
        processedSourceRecords: Int,
        insertedObservations: Int,
        insertedEvents: Int
    ) {
        self.sourceKey = sourceKey
        self.receivedRepositories = receivedRepositories
        self.receivedSessions = receivedSessions
        self.receivedMessages = receivedMessages
        self.receivedCommits = receivedCommits
        self.receivedRecords = receivedRecords
        self.processedSourceRecords = processedSourceRecords
        self.insertedObservations = insertedObservations
        self.insertedEvents = insertedEvents
    }

    public var receivedItems: Int {
        receivedRepositories + receivedSessions + receivedMessages + receivedCommits + receivedRecords
    }
}

public actor CollectionEngine {
    private let store: LedgerStore
    private let clock: any WallClock

    public init(store: LedgerStore, clock: any WallClock = SystemWallClock()) {
        self.store = store
        self.clock = clock
    }

    public func collect(from adapter: any SourceAdapter, range: DateInterval? = nil) async throws -> CollectionSummary {
        let cursor = try store.cursor(for: adapter.sourceKey)
        let batch = try await adapter.collect(
            request: CollectionRequest(range: range, cutoff: clock.now()),
            cursor: cursor
        )
        return try ingest(batch)
    }

    public func ingest(_ batch: CollectionBatch) throws -> CollectionSummary {
        var observations = 0
        var events = 0

        for collectedRepository in batch.repositories {
            try store.upsert(
                repository: collectedRepository.repository,
                workingCopy: collectedRepository.workingCopy,
                discoveryRootID: collectedRepository.discoveryRootID,
                relativePath: collectedRepository.relativePath
            )
        }

        for session in batch.sessions {
            try store.upsert(session: session)
        }

        for message in batch.messages {
            try store.upsert(message: message)
        }

        for commit in batch.commits {
            try store.upsert(commit: commit)
        }

        for (repositoryID, hashes) in batch.reachableCommitHashesByRepository {
            try store.reconcileCommitReachability(
                repositoryID: repositoryID,
                reachableHashes: hashes,
                observedAt: clock.now()
            )
        }

        for record in batch.records {
            let result = try store.ingest(evidence: record.evidence, event: record.event)
            if result.insertedObservation { observations += 1 }
            if result.insertedEvent { events += 1 }
        }

        if let nextCursor = batch.nextCursor {
            try store.setCursor(nextCursor, for: batch.sourceKey, at: clock.now())
        }

        return CollectionSummary(
            sourceKey: batch.sourceKey,
            receivedRepositories: batch.repositories.count,
            receivedSessions: batch.sessions.count,
            receivedMessages: batch.messages.count,
            receivedCommits: batch.commits.count,
            receivedRecords: batch.records.count,
            processedSourceRecords: batch.processedSourceRecords,
            insertedObservations: observations,
            insertedEvents: events
        )
    }
}
