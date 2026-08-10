import Foundation

public enum SummaryProviderID: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
}

public struct TrackifySettings: Codable, Equatable, Sendable {
    /// Kept for decoding V1 settings. New code uses `providerSelection`.
    public var summaryProvider: SummaryProviderID?
    public var providerSelection: ProviderSelectionMode
    public var generationBudgets: GenerationBudgets
    public var automaticSummariesUseLLM: Bool
    public var movingAverageActiveDays: Int
    public var automaticUpdateChecks: Bool
    public var collectionPaused: Bool
    public var launchAtLoginEnabled: Bool?

    public init(
        summaryProvider: SummaryProviderID? = nil,
        providerSelection: ProviderSelectionMode? = nil,
        generationBudgets: GenerationBudgets = GenerationBudgets(),
        automaticSummariesUseLLM: Bool = false,
        movingAverageActiveDays: Int = 14,
        automaticUpdateChecks: Bool = true,
        collectionPaused: Bool = false,
        launchAtLoginEnabled: Bool? = nil
    ) {
        self.summaryProvider = summaryProvider
        self.providerSelection =
            providerSelection ?? summaryProvider.map {
                $0 == .codex ? .codex : .claude
            } ?? .automatic
        self.generationBudgets = generationBudgets
        self.automaticSummariesUseLLM = automaticSummariesUseLLM
        self.movingAverageActiveDays = movingAverageActiveDays
        self.automaticUpdateChecks = automaticUpdateChecks
        self.collectionPaused = collectionPaused
        self.launchAtLoginEnabled = launchAtLoginEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case summaryProvider
        case providerSelection
        case generationBudgets
        case automaticSummariesUseLLM
        /// Decode-only compatibility with builds before canonical summaries.
        case scheduledModelReportsEnabled
        case movingAverageActiveDays
        case automaticUpdateChecks
        case collectionPaused
        case launchAtLoginEnabled
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        summaryProvider = try values.decodeIfPresent(SummaryProviderID.self, forKey: .summaryProvider)
        providerSelection =
            try values.decodeIfPresent(ProviderSelectionMode.self, forKey: .providerSelection)
            ?? summaryProvider.map { $0 == .codex ? .codex : .claude }
            ?? .automatic
        generationBudgets =
            try values.decodeIfPresent(GenerationBudgets.self, forKey: .generationBudgets)
            ?? GenerationBudgets()
        automaticSummariesUseLLM =
            try values.decodeIfPresent(Bool.self, forKey: .automaticSummariesUseLLM)
            ?? values.decodeIfPresent(Bool.self, forKey: .scheduledModelReportsEnabled)
            ?? (summaryProvider != nil)
        movingAverageActiveDays = try values.decodeIfPresent(Int.self, forKey: .movingAverageActiveDays) ?? 14
        automaticUpdateChecks = try values.decodeIfPresent(Bool.self, forKey: .automaticUpdateChecks) ?? true
        collectionPaused = try values.decodeIfPresent(Bool.self, forKey: .collectionPaused) ?? false
        launchAtLoginEnabled = try values.decodeIfPresent(Bool.self, forKey: .launchAtLoginEnabled)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(providerSelection, forKey: .providerSelection)
        try values.encode(generationBudgets, forKey: .generationBudgets)
        try values.encode(automaticSummariesUseLLM, forKey: .automaticSummariesUseLLM)
        try values.encode(movingAverageActiveDays, forKey: .movingAverageActiveDays)
        try values.encode(automaticUpdateChecks, forKey: .automaticUpdateChecks)
        try values.encode(collectionPaused, forKey: .collectionPaused)
        try values.encodeIfPresent(launchAtLoginEnabled, forKey: .launchAtLoginEnabled)
    }
}
