import Foundation
import TrackifyDomain
import TrackifyStore

enum ProviderGenerationLease {
    static let name = "provider-generation"
}

/// The single production boundary for launching a model CLI. It registers the
/// operation before process creation and always records a terminal state.
public enum RegisteredProviderInvocation {
    public static func generate(
        provider: any SummaryProvider,
        providerID: SummaryProviderID,
        packet: ReportEvidencePacket,
        recipe: ReportRecipeVersion?,
        purpose: String,
        store: LedgerStore,
        allowanceReader: any ProviderAllowanceReading = AutomaticProviderAllowanceReader(),
        now: @escaping @Sendable () -> Date = Date.init
    ) async throws -> ProviderGenerationResult {
        let context = try ProviderInvocationContext.create(purpose: purpose)
        defer { context.cleanup() }
        let startedAt = now()
        let allowanceBefore = allowanceReader.snapshot(provider: providerID, now: startedAt)
        try store.beginInternalProviderOperation(
            id: context.operationID, provider: providerID.rawValue,
            purpose: purpose, workingDirectory: context.workingDirectory,
            startedAt: startedAt)
        func recordAllowance(finishedAt: Date) {
            let allowanceAfter = allowanceReader.snapshot(provider: providerID, now: finishedAt)
            try? store.saveProviderAllowanceAttribution(
                operationID: context.operationID, provider: providerID,
                purpose: purpose, startedAt: startedAt, finishedAt: finishedAt,
                before: allowanceBefore, after: allowanceAfter)
        }
        do {
            let result = try await provider.generate(
                packet, recipe: recipe, context: context)
            let finishedAt = now()
            try store.finishInternalProviderOperation(
                id: context.operationID, state: "succeeded", finishedAt: finishedAt)
            recordAllowance(finishedAt: finishedAt)
            return result
        } catch {
            let finishedAt = now()
            try? store.finishInternalProviderOperation(
                id: context.operationID, state: "failed", finishedAt: finishedAt)
            recordAllowance(finishedAt: finishedAt)
            throw error
        }
    }
}
