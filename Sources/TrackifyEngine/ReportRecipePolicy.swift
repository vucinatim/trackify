import Foundation
import TrackifyDomain

public struct ReportRecipePolicy: Sendable {
    public static let promptVersion = "report-prompt-v2"
    public static let outputSchemaVersion = "report-output-v2"

    public init() {}

    public func apply(
        _ packet: ReportEvidencePacket,
        recipe: ReportRecipeVersion
    ) -> ReportEvidencePacket {
        let scopedRepositories = Set(recipe.repositoryIDs)
        let explicitScope = !scopedRepositories.isEmpty
        let disallowedGroup = recipe.groupNames.contains {
            let value = $0.lowercased()
            return value == "work" || value.contains("client")
        }
        let filtered: [ReportEventDigest]
        switch recipe.privacyProfile {
        case .private:
            filtered =
                explicitScope
                ? packet.events.filter { $0.repositoryID.map(scopedRepositories.contains) == true }
                : packet.events
        case .team:
            filtered = packet.events.filter { event in
                let scoped = !explicitScope || event.repositoryID.map(scopedRepositories.contains) == true
                let safeConversation = event.kind != .agentMessageObserved || event.repositoryID != nil
                return scoped && safeConversation
            }
        case .client:
            guard explicitScope else {
                filtered = []
                break
            }
            filtered = packet.events.filter { event in
                event.repositoryID.map(scopedRepositories.contains) == true
                    && event.kind != .agentMessageObserved
            }
        case .public:
            guard explicitScope, !disallowedGroup else {
                filtered = []
                break
            }
            filtered = packet.events.filter { event in
                event.repositoryID.map(scopedRepositories.contains) == true
                    && Self.publicKinds.contains(event.kind)
                    && event.kind != .agentMessageObserved
            }
        }

        let priorReports = recipe.privacyProfile == .private ? packet.priorReports : []
        let evidenceCount = filtered.count + priorReports.count
        let shouldRecalculate = recipe.privacyProfile != .private || explicitScope
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
            totalPriorReportCount: packet.selection.totalPriorReportCount,
            selectedPriorReportCount: priorReports.count,
            omittedQuietReportCount: packet.selection.omittedQuietReportCount,
            serializedByteLimit: packet.selection.serializedByteLimit)
        return ReportEvidencePacket(
            schemaVersion: packet.schemaVersion, periodStart: packet.periodStart,
            periodEnd: packet.periodEnd, state: evidenceCount == 0 ? .noActivity : packet.state,
            activity: activity, events: filtered, priorReports: priorReports, selection: selection)
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
        return ReportActivitySnapshot(
            rangeStart: packet.periodStart, rangeEnd: packet.periodEnd,
            activeHours: hours,
            llmTurns: events.filter { $0.kind == .agentRunFinished }.count,
            conversationMessages: events.filter { $0.kind == .agentMessageObserved }.count,
            commits: events.filter { $0.kind == .gitCommitObserved }.count,
            additions: additions, deletions: deletions, filesChanged: files,
            repositoryCount: repositories.count, evidenceCount: events.count,
            firstEvidenceAt: events.map(\.occurredAt).min(),
            lastEvidenceAt: events.map(\.occurredAt).max())
    }
}
