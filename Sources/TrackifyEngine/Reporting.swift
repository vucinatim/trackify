import Foundation
import TrackifyDomain
import TrackifyStore

public enum EvidenceSelectionReason: String, Codable, CaseIterable, Sendable {
    case userIntent = "user_intent"
    case concreteOutcome = "concrete_outcome"
    case failure
    case finalState = "final_state"
    case latestProgress = "latest_progress"
    case projectCoverage = "project_coverage"
    case contextContinuity = "context_continuity"
    case representative
}

public struct ReportEventDigest: Encodable, Equatable, Sendable {
    /// A packet-local alias such as `e1`, never the stable ledger event ID.
    public let eventID: EventID
    /// Local provenance. Custom encoding deliberately keeps this out of provider input.
    public let evidenceID: EvidenceID
    public let occurredAt: Date
    public let source: SourceKind
    public let kind: EventKind
    public let state: ObservedState?
    public let repositoryID: RepositoryID?
    public let repositoryName: String?
    public let sessionID: SessionID?
    public let messageRole: MessageRole?
    public let messageExcerpt: String?
    public let payload: [String: String]
    public let selectionReasons: [EvidenceSelectionReason]

    public init(
        eventID: EventID,
        evidenceID: EvidenceID,
        occurredAt: Date,
        source: SourceKind,
        kind: EventKind,
        state: ObservedState?,
        repositoryID: RepositoryID? = nil,
        repositoryName: String? = nil,
        sessionID: SessionID? = nil,
        messageRole: MessageRole? = nil,
        messageExcerpt: String? = nil,
        payload: [String: String],
        selectionReasons: [EvidenceSelectionReason] = [.representative]
    ) {
        self.eventID = eventID
        self.evidenceID = evidenceID
        self.occurredAt = occurredAt
        self.source = source
        self.kind = kind
        self.state = state
        self.repositoryID = repositoryID
        self.repositoryName = repositoryName
        self.sessionID = sessionID
        self.messageRole = messageRole
        self.messageExcerpt = messageExcerpt
        self.payload = payload
        self.selectionReasons = selectionReasons
    }

    private enum CodingKeys: String, CodingKey {
        case eventID
        case occurredAt
        case source
        case kind
        case state
        case repositoryID
        case repositoryName
        case sessionID
        case messageRole
        case messageExcerpt
        case payload
        case selectionReasons
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(occurredAt, forKey: .occurredAt)
        try container.encode(source, forKey: .source)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(state, forKey: .state)
        try container.encodeIfPresent(repositoryID, forKey: .repositoryID)
        try container.encodeIfPresent(repositoryName, forKey: .repositoryName)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(messageRole, forKey: .messageRole)
        try container.encodeIfPresent(messageExcerpt, forKey: .messageExcerpt)
        try container.encode(payload, forKey: .payload)
        try container.encode(selectionReasons, forKey: .selectionReasons)
    }
}

public struct ReportPeriodDigest: Encodable, Equatable, Sendable {
    public let alias: String
    public let periodStart: Date
    public let periodEnd: Date
    public let state: ReportPeriodState
    public let summary: String
    public let provider: String?
    public let evidenceIDs: [EvidenceID]

    public init(
        alias: String,
        periodStart: Date,
        periodEnd: Date,
        state: ReportPeriodState,
        summary: String,
        provider: String?,
        evidenceIDs: [EvidenceID]
    ) {
        self.alias = alias
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.state = state
        self.summary = summary
        self.provider = provider
        self.evidenceIDs = evidenceIDs
    }

    private enum CodingKeys: String, CodingKey {
        case alias
        case periodStart
        case periodEnd
        case state
        case summary
        case provider
        case evidenceCount
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(alias, forKey: .alias)
        try container.encode(periodStart, forKey: .periodStart)
        try container.encode(periodEnd, forKey: .periodEnd)
        try container.encode(state, forKey: .state)
        try container.encode(summary, forKey: .summary)
        try container.encodeIfPresent(provider, forKey: .provider)
        try container.encode(evidenceIDs.count, forKey: .evidenceCount)
    }
}

public struct ReportPacketSelection: Codable, Equatable, Sendable {
    public let compilerVersion: String
    public let totalEventCount: Int
    public let selectedEventCount: Int
    public let omittedEventCount: Int
    public let omittedByKind: [String: Int]
    public let activeContextCount: Int
    public let representedContextCount: Int
    public let omittedContextCount: Int
    public let totalPriorReportCount: Int
    public let selectedPriorReportCount: Int
    public let omittedQuietReportCount: Int
    public let serializedByteLimit: Int

    public init(
        compilerVersion: String,
        totalEventCount: Int,
        selectedEventCount: Int,
        omittedEventCount: Int,
        omittedByKind: [String: Int],
        activeContextCount: Int,
        representedContextCount: Int,
        omittedContextCount: Int,
        totalPriorReportCount: Int = 0,
        selectedPriorReportCount: Int = 0,
        omittedQuietReportCount: Int = 0,
        serializedByteLimit: Int
    ) {
        self.compilerVersion = compilerVersion
        self.totalEventCount = totalEventCount
        self.selectedEventCount = selectedEventCount
        self.omittedEventCount = omittedEventCount
        self.omittedByKind = omittedByKind
        self.activeContextCount = activeContextCount
        self.representedContextCount = representedContextCount
        self.omittedContextCount = omittedContextCount
        self.totalPriorReportCount = totalPriorReportCount
        self.selectedPriorReportCount = selectedPriorReportCount
        self.omittedQuietReportCount = omittedQuietReportCount
        self.serializedByteLimit = serializedByteLimit
    }

    public static let legacy = ReportPacketSelection(
        compilerVersion: "legacy",
        totalEventCount: 0,
        selectedEventCount: 0,
        omittedEventCount: 0,
        omittedByKind: [:],
        activeContextCount: 0,
        representedContextCount: 0,
        omittedContextCount: 0,
        totalPriorReportCount: 0,
        selectedPriorReportCount: 0,
        omittedQuietReportCount: 0,
        serializedByteLimit: 256 * 1_024
    )
}

public struct ReportActivitySnapshot: Codable, Equatable, Sendable {
    public let rangeStart: Date
    public let rangeEnd: Date
    public let activeHours: Int
    public let llmTurns: Int
    public let conversationMessages: Int
    public let commits: Int
    public let additions: Int
    public let deletions: Int
    public let filesChanged: Int
    public let repositoryCount: Int
    public let evidenceCount: Int
    public let firstEvidenceAt: Date?
    public let lastEvidenceAt: Date?

    public init(_ activity: ActivitySnapshot) {
        rangeStart = activity.rangeStart
        rangeEnd = activity.rangeEnd
        activeHours = activity.activeHours
        llmTurns = activity.llmTurns
        conversationMessages = activity.conversationMessages
        commits = activity.commits
        additions = activity.additions
        deletions = activity.deletions
        filesChanged = activity.filesChanged
        repositoryCount = activity.repositoryIDs.count
        evidenceCount = activity.evidenceCount
        firstEvidenceAt = activity.firstEvidenceAt
        lastEvidenceAt = activity.lastEvidenceAt
    }

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
        repositoryCount: Int,
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
        self.repositoryCount = repositoryCount
        self.evidenceCount = evidenceCount
        self.firstEvidenceAt = firstEvidenceAt
        self.lastEvidenceAt = lastEvidenceAt
    }
}

public struct ReportEvidencePacket: Encodable, Equatable, Sendable {
    public let schemaVersion: Int
    public let periodStart: Date
    public let periodEnd: Date
    public let state: ReportPeriodState
    public let activity: ReportActivitySnapshot
    public let events: [ReportEventDigest]
    public let priorReports: [ReportPeriodDigest]
    public let selection: ReportPacketSelection

    public init(
        schemaVersion: Int,
        periodStart: Date,
        periodEnd: Date,
        state: ReportPeriodState,
        activity: ActivitySnapshot,
        events: [ReportEventDigest],
        priorReports: [ReportPeriodDigest] = [],
        selection: ReportPacketSelection = .legacy
    ) {
        self.schemaVersion = schemaVersion
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.state = state
        self.activity = ReportActivitySnapshot(activity)
        self.events = events
        self.priorReports = priorReports
        self.selection = selection
    }

    init(
        schemaVersion: Int,
        periodStart: Date,
        periodEnd: Date,
        state: ReportPeriodState,
        activity: ReportActivitySnapshot,
        events: [ReportEventDigest],
        priorReports: [ReportPeriodDigest],
        selection: ReportPacketSelection
    ) {
        self.schemaVersion = schemaVersion
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.state = state
        self.activity = activity
        self.events = events
        self.priorReports = priorReports
        self.selection = selection
    }

    public var evidenceAliases: Set<String> {
        Set(events.map(\.eventID.rawValue)).union(priorReports.map(\.alias))
    }

    public func evidenceIDs(for aliases: [String]) -> [EvidenceID] {
        let eventEvidence = Dictionary(uniqueKeysWithValues: events.map { ($0.eventID.rawValue, [$0.evidenceID]) })
        let reportEvidence = Dictionary(uniqueKeysWithValues: priorReports.map { ($0.alias, $0.evidenceIDs) })
        var seen = Set<EvidenceID>()
        return aliases.flatMap { eventEvidence[$0] ?? reportEvidence[$0] ?? [] }
            .filter { seen.insert($0).inserted }
    }

    public var allEvidenceIDs: [EvidenceID] {
        evidenceIDs(for: events.map(\.eventID.rawValue) + priorReports.map(\.alias))
    }

    public var serializedByteCount: Int {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self).count) ?? 0
    }

    public var estimatedInputTokens: Int {
        (serializedByteCount + 3) / 4
    }
}

public struct ProviderSummary: Codable, Equatable, Sendable {
    public let summary: String
    public let topics: [String]
    public let evidenceAliases: [String]

    public init(summary: String, topics: [String], evidenceAliases: [String]) {
        self.summary = summary
        self.topics = topics
        self.evidenceAliases = evidenceAliases
    }
}

public struct ProviderGenerationResult: Codable, Equatable, Sendable {
    public let summary: ProviderSummary
    public let usage: ProviderUsage
    public let effectiveModel: String?
    public let invocationVersion: String

    public init(
        summary: ProviderSummary,
        usage: ProviderUsage = ProviderUsage(),
        effectiveModel: String? = nil,
        invocationVersion: String
    ) {
        self.summary = summary
        self.usage = usage
        self.effectiveModel = effectiveModel
        self.invocationVersion = invocationVersion
    }
}

public protocol SummaryProvider: Sendable {
    var id: String { get }
    var model: String { get }
    func summarize(_ packet: ReportEvidencePacket) async throws -> ProviderSummary
    func generate(
        _ packet: ReportEvidencePacket,
        recipe: ReportRecipeVersion?
    ) async throws -> ProviderGenerationResult
}

extension SummaryProvider {
    func generate(
        _ packet: ReportEvidencePacket,
        recipe: ReportRecipeVersion? = nil
    ) async throws -> ProviderGenerationResult {
        ProviderGenerationResult(
            summary: try await summarize(packet),
            effectiveModel: model,
            invocationVersion: "summary-provider-v1")
    }
}

public struct ReportGenerator: Sendable {
    public static let version = "report-v6"

    private let queries: ActivityQueries
    private let compiler: EvidenceCompiler

    public init(
        queries: ActivityQueries = ActivityQueries(),
        compiler: EvidenceCompiler = EvidenceCompiler()
    ) {
        self.queries = queries
        self.compiler = compiler
    }

    public func evidencePacket(
        store: LedgerStore,
        range: DateInterval,
        cutoff: Date
    ) throws -> ReportEvidencePacket {
        let effectiveCutoff = min(cutoff, range.end)
        let reachableCommitKeys = try store.reachableCommitKeys(from: range.start, through: effectiveCutoff)
        let events = try store.events(
            from: range.start,
            through: effectiveCutoff,
            kinds: CoreEvidence.kinds
        ).filter {
            $0.occurredAt < range.end
                && CoreEvidence.includes($0)
                && CoreEvidence.isReachable($0, commitKeys: reachableCommitKeys)
        }
        let activity = try queries.snapshot(store: store, range: range, cutoff: effectiveCutoff)
        let state =
            activity.evidenceCount == 0
            ? ReportPeriodState.noActivity
            : deriveState(events: events)
        return try compiler.compile(
            store: store,
            range: range,
            cutoff: effectiveCutoff,
            state: state,
            activity: activity,
            events: events
        )
    }

    public func generate(
        store: LedgerStore,
        range: DateInterval,
        cutoff: Date,
        provider: (any SummaryProvider)? = nil
    ) async throws -> WorkReport {
        let packet = try evidencePacket(store: store, range: range, cutoff: cutoff)
        let summary: String
        let evidenceIDs: [EvidenceID]
        let providerID: String?
        let model: String?
        if packet.state == .noActivity {
            summary = "No development activity was detected during this period."
            evidenceIDs = []
            providerID = nil
            model = nil
        } else if let provider {
            let result = try await provider.summarize(packet)
            summary = SecretRedactor.redact(result.summary)
            evidenceIDs = packet.evidenceIDs(for: result.evidenceAliases)
            providerID = provider.id
            model = provider.model
        } else {
            summary = deterministicSummary(packet)
            evidenceIDs = packet.allEvidenceIDs
            providerID = nil
            model = nil
        }

        let previous = try store.reports(overlapping: range)
        let revision = (previous.map(\.revision).max() ?? 0) + 1
        let identity = [
            String(range.start.timeIntervalSince1970),
            String(range.end.timeIntervalSince1970),
            String(revision),
        ].joined(separator: ":")
        let report = WorkReport(
            id: ReportID(StableHash.sha256("report:\(identity)")),
            periodStart: range.start,
            periodEnd: packet.periodEnd,
            state: packet.state,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            evidenceIDs: evidenceIDs,
            provider: providerID,
            model: model,
            generatorVersion: Self.version,
            revision: revision
        )
        try store.save(report: report)
        return report
    }

    private func deriveState(events: [LedgerEvent]) -> ReportPeriodState {
        guard !events.isEmpty else { return .noActivity }
        if events.contains(where: {
            ($0.kind == .testFinished || $0.kind == .buildFinished)
                && ($0.state == .failed || $0.state == .interrupted)
        }) {
            return .investigating
        }
        if let latestTree = events.last(where: { $0.kind == .gitWorkingTreeChanged }),
            latestTree.payload["clean"] != "true"
        {
            return .inProgress
        }
        if events.contains(where: { $0.kind == .gitCommitObserved || $0.kind == .buildFinished || $0.kind == .testFinished }) {
            return .completed
        }
        return .observed
    }

    func deterministicSummary(_ packet: ReportEvidencePacket) -> String {
        if let concrete = concreteSummary(packet) { return concrete }

        let activity = packet.activity
        let repositories = activity.repositoryCount
        let hours = counted(activity.activeHours, singular: "clock hour")
        let repositoryCount = counted(repositories, singular: "repository", plural: "repositories")
        let turns = counted(activity.llmTurns, singular: "LLM turn")
        let commits = counted(activity.commits, singular: "commit")
        let files = counted(activity.filesChanged, singular: "committed file")
        let base: String
        switch packet.state {
        case .observed:
            base = "Development evidence was observed, but no completion state was inferred"
        case .inProgress:
            base = "Work remained in progress at the end of the period"
        case .waiting:
            base = "Work was waiting at the end of the period"
        case .investigating:
            base = "The period included investigation after a failed build or test"
        case .completed:
            base = "Detected work reached a completed state during the period"
        case .noActivity:
            return "No development activity was detected during this period."
        }
        return
            "\(base). Evidence spans \(hours) across \(repositoryCount), with \(turns), \(commits), \(files), and +\(activity.additions)/-\(activity.deletions) committed lines."
    }

    private func counted(_ count: Int, singular: String, plural: String? = nil) -> String {
        "\(count) \(count == 1 ? singular : plural ?? singular + "s")"
    }

    private func concreteSummary(_ packet: ReportEvidencePacket) -> String? {
        let userRequests = packet.events.filter {
            $0.kind == .agentMessageObserved
                && $0.messageRole == .user
                && $0.messageExcerpt?.isEmpty == false
        }
        let assistantUpdates = packet.events.filter {
            $0.kind == .agentMessageObserved
                && $0.messageRole == .assistant
                && $0.messageExcerpt?.isEmpty == false
        }
        func intentText(_ event: ReportEventDigest?) -> String? {
            event?.messageExcerpt.map { concise($0, limit: 160) }
        }
        func relatedIntent(to outcome: ReportEventDigest) -> String? {
            let preceding = userRequests.filter { $0.occurredAt <= outcome.occurredAt }
            if let sessionID = outcome.sessionID,
                let match = preceding.last(where: { $0.sessionID == sessionID })
            {
                return intentText(match)
            }
            if let repositoryID = outcome.repositoryID,
                let match = preceding.last(where: { $0.repositoryID == repositoryID })
            {
                return intentText(match)
            }
            return nil
        }
        func withIntent(_ outcome: String, intent: String?) -> String {
            guard let intent else { return outcome }
            return "Requested “\(intent)”. \(outcome)"
        }

        if packet.state == .investigating,
            let failure = packet.events.last(where: {
                ($0.kind == .testFinished || $0.kind == .buildFinished)
                    && ($0.state == .failed || $0.state == .interrupted)
            })
        {
            let subject = failure.payload["suite"] ?? (failure.kind == .testFinished ? "test run" : "build")
            let location = failure.repositoryName.map { " in \($0)" } ?? ""
            return withIntent(
                "Investigating a failed \(concise(subject, limit: 80))\(location).",
                intent: relatedIntent(to: failure)
            )
        }

        if packet.state == .inProgress {
            let latestUserRequest = userRequests.last
            let latestAssistantUpdate = assistantUpdates.last
            let latestDirtyTree = packet.events.last(where: {
                $0.kind == .gitWorkingTreeChanged && $0.payload["clean"] != "true"
            })
            let latestProgress = [latestAssistantUpdate, latestDirtyTree]
                .compactMap { $0 }
                .max { $0.occurredAt < $1.occurredAt }
            if let request = latestUserRequest,
                latestProgress.map({ request.occurredAt > $0.occurredAt }) ?? true
            {
                return withIntent(
                    "No later completion evidence was recorded.",
                    intent: intentText(request)
                )
            }
            if let update = latestAssistantUpdate, let excerpt = update.messageExcerpt {
                let location = update.repositoryName.map { " in \($0)" } ?? ""
                return withIntent(
                    "Work remained in progress\(location). Latest agent update: "
                        + concise(excerpt, limit: 190),
                    intent: relatedIntent(to: update)
                )
            }
            if let dirtyTree = latestDirtyTree {
                let location = dirtyTree.repositoryName.map { " in \($0)" } ?? ""
                return withIntent(
                    "Uncommitted changes remained in progress\(location).",
                    intent: relatedIntent(to: dirtyTree)
                )
            }
        }

        let commits = packet.events.filter { $0.kind == .gitCommitObserved }
        if !commits.isEmpty {
            let highlights = commits.reversed().compactMap { event -> String? in
                guard let message = event.payload["message"], !message.isEmpty else { return nil }
                let title = concise(message, limit: 90)
                return event.repositoryName.map { "“\(title)” in \($0)" } ?? "“\(title)”"
            }
            let repositoryCount = Set(commits.compactMap(\.repositoryID)).count
            let scope =
                repositoryCount == 0
                ? "" : " across \(counted(repositoryCount, singular: "repository", plural: "repositories"))"
            guard !highlights.isEmpty else { return nil }
            guard let latestCommit = commits.last else { return nil }
            if commits.count == 1 {
                return withIntent("Committed \(highlights[0]).", intent: relatedIntent(to: latestCommit))
            }
            return withIntent(
                "Completed \(counted(commits.count, singular: "commit"))\(scope). Latest: \(highlights.prefix(2).joined(separator: "; ")).",
                intent: relatedIntent(to: latestCommit)
            )
        }

        let latestUserRequest = userRequests.last
        let latestAssistantUpdate = assistantUpdates.last
        if let request = latestUserRequest,
            latestAssistantUpdate.map({ request.occurredAt > $0.occurredAt }) ?? true
        {
            return withIntent(
                "No later completion evidence was recorded.",
                intent: intentText(request)
            )
        }
        if let update = latestAssistantUpdate, let excerpt = update.messageExcerpt {
            let location = update.repositoryName.map { " in \($0)" } ?? ""
            if let intent = relatedIntent(to: update) {
                return withIntent(
                    "Latest agent update\(location): " + concise(excerpt, limit: 190),
                    intent: intent
                )
            }
            return "Worked\(location): " + concise(excerpt, limit: 190)
        }
        return nil
    }

    private func concise(_ value: String, limit: Int) -> String {
        let firstLine = value.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? value
        let normalized = firstLine.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return normalized.count <= limit ? normalized : String(normalized.prefix(limit - 1)) + "…"
    }
}

public enum SecretRedactor {
    public static func redact(_ value: String, privatePaths: [String] = []) -> String {
        SensitiveText.redact(value, privatePaths: privatePaths)
    }
}
