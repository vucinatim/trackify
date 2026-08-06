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
    public var scheduledModelReportsEnabled: Bool
    public var movingAverageActiveDays: Int
    public var automaticUpdateChecks: Bool
    public var collectionPaused: Bool
    public var launchAtLoginEnabled: Bool?

    public init(
        summaryProvider: SummaryProviderID? = nil,
        providerSelection: ProviderSelectionMode? = nil,
        generationBudgets: GenerationBudgets = GenerationBudgets(),
        scheduledModelReportsEnabled: Bool = false,
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
        self.scheduledModelReportsEnabled = scheduledModelReportsEnabled
        self.movingAverageActiveDays = movingAverageActiveDays
        self.automaticUpdateChecks = automaticUpdateChecks
        self.collectionPaused = collectionPaused
        self.launchAtLoginEnabled = launchAtLoginEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case summaryProvider
        case providerSelection
        case generationBudgets
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
        scheduledModelReportsEnabled =
            try values.decodeIfPresent(
                Bool.self, forKey: .scheduledModelReportsEnabled) ?? (summaryProvider != nil)
        movingAverageActiveDays = try values.decodeIfPresent(Int.self, forKey: .movingAverageActiveDays) ?? 14
        automaticUpdateChecks = try values.decodeIfPresent(Bool.self, forKey: .automaticUpdateChecks) ?? true
        collectionPaused = try values.decodeIfPresent(Bool.self, forKey: .collectionPaused) ?? false
        launchAtLoginEnabled = try values.decodeIfPresent(Bool.self, forKey: .launchAtLoginEnabled)
    }
}
