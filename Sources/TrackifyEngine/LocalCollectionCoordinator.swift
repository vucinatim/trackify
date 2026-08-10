import Darwin
import Foundation
import TrackifyDomain
import TrackifyStore

public struct GitCollectionRoot: Equatable, Sendable {
    public let path: URL
    public let discoveryRootID: DiscoveryRootID?
    public let excludedPaths: Set<String>

    public init(
        path: URL,
        discoveryRootID: DiscoveryRootID? = nil,
        excludedPaths: Set<String> = []
    ) {
        self.path = path.standardizedFileURL
        self.discoveryRootID = discoveryRootID
        self.excludedPaths = excludedPaths
    }
}

public struct CollectionIssue: Codable, Equatable, Sendable {
    public let sourceKey: String
    public let message: String

    public init(sourceKey: String, message: String) {
        self.sourceKey = sourceKey
        self.message = message
    }
}

public struct LocalCollectionResult: Codable, Equatable, Sendable {
    public let summaries: [CollectionSummary]
    public let issues: [CollectionIssue]
    public let counts: LedgerCounts

    public init(summaries: [CollectionSummary], issues: [CollectionIssue], counts: LedgerCounts) {
        self.summaries = summaries
        self.issues = issues
        self.counts = counts
    }

    public var sourceReads: [EvidenceSourceReadAudit] {
        Dictionary(grouping: summaries, by: \.sourceKey).map { sourceKey, values in
            let opened = Set(values.flatMap(\.readMetrics.openedUnitFingerprints))
            let knownBytes = values.compactMap(\.readMetrics.bytesRead)
            return EvidenceSourceReadAudit(
                sourceKey: sourceKey,
                unit: values.first(where: { $0.readMetrics.unit != .unknown })?.readMetrics.unit
                    ?? .unknown,
                candidatesConsidered: values.map(\.readMetrics.candidatesConsidered).max() ?? 0,
                unitsOpened: opened.count,
                bytesRead: knownBytes.count == values.count ? knownBytes.reduce(0, +) : nil,
                recordsObserved: values.reduce(0) { $0 + $1.readMetrics.recordsObserved },
                recordsAccepted: values.reduce(0) { $0 + $1.readMetrics.recordsAccepted })
        }.sorted { $0.sourceKey < $1.sourceKey }
    }
}

public enum LocalCollectionError: Error, Equatable, LocalizedError {
    case collectionAlreadyRunning
    case batchLimitExceeded(String)

    public var errorDescription: String? {
        switch self {
        case .collectionAlreadyRunning:
            return "Another Trackify collector currently owns the collection lease."
        case .batchLimitExceeded(let source):
            return "Collection exceeded the bounded batch limit for \(source)."
        }
    }
}

public struct LocalCollectionCoordinator: Sendable {
    private let clock: any WallClock
    private let maximumBatchesPerSource: Int

    public init(
        clock: any WallClock = SystemWallClock(),
        maximumBatchesPerSource: Int = 10_000
    ) {
        precondition(maximumBatchesPerSource > 0)
        self.clock = clock
        self.maximumBatchesPerSource = maximumBatchesPerSource
    }

    public func collect(
        store: LedgerStore,
        gitRoots: [GitCollectionRoot],
        includeCodex: Bool = true,
        includeClaude: Bool = true,
        range: DateInterval? = nil,
        hookInboxURL: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async throws -> LocalCollectionResult {
        let ownerID = "cli:\(ProcessInfo.processInfo.processIdentifier):\(UUID().uuidString)"
        guard try acquireCollectionLease(store: store, ownerID: ownerID) else {
            throw LocalCollectionError.collectionAlreadyRunning
        }
        defer { try? store.releaseLease(name: "collection", ownerID: ownerID) }

        let engine = CollectionEngine(store: store, clock: clock)
        var summaries: [CollectionSummary] = []
        var issues: [CollectionIssue] = []
        var seenPaths = Set<String>()

        if let hookInboxURL, FileManager.default.fileExists(atPath: hookInboxURL.path) {
            let source = HookInboxSource(fileURL: hookInboxURL)
            await collectOne(sourceKey: source.sourceKey, issues: &issues) {
                for _ in 0..<maximumBatchesPerSource {
                    let summary = try await engine.collect(from: source, range: range)
                    summaries.append(summary)
                    if summary.processedSourceRecords == 0 { return }
                    try refreshLease(store: store, ownerID: ownerID)
                }
                throw LocalCollectionError.batchLimitExceeded(source.sourceKey)
            }
        }

        for root in gitRoots where seenPaths.insert(root.path.path).inserted {
            let source = GitSourceAdapter(
                root: root.path,
                discoveryRootID: root.discoveryRootID,
                excludedPaths: root.excludedPaths
            )
            await collectOne(sourceKey: source.sourceKey, issues: &issues) {
                summaries.append(try await engine.collect(from: source, range: range))
            }
            try refreshLease(store: store, ownerID: ownerID)
        }

        if includeCodex {
            for root in [
                homeDirectory.appending(path: ".codex/sessions"),
                homeDirectory.appending(path: ".codex/archived_sessions"),
            ] where FileManager.default.fileExists(atPath: root.path) {
                let source = ConversationDirectorySource(
                    provider: .codex,
                    root: root,
                    cursorScope: range.map(Self.backfillCursorScope)
                )
                await collectOne(sourceKey: source.sourceKey, issues: &issues) {
                    try await drain(source, engine: engine, range: range, summaries: &summaries, store: store, ownerID: ownerID)
                }
            }
        }

        if includeClaude {
            let roots: [(ConversationProvider, URL)] = [
                (.claude, homeDirectory.appending(path: ".claude/projects")),
                (
                    .claudeDesktop,
                    homeDirectory.appending(path: "Library/Application Support/Claude/local-agent-mode-sessions")
                ),
            ]
            for (provider, root) in roots where FileManager.default.fileExists(atPath: root.path) {
                let source = ConversationDirectorySource(
                    provider: provider,
                    root: root,
                    cursorScope: range.map(Self.backfillCursorScope)
                )
                await collectOne(sourceKey: source.sourceKey, issues: &issues) {
                    try await drain(source, engine: engine, range: range, summaries: &summaries, store: store, ownerID: ownerID)
                }
            }
        }

        try store.replaceCollectorIssues(issues.map { ($0.sourceKey, $0.message) }, at: clock.now())
        try store.recordHeartbeat(
            service: "collector",
            processID: ProcessInfo.processInfo.processIdentifier,
            observedAt: clock.now(),
            state: issues.isEmpty ? "healthy" : "degraded"
        )
        _ = try store.refreshEvidenceQualityAudit(at: clock.now())
        return try LocalCollectionResult(summaries: summaries, issues: issues, counts: store.counts())
    }

    private func drain(
        _ source: ConversationDirectorySource,
        engine: CollectionEngine,
        range: DateInterval?,
        summaries: inout [CollectionSummary],
        store: LedgerStore,
        ownerID: String
    ) async throws {
        for _ in 0..<maximumBatchesPerSource {
            let summary = try await engine.collect(from: source, range: range)
            summaries.append(summary)
            if summary.processedSourceRecords == 0 { return }
            try refreshLease(store: store, ownerID: ownerID)
        }
        throw LocalCollectionError.batchLimitExceeded(source.sourceKey)
    }

    private func refreshLease(store: LedgerStore, ownerID: String) throws {
        _ = try store.acquireLease(name: "collection", ownerID: ownerID, now: clock.now(), duration: 900)
    }

    private func acquireCollectionLease(store: LedgerStore, ownerID: String) throws -> Bool {
        let now = clock.now()
        if try store.acquireLease(name: "collection", ownerID: ownerID, now: now, duration: 900) {
            return true
        }
        guard let previousOwner = try store.leaseOwner(name: "collection"), Self.isDeadLocalOwner(previousOwner) else {
            return false
        }
        try store.releaseLease(name: "collection", ownerID: previousOwner)
        return try store.acquireLease(name: "collection", ownerID: ownerID, now: now, duration: 900)
    }

    private static func isDeadLocalOwner(_ ownerID: String) -> Bool {
        let components = ownerID.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count >= 3, components[0] == "cli", let processID = Int32(components[1]) else {
            return false
        }
        errno = 0
        return kill(processID, 0) == -1 && errno == ESRCH
    }

    static func backfillCursorScope(_ range: DateInterval) -> String {
        "backfill-\(Int64(range.start.timeIntervalSince1970))-\(Int64(range.end.timeIntervalSince1970))"
    }

    private func collectOne(
        sourceKey: String,
        issues: inout [CollectionIssue],
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
        } catch {
            issues.append(CollectionIssue(sourceKey: sourceKey, message: String(describing: error)))
        }
    }
}
