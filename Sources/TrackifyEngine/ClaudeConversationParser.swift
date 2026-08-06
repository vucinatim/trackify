import Foundation
import TrackifyDomain

public struct ClaudeConversationParser: Sendable {
    public init() {}

    public func parse(
        lines: [Data],
        fallbackSessionID: String,
        observedAt: Date
    ) throws -> ConversationParseResult {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var externalSessionID = fallbackSessionID
        var startedAt: Date?
        var lastObservedAt = observedAt
        var workingDirectory: String?
        var sourceVersion: String?
        var state: ObservedState = .unknown
        var pendingMessages: [(id: String?, role: MessageRole, date: Date?, text: String)] = []
        var lifecycleValues: [(recordID: String, date: Date, kind: EventKind, state: ObservedState, payload: [String: String])] = []
        var unknownRecordCount = 0

        for line in lines {
            let object = try ConversationJSON.object(line)
            let type = ConversationJSON.string(object, "type") ?? ""
            externalSessionID = ConversationJSON.string(object, "sessionId") ?? externalSessionID
            workingDirectory = ConversationJSON.string(object, "cwd") ?? workingDirectory
            sourceVersion = ConversationJSON.string(object, "version") ?? sourceVersion
            let timestamp = ConversationJSON.date(ConversationJSON.string(object, "timestamp"), formatter: formatter)
            if let timestamp {
                startedAt = min(startedAt ?? timestamp, timestamp)
                lastObservedAt = max(lastObservedAt, timestamp)
            }

            switch type {
            case "user":
                guard let timestamp else { continue }
                let content = ConversationJSON.object(object, "message")?["content"]
                if let text = ConversationJSON.textContent(content) {
                    let sourceID = ConversationJSON.string(object, "uuid")
                    pendingMessages.append((sourceID, .user, timestamp, text))
                    let turnID = ConversationJSON.string(object, "promptId") ?? sourceID ?? "timestamp:\(timestamp.timeIntervalSince1970)"
                    lifecycleValues.append(
                        (
                            "session:\(externalSessionID):turn:\(turnID):started", timestamp, .agentRunStarted, .inProgress,
                            ["turnID": turnID]
                        ))
                    state = .inProgress
                }

            case "assistant":
                guard let timestamp else { continue }
                let message = ConversationJSON.object(object, "message") ?? [:]
                let sourceID = ConversationJSON.string(object, "uuid") ?? (message["id"] as? String)
                if let text = ConversationJSON.textContent(message["content"]) {
                    pendingMessages.append((sourceID, .assistant, timestamp, text))
                }
                let stopReason = message["stop_reason"] as? String
                if stopReason == "end_turn" {
                    let turnID = (message["id"] as? String) ?? sourceID ?? "timestamp:\(timestamp.timeIntervalSince1970)"
                    lifecycleValues.append(
                        (
                            "session:\(externalSessionID):turn:\(turnID):completed", timestamp, .agentRunFinished, .completed,
                            ["turnID": turnID]
                        ))
                    state = .completed
                } else if stopReason == "tool_use" && state == .unknown {
                    state = .inProgress
                }

            case "system":
                guard ConversationJSON.string(object, "subtype") == "api_error", let timestamp else { continue }
                let identity = ConversationJSON.string(object, "uuid") ?? "timestamp:\(timestamp.timeIntervalSince1970)"
                lifecycleValues.append(("session:\(externalSessionID):error:\(identity)", timestamp, .agentRunFinished, .failed, [:]))
                state = .failed

            case "queue-operation", "attachment", "ai-title", "custom-title", "last-prompt", "mode":
                break
            default:
                unknownRecordCount += 1
            }
        }

        let sessionID = ConversationRecordFactory.sessionID(source: .claude, externalID: externalSessionID)
        let messages = pendingMessages.map {
            ConversationRecordFactory.message(
                source: .claude,
                sessionID: sessionID,
                sourceMessageID: $0.id,
                role: $0.role,
                occurredAt: $0.date,
                text: $0.text
            )
        }
        let lifecycleRecords = deduplicated(lifecycleValues).map {
            ConversationRecordFactory.lifecycle(
                source: .claude,
                sessionID: sessionID,
                sourceRecordID: $0.recordID,
                occurredAt: $0.date,
                observedAt: observedAt,
                kind: $0.kind,
                state: $0.state,
                payload: $0.payload
            )
        }
        let messageRecords = messages.compactMap {
            ConversationRecordFactory.messageRecord(source: .claude, message: $0, observedAt: observedAt)
        }
        let session = ConversationSession(
            id: sessionID,
            source: .claude,
            sourceSessionID: externalSessionID,
            startedAt: startedAt,
            lastObservedAt: lastObservedAt,
            workingDirectory: workingDirectory,
            sourceVersion: sourceVersion,
            state: state
        )
        return ConversationParseResult(
            session: session,
            messages: messages,
            records: (lifecycleRecords + messageRecords).sorted {
                $0.event.occurredAt == $1.event.occurredAt
                    ? $0.event.id.rawValue < $1.event.id.rawValue
                    : $0.event.occurredAt < $1.event.occurredAt
            },
            unknownRecordCount: unknownRecordCount
        )
    }

    private func deduplicated(
        _ values: [(recordID: String, date: Date, kind: EventKind, state: ObservedState, payload: [String: String])]
    ) -> [(recordID: String, date: Date, kind: EventKind, state: ObservedState, payload: [String: String])] {
        var byID: [String: (recordID: String, date: Date, kind: EventKind, state: ObservedState, payload: [String: String])] = [:]
        for value in values {
            if let existing = byID[value.recordID], existing.date > value.date { continue }
            byID[value.recordID] = value
        }
        return byID.values.sorted { lhs, rhs in
            lhs.date == rhs.date ? lhs.recordID < rhs.recordID : lhs.date < rhs.date
        }
    }
}
