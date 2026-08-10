import Foundation

public enum CapabilityState: String, Codable, CaseIterable, Sendable {
    case available
    case permissionDenied = "permission_denied"
    case unsupported
    case degraded
    case notFound = "not_found"
}

public enum AuthenticationState: String, Codable, CaseIterable, Sendable {
    case ready
    case unknown
    case unavailable
    case notInstalled = "not_installed"
}

public struct SourceCapability: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let family: String
    public let surface: String
    public let location: String
    public let adapterVersion: Int
    public let state: CapabilityState
    public let lastProbeAt: Date
    public let lastSuccessfulImportAt: Date?
    public let importedRecordCount: Int
    public let detail: String?

    public init(
        id: String,
        family: String,
        surface: String,
        location: String,
        adapterVersion: Int,
        state: CapabilityState,
        lastProbeAt: Date,
        lastSuccessfulImportAt: Date? = nil,
        importedRecordCount: Int = 0,
        detail: String? = nil
    ) {
        self.id = id
        self.family = family
        self.surface = surface
        self.location = location
        self.adapterVersion = adapterVersion
        self.state = state
        self.lastProbeAt = lastProbeAt
        self.lastSuccessfulImportAt = lastSuccessfulImportAt
        self.importedRecordCount = importedRecordCount
        self.detail = detail
    }
}

public struct GenerationCapability: Codable, Equatable, Sendable, Identifiable {
    public let id: SummaryProviderID
    public let executablePath: String?
    public let cliVersion: String?
    public let authentication: AuthenticationState
    public let structuredOutput: Bool
    public let usageReporting: Bool
    public let hardMonetaryCap: Bool
    public let requestedModel: String
    public let effectiveModelKnown: Bool
    public let invocationContractVersion: String
    public let lastProbeAt: Date
    public let detail: String?

    public init(
        id: SummaryProviderID,
        executablePath: String?,
        cliVersion: String?,
        authentication: AuthenticationState,
        structuredOutput: Bool,
        usageReporting: Bool,
        hardMonetaryCap: Bool,
        requestedModel: String,
        effectiveModelKnown: Bool,
        invocationContractVersion: String,
        lastProbeAt: Date,
        detail: String? = nil
    ) {
        self.id = id
        self.executablePath = executablePath
        self.cliVersion = cliVersion
        self.authentication = authentication
        self.structuredOutput = structuredOutput
        self.usageReporting = usageReporting
        self.hardMonetaryCap = hardMonetaryCap
        self.requestedModel = requestedModel
        self.effectiveModelKnown = effectiveModelKnown
        self.invocationContractVersion = invocationContractVersion
        self.lastProbeAt = lastProbeAt
        self.detail = detail
    }
}

public enum ProviderSelectionMode: String, Codable, CaseIterable, Sendable {
    case automatic
    case codex
    case claude
    case localOnly = "local_only"

    public var explicitProvider: SummaryProviderID? {
        switch self {
        case .codex: .codex
        case .claude: .claude
        case .automatic, .localOnly: nil
        }
    }
}

public struct GenerationBudgets: Codable, Equatable, Sendable {
    /// Conservative allowance for the provider CLI's own fixed system context.
    /// It is added to the locally measured packet estimate before token budgets
    /// are evaluated; actual provider usage replaces the estimate afterward.
    public static let conservativeProviderOverheadTokens = 16_000

    public var maximumInputBytesPerCall: Int
    public var maximumEstimatedInputTokensPerCall: Int
    public var maximumCallsPerDay: Int
    public var dailyTokenLimit: Int
    public var monthlyTokenLimit: Int?
    /// Trackify-owned weekly usage expressed using the provider's published
    /// equivalent credit rate. This remains useful when the provider does not
    /// expose a subscription allowance snapshot.
    public var weeklyCreditLimit: Decimal?
    /// Maximum percentage points of a provider's live weekly allowance that
    /// Trackify may attribute to its own automatic invocations.
    public var weeklyAllowancePercentLimit: Int?
    /// Automatic generation stops before consuming the account's final
    /// allowance. Manual provider use outside Trackify is never attributed to
    /// this budget.
    public var minimumProviderAllowanceRemainingPercent: Int
    /// Conservative output reservation used for preflight credit estimates.
    public var estimatedOutputTokensPerCall: Int
    public var dailyMonetaryLimit: Decimal?
    public var monthlyMonetaryLimit: Decimal?
    public var processDeadlineSeconds: Int

    public init(
        maximumInputBytesPerCall: Int = 256 * 1_024,
        maximumEstimatedInputTokensPerCall: Int = 100_000,
        maximumCallsPerDay: Int = 30,
        dailyTokenLimit: Int = 1_000_000,
        monthlyTokenLimit: Int? = 20_000_000,
        weeklyCreditLimit: Decimal? = 500,
        weeklyAllowancePercentLimit: Int? = 3,
        minimumProviderAllowanceRemainingPercent: Int = 5,
        estimatedOutputTokensPerCall: Int = 2_000,
        dailyMonetaryLimit: Decimal? = nil,
        monthlyMonetaryLimit: Decimal? = nil,
        processDeadlineSeconds: Int = 180
    ) {
        self.maximumInputBytesPerCall = maximumInputBytesPerCall
        self.maximumEstimatedInputTokensPerCall = maximumEstimatedInputTokensPerCall
        self.maximumCallsPerDay = maximumCallsPerDay
        self.dailyTokenLimit = dailyTokenLimit
        self.monthlyTokenLimit = monthlyTokenLimit
        self.weeklyCreditLimit = weeklyCreditLimit
        self.weeklyAllowancePercentLimit = weeklyAllowancePercentLimit
        self.minimumProviderAllowanceRemainingPercent = minimumProviderAllowanceRemainingPercent
        self.estimatedOutputTokensPerCall = estimatedOutputTokensPerCall
        self.dailyMonetaryLimit = dailyMonetaryLimit
        self.monthlyMonetaryLimit = monthlyMonetaryLimit
        self.processDeadlineSeconds = processDeadlineSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case maximumInputBytesPerCall
        case maximumEstimatedInputTokensPerCall
        case maximumCallsPerDay
        case dailyTokenLimit
        case monthlyTokenLimit
        case weeklyCreditLimit
        case weeklyAllowancePercentLimit
        case minimumProviderAllowanceRemainingPercent
        case estimatedOutputTokensPerCall
        case dailyMonetaryLimit
        case monthlyMonetaryLimit
        case processDeadlineSeconds
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        let modern = GenerationBudgets()
        if version < 2 {
            // V1's defaults were sized for synthetic provider tests and caused
            // ordinary summaries to fall back after only a few calls. Migrate
            // the entire policy once instead of carrying those accidental
            // product limits forward indefinitely.
            self = modern
            return
        }
        maximumInputBytesPerCall =
            try values.decodeIfPresent(
                Int.self, forKey: .maximumInputBytesPerCall) ?? modern.maximumInputBytesPerCall
        maximumEstimatedInputTokensPerCall =
            try values.decodeIfPresent(
                Int.self, forKey: .maximumEstimatedInputTokensPerCall)
            ?? modern.maximumEstimatedInputTokensPerCall
        maximumCallsPerDay =
            try values.decodeIfPresent(
                Int.self, forKey: .maximumCallsPerDay) ?? modern.maximumCallsPerDay
        dailyTokenLimit =
            try values.decodeIfPresent(
                Int.self, forKey: .dailyTokenLimit) ?? modern.dailyTokenLimit
        monthlyTokenLimit =
            values.contains(.monthlyTokenLimit)
            ? try values.decodeIfPresent(Int.self, forKey: .monthlyTokenLimit)
            : modern.monthlyTokenLimit
        weeklyCreditLimit =
            values.contains(.weeklyCreditLimit)
            ? try values.decodeIfPresent(Decimal.self, forKey: .weeklyCreditLimit)
            : modern.weeklyCreditLimit
        weeklyAllowancePercentLimit =
            values.contains(.weeklyAllowancePercentLimit)
            ? try values.decodeIfPresent(Int.self, forKey: .weeklyAllowancePercentLimit)
            : modern.weeklyAllowancePercentLimit
        minimumProviderAllowanceRemainingPercent =
            try values.decodeIfPresent(
                Int.self, forKey: .minimumProviderAllowanceRemainingPercent)
            ?? modern.minimumProviderAllowanceRemainingPercent
        estimatedOutputTokensPerCall =
            try values.decodeIfPresent(
                Int.self, forKey: .estimatedOutputTokensPerCall)
            ?? modern.estimatedOutputTokensPerCall
        dailyMonetaryLimit = try values.decodeIfPresent(
            Decimal.self, forKey: .dailyMonetaryLimit)
        monthlyMonetaryLimit = try values.decodeIfPresent(
            Decimal.self, forKey: .monthlyMonetaryLimit)
        processDeadlineSeconds =
            try values.decodeIfPresent(
                Int.self, forKey: .processDeadlineSeconds) ?? modern.processDeadlineSeconds
        self = normalized()
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(2, forKey: .version)
        try values.encode(maximumInputBytesPerCall, forKey: .maximumInputBytesPerCall)
        try values.encode(maximumEstimatedInputTokensPerCall, forKey: .maximumEstimatedInputTokensPerCall)
        try values.encode(maximumCallsPerDay, forKey: .maximumCallsPerDay)
        try values.encode(dailyTokenLimit, forKey: .dailyTokenLimit)
        try values.encodeIfPresent(monthlyTokenLimit, forKey: .monthlyTokenLimit)
        try values.encodeIfPresent(weeklyCreditLimit, forKey: .weeklyCreditLimit)
        try values.encodeIfPresent(weeklyAllowancePercentLimit, forKey: .weeklyAllowancePercentLimit)
        try values.encode(
            minimumProviderAllowanceRemainingPercent,
            forKey: .minimumProviderAllowanceRemainingPercent)
        try values.encode(estimatedOutputTokensPerCall, forKey: .estimatedOutputTokensPerCall)
        try values.encodeIfPresent(dailyMonetaryLimit, forKey: .dailyMonetaryLimit)
        try values.encodeIfPresent(monthlyMonetaryLimit, forKey: .monthlyMonetaryLimit)
        try values.encode(processDeadlineSeconds, forKey: .processDeadlineSeconds)
    }

    public func normalized() -> GenerationBudgets {
        GenerationBudgets(
            maximumInputBytesPerCall: min(max(maximumInputBytesPerCall, 4 * 1_024), 1_024 * 1_024),
            maximumEstimatedInputTokensPerCall: min(
                max(maximumEstimatedInputTokensPerCall, Self.conservativeProviderOverheadTokens),
                500_000),
            maximumCallsPerDay: min(max(maximumCallsPerDay, 1), 96),
            dailyTokenLimit: min(max(dailyTokenLimit, 50_000), 20_000_000),
            monthlyTokenLimit: monthlyTokenLimit.map { min(max($0, 1_000_000), 100_000_000) },
            weeklyCreditLimit: weeklyCreditLimit.map { min(max($0, 10), 10_000) },
            weeklyAllowancePercentLimit: weeklyAllowancePercentLimit.map { min(max($0, 1), 20) },
            minimumProviderAllowanceRemainingPercent: min(
                max(minimumProviderAllowanceRemainingPercent, 0), 25),
            estimatedOutputTokensPerCall: min(max(estimatedOutputTokensPerCall, 100), 20_000),
            dailyMonetaryLimit: dailyMonetaryLimit,
            monthlyMonetaryLimit: monthlyMonetaryLimit,
            processDeadlineSeconds: min(max(processDeadlineSeconds, 15), 600))
    }
}

public enum RecipeCadence: String, Codable, CaseIterable, Sendable {
    case hourly
    case daily
    case onDemand = "on_demand"
}

public enum RecipeOutputFormat: String, Codable, CaseIterable, Sendable {
    case plainText = "plain_text"
    case markdown
    case structuredJSON = "structured_json"
}

public enum PrivacyProfile: String, Codable, CaseIterable, Sendable {
    case `private`
    case team
    case client
    case `public`
}

public struct ReportRecipe: Codable, Equatable, Sendable, Identifiable {
    public let id: RecipeID
    public let currentVersionID: RecipeVersionID
    public let name: String
    public let isBuiltIn: Bool
    public let isEnabled: Bool

    public init(
        id: RecipeID,
        currentVersionID: RecipeVersionID,
        name: String,
        isBuiltIn: Bool,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.currentVersionID = currentVersionID
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.isEnabled = isEnabled
    }
}

public struct ReportRecipeVersion: Codable, Equatable, Sendable, Identifiable {
    public let id: RecipeVersionID
    public let recipeID: RecipeID
    public let version: Int
    public let purpose: String
    public let audience: String
    public let cadence: RecipeCadence
    public let repositoryIDs: [RepositoryID]
    public let groupNames: [String]
    public let customFocus: String?
    public let tone: String
    public let outputFormat: RecipeOutputFormat
    public let maximumCharacters: Int
    public let privacyProfile: PrivacyProfile
    public let providerModeOverride: ProviderSelectionMode?
    public let createdAt: Date

    public init(
        id: RecipeVersionID,
        recipeID: RecipeID,
        version: Int,
        purpose: String,
        audience: String,
        cadence: RecipeCadence,
        repositoryIDs: [RepositoryID] = [],
        groupNames: [String] = [],
        customFocus: String? = nil,
        tone: String = "concise and factual",
        outputFormat: RecipeOutputFormat = .plainText,
        maximumCharacters: Int = 2_000,
        privacyProfile: PrivacyProfile = .private,
        providerModeOverride: ProviderSelectionMode? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.recipeID = recipeID
        self.version = version
        self.purpose = purpose
        self.audience = audience
        self.cadence = cadence
        self.repositoryIDs = repositoryIDs
        self.groupNames = groupNames
        self.customFocus = customFocus
        self.tone = tone
        self.outputFormat = outputFormat
        self.maximumCharacters = maximumCharacters
        self.privacyProfile = privacyProfile
        self.providerModeOverride = providerModeOverride
        self.createdAt = createdAt
    }
}

/// The complete, immutable configuration used for one generation. A run keeps
/// this snapshot even when its template is edited later.
public struct ReportRunConfiguration: Codable, Equatable, Sendable {
    public let purpose: String
    public let audience: String
    public let repositoryIDs: [RepositoryID]
    public let groupNames: [String]
    public let customFocus: String?
    public let tone: String
    public let outputFormat: RecipeOutputFormat
    public let maximumCharacters: Int
    public let privacyProfile: PrivacyProfile
    public let providerModeOverride: ProviderSelectionMode?

    public init(
        purpose: String,
        audience: String,
        repositoryIDs: [RepositoryID] = [],
        groupNames: [String] = [],
        customFocus: String? = nil,
        tone: String,
        outputFormat: RecipeOutputFormat,
        maximumCharacters: Int,
        privacyProfile: PrivacyProfile,
        providerModeOverride: ProviderSelectionMode? = nil
    ) {
        self.purpose = purpose
        self.audience = audience
        self.repositoryIDs = repositoryIDs
        self.groupNames = groupNames
        self.customFocus = customFocus
        self.tone = tone
        self.outputFormat = outputFormat
        self.maximumCharacters = maximumCharacters
        self.privacyProfile = privacyProfile
        self.providerModeOverride = providerModeOverride
    }

    public init(recipe: ReportRecipeVersion) {
        self.init(
            purpose: recipe.purpose, audience: recipe.audience,
            repositoryIDs: recipe.repositoryIDs, groupNames: recipe.groupNames,
            customFocus: recipe.customFocus, tone: recipe.tone,
            outputFormat: recipe.outputFormat, maximumCharacters: recipe.maximumCharacters,
            privacyProfile: recipe.privacyProfile,
            providerModeOverride: recipe.providerModeOverride)
    }

    public func recipeVersion(basedOn recipe: ReportRecipeVersion) -> ReportRecipeVersion {
        ReportRecipeVersion(
            id: recipe.id, recipeID: recipe.recipeID, version: recipe.version,
            purpose: purpose, audience: audience, cadence: recipe.cadence,
            repositoryIDs: repositoryIDs, groupNames: groupNames,
            customFocus: customFocus, tone: tone, outputFormat: outputFormat,
            maximumCharacters: maximumCharacters, privacyProfile: privacyProfile,
            providerModeOverride: providerModeOverride, createdAt: recipe.createdAt)
    }
}

public struct ReportTemplate: Codable, Equatable, Sendable, Identifiable {
    public let recipe: ReportRecipe
    public let version: ReportRecipeVersion

    public init(recipe: ReportRecipe, version: ReportRecipeVersion) {
        self.recipe = recipe
        self.version = version
    }

    public var id: RecipeID { recipe.id }
}

public struct ReportTemplateDraft: Codable, Equatable, Sendable {
    public var name: String
    public var purpose: String
    public var audience: String
    public var cadence: RecipeCadence
    public var repositoryIDs: [RepositoryID]
    public var groupNames: [String]
    public var customFocus: String?
    public var tone: String
    public var outputFormat: RecipeOutputFormat
    public var maximumCharacters: Int
    public var privacyProfile: PrivacyProfile
    public var providerModeOverride: ProviderSelectionMode?

    public init(template: ReportTemplate, name: String? = nil) {
        self.name = name ?? template.recipe.name
        purpose = template.version.purpose
        audience = template.version.audience
        cadence = template.version.cadence
        repositoryIDs = template.version.repositoryIDs
        groupNames = template.version.groupNames
        customFocus = template.version.customFocus
        tone = template.version.tone
        outputFormat = template.version.outputFormat
        maximumCharacters = template.version.maximumCharacters
        privacyProfile = template.version.privacyProfile
        providerModeOverride = template.version.providerModeOverride
    }

    public var runConfiguration: ReportRunConfiguration {
        ReportRunConfiguration(
            purpose: purpose, audience: audience, repositoryIDs: repositoryIDs,
            groupNames: groupNames, customFocus: customFocus, tone: tone,
            outputFormat: outputFormat, maximumCharacters: maximumCharacters,
            privacyProfile: privacyProfile, providerModeOverride: providerModeOverride)
    }
}

public enum ReportScheduleCadence: String, Codable, CaseIterable, Sendable {
    case hourly
    case daily
}

public struct ReportSchedule: Codable, Equatable, Sendable, Identifiable {
    public let id: ReportScheduleID
    public let name: String
    public let recipeID: RecipeID
    public let cadence: ReportScheduleCadence
    public let repositoryIDs: [RepositoryID]
    public let groupNames: [String]
    public let providerModeOverride: ProviderSelectionMode?
    public let isEnabled: Bool
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: ReportScheduleID,
        name: String,
        recipeID: RecipeID,
        cadence: ReportScheduleCadence,
        repositoryIDs: [RepositoryID] = [],
        groupNames: [String] = [],
        providerModeOverride: ProviderSelectionMode? = nil,
        isEnabled: Bool = true,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.recipeID = recipeID
        self.cadence = cadence
        self.repositoryIDs = repositoryIDs
        self.groupNames = groupNames
        self.providerModeOverride = providerModeOverride
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ReportScheduleDraft: Codable, Equatable, Sendable {
    public var name: String
    public var recipeID: RecipeID
    public var cadence: ReportScheduleCadence
    public var repositoryIDs: [RepositoryID]
    public var groupNames: [String]
    public var providerModeOverride: ProviderSelectionMode?
    public var isEnabled: Bool

    public init(
        name: String,
        recipeID: RecipeID,
        cadence: ReportScheduleCadence,
        repositoryIDs: [RepositoryID] = [],
        groupNames: [String] = [],
        providerModeOverride: ProviderSelectionMode? = nil,
        isEnabled: Bool = true
    ) {
        self.name = name
        self.recipeID = recipeID
        self.cadence = cadence
        self.repositoryIDs = repositoryIDs
        self.groupNames = groupNames
        self.providerModeOverride = providerModeOverride
        self.isEnabled = isEnabled
    }

    public init(schedule: ReportSchedule) {
        self.init(
            name: schedule.name, recipeID: schedule.recipeID, cadence: schedule.cadence,
            repositoryIDs: schedule.repositoryIDs, groupNames: schedule.groupNames,
            providerModeOverride: schedule.providerModeOverride, isEnabled: schedule.isEnabled)
    }
}

public enum RecipeValidationError: Error, Equatable, LocalizedError {
    case focusTooLong
    case unsafeInstruction(String)
    case invalidMaximumCharacters

    public var errorDescription: String? {
        switch self {
        case .focusTooLong: "Custom focus must be 1,000 characters or fewer."
        case .unsafeInstruction(let phrase):
            "Custom focus cannot weaken Trackify's evidence or privacy policy (matched: \(phrase))."
        case .invalidMaximumCharacters: "Maximum output length must be between 100 and 2,000 characters."
        }
    }
}

public enum ReportRecipeValidator {
    public static func customFocus(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 1_000 else { throw RecipeValidationError.focusTooLong }
        let prohibited = [
            "ignore previous", "ignore the policy", "use tools", "read files",
            "read credentials", "show credentials", "full transcript", "raw transcript",
            "system prompt", "execute command", "run command", "disable redaction",
        ]
        let lowercased = value.lowercased()
        if let phrase = prohibited.first(where: lowercased.contains) {
            throw RecipeValidationError.unsafeInstruction(phrase)
        }
        return SensitiveText.redact(value)
    }
}

public enum ReportRunIntent: String, Codable, CaseIterable, Sendable {
    case scheduled
    case onDemand = "on_demand"
    case backfill
    case providerTest = "provider_test"
}

public enum ReportRunState: String, Codable, CaseIterable, Sendable {
    case pending
    case running
    case succeeded
    case fallback
    case cancelled
    case timedOut = "timed_out"
    case failed
}

public enum GenerationFailureClass: String, Codable, CaseIterable, Sendable {
    case unavailable
    case authentication
    case rateLimited = "rate_limited"
    case invalidResponse = "invalid_response"
    case timeout
    case cancelled
    case budget
    case process
    case unknown
}

public enum CostKind: String, Codable, CaseIterable, Sendable {
    case providerEstimate = "provider_estimate"
    case equivalentAPIEstimate = "equivalent_api_estimate"
    case includedSubscription = "included_subscription"
    case contractOrGatewayUnknown = "contract_or_gateway_unknown"
    case unknown
}

public struct ProviderUsage: Codable, Equatable, Sendable {
    public let inputTokens: Int?
    public let cachedInputTokens: Int?
    public let outputTokens: Int?
    public let reasoningTokens: Int?
    public let cost: Decimal?
    public let currency: String?
    public let costKind: CostKind
    public let billingContext: String?

    public init(
        inputTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        outputTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        cost: Decimal? = nil,
        currency: String? = nil,
        costKind: CostKind = .unknown,
        billingContext: String? = nil
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cost = cost
        self.currency = currency
        self.costKind = costKind
        self.billingContext = billingContext
    }

    public var knownTokenTotal: Int? {
        let values = [inputTokens, cachedInputTokens, outputTokens, reasoningTokens].compactMap { $0 }
        return values.isEmpty ? nil : values.reduce(0, +)
    }
}

public struct ReportRun: Codable, Equatable, Sendable, Identifiable {
    public let id: ReportRunID
    public let recipeID: RecipeID
    public let recipeVersionID: RecipeVersionID
    public let periodStart: Date
    public let periodEnd: Date
    public let intent: ReportRunIntent
    public let selectionMode: ProviderSelectionMode
    public let requestedProvider: SummaryProviderID?
    public let requestedModel: String?
    public let effectiveProvider: SummaryProviderID?
    public let effectiveModel: String?
    public let compilerVersion: String
    public let promptVersion: String
    public let invocationVersion: String?
    public let outputSchemaVersion: String
    public let inputBytes: Int?
    public let estimatedInputTokens: Int?
    public let usage: ProviderUsage
    public let queuedAt: Date
    public let startedAt: Date?
    public let finishedAt: Date?
    public let state: ReportRunState
    public let failureClass: GenerationFailureClass?
    public let failureDetail: String?
    public let artifactID: ArtifactID?
    public let configuration: ReportRunConfiguration?
    public let scheduleID: ReportScheduleID?

    public init(
        id: ReportRunID,
        recipeID: RecipeID,
        recipeVersionID: RecipeVersionID,
        periodStart: Date,
        periodEnd: Date,
        intent: ReportRunIntent,
        selectionMode: ProviderSelectionMode,
        requestedProvider: SummaryProviderID? = nil,
        requestedModel: String? = nil,
        effectiveProvider: SummaryProviderID? = nil,
        effectiveModel: String? = nil,
        compilerVersion: String,
        promptVersion: String,
        invocationVersion: String? = nil,
        outputSchemaVersion: String,
        inputBytes: Int? = nil,
        estimatedInputTokens: Int? = nil,
        usage: ProviderUsage = ProviderUsage(),
        queuedAt: Date,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        state: ReportRunState,
        failureClass: GenerationFailureClass? = nil,
        failureDetail: String? = nil,
        artifactID: ArtifactID? = nil,
        configuration: ReportRunConfiguration? = nil,
        scheduleID: ReportScheduleID? = nil
    ) {
        self.id = id
        self.recipeID = recipeID
        self.recipeVersionID = recipeVersionID
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.intent = intent
        self.selectionMode = selectionMode
        self.requestedProvider = requestedProvider
        self.requestedModel = requestedModel
        self.effectiveProvider = effectiveProvider
        self.effectiveModel = effectiveModel
        self.compilerVersion = compilerVersion
        self.promptVersion = promptVersion
        self.invocationVersion = invocationVersion
        self.outputSchemaVersion = outputSchemaVersion
        self.inputBytes = inputBytes
        self.estimatedInputTokens = estimatedInputTokens
        self.usage = usage
        self.queuedAt = queuedAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.state = state
        self.failureClass = failureClass
        self.failureDetail = failureDetail
        self.artifactID = artifactID
        self.configuration = configuration
        self.scheduleID = scheduleID
    }

    public var queueDuration: TimeInterval? { startedAt?.timeIntervalSince(queuedAt) }
    public var executionDuration: TimeInterval? {
        guard let startedAt, let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }
    public var totalDuration: TimeInterval? { finishedAt?.timeIntervalSince(queuedAt) }
}

public enum ArtifactType: String, Codable, CaseIterable, Sendable {
    case report
    case providerTest = "provider_test"
}

public struct Artifact: Codable, Equatable, Sendable, Identifiable {
    public let id: ArtifactID
    public let type: ArtifactType
    public let format: RecipeOutputFormat
    public let createdAt: Date
    public let recipeID: RecipeID
    public let recipeVersionID: RecipeVersionID
    public let reportRunID: ReportRunID?
    public let legacyReportID: ReportID?
    public let periodStart: Date
    public let periodEnd: Date
    public let repositoryIDs: [RepositoryID]
    public let groupNames: [String]
    public let privacyProfile: PrivacyProfile
    public let state: ReportPeriodState
    public let content: String
    public let evidenceIDs: [EvidenceID]
    public let revision: Int
    public let revisesArtifactID: ArtifactID?

    public init(
        id: ArtifactID,
        type: ArtifactType,
        format: RecipeOutputFormat,
        createdAt: Date,
        recipeID: RecipeID,
        recipeVersionID: RecipeVersionID,
        reportRunID: ReportRunID? = nil,
        legacyReportID: ReportID? = nil,
        periodStart: Date,
        periodEnd: Date,
        repositoryIDs: [RepositoryID] = [],
        groupNames: [String] = [],
        privacyProfile: PrivacyProfile,
        state: ReportPeriodState,
        content: String,
        evidenceIDs: [EvidenceID],
        revision: Int,
        revisesArtifactID: ArtifactID? = nil
    ) {
        self.id = id
        self.type = type
        self.format = format
        self.createdAt = createdAt
        self.recipeID = recipeID
        self.recipeVersionID = recipeVersionID
        self.reportRunID = reportRunID
        self.legacyReportID = legacyReportID
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.repositoryIDs = repositoryIDs
        self.groupNames = groupNames
        self.privacyProfile = privacyProfile
        self.state = state
        self.content = content
        self.evidenceIDs = evidenceIDs
        self.revision = revision
        self.revisesArtifactID = revisesArtifactID
    }
}

public enum DestinationKind: String, Codable, CaseIterable, Sendable {
    case clipboard
    case markdownFile = "markdown_file"
    case jsonFile = "json_file"
    case mock
}

public enum DeliveryPermission: String, Codable, CaseIterable, Sendable {
    case local
    case approved
    case denied
}

public struct Destination: Codable, Equatable, Sendable, Identifiable {
    public let id: DestinationID
    public let kind: DestinationKind
    public let name: String
    public let privacyProfile: PrivacyProfile
    public let permission: DeliveryPermission
    public let configuration: [String: String]
    public let isEnabled: Bool

    public init(
        id: DestinationID,
        kind: DestinationKind,
        name: String,
        privacyProfile: PrivacyProfile,
        permission: DeliveryPermission,
        configuration: [String: String] = [:],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.privacyProfile = privacyProfile
        self.permission = permission
        self.configuration = configuration
        self.isEnabled = isEnabled
    }
}

public enum DeliveryState: String, Codable, CaseIterable, Sendable {
    case pending
    case delivered
    case failed
    case cancelled
}

public struct DeliveryAttempt: Codable, Equatable, Sendable, Identifiable {
    public let id: DeliveryAttemptID
    public let artifactID: ArtifactID
    public let destinationID: DestinationID
    public let idempotencyKey: String
    public let state: DeliveryState
    public let attemptedAt: Date
    public let finishedAt: Date?
    public let retryCount: Int
    public let externalIdentifier: String?
    public let failureDetail: String?

    public init(
        id: DeliveryAttemptID,
        artifactID: ArtifactID,
        destinationID: DestinationID,
        idempotencyKey: String,
        state: DeliveryState,
        attemptedAt: Date,
        finishedAt: Date? = nil,
        retryCount: Int = 0,
        externalIdentifier: String? = nil,
        failureDetail: String? = nil
    ) {
        self.id = id
        self.artifactID = artifactID
        self.destinationID = destinationID
        self.idempotencyKey = idempotencyKey
        self.state = state
        self.attemptedAt = attemptedAt
        self.finishedAt = finishedAt
        self.retryCount = retryCount
        self.externalIdentifier = externalIdentifier
        self.failureDetail = failureDetail
    }
}

public struct UsageSummary: Codable, Equatable, Sendable {
    public let runs: Int
    public let succeeded: Int
    public let failed: Int
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int
    public let reasoningTokens: Int
    public let durationSeconds: Double
    public let knownCost: Decimal
    public let currency: String?
    public let hasUnknownCost: Bool

    public init(
        runs: Int,
        succeeded: Int,
        failed: Int,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        reasoningTokens: Int,
        durationSeconds: Double,
        knownCost: Decimal,
        currency: String?,
        hasUnknownCost: Bool
    ) {
        self.runs = runs
        self.succeeded = succeeded
        self.failed = failed
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.durationSeconds = durationSeconds
        self.knownCost = knownCost
        self.currency = currency
        self.hasUnknownCost = hasUnknownCost
    }
}

public struct WorkIntelligenceCounts: Codable, Equatable, Sendable {
    public let recipes: Int
    public let schedules: Int
    public let runs: Int
    public let pendingRuns: Int
    public let runningRuns: Int
    public let failedRuns: Int
    public let artifacts: Int
    public let deliveryAttempts: Int

    public init(
        recipes: Int,
        schedules: Int = 0,
        runs: Int,
        pendingRuns: Int,
        runningRuns: Int,
        failedRuns: Int,
        artifacts: Int,
        deliveryAttempts: Int
    ) {
        self.recipes = recipes
        self.schedules = schedules
        self.runs = runs
        self.pendingRuns = pendingRuns
        self.runningRuns = runningRuns
        self.failedRuns = failedRuns
        self.artifacts = artifacts
        self.deliveryAttempts = deliveryAttempts
    }
}
