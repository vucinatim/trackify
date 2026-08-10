import Foundation
import TrackifyDomain
import TrackifyStore

public protocol ProviderAllowanceReading: Sendable {
    func snapshot(provider: SummaryProviderID, now: Date) -> ProviderAllowanceSnapshot?
}

public struct NoProviderAllowanceReader: ProviderAllowanceReading {
    public init() {}
    public func snapshot(provider: SummaryProviderID, now: Date) -> ProviderAllowanceSnapshot? { nil }
}

public struct AutomaticProviderAllowanceReader: ProviderAllowanceReading {
    private let codex: CodexAllowanceReader

    public init(codex: CodexAllowanceReader = CodexAllowanceReader()) {
        self.codex = codex
    }

    public func snapshot(provider: SummaryProviderID, now: Date) -> ProviderAllowanceSnapshot? {
        switch provider {
        case .codex: codex.snapshot(provider: provider, now: now)
        case .claude: nil
        }
    }
}

/// Reads the same local allowance snapshot shown by Codex `/status`. Failure is
/// intentionally represented as nil so generation can continue under
/// Trackify's own credit and burst limits on older or incompatible CLIs.
public struct CodexAllowanceReader: ProviderAllowanceReading {
    private let executable: URL?
    private let timeout: TimeInterval

    public init(
        executable: URL? = ExecutableLocator.find(
            "codex",
            additionalPaths: ["/Applications/ChatGPT.app/Contents/Resources/codex"]),
        timeout: TimeInterval = 4
    ) {
        self.executable = executable
        self.timeout = timeout
    }

    public func snapshot(provider: SummaryProviderID, now: Date) -> ProviderAllowanceSnapshot? {
        guard provider == .codex, let executable else { return nil }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let state = JSONLineResponseState()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            state.consume(data)
        }
        do {
            try process.run()
            try write(
                [
                    "id": 1,
                    "method": "initialize",
                    "params": [
                        "clientInfo": [
                            "name": "trackify",
                            "version": "1",
                        ]
                    ],
                ], to: input.fileHandleForWriting)
            guard state.initialize.wait(timeout: .now() + timeout) == .success else {
                stop(process, input: input, output: output)
                return nil
            }
            try write(["method": "initialized"], to: input.fileHandleForWriting)
            try write(
                ["id": 2, "method": "account/rateLimits/read", "params": NSNull()],
                to: input.fileHandleForWriting)
            guard state.rateLimits.wait(timeout: .now() + timeout) == .success else {
                stop(process, input: input, output: output)
                return nil
            }
            let response = state.rateLimitResponse
            stop(process, input: input, output: output)
            return response.flatMap { decodeSnapshot($0, observedAt: now) }
        } catch {
            stop(process, input: input, output: output)
            return nil
        }
    }

    private func write(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func stop(_ process: Process, input: Pipe, output: Pipe) {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private func decodeSnapshot(_ data: Data, observedAt: Date) -> ProviderAllowanceSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = root["result"] as? [String: Any]
        else { return nil }
        let byID = result["rateLimitsByLimitId"] as? [String: Any]
        let raw =
            (byID?["codex"] as? [String: Any])
            ?? (result["rateLimits"] as? [String: Any])
        guard let raw,
            let primary = raw["primary"] as? [String: Any],
            let usedPercent = primary["usedPercent"] as? Int
        else { return nil }
        let resetSeconds = (primary["resetsAt"] as? NSNumber)?.doubleValue
        return ProviderAllowanceSnapshot(
            provider: .codex,
            limitID: raw["limitId"] as? String ?? "codex",
            plan: raw["planType"] as? String,
            usedPercent: usedPercent,
            windowDurationMinutes: (primary["windowDurationMins"] as? NSNumber)?.intValue,
            resetsAt: resetSeconds.map(Date.init(timeIntervalSince1970:)),
            observedAt: observedAt)
    }
}

private final class JSONLineResponseState: @unchecked Sendable {
    let initialize = DispatchSemaphore(value: 0)
    let rateLimits = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var buffer = Data()
    private var storedRateLimitResponse: Data?

    var rateLimitResponse: Data? {
        lock.withLock { storedRateLimitResponse }
    }

    func consume(_ data: Data) {
        lock.withLock {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                    let id = object["id"] as? Int
                else { continue }
                if id == 1 {
                    initialize.signal()
                } else if id == 2 {
                    storedRateLimitResponse = line
                    rateLimits.signal()
                }
            }
        }
    }
}

public struct GenerationBudgetRequest: Sendable {
    public let provider: SummaryProviderID
    public let model: String?
    public let calls: Int
    public let maximumInputBytes: Int
    public let maximumEstimatedInputTokens: Int
    public let totalEstimatedInputTokens: Int
    public let reservedCalls: Int
    public let reservedInputTokens: Int

    public init(
        provider: SummaryProviderID,
        model: String?,
        calls: Int,
        maximumInputBytes: Int,
        maximumEstimatedInputTokens: Int,
        totalEstimatedInputTokens: Int,
        reservedCalls: Int = 0,
        reservedInputTokens: Int = 0
    ) {
        self.provider = provider
        self.model = model
        self.calls = calls
        self.maximumInputBytes = maximumInputBytes
        self.maximumEstimatedInputTokens = maximumEstimatedInputTokens
        self.totalEstimatedInputTokens = totalEstimatedInputTokens
        self.reservedCalls = reservedCalls
        self.reservedInputTokens = reservedInputTokens
    }
}

public struct GenerationBudgetDecision: Sendable {
    public let allowed: Bool
    public let reason: String?
    public let status: GenerationBudgetStatus
}

public struct GenerationBudgetController: Sendable {
    private let allowanceReader: any ProviderAllowanceReading

    public init(
        allowanceReader: any ProviderAllowanceReading = AutomaticProviderAllowanceReader()
    ) {
        self.allowanceReader = allowanceReader
    }

    public func decision(
        request: GenerationBudgetRequest,
        budgets: GenerationBudgets,
        store: LedgerStore,
        now: Date,
        calendar: Calendar = .current
    ) throws -> GenerationBudgetDecision {
        let allowance = allowanceReader.snapshot(provider: request.provider, now: now)
        let status = try status(
            store: store, budgets: budgets, provider: request.provider,
            model: request.model, now: now, calendar: calendar,
            allowance: allowance)
        return try decision(
            request: request, budgets: budgets, store: store, now: now,
            calendar: calendar, status: status)
    }

    /// Re-evaluates an exact request against a recently observed provider
    /// status. Summary recovery uses this to decide whether a historical local
    /// fallback is still necessary without launching one allowance process per
    /// candidate summary. The actual invocation always performs a fresh
    /// authoritative decision immediately before process start.
    public func decision(
        request: GenerationBudgetRequest,
        budgets: GenerationBudgets,
        store: LedgerStore,
        now: Date,
        calendar: Calendar = .current,
        status: GenerationBudgetStatus
    ) throws -> GenerationBudgetDecision {
        let reason: String?
        if request.maximumInputBytes > budgets.maximumInputBytesPerCall {
            reason = "per-call byte safety limit"
        } else if request.maximumEstimatedInputTokens > budgets.maximumEstimatedInputTokensPerCall {
            reason = "per-call token safety limit"
        } else if status.callsToday + request.calls + request.reservedCalls > budgets.maximumCallsPerDay {
            reason = "daily call safety limit"
        } else if status.isPaused {
            reason = status.pauseReason
        } else if let weeklyCreditLimit = budgets.weeklyCreditLimit,
            let projectedCredits = GenerationCreditEstimator.credits(
                provider: request.provider, model: request.model,
                inputTokens: request.totalEstimatedInputTokens + request.reservedInputTokens,
                outputTokens: (request.calls + request.reservedCalls)
                    * budgets.estimatedOutputTokensPerCall),
            status.estimatedCreditsUsed + projectedCredits > weeklyCreditLimit
        {
            reason = "weekly Trackify credit budget"
        } else {
            guard let day = calendar.dateInterval(of: .day, for: now),
                let month = calendar.dateInterval(of: .month, for: now)
            else {
                return GenerationBudgetDecision(
                    allowed: false, reason: "calendar budget unavailable", status: status)
            }
            let dayTokens = try store.generationTokenCommitment(from: day.start, through: day.end)
            if dayTokens + request.totalEstimatedInputTokens + request.reservedInputTokens
                > budgets.dailyTokenLimit
            {
                reason = "daily token safety limit"
            } else if let monthlyLimit = budgets.monthlyTokenLimit,
                try store.generationTokenCommitment(from: month.start, through: month.end)
                    + request.totalEstimatedInputTokens + request.reservedInputTokens > monthlyLimit
            {
                reason = "monthly token safety limit"
            } else {
                let dailyUsage = try store.usage(from: day.start, through: day.end)
                if let limit = budgets.dailyMonetaryLimit,
                    !dailyUsage.hasUnknownCost, dailyUsage.knownCost >= limit
                {
                    reason = "daily monetary limit"
                } else if let limit = budgets.monthlyMonetaryLimit {
                    let monthlyUsage = try store.usage(from: month.start, through: month.end)
                    reason =
                        !monthlyUsage.hasUnknownCost && monthlyUsage.knownCost >= limit
                        ? "monthly monetary limit" : nil
                } else {
                    reason = nil
                }
            }
        }
        return GenerationBudgetDecision(allowed: reason == nil, reason: reason, status: status)
    }

    public func status(
        store: LedgerStore,
        budgets: GenerationBudgets,
        provider: SummaryProviderID?,
        model: String? = nil,
        now: Date,
        calendar: Calendar = .current
    ) throws -> GenerationBudgetStatus {
        let allowance = provider.flatMap { allowanceReader.snapshot(provider: $0, now: now) }
        return try status(
            store: store, budgets: budgets, provider: provider,
            model: model, now: now, calendar: calendar, allowance: allowance)
    }

    private func status(
        store: LedgerStore,
        budgets: GenerationBudgets,
        provider: SummaryProviderID?,
        model: String?,
        now: Date,
        calendar: Calendar,
        allowance: ProviderAllowanceSnapshot?
    ) throws -> GenerationBudgetStatus {
        let fallbackWeek =
            calendar.dateInterval(of: .weekOfYear, for: now)
            ?? DateInterval(start: now.addingTimeInterval(-7 * 86_400), end: now)
        let windowStart = allowance?.windowStart ?? fallbackWeek.start
        let windowEnd = allowance?.resetsAt ?? fallbackWeek.end
        let records = try store.generationUsageRecords(from: windowStart, through: min(now, windowEnd))
        let credits = records.compactMap(GenerationCreditEstimator.credits(for:)).reduce(0, +)
        let attributed: Int
        if let allowance, let resetsAt = allowance.resetsAt {
            attributed = try store.attributedAllowancePercent(
                provider: allowance.provider, resetsAt: resetsAt)
        } else {
            attributed = 0
        }
        let day =
            calendar.dateInterval(of: .day, for: now)
            ?? DateInterval(start: now, duration: 86_400)
        let calls = try store.providerInvocationCount(from: day.start, through: day.end)
        let reason: String?
        if let allowance,
            allowance.remainingPercent <= budgets.minimumProviderAllowanceRemainingPercent
        {
            reason = "provider weekly allowance reserve"
        } else if let limit = budgets.weeklyAllowancePercentLimit,
            attributed >= limit
        {
            reason = "weekly Trackify allowance target"
        } else if let limit = budgets.weeklyCreditLimit, credits >= limit {
            reason = "weekly Trackify credit budget"
        } else if calls >= budgets.maximumCallsPerDay {
            reason = "daily call safety limit"
        } else {
            reason = nil
        }
        _ = provider
        _ = model
        return GenerationBudgetStatus(
            allowance: allowance,
            allowanceAttributedPercent: attributed,
            allowancePercentLimit: budgets.weeklyAllowancePercentLimit,
            estimatedCreditsUsed: credits,
            weeklyCreditLimit: budgets.weeklyCreditLimit,
            callsToday: calls,
            callsPerDayLimit: budgets.maximumCallsPerDay,
            isPaused: reason != nil,
            pauseReason: reason)
    }
}
