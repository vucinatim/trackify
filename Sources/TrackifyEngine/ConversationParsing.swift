import Foundation
import TrackifyDomain

public struct ConversationParserState: Codable, Equatable, Sendable {
    public var externalSessionID: String?
    public var startedAt: Date?
    public var lastObservedAt: Date?
    public var workingDirectory: String?
    public var sourceVersion: String?
    public var observedState: ObservedState
    public var currentTurnID: String?
    public var currentSidechainTurnID: String?
    public var recordTurnIDs: [String: String]
    public var recordTurnOrder: [String]

    public init(
        externalSessionID: String? = nil,
        startedAt: Date? = nil,
        lastObservedAt: Date? = nil,
        workingDirectory: String? = nil,
        sourceVersion: String? = nil,
        observedState: ObservedState = .unknown,
        currentTurnID: String? = nil,
        currentSidechainTurnID: String? = nil,
        recordTurnIDs: [String: String] = [:],
        recordTurnOrder: [String] = []
    ) {
        self.externalSessionID = externalSessionID
        self.startedAt = startedAt
        self.lastObservedAt = lastObservedAt
        self.workingDirectory = workingDirectory
        self.sourceVersion = sourceVersion
        self.observedState = observedState
        self.currentTurnID = currentTurnID
        self.currentSidechainTurnID = currentSidechainTurnID
        self.recordTurnIDs = recordTurnIDs
        self.recordTurnOrder = recordTurnOrder
    }

    private enum CodingKeys: String, CodingKey {
        case externalSessionID
        case startedAt
        case lastObservedAt
        case workingDirectory
        case sourceVersion
        case observedState
        case currentTurnID
        case currentSidechainTurnID
        case recordTurnIDs
        case recordTurnOrder
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        externalSessionID = try container.decodeIfPresent(String.self, forKey: .externalSessionID)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        lastObservedAt = try container.decodeIfPresent(Date.self, forKey: .lastObservedAt)
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        sourceVersion = try container.decodeIfPresent(String.self, forKey: .sourceVersion)
        observedState =
            try container.decodeIfPresent(ObservedState.self, forKey: .observedState)
            ?? .unknown
        currentTurnID = try container.decodeIfPresent(String.self, forKey: .currentTurnID)
        currentSidechainTurnID = try container.decodeIfPresent(
            String.self, forKey: .currentSidechainTurnID)
        recordTurnIDs =
            try container.decodeIfPresent(
                [String: String].self, forKey: .recordTurnIDs) ?? [:]
        recordTurnOrder =
            try container.decodeIfPresent(
                [String].self, forKey: .recordTurnOrder) ?? []
    }

    public func retainingRecentRecordTurns(_ limit: Int) -> ConversationParserState {
        precondition(limit >= 0)
        let retainedOrder = Array(recordTurnOrder.suffix(limit))
        let retainedIDs = Set(retainedOrder)
        return ConversationParserState(
            externalSessionID: externalSessionID,
            startedAt: startedAt,
            lastObservedAt: lastObservedAt,
            workingDirectory: workingDirectory,
            sourceVersion: sourceVersion,
            observedState: observedState,
            currentTurnID: currentTurnID,
            currentSidechainTurnID: currentSidechainTurnID,
            recordTurnIDs: recordTurnIDs.filter { retainedIDs.contains($0.key) },
            recordTurnOrder: retainedOrder)
    }
}

public struct ConversationParseResult: Equatable, Sendable {
    public let session: ConversationSession
    public let messages: [ConversationMessage]
    public let normalizedRecords: [NormalizedConversationRecord]
    public let records: [CollectedRecord]
    public let unknownRecordCount: Int
    public let parserState: ConversationParserState

    public init(
        session: ConversationSession,
        messages: [ConversationMessage],
        normalizedRecords: [NormalizedConversationRecord] = [],
        records: [CollectedRecord],
        unknownRecordCount: Int,
        parserState: ConversationParserState = ConversationParserState()
    ) {
        self.session = session
        self.messages = messages
        self.normalizedRecords = normalizedRecords
        self.records = records
        self.unknownRecordCount = unknownRecordCount
        self.parserState = parserState
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
        text: String,
        provenance: ConversationProvenance = ConversationProvenance()
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
        let canonicalID =
            provenance.logicalMessageID?.rawValue
            ?? StableHash.sha256("message:\(fingerprint)")
        return ConversationMessage(
            id: MessageID(canonicalID),
            sessionID: sessionID,
            sourceMessageID: sourceMessageID,
            role: role,
            occurredAt: occurredAt,
            normalizedText: text,
            fingerprint: fingerprint,
            provenance: provenance
        )
    }

    static func logicalTurnID(source: SourceKind, sourceTurnID: String?) -> LogicalTurnID? {
        guard let sourceTurnID, !sourceTurnID.isEmpty else { return nil }
        return LogicalTurnID(StableHash.sha256("logical-turn:\(source.rawValue):\(sourceTurnID)"))
    }

    static func logicalMessageID(
        source: SourceKind,
        sourceMessageID: String?,
        sourceTurnID: String?,
        role: MessageRole?,
        occurredAt: Date?,
        text: String?
    ) -> LogicalMessageID? {
        if let sourceMessageID, !sourceMessageID.isEmpty {
            return LogicalMessageID(
                StableHash.sha256("logical-message:\(source.rawValue):id:\(sourceMessageID)"))
        }
        if let sourceTurnID, let role, let text {
            return LogicalMessageID(
                StableHash.sha256(
                    "logical-message:\(source.rawValue):turn:\(sourceTurnID):\(role.rawValue):\(StableHash.sha256(text))"
                ))
        }
        if let occurredAt, let role, let text {
            return LogicalMessageID(
                StableHash.sha256(
                    "logical-message:\(source.rawValue):legacy:\(occurredAt.timeIntervalSince1970):\(role.rawValue):\(StableHash.sha256(text))"
                ))
        }
        return nil
    }

    static func normalizedRecord(
        source: SourceKind,
        sessionID: SessionID,
        occurredAt: Date?,
        observedAt: Date,
        role: MessageRole?,
        text: String?,
        provenance: ConversationProvenance,
        adapterVersion: Int
    ) -> NormalizedConversationRecord {
        let sanitized = text.map(MessageTextSanitizer.sanitize)
        let sourceIdentity =
            provenance.sourceRecordID.map {
                "\(provenance.sourceRecordType)\u{1f}\($0)"
            }
            ?? [
                provenance.sourceRecordType,
                provenance.sourceTurnID ?? "",
                role?.rawValue ?? "",
                occurredAt.map { String($0.timeIntervalSince1970) } ?? "",
                sanitized.map(StableHash.sha256) ?? "",
            ].joined(separator: "\u{1f}")
        return NormalizedConversationRecord(
            id: ConversationRecordID(
                StableHash.sha256(
                    "conversation-record:\(source.rawValue):\(sessionID.rawValue):\(sourceIdentity)")),
            source: source,
            sessionID: sessionID,
            occurredAt: occurredAt,
            observedAt: observedAt,
            role: role,
            normalizedText: sanitized,
            textFingerprint: sanitized.map(StableHash.sha256),
            provenance: provenance,
            adapterVersion: adapterVersion)
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
        let sourceRecordID = "logical-message:\(message.provenance.logicalMessageID?.rawValue ?? message.id.rawValue)"
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
                    "logicalTurnID": message.provenance.logicalTurnID?.rawValue ?? "",
                    "origin": message.provenance.origin.rawValue,
                    "semanticKind": message.provenance.semanticKind.rawValue,
                    "disposition": message.provenance.disposition.rawValue,
                ]
            )
        )
    }
}
