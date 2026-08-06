import Foundation
import TrackifyDomain

public struct GitSourceCursor: Codable, Equatable, Sendable {
    public let lastCollectedAt: Date
    public let lastFullHistoryAt: Date
    public let stateFingerprints: [String: String]
    public let stateRevisions: [String: Int]

    public init(
        lastCollectedAt: Date,
        lastFullHistoryAt: Date,
        stateFingerprints: [String: String] = [:],
        stateRevisions: [String: Int] = [:]
    ) {
        self.lastCollectedAt = lastCollectedAt
        self.lastFullHistoryAt = lastFullHistoryAt
        self.stateFingerprints = stateFingerprints
        self.stateRevisions = stateRevisions
    }

    private enum CodingKeys: String, CodingKey {
        case lastCollectedAt
        case lastFullHistoryAt
        case stateFingerprints
        case stateRevisions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastCollectedAt = try container.decode(Date.self, forKey: .lastCollectedAt)
        lastFullHistoryAt = try container.decode(Date.self, forKey: .lastFullHistoryAt)
        stateFingerprints = try container.decodeIfPresent([String: String].self, forKey: .stateFingerprints) ?? [:]
        stateRevisions = try container.decodeIfPresent([String: Int].self, forKey: .stateRevisions) ?? [:]
    }
}

public struct GitSourceAdapter: SourceAdapter {
    public let sourceKey: String
    private let root: URL
    private let discovery: RepositoryDiscovery
    private let git: GitClient

    public init(
        root: URL,
        discoveryRootID: DiscoveryRootID? = nil,
        excludedPaths: Set<String> = [],
        discovery: RepositoryDiscovery = RepositoryDiscovery(),
        git: GitClient = GitClient()
    ) {
        self.root = root.standardizedFileURL
        sourceKey = "git:\(self.root.path)"
        self.discoveryRootID = discoveryRootID
        self.discovery =
            excludedPaths.isEmpty
            ? discovery
            : RepositoryDiscovery(options: RepositoryDiscoveryOptions(excludedPaths: excludedPaths))
        self.git = git
    }

    private let discoveryRootID: DiscoveryRootID?

    public func collect(request: CollectionRequest, cursor: Data?) async throws -> CollectionBatch {
        let previous = decodeCursor(cursor)
        let fullHistoryAge = previous.map { request.cutoff.timeIntervalSince($0.lastFullHistoryAt) }
        let needsFullHistory =
            request.range == nil
            && (fullHistoryAge.map { $0 >= 7 * 86_400 } ?? true)
        let commitRange: DateInterval?
        if let requested = request.range {
            commitRange = requested
        } else if needsFullHistory {
            commitRange = nil
        } else if let previous {
            commitRange = DateInterval(
                start: previous.lastCollectedAt.addingTimeInterval(-2 * 86_400),
                end: request.cutoff
            )
        } else {
            commitRange = nil
        }
        let candidates = try discovery.discover(under: root)
        var repositories: [CollectedRepository] = []
        var commits: [GitCommit] = []
        var reachableCommitHashesByRepository: [RepositoryID: Set<String>] = [:]
        var records: [CollectedRecord] = []
        var stateFingerprints = previous?.stateFingerprints ?? [:]
        var stateRevisions = previous?.stateRevisions ?? [:]

        for candidate in candidates where candidate.kind != .bare {
            let inspection = try git.inspect(candidate)
            let repositoryIdentity = inspection.remoteIdentity ?? inspection.commonDirectory.path
            let repositoryID = RepositoryID(StableHash.sha256("repository:\(repositoryIdentity)"))
            let workingCopyID = WorkingCopyID(StableHash.sha256("working-copy:\(inspection.root.path)"))
            let repository = Repository(
                id: repositoryID,
                displayName: inspection.root.lastPathComponent,
                remoteIdentity: inspection.remoteIdentity,
                firstObservedAt: request.cutoff,
                lastObservedAt: request.cutoff
            )
            let workingCopy = WorkingCopy(
                id: workingCopyID,
                repositoryID: repositoryID,
                canonicalPath: inspection.root.path,
                branch: inspection.state.branch,
                headCommit: inspection.state.headCommit,
                firstObservedAt: request.cutoff,
                lastObservedAt: request.cutoff
            )
            let relativePath =
                inspection.root.path == root.path
                ? "."
                : String(inspection.root.path.dropFirst(root.path.count + 1))
            repositories.append(
                CollectedRepository(
                    repository: repository,
                    workingCopy: workingCopy,
                    discoveryRootID: discoveryRootID,
                    relativePath: relativePath
                ))

            let inspectedCommits = try git.commits(at: inspection.root, in: commitRange)
            if needsFullHistory {
                reachableCommitHashesByRepository[repositoryID] = try git.reachableCommitHashes(at: inspection.root)
            }
            for inspectedCommit in inspectedCommits {
                let commitID = StableHash.sha256("commit:\(repositoryID.rawValue):\(inspectedCommit.hash)")
                commits.append(
                    GitCommit(
                        id: commitID,
                        repositoryID: repositoryID,
                        hash: inspectedCommit.hash,
                        authorTime: inspectedCommit.authorTime,
                        message: inspectedCommit.message,
                        additions: inspectedCommit.additions,
                        deletions: inspectedCommit.deletions,
                        filesChanged: inspectedCommit.filesChanged,
                        firstObservedAt: request.cutoff,
                        lastObservedAt: request.cutoff,
                        isReachable: true
                    ))
                let commitRecordKey = "repository:\(repositoryID.rawValue):commit:\(inspectedCommit.hash)"
                let commitEvidence = SourceEvidence(
                    id: EvidenceID(StableHash.sha256("evidence:\(commitRecordKey)")),
                    source: .git,
                    ingestionPath: .observation,
                    sourceRecordID: commitRecordKey,
                    fingerprint: StableHash.sha256(commitRecordKey),
                    occurredAt: inspectedCommit.authorTime,
                    observedAt: request.cutoff,
                    adapterVersion: 1
                )
                records.append(
                    CollectedRecord(
                        evidence: commitEvidence,
                        event: LedgerEvent(
                            id: EventID(StableHash.sha256("event:\(commitRecordKey)")),
                            evidenceID: commitEvidence.id,
                            occurredAt: inspectedCommit.authorTime,
                            observedAt: request.cutoff,
                            source: .git,
                            kind: .gitCommitObserved,
                            repositoryID: repositoryID,
                            workingCopyID: workingCopyID,
                            payload: [
                                "hash": inspectedCommit.hash,
                                "message": inspectedCommit.message,
                                "additions": String(inspectedCommit.additions),
                                "deletions": String(inspectedCommit.deletions),
                                "filesChanged": String(inspectedCommit.filesChanged),
                            ]
                        )
                    ))
            }

            let discoveryRecordKey = "repository:\(repositoryID.rawValue):discovered"
            records.append(
                makeRecord(
                    sourceRecordID: discoveryRecordKey,
                    eventID: EventID(StableHash.sha256("event:\(discoveryRecordKey)")),
                    kind: .repositoryDiscovered,
                    repositoryID: repositoryID,
                    workingCopyID: workingCopyID,
                    inspection: inspection,
                    cutoff: request.cutoff
                ))

            let stateFingerprint = StableHash.sha256(
                [
                    inspection.state.headCommit ?? "unborn",
                    inspection.state.branch ?? "detached",
                    inspection.state.changedFiles.joined(separator: "\u{0}"),
                    String(inspection.state.additions),
                    String(inspection.state.deletions),
                ].joined(separator: "\u{1f}"))
            let workingCopyKey = workingCopyID.rawValue
            if stateFingerprints[workingCopyKey] != stateFingerprint {
                let revision = (stateRevisions[workingCopyKey] ?? 0) + 1
                let stateRecordKey = "working-copy:\(workingCopyKey):state:\(revision):\(stateFingerprint)"
                records.append(
                    makeRecord(
                        sourceRecordID: stateRecordKey,
                        eventID: EventID(StableHash.sha256("event:\(stateRecordKey)")),
                        kind: .gitWorkingTreeChanged,
                        repositoryID: repositoryID,
                        workingCopyID: workingCopyID,
                        inspection: inspection,
                        cutoff: request.cutoff,
                        additionalPayload: ["baseline": String(revision == 1)]
                    ))
                stateFingerprints[workingCopyKey] = stateFingerprint
                stateRevisions[workingCopyKey] = revision
            }
        }

        let cursorValue = try JSONEncoder().encode(
            GitSourceCursor(
                lastCollectedAt: request.cutoff,
                lastFullHistoryAt: needsFullHistory ? request.cutoff : previous?.lastFullHistoryAt ?? request.cutoff,
                stateFingerprints: stateFingerprints,
                stateRevisions: stateRevisions
            ))
        return CollectionBatch(
            sourceKey: sourceKey,
            repositories: repositories,
            commits: commits,
            reachableCommitHashesByRepository: reachableCommitHashesByRepository,
            records: records,
            nextCursor: cursorValue
        )
    }

    private func decodeCursor(_ data: Data?) -> GitSourceCursor? {
        guard let data else { return nil }
        if let cursor = try? JSONDecoder().decode(GitSourceCursor.self, from: data) { return cursor }
        guard let timestamp = TimeInterval(String(decoding: data, as: UTF8.self)) else { return nil }
        let date = Date(timeIntervalSince1970: timestamp)
        return GitSourceCursor(lastCollectedAt: date, lastFullHistoryAt: date)
    }

    private func makeRecord(
        sourceRecordID: String,
        eventID: EventID,
        kind: EventKind,
        repositoryID: RepositoryID,
        workingCopyID: WorkingCopyID,
        inspection: GitRepositoryInspection,
        cutoff: Date,
        additionalPayload: [String: String] = [:]
    ) -> CollectedRecord {
        let evidence = SourceEvidence(
            id: EvidenceID(StableHash.sha256("evidence:\(sourceRecordID)")),
            source: .git,
            ingestionPath: .observation,
            sourceRecordID: sourceRecordID,
            fingerprint: StableHash.sha256(sourceRecordID),
            occurredAt: cutoff,
            observedAt: cutoff,
            adapterVersion: 1
        )
        var payload: [String: String] = [
            "branch": inspection.state.branch ?? "",
            "head": inspection.state.headCommit ?? "",
            "clean": String(inspection.state.isClean),
            "changedFiles": String(inspection.state.changedFiles.count),
            "additions": String(inspection.state.additions),
            "deletions": String(inspection.state.deletions),
        ]
        payload.merge(additionalPayload) { _, latest in latest }
        let event = LedgerEvent(
            id: eventID,
            evidenceID: evidence.id,
            occurredAt: cutoff,
            observedAt: cutoff,
            source: .git,
            kind: kind,
            repositoryID: repositoryID,
            workingCopyID: workingCopyID,
            payload: payload
        )
        return CollectedRecord(evidence: evidence, event: event)
    }
}
