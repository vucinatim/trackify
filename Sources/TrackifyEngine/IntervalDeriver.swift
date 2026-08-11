import Foundation
import TrackifyDomain
import TrackifyStore

public struct IntervalDeriver: Sendable {
    public static let version = 1

    public init() {}

    public func derive(events: [LedgerEvent], cutoff: Date) -> [WorkInterval] {
        struct OpenRun {
            let event: LedgerEvent
            let turnID: String?
        }

        var openBySession: [SessionID: [OpenRun]] = [:]
        var intervals: [WorkInterval] = []

        for event in events.sorted(by: eventOrder) {
            guard let sessionID = event.sessionID else { continue }
            switch event.kind {
            case .agentRunStarted:
                let open = OpenRun(event: event, turnID: event.payload["turnID"])
                if !(openBySession[sessionID] ?? []).contains(where: { $0.event.id == event.id }) {
                    openBySession[sessionID, default: []].append(open)
                }

            case .agentRunFinished, .agentRunWaiting:
                guard var openRuns = openBySession[sessionID], !openRuns.isEmpty else { continue }
                let turnID = event.payload["turnID"]
                let index =
                    turnID.flatMap { expected in
                        openRuns.lastIndex(where: { $0.turnID == expected })
                    } ?? (openRuns.count - 1)
                let open = openRuns.remove(at: index)
                openBySession[sessionID] = openRuns
                guard event.occurredAt >= open.event.occurredAt else { continue }
                intervals.append(makeInterval(start: open.event, end: event, state: event.state ?? .unknown))

            default:
                continue
            }
        }

        for (_, openRuns) in openBySession {
            for open in openRuns where cutoff >= open.event.occurredAt {
                intervals.append(makeOpenInterval(start: open.event, cutoff: cutoff))
            }
        }

        return intervals.sorted {
            $0.startedAt == $1.startedAt ? $0.id.rawValue < $1.id.rawValue : $0.startedAt < $1.startedAt
        }
    }

    public func rebuild(store: LedgerStore, range: DateInterval, cutoff: Date) throws -> [WorkInterval] {
        let events = try store.events(from: range.start.addingTimeInterval(-7 * 86_400), through: cutoff)
        let intervals = derive(events: events, cutoff: cutoff).filter {
            $0.startedAt < range.end && $0.endedAt > range.start
        }
        try store.replaceWorkIntervals(overlapping: range, with: intervals)
        return intervals
    }

    public func summarize(_ intervals: [WorkInterval], within range: DateInterval) -> TimeSummary {
        let clipped = intervals.compactMap { interval -> DateInterval? in
            let start = max(interval.startedAt, range.start)
            let end = min(interval.endedAt, range.end)
            guard end > start else { return nil }
            return DateInterval(start: start, end: end)
        }
        let agentSeconds = clipped.reduce(0) { $0 + $1.duration }
        let trackedSeconds = unionDuration(clipped)
        return TimeSummary(trackedSeconds: trackedSeconds, agentSeconds: agentSeconds)
    }

    private func unionDuration(_ intervals: [DateInterval]) -> TimeInterval {
        let sorted = intervals.sorted { $0.start < $1.start }
        guard var current = sorted.first else { return 0 }
        var total: TimeInterval = 0
        for interval in sorted.dropFirst() {
            if interval.start <= current.end {
                current = DateInterval(start: current.start, end: max(current.end, interval.end))
            } else {
                total += current.duration
                current = interval
            }
        }
        return total + current.duration
    }

    private func makeInterval(start: LedgerEvent, end: LedgerEvent, state: ObservedState) -> WorkInterval {
        WorkInterval(
            id: WorkIntervalID(StableHash.sha256("agent-interval:\(start.id.rawValue)")),
            kind: .agent,
            startedAt: start.occurredAt,
            endedAt: end.occurredAt,
            repositoryID: start.repositoryID ?? end.repositoryID,
            sessionID: start.sessionID,
            state: state,
            sourceEventIDs: [start.id, end.id],
            derivationVersion: Self.version
        )
    }

    private func makeOpenInterval(start: LedgerEvent, cutoff: Date) -> WorkInterval {
        WorkInterval(
            id: WorkIntervalID(StableHash.sha256("agent-interval:\(start.id.rawValue)")),
            kind: .agent,
            startedAt: start.occurredAt,
            endedAt: cutoff,
            repositoryID: start.repositoryID,
            sessionID: start.sessionID,
            state: .inProgress,
            sourceEventIDs: [start.id],
            derivationVersion: Self.version
        )
    }

    private func eventOrder(_ lhs: LedgerEvent, _ rhs: LedgerEvent) -> Bool {
        lhs.occurredAt == rhs.occurredAt ? lhs.id.rawValue < rhs.id.rawValue : lhs.occurredAt < rhs.occurredAt
    }
}
