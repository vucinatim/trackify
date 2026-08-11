import Foundation

public struct ProviderAllowanceSnapshot: Codable, Equatable, Sendable {
    public let provider: SummaryProviderID
    public let limitID: String
    public let plan: String?
    public let usedPercent: Int
    public let windowDurationMinutes: Int?
    public let resetsAt: Date?
    public let observedAt: Date

    public init(
        provider: SummaryProviderID,
        limitID: String,
        plan: String? = nil,
        usedPercent: Int,
        windowDurationMinutes: Int? = nil,
        resetsAt: Date? = nil,
        observedAt: Date
    ) {
        self.provider = provider
        self.limitID = limitID
        self.plan = plan
        self.usedPercent = usedPercent
        self.windowDurationMinutes = windowDurationMinutes
        self.resetsAt = resetsAt
        self.observedAt = observedAt
    }

    public var remainingPercent: Int { max(0, 100 - usedPercent) }

    public var windowStart: Date? {
        guard let resetsAt, let windowDurationMinutes else { return nil }
        return resetsAt.addingTimeInterval(-TimeInterval(windowDurationMinutes * 60))
    }
}

public struct GenerationUsageRecord: Codable, Equatable, Sendable {
    public let provider: SummaryProviderID
    public let model: String?
    public let estimatedInputTokens: Int?
    public let usage: ProviderUsage

    public init(
        provider: SummaryProviderID,
        model: String?,
        estimatedInputTokens: Int?,
        usage: ProviderUsage
    ) {
        self.provider = provider
        self.model = model
        self.estimatedInputTokens = estimatedInputTokens
        self.usage = usage
    }
}

public struct GenerationBudgetStatus: Codable, Equatable, Sendable {
    public let allowance: ProviderAllowanceSnapshot?
    public let allowanceAttributedPercent: Int
    public let allowancePercentLimit: Int?
    public let estimatedCreditsUsed: Decimal
    public let weeklyCreditLimit: Decimal?
    public let callsToday: Int
    public let callsPerDayLimit: Int
    public let isPaused: Bool
    public let pauseReason: String?

    public init(
        allowance: ProviderAllowanceSnapshot?,
        allowanceAttributedPercent: Int,
        allowancePercentLimit: Int?,
        estimatedCreditsUsed: Decimal,
        weeklyCreditLimit: Decimal?,
        callsToday: Int,
        callsPerDayLimit: Int,
        isPaused: Bool,
        pauseReason: String?
    ) {
        self.allowance = allowance
        self.allowanceAttributedPercent = allowanceAttributedPercent
        self.allowancePercentLimit = allowancePercentLimit
        self.estimatedCreditsUsed = estimatedCreditsUsed
        self.weeklyCreditLimit = weeklyCreditLimit
        self.callsToday = callsToday
        self.callsPerDayLimit = callsPerDayLimit
        self.isPaused = isPaused
        self.pauseReason = pauseReason
    }
}

/// Published provider credit rates are deliberately isolated here. Unknown
/// providers or model families return nil instead of inventing a conversion.
public enum GenerationCreditEstimator {
    public static func credits(
        provider: SummaryProviderID,
        model: String?,
        inputTokens: Int,
        cachedInputTokens: Int = 0,
        outputTokens: Int
    ) -> Decimal? {
        guard provider == .codex, let rate = codexRate(model: model) else { return nil }
        let uncachedInput = max(0, inputTokens - cachedInputTokens)
        return perMillion(uncachedInput, rate.input)
            + perMillion(cachedInputTokens, rate.cachedInput)
            + perMillion(outputTokens, rate.output)
    }

    public static func credits(for record: GenerationUsageRecord) -> Decimal? {
        let input = record.usage.inputTokens ?? record.estimatedInputTokens ?? 0
        let cached = record.usage.cachedInputTokens ?? 0
        // Codex reports reasoning separately for diagnostics, but reasoning is
        // already part of billable output. Do not count it twice.
        let output = record.usage.outputTokens ?? record.usage.reasoningTokens ?? 0
        return credits(
            provider: record.provider, model: record.model,
            inputTokens: input, cachedInputTokens: cached, outputTokens: output)
    }

    private struct Rate {
        let input: Decimal
        let cachedInput: Decimal
        let output: Decimal
    }

    private static func codexRate(model: String?) -> Rate? {
        let normalized = model?.lowercased() ?? "gpt-5.6-sol"
        if normalized.contains("terra") { return Rate(input: 50, cachedInput: 5, output: 300) }
        if normalized.contains("luna") { return Rate(input: 5, cachedInput: 0.5, output: 30) }
        if normalized.contains("sol") || normalized.contains("gpt-5.6") {
            return Rate(input: 125, cachedInput: 12.5, output: 750)
        }
        return nil
    }

    private static func perMillion(_ tokens: Int, _ rate: Decimal) -> Decimal {
        Decimal(tokens) * rate / 1_000_000
    }
}
