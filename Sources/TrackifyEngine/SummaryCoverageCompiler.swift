import Foundation
import TrackifyDomain
import TrackifyStore

public enum SummaryCoverageCompilerError: Error, Equatable, LocalizedError {
    case eventCannotFit(EvidenceID)
    case incomplete(expected: Int, covered: Int)

    public var errorDescription: String? {
        switch self {
        case .eventCannotFit(let id):
            "Evidence \(id.rawValue) could not fit in a bounded summary chunk."
        case .incomplete(let expected, let covered):
            "Summary coverage was incomplete: covered \(covered) of \(expected) eligible events."
        }
    }
}

public struct SummaryCompilation: Equatable, Sendable {
    public let range: DateInterval
    public let state: ReportPeriodState
    public let statistics: SummaryStatistics
    public let chunks: [ReportEvidencePacket]
    public let evidenceIDs: [EvidenceID]
    public let sourceFingerprint: String
    public let coverage: SummaryCoverage

    public var serializedByteCount: Int { chunks.reduce(0) { $0 + $1.serializedByteCount } }
    public var estimatedInputTokens: Int { chunks.reduce(0) { $0 + $1.estimatedInputTokens } }
}

/// Produces ordered provider packets with complete canonical event coverage.
/// User and commit messages are preserved in full across fragments; assistant
/// responses are deliberately bounded and carry explicit truncation metadata.
public struct SummaryCoverageCompiler: Sendable {
    public static let version = "summary-coverage-v2"

    public struct Configuration: Equatable, Sendable {
        public var maximumAssistantCharacters: Int
        public var maximumFragmentCharacters: Int
        public var maximumChunkBytes: Int

        public init(
            maximumAssistantCharacters: Int = 1_200,
            maximumFragmentCharacters: Int = 6_000,
            maximumChunkBytes: Int = 20 * 1_024
        ) {
            precondition(maximumAssistantCharacters >= 200)
            precondition(maximumFragmentCharacters >= 1_000)
            precondition(maximumChunkBytes >= 8 * 1_024)
            self.maximumAssistantCharacters = maximumAssistantCharacters
            self.maximumFragmentCharacters = maximumFragmentCharacters
            self.maximumChunkBytes = maximumChunkBytes
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
        repositoryIDs: Set<RepositoryID>? = nil,
        calendar: Calendar = .current
    ) throws -> SummaryCompilation {
        let effectiveCutoff = min(cutoff, range.end)
        let reachable = try store.reachableCommitKeys(from: range.start, through: effectiveCutoff)
        let sourceEvents = try store.events(
            from: range.start, through: effectiveCutoff, kinds: CoreEvidence.kinds
        )
        .filter { event in
            event.occurredAt < range.end
                && CoreEvidence.includes(event)
                && CoreEvidence.isReachable(event, commitKeys: reachable)
                && (repositoryIDs.map { ids in event.repositoryID.map(ids.contains) == true } ?? true)
        }
        let canonical = try canonicalEvents(store: store, events: sourceEvents)
        let messages = try resolvedMessages(store: store, events: canonical)
        let events = canonical.filter { event in
            guard event.kind == .agentMessageObserved,
                let messageID = event.payload["messageID"],
                let message = messages[MessageID(messageID)]
            else { return event.kind != .agentMessageObserved }
            return ConversationMessageVisibility.isWorkEvidence(message)
        }
        let activity = activitySnapshot(
            events: events, range: range, cutoff: effectiveCutoff,
            calendar: calendar)
        let statistics = SummaryStatistics(activity)
        let state = deriveState(events)
        let privatePaths = try store.workingCopies().map(\.canonicalPath)
        let repositoryNames = Dictionary(
            uniqueKeysWithValues: try store.repositories().map { ($0.id, $0.displayName) })

        var digests: [ReportEventDigest] = []
        var covered = Set<EvidenceID>()
        var truncatedAssistantCount = 0
        for (offset, event) in events.enumerated() {
            let message = event.payload["messageID"].flatMap { messages[MessageID($0)] }
            let values = makeDigests(
                event: event, message: message, ordinal: offset + 1,
                repositoryName: event.repositoryID.flatMap { repositoryNames[$0] },
                privatePaths: privatePaths)
            if values.contains(where: { $0.wasTruncated }) { truncatedAssistantCount += 1 }
            digests.append(contentsOf: values)
            covered.insert(event.evidenceID)
        }

        let eligibleEvidence = Set(events.map(\.evidenceID))
        guard covered.count == eligibleEvidence.count else {
            throw SummaryCoverageCompilerError.incomplete(
                expected: eligibleEvidence.count, covered: covered.count)
        }

        let chunks = try makeChunks(
            range: range, cutoff: effectiveCutoff, state: state,
            activity: activity, digests: digests, eligibleCount: eligibleEvidence.count)
        let fingerprintMaterial = events.map {
            "\($0.id.rawValue):\($0.evidenceID.rawValue):\($0.observedAt.timeIntervalSince1970)"
        }.joined(separator: "|")
        let fingerprint = StableHash.sha256(
            "\(Self.version)|\(range.start.timeIntervalSince1970)|\(range.end.timeIntervalSince1970)|\(fingerprintMaterial)")
        return SummaryCompilation(
            range: range, state: state, statistics: statistics, chunks: chunks,
            evidenceIDs: eligibleEvidence.sorted { $0.rawValue < $1.rawValue },
            sourceFingerprint: fingerprint,
            coverage: SummaryCoverage(
                eligibleEventCount: eligibleEvidence.count,
                coveredEventCount: covered.count,
                truncatedAssistantCount: truncatedAssistantCount,
                chunkCount: max(chunks.count, 1)))
    }

    private func canonicalEvents(
        store: LedgerStore,
        events: [LedgerEvent]
    ) throws -> [LedgerEvent] {
        try CanonicalWorkEvidenceService().events(store: store, events: events)
    }

    private func resolvedMessages(
        store: LedgerStore,
        events: [LedgerEvent]
    ) throws -> [MessageID: ConversationMessage] {
        let ids = Array(
            Set(
                events.compactMap { event in
                    event.payload["messageID"].map { MessageID($0) }
                }))
        var result: [MessageID: ConversationMessage] = [:]
        for offset in stride(from: 0, to: ids.count, by: 500) {
            let end = min(offset + 500, ids.count)
            result.merge(try store.messagesResolvingAliases(ids: Array(ids[offset..<end]))) { lhs, _ in lhs }
        }
        return result
    }

    private func makeDigests(
        event: LedgerEvent,
        message: ConversationMessage?,
        ordinal: Int,
        repositoryName: String?,
        privatePaths: [String]
    ) -> [ReportEventDigest] {
        let role = message?.role
        let originalText = message.flatMap(ConversationMessageVisibility.workText).map {
            SecretRedactor.redact($0, privatePaths: privatePaths)
        }
        let includedText: String?
        let wasTruncated: Bool
        if role == .assistant, let originalText,
            originalText.count > configuration.maximumAssistantCharacters
        {
            includedText = String(originalText.prefix(configuration.maximumAssistantCharacters)) + "…"
            wasTruncated = true
        } else {
            includedText = originalText
            wasTruncated = false
        }

        var payload = providerPayload(event.payload, kind: event.kind, privatePaths: privatePaths)
        var fragmentText = includedText
        if event.kind == .gitCommitObserved, let message = payload["message"] {
            fragmentText = message
            payload.removeValue(forKey: "message")
        }
        let fragments = fragmentText.map(fragment) ?? [nil]
        return fragments.enumerated().map { index, fragment in
            let alias = fragments.count == 1 ? "e\(ordinal)" : "e\(ordinal)p\(index + 1)"
            var fragmentPayload = payload
            if event.kind == .gitCommitObserved, let fragment {
                fragmentPayload["message"] = fragment
            }
            return ReportEventDigest(
                eventID: EventID(alias), evidenceID: event.evidenceID,
                occurredAt: event.occurredAt, source: event.source, kind: event.kind,
                state: event.state, repositoryID: event.repositoryID,
                repositoryName: repositoryName, sessionID: event.sessionID,
                messageRole: role,
                logicalTurnID: message?.provenance.logicalTurnID,
                messageOrigin: message?.provenance.origin,
                messageSemanticKind: message?.provenance.semanticKind,
                messageExcerpt: event.kind == .gitCommitObserved ? nil : fragment,
                originalCharacterCount: originalText?.count ?? fragmentText?.count,
                includedCharacterCount: fragmentText?.count,
                wasTruncated: wasTruncated,
                fragmentIndex: fragments.count == 1 ? nil : index + 1,
                fragmentCount: fragments.count == 1 ? nil : fragments.count,
                payload: fragmentPayload,
                selectionReasons: isWorkIntent(message) ? [.userIntent] : [.representative])
        }
    }

    private func isWorkIntent(_ message: ConversationMessage?) -> Bool {
        guard let message, message.provenance.disposition == .work else { return false }
        let origin = message.provenance.origin
        let semantic = message.provenance.semanticKind
        if message.provenance.classificationReason == "legacy-compatible" {
            return message.role == .user
        }
        return (origin == .human || origin == .agent)
            && (semantic == .intent || semantic == .steering)
    }

    private func fragment(_ value: String) -> [String?] {
        guard value.count > configuration.maximumFragmentCharacters else { return [value] }
        var result: [String?] = []
        var index = value.startIndex
        while index < value.endIndex {
            let end =
                value.index(
                    index, offsetBy: configuration.maximumFragmentCharacters,
                    limitedBy: value.endIndex) ?? value.endIndex
            result.append(String(value[index..<end]))
            index = end
        }
        return result
    }

    private func makeChunks(
        range: DateInterval,
        cutoff: Date,
        state: ReportPeriodState,
        activity: ActivitySnapshot,
        digests: [ReportEventDigest],
        eligibleCount: Int
    ) throws -> [ReportEvidencePacket] {
        guard !digests.isEmpty else { return [] }
        var groups: [[ReportEventDigest]] = []
        var current: [ReportEventDigest] = []
        for digest in digests {
            let candidate = packet(
                range: range, cutoff: cutoff, state: state, activity: activity,
                events: current + [digest], eligibleCount: eligibleCount)
            if candidate.serializedByteCount <= configuration.maximumChunkBytes {
                current.append(digest)
                continue
            }
            guard !current.isEmpty else {
                throw SummaryCoverageCompilerError.eventCannotFit(digest.evidenceID)
            }
            groups.append(current)
            current = [digest]
            let single = packet(
                range: range, cutoff: cutoff, state: state, activity: activity,
                events: current, eligibleCount: eligibleCount)
            guard single.serializedByteCount <= configuration.maximumChunkBytes else {
                throw SummaryCoverageCompilerError.eventCannotFit(digest.evidenceID)
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups.map {
            packet(
                range: range, cutoff: cutoff, state: state, activity: activity,
                events: $0, eligibleCount: eligibleCount)
        }
    }

    private func packet(
        range: DateInterval,
        cutoff: Date,
        state: ReportPeriodState,
        activity: ActivitySnapshot,
        events: [ReportEventDigest],
        eligibleCount: Int
    ) -> ReportEvidencePacket {
        ReportEvidencePacket(
            schemaVersion: 2, periodStart: range.start, periodEnd: min(cutoff, range.end),
            state: state, activity: activity, events: events,
            selection: ReportPacketSelection(
                compilerVersion: Self.version, totalEventCount: eligibleCount,
                selectedEventCount: Set(events.map(\.evidenceID)).count,
                omittedEventCount: 0, omittedByKind: [:],
                activeContextCount: Set(events.map(context)).count,
                representedContextCount: Set(events.map(context)).count,
                omittedContextCount: 0, serializedByteLimit: configuration.maximumChunkBytes))
    }

    private func providerPayload(
        _ payload: [String: String],
        kind: EventKind,
        privatePaths: [String]
    ) -> [String: String] {
        let allowed: Set<String>
        switch kind {
        case .gitCommitObserved:
            allowed = ["message", "hash", "additions", "deletions", "filesChanged"]
        case .gitWorkingTreeChanged:
            allowed = ["branch", "clean", "changedFiles", "additions", "deletions"]
        case .buildStarted, .buildFinished, .testFinished:
            allowed = ["suite", "result"]
        default:
            allowed = []
        }
        return Dictionary(
            uniqueKeysWithValues: payload.compactMap { key, value in
                guard allowed.contains(key) else { return nil }
                return (key, SecretRedactor.redact(value, privatePaths: privatePaths))
            })
    }

    private func deriveState(_ events: [LedgerEvent]) -> ReportPeriodState {
        guard !events.isEmpty else { return .noActivity }
        if events.contains(where: {
            ($0.kind == .testFinished || $0.kind == .buildFinished)
                && ($0.state == .failed || $0.state == .interrupted)
        }) {
            return .investigating
        }
        if let tree = events.last(where: { $0.kind == .gitWorkingTreeChanged }),
            tree.payload["clean"] != "true"
        {
            return .inProgress
        }
        if events.contains(where: {
            $0.kind == .gitCommitObserved || $0.kind == .buildFinished || $0.kind == .testFinished
        }) {
            return .completed
        }
        return .observed
    }

    private func activitySnapshot(
        events: [LedgerEvent],
        range: DateInterval,
        cutoff: Date,
        calendar: Calendar
    ) -> ActivitySnapshot {
        let commits = events.filter { $0.kind == .gitCommitObserved }
        let messages = events.filter { $0.kind == .agentMessageObserved }
        return ActivitySnapshot(
            rangeStart: range.start,
            rangeEnd: min(cutoff, range.end),
            activeHours: Set(
                events.compactMap {
                    calendar.dateInterval(of: .hour, for: $0.occurredAt)?.start
                }
            ).count,
            llmTurns: CanonicalWorkEvidenceService().logicalTurnCount(in: messages),
            conversationMessages: messages.count,
            commits: commits.count,
            additions: commits.reduce(0) { $0 + (Int($1.payload["additions"] ?? "") ?? 0) },
            deletions: commits.reduce(0) { $0 + (Int($1.payload["deletions"] ?? "") ?? 0) },
            filesChanged: commits.reduce(0) {
                $0 + (Int($1.payload["filesChanged"] ?? "") ?? 0)
            },
            repositoryIDs: Array(Set(events.compactMap(\.repositoryID)))
                .sorted { $0.rawValue < $1.rawValue },
            evidenceCount: events.count,
            firstEvidenceAt: events.first?.occurredAt,
            lastEvidenceAt: events.last?.occurredAt)
    }

    private func context(_ event: ReportEventDigest) -> String {
        if let repositoryID = event.repositoryID { return "repository:\(repositoryID.rawValue)" }
        if let sessionID = event.sessionID { return "session:\(sessionID.rawValue)" }
        return "source:\(event.source.rawValue)"
    }

    private func eventOrder(_ lhs: LedgerEvent, _ rhs: LedgerEvent) -> Bool {
        lhs.occurredAt == rhs.occurredAt
            ? lhs.id.rawValue < rhs.id.rawValue
            : lhs.occurredAt < rhs.occurredAt
    }
}

extension SummaryStatistics {
    init(_ activity: ActivitySnapshot) {
        self.init(
            activeHours: activity.activeHours, llmTurns: activity.llmTurns,
            conversationMessages: activity.conversationMessages, commits: activity.commits,
            additions: activity.additions, deletions: activity.deletions,
            filesChanged: activity.filesChanged, repositoryIDs: activity.repositoryIDs,
            evidenceCount: activity.evidenceCount)
    }
}
