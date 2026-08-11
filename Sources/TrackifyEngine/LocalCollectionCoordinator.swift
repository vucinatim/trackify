import Darwin
import Foundation
import TrackifyDomain
import TrackifyStore

public struct GitCollectionRoot: Equatable, Sendable {
    public let path: URL
    public let discoveryRootID: DiscoveryRootID?
    public let excludedPaths: Set<String>
    public let includedRepositories: Set<URL>?

    public init(
        path: URL,
        discoveryRootID: DiscoveryRootID? = nil,
        excludedPaths: Set<String> = [],
        includedRepositories: Set<URL>? = nil
    ) {
        self.path = path.standardizedFileURL
        self.discoveryRootID = discoveryRootID
        self.excludedPaths = excludedPaths
        self.includedRepositories = includedRepositories
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

public enum CollectionMaintenanceScope: Sendable, Equatable {
    case allSources
    case touchedSources
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
        codexFiles: Set<URL>? = nil,
        claudeFiles: Set<URL>? = nil,
        claudeDesktopFiles: Set<URL>? = nil,
        maintenanceScope: CollectionMaintenanceScope = .allSources,
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
                excludedPaths: root.excludedPaths,
                includedRepositories: root.includedRepositories
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
                    cursorScope: range.map(Self.backfillCursorScope),
                    includedFiles: codexFiles.map { files in
                        Set(files.filter { $0.path == root.path || $0.path.hasPrefix(root.path + "/") })
                    }
                )
                await collectOne(sourceKey: source.sourceKey, issues: &issues) {
                    try await drain(source, engine: engine, range: range, summaries: &summaries, store: store, ownerID: ownerID)
                }
            }
        }

        if includeClaude {
            let roots: [(ConversationProvider, URL, Set<URL>?)] = [
                (.claude, homeDirectory.appending(path: ".claude/projects"), claudeFiles),
                (
                    .claudeDesktop,
                    homeDirectory.appending(path: "Library/Application Support/Claude/local-agent-mode-sessions"),
                    claudeDesktopFiles
                ),
            ]
            for (provider, root, includedFiles) in roots where FileManager.default.fileExists(atPath: root.path) {
                let source = ConversationDirectorySource(
                    provider: provider,
                    root: root,
                    cursorScope: range.map(Self.backfillCursorScope),
                    includedFiles: includedFiles
                )
                await collectOne(sourceKey: source.sourceKey, issues: &issues) {
                    try await drain(source, engine: engine, range: range, summaries: &summaries, store: store, ownerID: ownerID)
                }
            }
        }

        let issueRows = issues.map { ($0.sourceKey, $0.message) }
        switch maintenanceScope {
        case .allSources:
            try store.replaceCollectorIssues(issueRows, at: clock.now())
        case .touchedSources:
            let sourceKeys = Set(summaries.map(\.sourceKey)).union(issues.map(\.sourceKey))
            try store.replaceCollectorIssues(
                issueRows, forSourceKeys: sourceKeys, at: clock.now())
        }
        let heartbeatService = maintenanceScope == .allSources ? "collector" : "live-collector"
        try store.recordHeartbeat(
            service: heartbeatService,
            processID: ProcessInfo.processInfo.processIdentifier,
            observedAt: clock.now(),
            state: issues.isEmpty ? "healthy" : "degraded"
        )
        if maintenanceScope == .allSources {
            try store.recordHeartbeat(
                service: "reconciliation",
                processID: ProcessInfo.processInfo.processIdentifier,
                observedAt: clock.now(),
                state: issues.isEmpty ? "healthy" : "degraded"
            )
        }
        if maintenanceScope == .allSources {
            _ = try store.refreshEvidenceQualityAudit(at: clock.now())
        }
        let result = try LocalCollectionResult(summaries: summaries, issues: issues, counts: store.counts())
        if summaries.contains(where: { $0.insertedEvents > 0 || $0.insertedObservations > 0 }) {
            TrackifyChangeSignal.post(for: store.databaseURL, kind: .ledger)
        }
        return result
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
        try LocalProcessLease.acquire(
            store: store, name: "collection", ownerID: ownerID,
            ownerKinds: ["cli"], now: clock.now(), duration: 900)
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
