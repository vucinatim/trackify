import Foundation
import TrackifyDomain
import TrackifyStore

/// The only application boundary that converts persisted provider observations
/// into work evidence. Callers may shape or render the result, but must not
/// reinterpret raw roles, aliases, or provider control records independently.
public struct CanonicalWorkEvidenceService: Sendable {
    public static let projectionVersion = ConversationProvenance.currentClassificationVersion

    public init() {}

    public func events(
        store: LedgerStore,
        events: [LedgerEvent]
    ) throws -> [LedgerEvent] {
        let messageIDs: [MessageID] = Array(
            Set(
                events.compactMap { event -> MessageID? in
                    guard event.kind == .agentMessageObserved,
                        let value = event.payload["messageID"]
                    else { return nil }
                    return MessageID(value)
                }))
        var mappings: [MessageID: MessageID] = [:]
        var messages: [MessageID: ConversationMessage] = [:]
        for offset in stride(from: 0, to: messageIDs.count, by: 500) {
            let end = min(offset + 500, messageIDs.count)
            let batch = Array(messageIDs[offset..<end])
            mappings.merge(try store.canonicalMessageIDs(batch)) { _, latest in latest }
            messages.merge(try store.messagesResolvingAliases(ids: batch)) { current, _ in current }
        }

        var seenMessages = Set<String>()
        var seenEvidence = Set<EvidenceID>()
        return events.sorted(by: eventOrder).filter { event in
            guard event.kind == .agentMessageObserved,
                let rawID = event.payload["messageID"]
            else { return seenEvidence.insert(event.evidenceID).inserted }
            let requestedID = MessageID(rawID)
            let canonicalID = mappings[requestedID] ?? requestedID
            guard let message = messages[requestedID],
                ConversationMessageVisibility.isWorkEvidence(message)
            else { return false }
            let logicalKey =
                message.provenance.logicalMessageID?.rawValue
                ?? canonicalID.rawValue
            return seenMessages.insert(logicalKey).inserted
        }
    }

    public func messages(_ values: [ConversationMessage]) -> [ConversationMessage] {
        var seen = Set<String>()
        return values.filter { message in
            guard ConversationMessageVisibility.isWorkEvidence(message) else { return false }
            let key = message.provenance.logicalMessageID?.rawValue ?? message.id.rawValue
            return seen.insert(key).inserted
        }
    }

    public func logicalTurnCount(in events: [LedgerEvent]) -> Int {
        var turns = Set<String>()
        for event in events where event.kind == .agentMessageObserved {
            let disposition = event.payload["disposition"]
            if disposition != nil, disposition != EvidenceDisposition.work.rawValue { continue }
            if (event.payload["logicalTurnID"] ?? "").isEmpty,
                event.payload["role"] == MessageRole.user.rawValue
            {
                // Explicit compatibility for pre-Goal-4 fixtures and ledgers.
                let messageID = event.payload["messageID"] ?? event.id.rawValue
                turns.insert("legacy-message:\(messageID)")
                continue
            }
            let origin = event.payload["origin"]
            let semantic = event.payload["semanticKind"]
            let isIntent =
                semantic == nil
                || semantic == ConversationSemanticKind.intent.rawValue
                || semantic == ConversationSemanticKind.steering.rawValue
            let isWorkOrigin =
                origin == nil
                || origin == ConversationOrigin.human.rawValue
                || origin == ConversationOrigin.agent.rawValue
            guard isIntent, isWorkOrigin else { continue }
            if let logicalTurnID = event.payload["logicalTurnID"], !logicalTurnID.isEmpty {
                turns.insert(logicalTurnID)
            }
        }
        return turns.count
    }

    public func quality(store: LedgerStore) throws -> EvidenceQualitySnapshot {
        try store.evidenceQuality()
    }

    private func eventOrder(_ left: LedgerEvent, _ right: LedgerEvent) -> Bool {
        left.occurredAt == right.occurredAt
            ? left.id.rawValue < right.id.rawValue
            : left.occurredAt < right.occurredAt
    }
}
