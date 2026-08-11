import Foundation
import TrackifyDomain

public enum LiveSourceFamily: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
    case claudeDesktop = "claude-desktop"
    case git
    case hook
    case ledger
    case discovery
}

public enum LiveTriggerReason: String, Codable, Sendable {
    case filesystem
    case hook
    case wake
    case manual
    case reconciliation
    case ledgerMutation = "ledger-mutation"
}

public struct LiveCollectionTrigger: Equatable, Sendable {
    public let families: Set<LiveSourceFamily>
    public let paths: Set<String>
    public let observedAt: Date
    public let reason: LiveTriggerReason
    public let requiresReconciliation: Bool

    public init(
        families: Set<LiveSourceFamily>,
        paths: Set<String> = [],
        observedAt: Date,
        reason: LiveTriggerReason,
        requiresReconciliation: Bool = false
    ) {
        self.families = families
        self.paths = paths
        self.observedAt = observedAt
        self.reason = reason
        self.requiresReconciliation = requiresReconciliation
    }
}

public struct LiveCollectionBatch: Equatable, Sendable {
    public let families: Set<LiveSourceFamily>
    public let paths: Set<String>
    public let reasons: Set<LiveTriggerReason>
    public let firstObservedAt: Date
    public let lastObservedAt: Date
    public let requiresReconciliation: Bool
    public let triggerCount: Int

    public init(
        families: Set<LiveSourceFamily>,
        paths: Set<String>,
        reasons: Set<LiveTriggerReason>,
        firstObservedAt: Date,
        lastObservedAt: Date,
        requiresReconciliation: Bool,
        triggerCount: Int
    ) {
        self.families = families
        self.paths = paths
        self.reasons = reasons
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
        self.requiresReconciliation = requiresReconciliation
        self.triggerCount = triggerCount
    }

    public var onlyRequiresPresentationRefresh: Bool {
        !requiresReconciliation && !families.isDisjoint(with: [.ledger])
            && families.subtracting([.ledger]).isEmpty
    }
}

public struct LedgerMutation: Codable, Equatable, Sendable {
    public let committedAt: Date
    public let firstTriggerAt: Date
    public let insertedEvents: Int
    public let insertedObservations: Int
    public let affectedRepositoryIDs: Set<RepositoryID>
    public let changedFamilies: Set<LiveSourceFamily>

    public init(
        committedAt: Date,
        firstTriggerAt: Date,
        insertedEvents: Int,
        insertedObservations: Int,
        affectedRepositoryIDs: Set<RepositoryID> = [],
        changedFamilies: Set<LiveSourceFamily>
    ) {
        self.committedAt = committedAt
        self.firstTriggerAt = firstTriggerAt
        self.insertedEvents = insertedEvents
        self.insertedObservations = insertedObservations
        self.affectedRepositoryIDs = affectedRepositoryIDs
        self.changedFamilies = changedFamilies
    }

    public var latency: TimeInterval {
        max(0, committedAt.timeIntervalSince(firstTriggerAt))
    }
}

public struct LiveCollectionPolicy: Equatable, Sendable {
    public let providerDebounce: TimeInterval
    public let gitDebounce: TimeInterval
    public let discoveryDebounce: TimeInterval
    public let maximumDelay: TimeInterval
    public let retryDelay: TimeInterval
    public let maximumPathsPerBatch: Int

    public init(
        providerDebounce: TimeInterval = 1,
        gitDebounce: TimeInterval = 2,
        discoveryDebounce: TimeInterval = 5,
        maximumDelay: TimeInterval = 8,
        retryDelay: TimeInterval = 5,
        maximumPathsPerBatch: Int = 2_000
    ) {
        precondition(providerDebounce >= 0)
        precondition(gitDebounce >= 0)
        precondition(discoveryDebounce >= 0)
        precondition(maximumDelay >= 0)
        precondition(retryDelay >= 0)
        precondition(maximumPathsPerBatch > 0)
        self.providerDebounce = providerDebounce
        self.gitDebounce = gitDebounce
        self.discoveryDebounce = discoveryDebounce
        self.maximumDelay = maximumDelay
        self.retryDelay = retryDelay
        self.maximumPathsPerBatch = maximumPathsPerBatch
    }

    fileprivate func debounce(for families: Set<LiveSourceFamily>) -> TimeInterval {
        if families.contains(.discovery) { return discoveryDebounce }
        if families.contains(.git) { return gitDebounce }
        return providerDebounce
    }
}

public actor LiveCollectionCoordinator {
    public typealias Collector = @Sendable (LiveCollectionBatch) async throws -> LedgerMutation?
    public typealias MutationHandler = @Sendable (LedgerMutation) async -> Void
    public typealias StatusHandler = @Sendable (LiveCollectorRuntimeStatus) async -> Void

    private struct Pending: Sendable {
        var families = Set<LiveSourceFamily>()
        var paths = Set<String>()
        var reasons = Set<LiveTriggerReason>()
        var firstObservedAt: Date
        var lastObservedAt: Date
        var requiresReconciliation = false
        var triggerCount = 0

        init(_ trigger: LiveCollectionTrigger, maximumPaths: Int) {
            firstObservedAt = trigger.observedAt
            lastObservedAt = trigger.observedAt
            merge(trigger, maximumPaths: maximumPaths)
        }

        mutating func merge(_ trigger: LiveCollectionTrigger, maximumPaths: Int) {
            families.formUnion(trigger.families)
            reasons.insert(trigger.reason)
            firstObservedAt = min(firstObservedAt, trigger.observedAt)
            lastObservedAt = max(lastObservedAt, trigger.observedAt)
            requiresReconciliation = requiresReconciliation || trigger.requiresReconciliation
            triggerCount += 1
            if paths.count < maximumPaths {
                paths.formUnion(trigger.paths.prefix(maximumPaths - paths.count))
            }
            if paths.count >= maximumPaths && !trigger.paths.isSubset(of: paths) {
                requiresReconciliation = true
            }
        }

        mutating func merge(_ batch: LiveCollectionBatch, maximumPaths: Int) {
            families.formUnion(batch.families)
            reasons.formUnion(batch.reasons)
            firstObservedAt = min(firstObservedAt, batch.firstObservedAt)
            lastObservedAt = max(lastObservedAt, batch.lastObservedAt)
            requiresReconciliation = requiresReconciliation || batch.requiresReconciliation
            triggerCount += batch.triggerCount
            if paths.count < maximumPaths {
                paths.formUnion(batch.paths.prefix(maximumPaths - paths.count))
            }
            if paths.count >= maximumPaths && !batch.paths.isSubset(of: paths) {
                requiresReconciliation = true
            }
        }

        var batch: LiveCollectionBatch {
            LiveCollectionBatch(
                families: families, paths: paths, reasons: reasons,
                firstObservedAt: firstObservedAt, lastObservedAt: lastObservedAt,
                requiresReconciliation: requiresReconciliation, triggerCount: triggerCount)
        }
    }

    private let policy: LiveCollectionPolicy
    private let clock: any WallClock
    private let collector: Collector
    private let mutationHandler: MutationHandler
    private let statusHandler: StatusHandler
    private var pending: Pending?
    private var scheduledTask: Task<Void, Never>?
    private var isCollecting = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var isStopped = false
    private var isPaused = false
    private var lastTriggerAt: Date?
    private var lastCollectionStartedAt: Date?
    private var lastCollectionFinishedAt: Date?
    private var lastMutationAt: Date?
    private var lastLatencySeconds: Double?
    private var latencySamples: [Double] = []
    private var consecutiveFailures = 0
    private var lastError: String?

    public init(
        policy: LiveCollectionPolicy = LiveCollectionPolicy(),
        clock: any WallClock = SystemWallClock(),
        collector: @escaping Collector,
        mutationHandler: @escaping MutationHandler = { _ in },
        statusHandler: @escaping StatusHandler = { _ in }
    ) {
        self.policy = policy
        self.clock = clock
        self.collector = collector
        self.mutationHandler = mutationHandler
        self.statusHandler = statusHandler
    }

    public func submit(_ trigger: LiveCollectionTrigger) async {
        guard !isStopped, !isPaused, !trigger.families.isEmpty else { return }
        lastTriggerAt = max(lastTriggerAt ?? trigger.observedAt, trigger.observedAt)
        if pending == nil {
            pending = Pending(trigger, maximumPaths: policy.maximumPathsPerBatch)
        } else {
            pending?.merge(trigger, maximumPaths: policy.maximumPathsPerBatch)
        }
        await publishStatus()
        if !isCollecting { schedulePending() }
    }

    public func flush() async {
        guard !isStopped else { return }
        if isCollecting {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
        guard !isStopped else { return }
        scheduledTask?.cancel()
        scheduledTask = nil
        await processPending()
    }

    public func stop() async {
        isStopped = true
        scheduledTask?.cancel()
        scheduledTask = nil
        pending = nil
        await publishStatus()
    }

    public func pause() async {
        guard !isStopped else { return }
        isPaused = true
        scheduledTask?.cancel()
        scheduledTask = nil
        pending = nil
        await publishStatus()
    }

    public func resume() async {
        guard !isStopped else { return }
        isPaused = false
        lastError = nil
        await publishStatus()
    }

    public func status() -> LiveCollectorRuntimeStatus {
        makeStatus()
    }

    private func schedulePending(after overrideDelay: TimeInterval? = nil) {
        guard let pending, !isStopped else { return }
        scheduledTask?.cancel()
        let elapsed = max(0, clock.now().timeIntervalSince(pending.firstObservedAt))
        let normalDelay = overrideDelay ?? policy.debounce(for: pending.families)
        let delay = max(0, min(normalDelay, policy.maximumDelay - elapsed))
        scheduledTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { return }
            await self?.scheduledFire()
        }
    }

    private func scheduledFire() async {
        scheduledTask = nil
        await processPending()
    }

    private func processPending() async {
        guard !isCollecting, let batch = pending?.batch, !isStopped else { return }
        pending = nil
        isCollecting = true
        lastCollectionStartedAt = clock.now()
        await publishStatus()

        do {
            let mutation = try await collector(batch)
            lastCollectionFinishedAt = clock.now()
            consecutiveFailures = 0
            lastError = nil
            if let mutation {
                lastMutationAt = mutation.committedAt
                let isOrdinaryLiveMutation = batch.reasons.isDisjoint(
                    with: [.reconciliation, .wake, .manual])
                if isOrdinaryLiveMutation {
                    lastLatencySeconds = mutation.latency
                    latencySamples.append(mutation.latency)
                    if latencySamples.count > 100 {
                        latencySamples.removeFirst(latencySamples.count - 100)
                    }
                }
                await mutationHandler(mutation)
            }
        } catch {
            lastCollectionFinishedAt = clock.now()
            consecutiveFailures += 1
            lastError = "Live collection failed; run trackify doctor for source details."
            if pending == nil {
                pending = Pending(
                    LiveCollectionTrigger(
                        families: batch.families, paths: batch.paths,
                        observedAt: batch.firstObservedAt, reason: .reconciliation,
                        requiresReconciliation: true),
                    maximumPaths: policy.maximumPathsPerBatch)
            } else {
                pending?.merge(batch, maximumPaths: policy.maximumPathsPerBatch)
            }
        }

        isCollecting = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await publishStatus()
        if pending != nil {
            schedulePending(after: lastError == nil ? nil : policy.retryDelay)
        }
    }

    private func makeStatus() -> LiveCollectorRuntimeStatus {
        let mode: LiveCollectorMode
        if isStopped || isPaused {
            mode = .stopped
        } else if isCollecting {
            mode = .collecting
        } else if lastError != nil {
            mode = .degraded
        } else if pending != nil {
            mode = .pending
        } else {
            mode = .upToDate
        }
        return LiveCollectorRuntimeStatus(
            mode: mode,
            pendingTriggerCount: pending?.triggerCount ?? 0,
            pendingPathCount: pending?.paths.count ?? 0,
            lastTriggerAt: lastTriggerAt,
            lastCollectionStartedAt: lastCollectionStartedAt,
            lastCollectionFinishedAt: lastCollectionFinishedAt,
            lastMutationAt: lastMutationAt,
            lastLatencySeconds: lastLatencySeconds,
            medianLatencySeconds: percentile(0.5),
            p95LatencySeconds: percentile(0.95),
            consecutiveFailures: consecutiveFailures,
            lastError: lastError)
    }

    private func publishStatus() async {
        await statusHandler(makeStatus())
    }

    private func percentile(_ fraction: Double) -> Double? {
        guard !latencySamples.isEmpty else { return nil }
        let sorted = latencySamples.sorted()
        let index = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))
        return sorted[index]
    }
}
