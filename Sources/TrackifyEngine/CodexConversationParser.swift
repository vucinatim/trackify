import Foundation
import TrackifyDomain

public struct CodexConversationParser: Sendable {
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
            let timestamp = ConversationJSON.date(ConversationJSON.string(object, "timestamp"), formatter: formatter)
            if let timestamp {
                startedAt = min(startedAt ?? timestamp, timestamp)
                lastObservedAt = max(lastObservedAt, timestamp)
            }

            switch type {
            case "session_meta":
                let payload = ConversationJSON.object(object, "payload") ?? [:]
                externalSessionID = (payload["id"] as? String) ?? (payload["session_id"] as? String) ?? externalSessionID
                workingDirectory = payload["cwd"] as? String
                sourceVersion = payload["cli_version"] as? String

            case "turn_context":
                workingDirectory = ConversationJSON.string(object, "payload", "cwd") ?? workingDirectory

            case "event_msg":
                let payload = ConversationJSON.object(object, "payload") ?? [:]
                let payloadType = payload["type"] as? String ?? ""
                let turnID = (payload["turn_id"] as? String) ?? (payload["turnId"] as? String)
                guard let timestamp else { continue }

                switch payloadType {
                case "task_started":
                    let identity = turnID ?? "timestamp:\(timestamp.timeIntervalSince1970)"
                    lifecycleValues.append(
                        (
                            "session:\(externalSessionID):turn:\(identity):started", timestamp, .agentRunStarted, .inProgress,
                            turnID.map { ["turnID": $0] } ?? [:]
                        ))
                    state = .inProgress
                case "task_complete":
                    let identity = turnID ?? "timestamp:\(timestamp.timeIntervalSince1970)"
                    lifecycleValues.append(
                        (
                            "session:\(externalSessionID):turn:\(identity):completed", timestamp, .agentRunFinished, .completed,
                            turnID.map { ["turnID": $0] } ?? [:]
                        ))
                    state = .completed
                case "turn_aborted":
                    let identity = turnID ?? "timestamp:\(timestamp.timeIntervalSince1970)"
                    lifecycleValues.append(
                        (
                            "session:\(externalSessionID):turn:\(identity):interrupted", timestamp, .agentRunFinished, .interrupted,
                            turnID.map { ["turnID": $0] } ?? [:]
                        ))
                    state = .interrupted
                case "error":
                    let identity = turnID ?? "timestamp:\(timestamp.timeIntervalSince1970)"
                    lifecycleValues.append(
                        ("session:\(externalSessionID):turn:\(identity):failed", timestamp, .agentRunFinished, .failed, [:]))
                    state = .failed
                case "user_message":
                    if let text = ConversationJSON.normalized(payload["message"] as? String ?? "") {
                        pendingMessages.append((turnID, .user, timestamp, text))
                    }
                case "agent_message":
                    if let text = ConversationJSON.normalized(payload["message"] as? String ?? "") {
                        pendingMessages.append((turnID, .assistant, timestamp, text))
                    }
                case "agent_reasoning", "token_count", "thread_settings_applied", "patch_apply_end", "web_search_end", "context_compacted",
                    "image_generation_end", "exec_command_end":
                    break
                default:
                    unknownRecordCount += 1
                }

            case "response_item":
                let payload = ConversationJSON.object(object, "payload") ?? [:]
                guard payload["type"] as? String == "message",
                    let roleValue = payload["role"] as? String,
                    let role = MessageRole(rawValue: roleValue),
                    let text = ConversationJSON.textContent(payload["content"])
                else { continue }
                pendingMessages.append((payload["id"] as? String, role, timestamp, text))

            case "world_state", "compacted":
                break
            default:
                unknownRecordCount += 1
            }
        }

        let sessionID = ConversationRecordFactory.sessionID(source: .codex, externalID: externalSessionID)
        let messages = pendingMessages.map {
            ConversationRecordFactory.message(
                source: .codex,
                sessionID: sessionID,
                sourceMessageID: $0.id,
                role: $0.role,
                occurredAt: $0.date,
                text: $0.text
            )
        }
        let lifecycleRecords = deduplicated(lifecycleValues).map {
            ConversationRecordFactory.lifecycle(
                source: .codex,
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
            ConversationRecordFactory.messageRecord(source: .codex, message: $0, observedAt: observedAt)
        }
        let session = ConversationSession(
            id: sessionID,
            source: .codex,
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
