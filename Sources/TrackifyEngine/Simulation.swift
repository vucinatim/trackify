import Foundation
import TrackifyDomain
import TrackifyStore

public struct SimulationResult: Codable, Equatable, Sendable {
    public let startedAt: Date
    public let endedAt: Date
    public let generatedEvents: Int
    public let counts: LedgerCounts
    public let days: [ActivitySnapshot]

    public init(
        startedAt: Date,
        endedAt: Date,
        generatedEvents: Int,
        counts: LedgerCounts,
        days: [ActivitySnapshot]
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.generatedEvents = generatedEvents
        self.counts = counts
        self.days = days
    }
}

public struct FoundationSimulation {
    public init() {}

    public func run(store: LedgerStore, start: Date, days: Int = 2) async throws -> SimulationResult {
        precondition(days > 0)
        let clock = MutableWallClock(start)
        let engine = CollectionEngine(store: store, clock: clock)
        var repositories: [CollectedRepository] = []
        var sessions: [ConversationSession] = []
        var messages: [ConversationMessage] = []
        var commits: [GitCommit] = []
        var records: [CollectedRecord] = []

        for index in 0..<2 {
            let repositoryID = RepositoryID("simulation-repository-\(index)")
            let path = "/simulation/\(index == 0 ? "alpha" : "beta")"
            repositories.append(
                CollectedRepository(
                    repository: Repository(
                        id: repositoryID,
                        displayName: index == 0 ? "Alpha" : "Beta",
                        firstObservedAt: start,
                        lastObservedAt: start.addingTimeInterval(TimeInterval(days * 86_400))
                    ),
                    workingCopy: WorkingCopy(
                        id: WorkingCopyID("simulation-copy-\(index)"),
                        repositoryID: repositoryID,
                        canonicalPath: path,
                        branch: "main",
                        headCommit: "simulation-head-\(index)",
                        firstObservedAt: start,
                        lastObservedAt: start.addingTimeInterval(TimeInterval(days * 86_400))
                    )
                ))
        }

        for day in 0..<days {
            let dayStart = start.addingTimeInterval(TimeInterval(day * 86_400))
            let repositoryID = RepositoryID("simulation-repository-\(day % 2)")
            let primarySessionID = SessionID("simulation-session-\(day)-primary")
            let secondarySessionID = SessionID("simulation-session-\(day)-secondary")
            sessions.append(contentsOf: [
                ConversationSession(
                    id: primarySessionID,
                    source: .simulation,
                    sourceSessionID: primarySessionID.rawValue,
                    startedAt: dayStart.addingTimeInterval(9 * 3_600),
                    lastObservedAt: dayStart.addingTimeInterval(10 * 3_600),
                    workingDirectory: day % 2 == 0 ? "/simulation/alpha" : "/simulation/beta",
                    state: .completed
                ),
                ConversationSession(
                    id: secondarySessionID,
                    source: .simulation,
                    sourceSessionID: secondarySessionID.rawValue,
                    startedAt: dayStart.addingTimeInterval((day == days - 1 ? 21.5 : 9.5) * 3_600),
                    lastObservedAt: dayStart.addingTimeInterval((day == days - 1 ? 21.5 : 11) * 3_600),
                    workingDirectory: day % 2 == 0 ? "/simulation/beta" : "/simulation/alpha",
                    state: day == days - 1 ? .inProgress : .completed
                ),
            ])

            let secondaryStart = dayStart.addingTimeInterval((day == days - 1 ? 21.5 : 9.5) * 3_600)
            var messageSpecifications: [(String, Date, MessageRole, SessionID, RepositoryID, String)] = [
                (
                    "day-\(day)-primary-user", dayStart.addingTimeInterval(9 * 3_600), .user,
                    primarySessionID, repositoryID, "Implement the simulated feature"
                ),
                (
                    "day-\(day)-primary-assistant", dayStart.addingTimeInterval(10 * 3_600), .assistant,
                    primarySessionID, repositoryID, "Implemented and verified the simulated feature"
                ),
                (
                    "day-\(day)-secondary-user", secondaryStart, .user,
                    secondarySessionID, RepositoryID("simulation-repository-\((day + 1) % 2)"),
                    "Investigate the secondary project"
                ),
            ]
            if day != days - 1 {
                messageSpecifications.append(
                    (
                        "day-\(day)-secondary-assistant", dayStart.addingTimeInterval(11 * 3_600), .assistant,
                        secondarySessionID, RepositoryID("simulation-repository-\((day + 1) % 2)"),
                        "Finished the secondary investigation"
                    ))
            }
            for specification in messageSpecifications {
                let item = makeMessageRecord(
                    key: specification.0,
                    at: specification.1,
                    role: specification.2,
                    sessionID: specification.3,
                    repositoryID: specification.4,
                    text: specification.5
                )
                messages.append(item.message)
                records.append(item.record)
            }

            let commitTime = dayStart.addingTimeInterval(10.25 * 3_600)
            let commitID = "simulation-commit-\(day)"
            commits.append(
                GitCommit(
                    id: commitID,
                    repositoryID: repositoryID,
                    hash: "simulationhash\(day)",
                    authorTime: commitTime,
                    message: day == days - 1 ? "Begin unfinished feature" : "Complete simulated feature",
                    additions: 20 + day,
                    deletions: 4,
                    filesChanged: 3,
                    firstObservedAt: commitTime,
                    lastObservedAt: commitTime,
                    isReachable: true
                ))
            records.append(
                makeCommitRecord(
                    key: commitID,
                    at: commitTime,
                    repositoryID: repositoryID,
                    additions: 20 + day,
                    deletions: 4,
                    filesChanged: 3
                ))
        }

        _ = try await engine.ingest(
            CollectionBatch(
                sourceKey: "simulation:foundation",
                repositories: repositories,
                sessions: sessions,
                messages: messages,
                commits: commits,
                records: records
            ))
        let endedAt = clock.advance(by: TimeInterval(days * 86_400))
        let snapshots = try (0..<days).map { day in
            let dayStart = start.addingTimeInterval(TimeInterval(day * 86_400))
            return try ActivityQueries().snapshot(
                store: store,
                range: DateInterval(start: dayStart, duration: 86_400),
                cutoff: endedAt
            )
        }
        return try SimulationResult(
            startedAt: start,
            endedAt: endedAt,
            generatedEvents: records.count,
            counts: store.counts(),
            days: snapshots
        )
    }

    private func makeMessageRecord(
        key: String,
        at date: Date,
        role: MessageRole,
        sessionID: SessionID,
        repositoryID: RepositoryID,
        text: String
    ) -> (message: ConversationMessage, record: CollectedRecord) {
        let message = ConversationMessage(
            id: MessageID("simulation-message-\(key)"),
            sessionID: sessionID,
            sourceMessageID: key,
            role: role,
            occurredAt: date,
            normalizedText: text,
            fingerprint: "simulation-message-fingerprint-\(key)"
        )
        let record = makeRecord(
            key: key,
            at: date,
            kind: .agentMessageObserved,
            repositoryID: repositoryID,
            sessionID: sessionID,
            payload: [
                "messageID": message.id.rawValue,
                "role": role.rawValue,
                "scenario": "foundation",
            ]
        )
        return (message, record)
    }

    private func makeCommitRecord(
        key: String,
        at date: Date,
        repositoryID: RepositoryID,
        additions: Int,
        deletions: Int,
        filesChanged: Int
    ) -> CollectedRecord {
        makeRecord(
            key: key,
            at: date,
            kind: .gitCommitObserved,
            repositoryID: repositoryID,
            payload: [
                "additions": String(additions),
                "deletions": String(deletions),
                "filesChanged": String(filesChanged),
            ]
        )
    }

    private func makeRecord(
        key: String,
        at date: Date,
        kind: EventKind,
        state: ObservedState? = nil,
        repositoryID: RepositoryID,
        sessionID: SessionID? = nil,
        payload: [String: String]
    ) -> CollectedRecord {
        let evidence = SourceEvidence(
            id: EvidenceID("simulation-evidence-\(key)"),
            source: .simulation,
            ingestionPath: .fixture,
            sourceRecordID: key,
            fingerprint: "simulation-\(key)",
            occurredAt: date,
            observedAt: date,
            adapterVersion: 1
        )
        return CollectedRecord(
            evidence: evidence,
            event: LedgerEvent(
                id: EventID("simulation-event-\(key)"),
                evidenceID: evidence.id,
                occurredAt: date,
                observedAt: date,
                source: .simulation,
                kind: kind,
                repositoryID: repositoryID,
                sessionID: sessionID,
                state: state,
                payload: payload
            )
        )
    }
}
