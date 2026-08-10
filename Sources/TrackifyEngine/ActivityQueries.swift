import Foundation
import TrackifyDomain
import TrackifyStore

enum CoreEvidence {
    static let kinds: Set<EventKind> = [
        .gitCommitObserved,
        .gitWorkingTreeChanged,
        .agentMessageObserved,
        .buildStarted,
        .buildFinished,
        .testFinished,
    ]

    static func includes(_ event: LedgerEvent) -> Bool {
        switch event.kind {
        case .gitWorkingTreeChanged:
            return event.payload["baseline"] != "true"
        case .gitCommitObserved, .agentMessageObserved, .buildStarted, .buildFinished, .testFinished:
            return true
        default:
            return false
        }
    }

    static func isReachable(_ event: LedgerEvent, commitKeys: Set<String>) -> Bool {
        guard event.kind == .gitCommitObserved,
            let repositoryID = event.repositoryID,
            let hash = event.payload["hash"]
        else { return true }
        return commitKeys.contains("\(repositoryID.rawValue):\(hash)")
    }
}

public struct ActivitySnapshot: Codable, Equatable, Sendable {
    public let rangeStart: Date
    public let rangeEnd: Date
    public let activeHours: Int
    public let llmTurns: Int
    public let conversationMessages: Int
    public let commits: Int
    public let additions: Int
    public let deletions: Int
    public let filesChanged: Int
    public let repositoryIDs: [RepositoryID]
    public let evidenceCount: Int
    public let firstEvidenceAt: Date?
    public let lastEvidenceAt: Date?

    public init(
        rangeStart: Date,
        rangeEnd: Date,
        activeHours: Int,
        llmTurns: Int,
        conversationMessages: Int,
        commits: Int,
        additions: Int,
        deletions: Int,
        filesChanged: Int,
        repositoryIDs: [RepositoryID],
        evidenceCount: Int,
        firstEvidenceAt: Date?,
        lastEvidenceAt: Date?
    ) {
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.activeHours = activeHours
        self.llmTurns = llmTurns
        self.conversationMessages = conversationMessages
        self.commits = commits
        self.additions = additions
        self.deletions = deletions
        self.filesChanged = filesChanged
        self.repositoryIDs = repositoryIDs
        self.evidenceCount = evidenceCount
        self.firstEvidenceAt = firstEvidenceAt
        self.lastEvidenceAt = lastEvidenceAt
    }
}

public struct MetricComparison: Codable, Equatable, Sendable {
    public let current: Double
    public let movingAverage: Double
    public let percentChange: Double?

    public init(current: Double, movingAverage: Double) {
        self.current = current
        self.movingAverage = movingAverage
        percentChange = movingAverage > 0 ? ((current - movingAverage) / movingAverage) * 100 : nil
    }
}

public struct ActivityComparison: Codable, Equatable, Sendable {
    public let activeDays: Int
    public let activeHours: MetricComparison
    public let llmTurns: MetricComparison
    public let commits: MetricComparison
    public let additions: MetricComparison
    public let deletions: MetricComparison
    public let filesChanged: MetricComparison
}

public struct ActivityDashboard: Codable, Equatable, Sendable {
    public let activity: ActivitySnapshot
    public let comparison: ActivityComparison
}

public struct ActivityQueries: Sendable {
    public init() {}

    public func snapshot(
        store: LedgerStore,
        range: DateInterval,
        cutoff: Date,
        repositoryIDs: Set<RepositoryID>? = nil,
        calendar: Calendar = .current
    ) throws -> ActivitySnapshot {
        let effectiveCutoff = max(range.start, min(cutoff, range.end))
        let sourceEvents = try canonicalEvents(
            store: store,
            events: store.events(
                from: range.start,
                through: effectiveCutoff,
                kinds: CoreEvidence.kinds
            ).filter { event in
                repositoryIDs.map { ids in
                    event.repositoryID.map(ids.contains) == true
                } ?? true
            })
        let reachableCommitKeys = try store.reachableCommitKeys(from: range.start, through: effectiveCutoff)
        return snapshot(
            sourceEvents: sourceEvents,
            reachableCommitKeys: reachableCommitKeys,
            range: range,
            cutoff: effectiveCutoff,
            calendar: calendar
        )
    }

    public func snapshots(
        store: LedgerStore,
        ranges: [DateInterval],
        cutoff: Date,
        calendar: Calendar = .current
    ) throws -> [ActivitySnapshot] {
        guard let firstStart = ranges.map(\.start).min(), let finalEnd = ranges.map(\.end).max() else { return [] }
        let effectiveEnd = min(cutoff, finalEnd)
        let sourceEvents = try canonicalEvents(
            store: store,
            events: store.events(
                from: firstStart,
                through: effectiveEnd,
                kinds: CoreEvidence.kinds
            ))
        let reachableCommitKeys = try store.reachableCommitKeys(from: firstStart, through: effectiveEnd)
        if let partitioned = partition(sourceEvents, among: ranges, cutoff: cutoff) {
            return zip(ranges, partitioned).map { range, events in
                snapshot(
                    selectedEvents: events,
                    reachableCommitKeys: reachableCommitKeys,
                    range: range,
                    cutoff: min(cutoff, range.end),
                    calendar: calendar
                )
            }
        }
        return ranges.map {
            snapshot(
                sourceEvents: sourceEvents,
                reachableCommitKeys: reachableCommitKeys,
                range: $0,
                cutoff: min(cutoff, $0.end),
                calendar: calendar
            )
        }
    }

    private func snapshot(
        sourceEvents: [LedgerEvent],
        reachableCommitKeys: Set<String>,
        range: DateInterval,
        cutoff: Date,
        calendar: Calendar
    ) -> ActivitySnapshot {
        let effectiveCutoff = max(range.start, min(cutoff, range.end))
        let events = sourceEvents.filter {
            $0.occurredAt >= range.start
                && $0.occurredAt < effectiveCutoff
        }
        return snapshot(
            selectedEvents: events,
            reachableCommitKeys: reachableCommitKeys,
            range: range,
            cutoff: effectiveCutoff,
            calendar: calendar
        )
    }

    private func snapshot(
        selectedEvents: [LedgerEvent],
        reachableCommitKeys: Set<String>,
        range: DateInterval,
        cutoff: Date,
        calendar: Calendar
    ) -> ActivitySnapshot {
        let effectiveCutoff = max(range.start, min(cutoff, range.end))
        let events = selectedEvents.filter {
            CoreEvidence.includes($0)
                && CoreEvidence.isReachable($0, commitKeys: reachableCommitKeys)
        }
        let commitEvents = events.filter { $0.kind == .gitCommitObserved }
        let additions = commitEvents.reduce(0) { $0 + (Int($1.payload["additions"] ?? "") ?? 0) }
        let deletions = commitEvents.reduce(0) { $0 + (Int($1.payload["deletions"] ?? "") ?? 0) }
        let filesChanged = commitEvents.reduce(0) { $0 + (Int($1.payload["filesChanged"] ?? "") ?? 0) }
        let repositoryIDs = Set(events.compactMap(\.repositoryID)).sorted { $0.rawValue < $1.rawValue }
        let messages = events.filter { $0.kind == .agentMessageObserved }
        let activeHours = Set(events.compactMap { calendar.dateInterval(of: .hour, for: $0.occurredAt)?.start }).count

        return ActivitySnapshot(
            rangeStart: range.start,
            rangeEnd: effectiveCutoff,
            activeHours: activeHours,
            llmTurns: CanonicalWorkEvidenceService().logicalTurnCount(in: messages),
            conversationMessages: messages.count,
            commits: commitEvents.count,
            additions: additions,
            deletions: deletions,
            filesChanged: filesChanged,
            repositoryIDs: repositoryIDs,
            evidenceCount: events.count,
            firstEvidenceAt: events.first?.occurredAt,
            lastEvidenceAt: events.last?.occurredAt
        )
    }

    /// Dense chart queries can contain hundreds of adjacent hourly ranges.
    /// Partitioning the fetched evidence once avoids rescanning the same event
    /// set for every bar. Overlapping or unordered ranges retain the general
    /// implementation above.
    private func partition(
        _ events: [LedgerEvent],
        among ranges: [DateInterval],
        cutoff: Date
    ) -> [[LedgerEvent]]? {
        guard !ranges.isEmpty else { return [] }
        for index in ranges.indices.dropFirst() {
            guard ranges[index - 1].start <= ranges[index].start,
                ranges[index - 1].end <= ranges[index].start
            else { return nil }
        }

        var buckets = Array(repeating: [LedgerEvent](), count: ranges.count)
        var rangeIndex = 0
        for event in events.sorted(by: { $0.occurredAt < $1.occurredAt }) {
            while rangeIndex < ranges.count && event.occurredAt >= ranges[rangeIndex].end {
                rangeIndex += 1
            }
            guard rangeIndex < ranges.count else { break }
            let range = ranges[rangeIndex]
            if event.occurredAt >= range.start && event.occurredAt < min(cutoff, range.end) {
                buckets[rangeIndex].append(event)
            }
        }
        return buckets
    }

    private func canonicalEvents(store: LedgerStore, events: [LedgerEvent]) throws -> [LedgerEvent] {
        try CanonicalWorkEvidenceService().events(store: store, events: events)
    }

    public func dashboard(
        store: LedgerStore,
        range: DateInterval,
        cutoff: Date,
        calendar: Calendar = .current,
        activeDayWindow: Int = 14
    ) throws -> ActivityDashboard {
        precondition(activeDayWindow > 0)
        let elapsed = max(0, min(cutoff, range.end).timeIntervalSince(range.start))
        let current = try snapshot(store: store, range: range, cutoff: cutoff, calendar: calendar)
        var prior: [ActivitySnapshot] = []
        var candidateStart = range.start
        var examinedDays = 0
        while prior.count < activeDayWindow && examinedDays < 366 {
            var batch: [DateInterval] = []
            for _ in 0..<min(21, 366 - examinedDays) {
                guard let previousStart = calendar.date(byAdding: .day, value: -1, to: candidateStart),
                    let nextStart = calendar.date(byAdding: .day, value: 1, to: previousStart)
                else { break }
                candidateStart = previousStart
                examinedDays += 1
                let comparisonCutoff = min(previousStart.addingTimeInterval(elapsed), nextStart)
                batch.append(DateInterval(start: previousStart, end: comparisonCutoff))
            }
            guard !batch.isEmpty else { break }
            let active = try snapshots(store: store, ranges: batch, cutoff: cutoff, calendar: calendar)
                .filter { $0.evidenceCount > 0 }
            prior.append(contentsOf: active.prefix(activeDayWindow - prior.count))
        }

        func average(_ value: (ActivitySnapshot) -> Double) -> Double {
            guard !prior.isEmpty else { return 0 }
            return prior.reduce(0) { $0 + value($1) } / Double(prior.count)
        }

        let comparison = ActivityComparison(
            activeDays: prior.count,
            activeHours: MetricComparison(current: Double(current.activeHours), movingAverage: average { Double($0.activeHours) }),
            llmTurns: MetricComparison(current: Double(current.llmTurns), movingAverage: average { Double($0.llmTurns) }),
            commits: MetricComparison(current: Double(current.commits), movingAverage: average { Double($0.commits) }),
            additions: MetricComparison(current: Double(current.additions), movingAverage: average { Double($0.additions) }),
            deletions: MetricComparison(current: Double(current.deletions), movingAverage: average { Double($0.deletions) }),
            filesChanged: MetricComparison(current: Double(current.filesChanged), movingAverage: average { Double($0.filesChanged) })
        )
        return ActivityDashboard(activity: current, comparison: comparison)
    }
}
