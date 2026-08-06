import Foundation
import TrackifyDomain

public struct ConversationParseResult: Equatable, Sendable {
    public let session: ConversationSession
    public let messages: [ConversationMessage]
    public let records: [CollectedRecord]
    public let unknownRecordCount: Int

    public init(
        session: ConversationSession,
        messages: [ConversationMessage],
        records: [CollectedRecord],
        unknownRecordCount: Int
    ) {
        self.session = session
        self.messages = messages
        self.records = records
        self.unknownRecordCount = unknownRecordCount
    }
}

enum ConversationJSON {
    static func object(_ line: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Expected a JSON object."))
        }
        return object
    }

    static func string(_ object: [String: Any], _ path: String...) -> String? {
        value(object, path) as? String
    }

    static func object(_ object: [String: Any], _ path: String...) -> [String: Any]? {
        value(object, path) as? [String: Any]
    }

    static func array(_ object: [String: Any], _ path: String...) -> [[String: Any]] {
        value(object, path) as? [[String: Any]] ?? []
    }

    static func date(_ value: String?, formatter: ISO8601DateFormatter) -> Date? {
        value.flatMap(formatter.date(from:))
    }

    static func textContent(_ content: Any?) -> String? {
        if let text = content as? String {
            return normalized(text)
        }
        guard let items = content as? [[String: Any]] else { return nil }
        let texts = items.compactMap { item -> String? in
            guard ["text", "input_text", "output_text"].contains(item["type"] as? String) else { return nil }
            return item["text"] as? String
        }
        return normalized(texts.joined(separator: "\n"))
    }

    static func normalized(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func value(_ object: [String: Any], _ path: [String]) -> Any? {
        var value: Any = object
        for component in path {
            guard let dictionary = value as? [String: Any], let next = dictionary[component] else { return nil }
            value = next
        }
        return value
    }
}

enum ConversationRecordFactory {
    static func sessionID(source: SourceKind, externalID: String) -> SessionID {
        SessionID(StableHash.sha256("session:\(source.rawValue):\(externalID)"))
    }

    static func message(
        source: SourceKind,
        sessionID: SessionID,
        sourceMessageID: String?,
        role: MessageRole,
        occurredAt: Date?,
        text: String
    ) -> ConversationMessage {
        let text = MessageTextSanitizer.sanitize(text)
        let fingerprint = StableHash.sha256(
            [
                source.rawValue,
                sessionID.rawValue,
                sourceMessageID ?? "",
                role.rawValue,
                occurredAt.map { String($0.timeIntervalSince1970) } ?? "",
                text,
            ].joined(separator: "\u{1f}"))
        return ConversationMessage(
            id: MessageID(StableHash.sha256("message:\(fingerprint)")),
            sessionID: sessionID,
            sourceMessageID: sourceMessageID,
            role: role,
            occurredAt: occurredAt,
            normalizedText: text,
            fingerprint: fingerprint
        )
    }

    static func lifecycle(
        source: SourceKind,
        sessionID: SessionID,
        sourceRecordID: String,
        occurredAt: Date,
        observedAt: Date,
        kind: EventKind,
        state: ObservedState,
        payload: [String: String] = [:]
    ) -> CollectedRecord {
        let canonical = "\(source.rawValue):\(sourceRecordID)"
        let evidence = SourceEvidence(
            id: EvidenceID(StableHash.sha256("evidence:\(canonical)")),
            source: source,
            ingestionPath: .cache,
            sourceRecordID: sourceRecordID,
            fingerprint: StableHash.sha256(canonical),
            occurredAt: occurredAt,
            observedAt: observedAt,
            adapterVersion: 1
        )
        let event = LedgerEvent(
            id: EventID(StableHash.sha256("event:\(canonical)")),
            evidenceID: evidence.id,
            occurredAt: occurredAt,
            observedAt: observedAt,
            source: source,
            kind: kind,
            sessionID: sessionID,
            state: state,
            payload: payload
        )
        return CollectedRecord(evidence: evidence, event: event)
    }

    static func messageRecord(
        source: SourceKind,
        message: ConversationMessage,
        observedAt: Date
    ) -> CollectedRecord? {
        guard let occurredAt = message.occurredAt else { return nil }
        let sourceRecordID = "session:\(message.sessionID.rawValue):message:\(message.fingerprint)"
        let canonical = "\(source.rawValue):\(sourceRecordID)"
        let evidence = SourceEvidence(
            id: EvidenceID(StableHash.sha256("evidence:\(canonical)")),
            source: source,
            ingestionPath: .cache,
            sourceRecordID: sourceRecordID,
            fingerprint: StableHash.sha256(canonical),
            occurredAt: occurredAt,
            observedAt: observedAt,
            adapterVersion: 2
        )
        return CollectedRecord(
            evidence: evidence,
            event: LedgerEvent(
                id: EventID(StableHash.sha256("event:\(canonical)")),
                evidenceID: evidence.id,
                occurredAt: occurredAt,
                observedAt: observedAt,
                source: source,
                kind: .agentMessageObserved,
                sessionID: message.sessionID,
                payload: [
                    "messageID": message.id.rawValue,
                    "role": message.role.rawValue,
                ]
            )
        )
    }
}
