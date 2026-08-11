import Foundation

public enum WorkSummaryKind: String, Codable, CaseIterable, Sendable {
    case segment
    case current
    case day
}

public enum SummaryGenerationSource: String, Codable, CaseIterable, Sendable {
    case local
    case codex
    case claude
    case migrated

    public init(provider: SummaryProviderID?) {
        switch provider {
        case .codex: self = .codex
        case .claude: self = .claude
        case nil: self = .local
        }
    }
}

public struct SummaryProjectSection: Codable, Equatable, Sendable {
    public let project: String
    public let narrative: String
    public let intents: [String]
    public let outcomes: [String]
    public let openWork: [String]
    public let blockers: [String]

    public init(
        project: String,
        narrative: String,
        intents: [String] = [],
        outcomes: [String] = [],
        openWork: [String] = [],
        blockers: [String] = []
    ) {
        self.project = project
        self.narrative = narrative
        self.intents = intents
        self.outcomes = outcomes
        self.openWork = openWork
        self.blockers = blockers
    }
}

public struct SummaryContent: Codable, Equatable, Sendable {
    public let narrative: String
    public let compactNarrative: String
    public let projects: [String]
    public let projectSections: [SummaryProjectSection]
    public let intents: [String]
    public let outcomes: [String]
    public let openWork: [String]
    public let blockers: [String]
    public let topics: [String]

    public init(
        narrative: String,
        compactNarrative: String? = nil,
        projects: [String] = [],
        projectSections: [SummaryProjectSection] = [],
        intents: [String] = [],
        outcomes: [String] = [],
        openWork: [String] = [],
        blockers: [String] = [],
        topics: [String] = []
    ) {
        self.narrative = narrative
        self.compactNarrative = compactNarrative ?? narrative
        self.projects = projects
        self.projectSections = projectSections
        self.intents = intents
        self.outcomes = outcomes
        self.openWork = openWork
        self.blockers = blockers
        self.topics = topics
    }

    private enum CodingKeys: String, CodingKey {
        case narrative, compactNarrative, projects, projectSections
        case intents, outcomes, openWork, blockers, topics
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        narrative = try values.decode(String.self, forKey: .narrative)
        compactNarrative = try values.decodeIfPresent(String.self, forKey: .compactNarrative) ?? narrative
        projects = try values.decodeIfPresent([String].self, forKey: .projects) ?? []
        projectSections =
            try values.decodeIfPresent(
                [SummaryProjectSection].self, forKey: .projectSections) ?? []
        intents = try values.decodeIfPresent([String].self, forKey: .intents) ?? []
        outcomes = try values.decodeIfPresent([String].self, forKey: .outcomes) ?? []
        openWork = try values.decodeIfPresent([String].self, forKey: .openWork) ?? []
        blockers = try values.decodeIfPresent([String].self, forKey: .blockers) ?? []
        topics = try values.decodeIfPresent([String].self, forKey: .topics) ?? []
    }
}

public struct SummaryStatistics: Codable, Equatable, Sendable {
    public let activeHours: Int
    public let llmTurns: Int
    public let conversationMessages: Int
    public let commits: Int
    public let additions: Int
    public let deletions: Int
    public let filesChanged: Int
    public let repositoryIDs: [RepositoryID]
    public let evidenceCount: Int

    public init(
        activeHours: Int = 0,
        llmTurns: Int = 0,
        conversationMessages: Int = 0,
        commits: Int = 0,
        additions: Int = 0,
        deletions: Int = 0,
        filesChanged: Int = 0,
        repositoryIDs: [RepositoryID] = [],
        evidenceCount: Int = 0
    ) {
        self.activeHours = activeHours
        self.llmTurns = llmTurns
        self.conversationMessages = conversationMessages
        self.commits = commits
        self.additions = additions
        self.deletions = deletions
        self.filesChanged = filesChanged
        self.repositoryIDs = repositoryIDs
        self.evidenceCount = evidenceCount
    }
}

public struct SummaryCoverage: Codable, Equatable, Sendable {
    public let eligibleEventCount: Int
    public let coveredEventCount: Int
    public let truncatedAssistantCount: Int
    public let chunkCount: Int
    public let isKnown: Bool

    public init(
        eligibleEventCount: Int,
        coveredEventCount: Int,
        truncatedAssistantCount: Int = 0,
        chunkCount: Int = 1,
        isKnown: Bool = true
    ) {
        self.eligibleEventCount = eligibleEventCount
        self.coveredEventCount = coveredEventCount
        self.truncatedAssistantCount = truncatedAssistantCount
        self.chunkCount = chunkCount
        self.isKnown = isKnown
    }

    public var isComplete: Bool {
        isKnown && eligibleEventCount == coveredEventCount
    }

    public static let migratedUnknown = SummaryCoverage(
        eligibleEventCount: 0,
        coveredEventCount: 0,
        chunkCount: 1,
        isKnown: false)
}

public struct WorkSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: SummaryID
    public let kind: WorkSummaryKind
    public let periodStart: Date
    public let periodEnd: Date
    public let generatedAt: Date
    public let state: ReportPeriodState
    public let content: SummaryContent
    public let statistics: SummaryStatistics
    public let evidenceIDs: [EvidenceID]
    public let childSummaryIDs: [SummaryID]
    public let generationSource: SummaryGenerationSource
    public let provider: SummaryProviderID?
    public let model: String?
    public let generatorVersion: String
    public let promptVersion: String
    public let schemaVersion: String
    public let sourceFingerprint: String
    public let coverage: SummaryCoverage
    public let revision: Int
    public let revisesSummaryID: SummaryID?

    public init(
        id: SummaryID,
        kind: WorkSummaryKind,
        periodStart: Date,
        periodEnd: Date,
        generatedAt: Date,
        state: ReportPeriodState,
        content: SummaryContent,
        statistics: SummaryStatistics = SummaryStatistics(),
        evidenceIDs: [EvidenceID] = [],
        childSummaryIDs: [SummaryID] = [],
        generationSource: SummaryGenerationSource,
        provider: SummaryProviderID? = nil,
        model: String? = nil,
        generatorVersion: String,
        promptVersion: String,
        schemaVersion: String,
        sourceFingerprint: String,
        coverage: SummaryCoverage,
        revision: Int,
        revisesSummaryID: SummaryID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.generatedAt = generatedAt
        self.state = state
        self.content = content
        self.statistics = statistics
        self.evidenceIDs = evidenceIDs
        self.childSummaryIDs = childSummaryIDs
        self.generationSource = generationSource
        self.provider = provider
        self.model = model
        self.generatorVersion = generatorVersion
        self.promptVersion = promptVersion
        self.schemaVersion = schemaVersion
        self.sourceFingerprint = sourceFingerprint
        self.coverage = coverage
        self.revision = revision
        self.revisesSummaryID = revisesSummaryID
    }
}

public struct SummaryRun: Codable, Equatable, Sendable, Identifiable {
    public let id: SummaryRunID
    public let kind: WorkSummaryKind
    public let periodStart: Date
    public let periodEnd: Date
    public let selectionMode: ProviderSelectionMode
    public let requestedProvider: SummaryProviderID?
    public let requestedModel: String?
    public let effectiveProvider: SummaryProviderID?
    public let effectiveModel: String?
    public let sourceFingerprint: String
    public let inputBytes: Int
    public let estimatedInputTokens: Int
    public let usage: ProviderUsage
    public let queuedAt: Date
    public let startedAt: Date?
    public let finishedAt: Date?
    public let state: ReportRunState
    public let failureClass: GenerationFailureClass?
    public let failureDetail: String?
    public let summaryID: SummaryID?

    public init(
        id: SummaryRunID,
        kind: WorkSummaryKind,
        periodStart: Date,
        periodEnd: Date,
        selectionMode: ProviderSelectionMode,
        requestedProvider: SummaryProviderID? = nil,
        requestedModel: String? = nil,
        effectiveProvider: SummaryProviderID? = nil,
        effectiveModel: String? = nil,
        sourceFingerprint: String,
        inputBytes: Int = 0,
        estimatedInputTokens: Int = 0,
        usage: ProviderUsage = ProviderUsage(),
        queuedAt: Date,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        state: ReportRunState,
        failureClass: GenerationFailureClass? = nil,
        failureDetail: String? = nil,
        summaryID: SummaryID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.selectionMode = selectionMode
        self.requestedProvider = requestedProvider
        self.requestedModel = requestedModel
        self.effectiveProvider = effectiveProvider
        self.effectiveModel = effectiveModel
        self.sourceFingerprint = sourceFingerprint
        self.inputBytes = inputBytes
        self.estimatedInputTokens = estimatedInputTokens
        self.usage = usage
        self.queuedAt = queuedAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.state = state
        self.failureClass = failureClass
        self.failureDetail = failureDetail
        self.summaryID = summaryID
    }
}
