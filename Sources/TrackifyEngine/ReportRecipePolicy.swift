import Foundation
import TrackifyDomain
import TrackifyStore

public struct ReportRecipePolicy: Sendable {
    public static let promptVersion = "report-prompt-v3"
    public static let outputSchemaVersion = "report-output-v2"

    public init() {}

    public func apply(
        _ packet: ReportEvidencePacket,
        recipe: ReportRecipeVersion,
        scopedRepositoryIDs: Set<RepositoryID>? = nil
    ) -> ReportEvidencePacket {
        let declaredScope = !recipe.repositoryIDs.isEmpty || !recipe.groupNames.isEmpty
        let scopeWasApplied = scopedRepositoryIDs != nil || !declaredScope
        let disallowedGroup = recipe.groupNames.contains {
            let value = $0.lowercased()
            return value == "work" || value.contains("client")
        }
        let filtered: [ReportEventDigest]
        guard scopeWasApplied else {
            return emptyPacket(from: packet)
        }
        switch recipe.privacyProfile {
        case .private:
            filtered = packet.events
        case .team:
            filtered = packet.events.filter { event in
                let safeConversation = event.kind != .agentMessageObserved || event.repositoryID != nil
                return safeConversation
            }
        case .client:
            guard declaredScope else {
                filtered = []
                break
            }
            filtered = packet.events.filter { $0.kind != .agentMessageObserved }
        case .public:
            guard declaredScope, !disallowedGroup else {
                filtered = []
                break
            }
            filtered = packet.events.filter { event in
                Self.publicKinds.contains(event.kind)
                    && event.kind != .agentMessageObserved
            }
        }

        let priorSummaries = recipe.privacyProfile == .private ? packet.priorSummaries : []
        let evidenceCount = filtered.count + priorSummaries.count
        let shouldRecalculate = recipe.privacyProfile != .private
        let activity =
            evidenceCount == 0
            ? ReportActivitySnapshot(
                rangeStart: packet.periodStart, rangeEnd: packet.periodEnd,
                activeHours: 0, llmTurns: 0, conversationMessages: 0, commits: 0,
                additions: 0, deletions: 0, filesChanged: 0, repositoryCount: 0,
                evidenceCount: 0, firstEvidenceAt: nil, lastEvidenceAt: nil)
            : shouldRecalculate
                ? activitySnapshot(events: filtered, packet: packet)
                : packet.activity
        let representedContexts = Set(
            filtered.map {
                $0.repositoryID?.rawValue ?? $0.sessionID?.rawValue ?? "local"
            }
        ).count
        let selection = ReportPacketSelection(
            compilerVersion: packet.selection.compilerVersion,
            totalEventCount: packet.selection.totalEventCount,
            selectedEventCount: filtered.count,
            omittedEventCount: packet.selection.omittedEventCount + packet.events.count - filtered.count,
            omittedByKind: packet.selection.omittedByKind,
            activeContextCount: packet.selection.activeContextCount,
            representedContextCount: representedContexts,
            omittedContextCount: max(0, packet.selection.activeContextCount - representedContexts),
            totalPriorSummaryCount: packet.selection.totalPriorSummaryCount,
            selectedPriorSummaryCount: priorSummaries.count,
            omittedQuietSummaryCount: packet.selection.omittedQuietSummaryCount,
            serializedByteLimit: packet.selection.serializedByteLimit)
        return ReportEvidencePacket(
            schemaVersion: packet.schemaVersion, periodStart: packet.periodStart,
            periodEnd: packet.periodEnd, state: evidenceCount == 0 ? .noActivity : packet.state,
            activity: activity, events: filtered, priorSummaries: priorSummaries, selection: selection)
    }

    private func emptyPacket(from packet: ReportEvidencePacket) -> ReportEvidencePacket {
        ReportEvidencePacket(
            schemaVersion: packet.schemaVersion, periodStart: packet.periodStart,
            periodEnd: packet.periodEnd, state: .noActivity,
            activity: ReportActivitySnapshot(
                rangeStart: packet.periodStart, rangeEnd: packet.periodEnd,
                activeHours: 0, llmTurns: 0, conversationMessages: 0,
                commits: 0, additions: 0, deletions: 0, filesChanged: 0,
                repositoryCount: 0, evidenceCount: 0,
                firstEvidenceAt: nil, lastEvidenceAt: nil),
            events: [], priorSummaries: [],
            selection: ReportPacketSelection(
                compilerVersion: packet.selection.compilerVersion,
                totalEventCount: packet.selection.totalEventCount,
                selectedEventCount: 0,
                omittedEventCount: packet.selection.omittedEventCount + packet.events.count,
                omittedByKind: packet.selection.omittedByKind,
                activeContextCount: packet.selection.activeContextCount,
                representedContextCount: 0,
                omittedContextCount: packet.selection.activeContextCount,
                totalPriorSummaryCount: packet.selection.totalPriorSummaryCount,
                selectedPriorSummaryCount: 0,
                omittedQuietSummaryCount: packet.selection.omittedQuietSummaryCount,
                serializedByteLimit: packet.selection.serializedByteLimit))
    }

    private static let publicKinds: Set<EventKind> = [
        .gitCommitObserved, .testFinished, .buildFinished,
    ]

    private func activitySnapshot(
        events: [ReportEventDigest],
        packet: ReportEvidencePacket
    ) -> ReportActivitySnapshot {
        let hours = Set(
            events.map {
                Calendar(identifier: .gregorian).dateInterval(of: .hour, for: $0.occurredAt)?.start
            }.compactMap { $0 }
        ).count
        let repositories = Set(events.compactMap(\.repositoryID))
        let additions = events.reduce(0) { $0 + (Int($1.payload["additions"] ?? "") ?? 0) }
        let deletions = events.reduce(0) { $0 + (Int($1.payload["deletions"] ?? "") ?? 0) }
        let files = events.reduce(0) { $0 + (Int($1.payload["filesChanged"] ?? "") ?? 0) }
        let logicalTurns = Set(
            events.compactMap { event -> String? in
                guard event.kind == .agentMessageObserved else { return nil }
                if let turnID = event.logicalTurnID,
                    event.messageOrigin == .human || event.messageOrigin == .agent,
                    event.messageSemanticKind == .intent || event.messageSemanticKind == .steering
                {
                    return turnID.rawValue
                }
                guard event.logicalTurnID == nil, event.messageRole == .user else { return nil }
                return "legacy:\(event.eventID.rawValue)"
            })
        return ReportActivitySnapshot(
            rangeStart: packet.periodStart, rangeEnd: packet.periodEnd,
            activeHours: hours,
            llmTurns: logicalTurns.count,
            conversationMessages: events.filter { $0.kind == .agentMessageObserved }.count,
            commits: events.filter { $0.kind == .gitCommitObserved }.count,
            additions: additions, deletions: deletions, filesChanged: files,
            repositoryCount: repositories.count, evidenceCount: events.count,
            firstEvidenceAt: events.map(\.occurredAt).min(),
            lastEvidenceAt: events.map(\.occurredAt).max())
    }
}

public struct ReportScopeResolver: Sendable {
    public init() {}

    public func repositoryIDs(
        store: LedgerStore,
        recipe: ReportRecipeVersion
    ) throws -> Set<RepositoryID>? {
        let requestedGroups = Set(
            recipe.groupNames.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { !$0.isEmpty }
        )
        guard !recipe.repositoryIDs.isEmpty || !requestedGroups.isEmpty else { return nil }

        var resolved = Set(recipe.repositoryIDs)
        for item in try store.repositoryCatalog() {
            guard let group = item.discoveryRootName?.lowercased(), requestedGroups.contains(group) else { continue }
            resolved.insert(item.repository.id)
        }
        return resolved
    }
}
