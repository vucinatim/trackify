import Foundation
import TrackifyDomain
import TrackifyStore

public enum EvidenceCompilerError: Error, Equatable, LocalizedError {
    case packetExceedsBudget(limit: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .packetExceedsBudget(let limit, let actual):
            return "The compiled report packet uses \(actual) bytes, above its \(limit)-byte budget."
        }
    }
}

/// Deterministically reduces a period's complete core evidence into a small,
/// representative provider packet. Selection never invokes a model.
public struct EvidenceCompiler: Sendable {
    public static let version = "evidence-compiler-v1"

    public struct Configuration: Equatable, Sendable {
        public var maxHourlyEvents: Int
        public var maxDailyEvents: Int
        public var maxExcerptCharacters: Int
        public var maxPayloadCharacters: Int
        public var maxPriorReportCharacters: Int
        public var maxSerializedBytes: Int

        public init(
            maxHourlyEvents: Int = 30,
            maxDailyEvents: Int = 12,
            maxExcerptCharacters: Int = 280,
            maxPayloadCharacters: Int = 160,
            maxPriorReportCharacters: Int = 220,
            maxSerializedBytes: Int = 20 * 1_024
        ) {
            precondition(maxHourlyEvents > 0)
            precondition(maxDailyEvents > 0)
            precondition(maxExcerptCharacters >= 80)
            precondition(maxPayloadCharacters >= 40)
            precondition(maxPriorReportCharacters >= 80)
            precondition(maxSerializedBytes >= 1_024)
            self.maxHourlyEvents = maxHourlyEvents
            self.maxDailyEvents = maxDailyEvents
            self.maxExcerptCharacters = maxExcerptCharacters
            self.maxPayloadCharacters = maxPayloadCharacters
            self.maxPriorReportCharacters = maxPriorReportCharacters
            self.maxSerializedBytes = maxSerializedBytes
        }
    }

    private let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func compile(
        store: LedgerStore,
        range: DateInterval,
        cutoff: Date,
        state: ReportPeriodState,
        activity: ActivitySnapshot,
        events: [LedgerEvent]
    ) throws -> ReportEvidencePacket {
        let privatePaths = try store.workingCopies().map(\.canonicalPath)
        let repositoryNames = Dictionary(
            uniqueKeysWithValues: try store.repositories().map { ($0.id, $0.displayName) }
        )
        let messages = try resolvedMessages(store: store, events: events)
        let hydrated = deduplicatedCandidates(
            events: events,
            messages: messages
        )
        let priorReportResult = try priorReports(
            store: store,
            range: range,
            privatePaths: privatePaths
        )
        // Calendar days are 23–25 hours around daylight-saving transitions.
        // A 20-hour threshold distinguishes them from every supported hourly period.
        let isDaily = range.duration >= 20 * 3_600
        let eventLimit = isDaily ? configuration.maxDailyEvents : configuration.maxHourlyEvents
        var selected = select(Array(hydrated), limit: eventLimit)

        while true {
            let packet = makePacket(
                range: range,
                cutoff: cutoff,
                state: state,
                activity: activity,
                allCandidates: hydrated,
                selected: selected,
                repositoryNames: repositoryNames,
                privatePaths: privatePaths,
                priorReportResult: priorReportResult
            )
            let size = packet.serializedByteCount
            if size <= configuration.maxSerializedBytes { return packet }
            guard selected.count > 1 else {
                throw EvidenceCompilerError.packetExceedsBudget(
                    limit: configuration.maxSerializedBytes,
                    actual: size
                )
            }
            selected.removeLast()
        }
    }

    private func resolvedMessages(
        store: LedgerStore,
        events: [LedgerEvent]
    ) throws -> [MessageID: ConversationMessage] {
        let messageIDs: [MessageID] = events.compactMap { event in
            guard let rawValue = event.payload["messageID"] else { return nil }
            return MessageID(rawValue)
        }
        let ids = Array(Set(messageIDs))
        var result: [MessageID: ConversationMessage] = [:]
        for offset in stride(from: 0, to: ids.count, by: 500) {
            let end = min(offset + 500, ids.count)
            result.merge(try store.messagesResolvingAliases(ids: Array(ids[offset..<end]))) { current, _ in current }
        }
        return result
    }

    private func deduplicatedCandidates(
        events: [LedgerEvent],
        messages: [MessageID: ConversationMessage]
    ) -> [Candidate] {
        let hydrated = events.map { event -> HydratedEvent in
            let message = event.payload["messageID"].flatMap { messages[MessageID($0)] }
            return HydratedEvent(event: event, message: message)
        }

        var latestBySignature: [String: HydratedEvent] = [:]
        for value in hydrated {
            let signature = semanticSignature(value)
            if let current = latestBySignature[signature], current.event.occurredAt > value.event.occurredAt {
                continue
            }
            latestBySignature[signature] = value
        }
        let unique = latestBySignature.values.sorted(by: eventOrder)

        let latestTree = latestIDs(in: unique) { $0.event.kind == .gitWorkingTreeChanged }
        let latestAssistant = latestIDs(in: unique) {
            $0.event.kind == .agentMessageObserved && $0.message?.role == .assistant
        }
        return unique.map { value in
            var reasons: Set<EvidenceSelectionReason> = []
            let priority: Int
            switch (value.event.kind, value.message?.role, value.event.state) {
            case (.agentMessageObserved, .user?, _):
                priority = 100
                reasons.insert(.userIntent)
            case (.testFinished, _, .failed?), (.testFinished, _, .interrupted?),
                (.buildFinished, _, .failed?), (.buildFinished, _, .interrupted?):
                priority = 98
                reasons.formUnion([.failure, .concreteOutcome])
            case (.gitCommitObserved, _, _):
                priority = 94
                reasons.insert(.concreteOutcome)
            case (.testFinished, _, _), (.buildFinished, _, _):
                priority = 90
                reasons.insert(.concreteOutcome)
            case (.gitWorkingTreeChanged, _, _):
                priority = latestTree.contains(value.event.id) ? 88 : 58
                if latestTree.contains(value.event.id) { reasons.insert(.finalState) }
            case (.agentMessageObserved, .assistant?, _):
                priority = latestAssistant.contains(value.event.id) ? 78 : 62
                if latestAssistant.contains(value.event.id) { reasons.insert(.latestProgress) }
            case (.buildStarted, _, _):
                priority = 45
            default:
                priority = 40
            }
            if reasons.isEmpty { reasons.insert(.representative) }
            return Candidate(
                value: value,
                context: context(for: value.event),
                priority: priority,
                reasons: reasons
            )
        }
    }

    private func latestIDs(
        in values: [HydratedEvent],
        matching predicate: (HydratedEvent) -> Bool
    ) -> Set<EventID> {
        var latest: [String: HydratedEvent] = [:]
        for value in values where predicate(value) {
            let key = context(for: value.event)
            if let current = latest[key], current.event.occurredAt > value.event.occurredAt { continue }
            latest[key] = value
        }
        return Set(latest.values.map(\.event.id))
    }

    private func select(_ candidates: [Candidate], limit: Int) -> [SelectedCandidate] {
        let ranked = candidates.sorted(by: candidateRank)
        let grouped = Dictionary(grouping: ranked, by: \.context)
        let contextOrder = grouped.keys.sorted { left, right in
            guard let leftFirst = grouped[left]?.first, let rightFirst = grouped[right]?.first else {
                return left < right
            }
            if leftFirst.priority != rightFirst.priority { return leftFirst.priority > rightFirst.priority }
            if leftFirst.value.event.occurredAt != rightFirst.value.event.occurredAt {
                return leftFirst.value.event.occurredAt > rightFirst.value.event.occurredAt
            }
            return left < right
        }

        var selected: [EventID: SelectedCandidate] = [:]
        func add(_ candidate: Candidate, reason: EvidenceSelectionReason) {
            guard selected.count < limit else { return }
            if var existing = selected[candidate.value.event.id] {
                existing.reasons.insert(reason)
                selected[candidate.value.event.id] = existing
            } else {
                let bucket = selectionBucket(candidate)
                let bucketCount = selected.values.count {
                    $0.candidate.context == candidate.context
                        && selectionBucket($0.candidate) == bucket
                }
                guard bucketCount < perContextLimit(for: bucket) else { return }
                var reasons = candidate.reasons
                reasons.insert(reason)
                selected[candidate.value.event.id] = SelectedCandidate(candidate: candidate, reasons: reasons)
            }
        }

        // First preserve one representative for every context. Then explicitly
        // reserve room for concrete outcomes/failures/final state before adding
        // conversational continuity and general high-priority evidence.
        for key in contextOrder {
            guard selected.count < limit, let first = grouped[key]?.first else { continue }
            add(first, reason: .projectCoverage)
        }
        for key in contextOrder {
            guard selected.count < limit, let values = grouped[key] else { continue }
            let critical = values.first {
                !selected.keys.contains($0.value.event.id)
                    && !$0.reasons.isDisjoint(with: [.failure, .concreteOutcome, .finalState])
            }
            if let critical { add(critical, reason: .contextContinuity) }
        }
        for key in contextOrder {
            guard selected.count < limit, let values = grouped[key] else { continue }
            if let continuity = values.first(where: { !selected.keys.contains($0.value.event.id) }) {
                add(continuity, reason: .contextContinuity)
            }
        }
        for candidate in ranked where selected.count < limit {
            add(candidate, reason: .representative)
        }

        // Lowest-ranked values remain last so byte-budget trimming removes them first.
        return selected.values.sorted { left, right in
            candidateRank(left.candidate, right.candidate)
        }
    }

    private func makePacket(
        range: DateInterval,
        cutoff: Date,
        state: ReportPeriodState,
        activity: ActivitySnapshot,
        allCandidates: [Candidate],
        selected: [SelectedCandidate],
        repositoryNames: [RepositoryID: String],
        privatePaths: [String],
        priorReportResult: PriorReportResult
    ) -> ReportEvidencePacket {
        let chronological = selected.sorted {
            if $0.candidate.value.event.occurredAt != $1.candidate.value.event.occurredAt {
                return $0.candidate.value.event.occurredAt < $1.candidate.value.event.occurredAt
            }
            return $0.candidate.value.event.id.rawValue < $1.candidate.value.event.id.rawValue
        }
        let repositoryIDs = Array(Set(chronological.compactMap { $0.candidate.value.event.repositoryID }))
            .sorted { $0.rawValue < $1.rawValue }
        let sessionIDs = Array(Set(chronological.compactMap { $0.candidate.value.event.sessionID }))
            .sorted { $0.rawValue < $1.rawValue }
        let repositoryAliases = Dictionary(
            uniqueKeysWithValues: repositoryIDs.enumerated().map { ($0.element, RepositoryID("r\($0.offset + 1)")) }
        )
        let sessionAliases = Dictionary(
            uniqueKeysWithValues: sessionIDs.enumerated().map { ($0.element, SessionID("s\($0.offset + 1)")) }
        )
        let digests = chronological.enumerated().map { offset, selected in
            let value = selected.candidate.value
            return ReportEventDigest(
                eventID: EventID("e\(offset + 1)"),
                evidenceID: value.event.evidenceID,
                occurredAt: value.event.occurredAt,
                source: value.event.source,
                kind: value.event.kind,
                state: value.event.state,
                repositoryID: value.event.repositoryID.flatMap { repositoryAliases[$0] },
                repositoryName: value.event.repositoryID.flatMap { repositoryNames[$0] },
                sessionID: value.event.sessionID.flatMap { sessionAliases[$0] },
                messageRole: value.message?.role,
                messageExcerpt: value.message.map {
                    bounded(
                        SecretRedactor.redact($0.normalizedText, privatePaths: privatePaths),
                        limit: configuration.maxExcerptCharacters
                    )
                },
                payload: providerPayload(
                    value.event.payload,
                    kind: value.event.kind,
                    privatePaths: privatePaths
                ),
                selectionReasons: selected.reasons.sorted { $0.rawValue < $1.rawValue }
            )
        }
        let selectedIDs = Set(selected.map { $0.candidate.value.event.id })
        let omitted = allCandidates.filter { !selectedIDs.contains($0.value.event.id) }
        let omittedByKind = Dictionary(grouping: omitted, by: { $0.value.event.kind.rawValue })
            .mapValues(\.count)
        let activeContexts = Set(allCandidates.map(\.context))
        let representedContexts = Set(selected.map { $0.candidate.context })
        let selection = ReportPacketSelection(
            compilerVersion: Self.version,
            totalEventCount: allCandidates.count,
            selectedEventCount: digests.count,
            omittedEventCount: omitted.count,
            omittedByKind: omittedByKind,
            activeContextCount: activeContexts.count,
            representedContextCount: representedContexts.count,
            omittedContextCount: activeContexts.subtracting(representedContexts).count,
            totalPriorReportCount: priorReportResult.total,
            selectedPriorReportCount: priorReportResult.reports.count,
            omittedQuietReportCount: priorReportResult.omittedQuiet,
            serializedByteLimit: configuration.maxSerializedBytes
        )
        return ReportEvidencePacket(
            schemaVersion: 4,
            periodStart: range.start,
            periodEnd: cutoff,
            state: state,
            activity: activity,
            events: digests,
            priorReports: priorReportResult.reports,
            selection: selection
        )
    }

    private func priorReports(
        store: LedgerStore,
        range: DateInterval,
        privatePaths: [String]
    ) throws -> PriorReportResult {
        guard range.duration >= 20 * 3_600 else { return PriorReportResult(reports: [], total: 0, omittedQuiet: 0) }
        let candidates = try store.reports(overlapping: range).filter {
            $0.periodStart >= range.start
                && $0.periodEnd <= range.end
                && $0.periodEnd.timeIntervalSince($0.periodStart) <= 2 * 3_600
        }
        var latestByPeriod: [String: WorkReport] = [:]
        for report in candidates {
            let key = "\(report.periodStart.timeIntervalSinceReferenceDate):\(report.periodEnd.timeIntervalSinceReferenceDate)"
            if let current = latestByPeriod[key], current.revision > report.revision { continue }
            latestByPeriod[key] = report
        }
        let latest = latestByPeriod.values.sorted {
            $0.periodStart == $1.periodStart ? $0.id.rawValue < $1.id.rawValue : $0.periodStart < $1.periodStart
        }
        let active = latest.filter { $0.state != .noActivity }
        let digests = active.prefix(24).enumerated().map { offset, report in
            ReportPeriodDigest(
                alias: "h\(offset + 1)",
                periodStart: report.periodStart,
                periodEnd: report.periodEnd,
                state: report.state,
                summary: bounded(
                    SecretRedactor.redact(report.summary, privatePaths: privatePaths),
                    limit: configuration.maxPriorReportCharacters
                ),
                provider: report.provider,
                evidenceIDs: report.evidenceIDs
            )
        }
        return PriorReportResult(
            reports: Array(digests),
            total: latest.count,
            omittedQuiet: latest.count - active.count
        )
    }

    private func providerPayload(
        _ payload: [String: String],
        kind: EventKind,
        privatePaths: [String]
    ) -> [String: String] {
        let allowed = allowedPayloadKeys(for: kind)
        return Dictionary(
            uniqueKeysWithValues: payload.compactMap { key, value in
                guard allowed.contains(key) else { return nil }
                return (
                    key,
                    bounded(
                        SecretRedactor.redact(value, privatePaths: privatePaths),
                        limit: configuration.maxPayloadCharacters
                    )
                )
            })
    }

    private func semanticSignature(_ value: HydratedEvent) -> String {
        let allowed = allowedPayloadKeys(for: value.event.kind)
        let payload = value.event.payload.filter { allowed.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "|")
        return [
            value.event.kind.rawValue,
            value.event.repositoryID?.rawValue ?? "",
            value.event.sessionID?.rawValue ?? "",
            value.message?.role.rawValue ?? "",
            value.message?.fingerprint ?? "",
            payload,
        ].joined(separator: "\u{1f}")
    }

    private func allowedPayloadKeys(for kind: EventKind) -> Set<String> {
        switch kind {
        case .gitCommitObserved:
            ["message", "additions", "deletions", "filesChanged"]
        case .gitWorkingTreeChanged:
            ["branch", "clean", "changedFiles", "additions", "deletions"]
        case .buildStarted, .buildFinished, .testFinished:
            ["suite", "result"]
        default:
            []
        }
    }

    private func context(for event: LedgerEvent) -> String {
        if let repositoryID = event.repositoryID { return "repository:\(repositoryID.rawValue)" }
        if let sessionID = event.sessionID { return "session:\(sessionID.rawValue)" }
        return "source:\(event.source.rawValue)"
    }

    private func bounded(_ value: String, limit: Int) -> String {
        let normalized = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return normalized.count <= limit ? normalized : String(normalized.prefix(limit - 1)) + "…"
    }

    private func eventOrder(_ left: HydratedEvent, _ right: HydratedEvent) -> Bool {
        left.event.occurredAt == right.event.occurredAt
            ? left.event.id.rawValue < right.event.id.rawValue
            : left.event.occurredAt < right.event.occurredAt
    }

    private func candidateRank(_ left: Candidate, _ right: Candidate) -> Bool {
        if left.priority != right.priority { return left.priority > right.priority }
        if left.value.event.occurredAt != right.value.event.occurredAt {
            return left.value.event.occurredAt > right.value.event.occurredAt
        }
        return left.value.event.id.rawValue < right.value.event.id.rawValue
    }

    private func selectionBucket(_ candidate: Candidate) -> SelectionBucket {
        switch (candidate.value.event.kind, candidate.value.message?.role) {
        case (.agentMessageObserved, .user?): .userMessage
        case (.agentMessageObserved, .assistant?): .assistantMessage
        case (.gitCommitObserved, _): .commit
        case (.gitWorkingTreeChanged, _): .workingTree
        case (.buildFinished, _), (.testFinished, _): .verification
        case (.buildStarted, _): .buildStart
        default: .other
        }
    }

    private func perContextLimit(for bucket: SelectionBucket) -> Int {
        switch bucket {
        case .userMessage: 4
        case .assistantMessage: 3
        case .commit: 5
        case .workingTree: 2
        case .verification: 4
        case .buildStart: 1
        case .other: 2
        }
    }

    private struct HydratedEvent: Sendable {
        let event: LedgerEvent
        let message: ConversationMessage?
    }

    private struct Candidate: Sendable {
        let value: HydratedEvent
        let context: String
        let priority: Int
        let reasons: Set<EvidenceSelectionReason>
    }

    private struct SelectedCandidate: Sendable {
        let candidate: Candidate
        var reasons: Set<EvidenceSelectionReason>
    }

    private struct PriorReportResult: Sendable {
        let reports: [ReportPeriodDigest]
        let total: Int
        let omittedQuiet: Int
    }

    private enum SelectionBucket: Sendable {
        case userMessage
        case assistantMessage
        case commit
        case workingTree
        case verification
        case buildStart
        case other
    }
}
