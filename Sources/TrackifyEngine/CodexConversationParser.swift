import Foundation
import TrackifyDomain

public struct CodexConversationParser: Sendable {
    public static let adapterVersion = 6

    private struct PendingMessage {
        let sourceRecordID: String?
        let sourceMessageID: String?
        let sourceTurnID: String?
        let recordType: String
        let role: MessageRole
        let date: Date?
        let text: String
        let workingDirectory: String?
    }

    private struct PendingStructuralRecord {
        let sourceRecordID: String?
        let sourceTurnID: String?
        let recordType: String
        let date: Date?
        let workingDirectory: String?
        let disposition: EvidenceDisposition
        let semanticKind: ConversationSemanticKind
        let reason: String
    }

    public init() {}

    public func parse(
        lines: [Data],
        fallbackSessionID: String,
        observedAt: Date,
        previousState: ConversationParserState = ConversationParserState()
    ) throws -> ConversationParseResult {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var externalSessionID = previousState.externalSessionID ?? fallbackSessionID
        var startedAt: Date? = previousState.startedAt
        var lastObservedAt = previousState.lastObservedAt ?? observedAt
        var workingDirectory: String? = previousState.workingDirectory
        var sourceVersion: String? = previousState.sourceVersion
        var state: ObservedState = previousState.observedState
        var currentTurnID = previousState.currentTurnID
        var pendingMessages: [PendingMessage] = []
        var pendingStructuralRecords: [PendingStructuralRecord] = []
        var lifecycleValues: [(recordID: String, date: Date, kind: EventKind, state: ObservedState, payload: [String: String])] = []
        var unknownRecordCount = 0

        for line in lines {
            try autoreleasepool {
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
                    let payload = ConversationJSON.object(object, "payload") ?? [:]
                    currentTurnID = ConversationJSON.string(payload, "turn_id") ?? currentTurnID
                    pendingStructuralRecords.append(
                        PendingStructuralRecord(
                            sourceRecordID: ConversationJSON.string(payload, "turn_id"),
                            sourceTurnID: ConversationJSON.string(payload, "turn_id"),
                            recordType: "turn_context", date: timestamp,
                            workingDirectory: workingDirectory, disposition: .control,
                            semanticKind: .control, reason: "codex-turn-context"))

                case "event_msg":
                    let payload = ConversationJSON.object(object, "payload") ?? [:]
                    let payloadType = payload["type"] as? String ?? ""
                    let turnID =
                        (payload["turn_id"] as? String) ?? (payload["turnId"] as? String)
                        ?? currentTurnID
                    currentTurnID = turnID ?? currentTurnID
                    guard let timestamp else { return }

                    switch payloadType {
                    case "task_started":
                        let identity = turnID ?? "timestamp:\(timestamp.timeIntervalSince1970)"
                        lifecycleValues.append(
                            (
                                "session:\(externalSessionID):turn:\(identity):started", timestamp, .agentRunStarted, .inProgress,
                                turnID.map { ["turnID": $0] } ?? [:]
                            ))
                        state = .inProgress
                        pendingStructuralRecords.append(
                            PendingStructuralRecord(
                                sourceRecordID: "turn:\(turnID ?? String(timestamp.timeIntervalSince1970)):started",
                                sourceTurnID: turnID, recordType: "event_msg.task_started",
                                date: timestamp, workingDirectory: workingDirectory,
                                disposition: .control, semanticKind: .lifecycle,
                                reason: "codex-task-started"))
                    case "task_complete":
                        let identity = turnID ?? "timestamp:\(timestamp.timeIntervalSince1970)"
                        lifecycleValues.append(
                            (
                                "session:\(externalSessionID):turn:\(identity):completed", timestamp, .agentRunFinished, .completed,
                                turnID.map { ["turnID": $0] } ?? [:]
                            ))
                        state = .completed
                        pendingStructuralRecords.append(
                            PendingStructuralRecord(
                                sourceRecordID: "turn:\(turnID ?? String(timestamp.timeIntervalSince1970)):completed",
                                sourceTurnID: turnID, recordType: "event_msg.task_complete",
                                date: timestamp, workingDirectory: workingDirectory,
                                disposition: .control, semanticKind: .lifecycle,
                                reason: "codex-task-complete"))
                    case "turn_aborted":
                        let identity = turnID ?? "timestamp:\(timestamp.timeIntervalSince1970)"
                        lifecycleValues.append(
                            (
                                "session:\(externalSessionID):turn:\(identity):interrupted", timestamp, .agentRunFinished, .interrupted,
                                turnID.map { ["turnID": $0] } ?? [:]
                            ))
                        state = .interrupted
                        pendingStructuralRecords.append(
                            PendingStructuralRecord(
                                sourceRecordID: "turn:\(turnID ?? String(timestamp.timeIntervalSince1970)):aborted",
                                sourceTurnID: turnID, recordType: "event_msg.turn_aborted",
                                date: timestamp, workingDirectory: workingDirectory,
                                disposition: .diagnostic, semanticKind: .lifecycle,
                                reason: "codex-turn-aborted"))
                    case "error":
                        let identity = turnID ?? "timestamp:\(timestamp.timeIntervalSince1970)"
                        lifecycleValues.append(
                            ("session:\(externalSessionID):turn:\(identity):failed", timestamp, .agentRunFinished, .failed, [:]))
                        state = .failed
                        pendingStructuralRecords.append(
                            PendingStructuralRecord(
                                sourceRecordID: "turn:\(turnID ?? String(timestamp.timeIntervalSince1970)):error",
                                sourceTurnID: turnID, recordType: "event_msg.error",
                                date: timestamp, workingDirectory: workingDirectory,
                                disposition: .diagnostic, semanticKind: .failure,
                                reason: "codex-run-error"))
                    case "user_message":
                        if let text = ConversationJSON.normalized(payload["message"] as? String ?? "") {
                            let clientID = payload["client_id"] as? String
                            pendingMessages.append(
                                PendingMessage(
                                    sourceRecordID: clientID ?? turnID,
                                    sourceMessageID: clientID,
                                    sourceTurnID: turnID,
                                    recordType: "event_msg.user_message", role: .user,
                                    date: timestamp, text: text,
                                    workingDirectory: workingDirectory))
                        }
                    case "agent_message":
                        if let text = ConversationJSON.normalized(payload["message"] as? String ?? "") {
                            pendingMessages.append(
                                PendingMessage(
                                    sourceRecordID: payload["id"] as? String ?? turnID,
                                    sourceMessageID: payload["id"] as? String,
                                    sourceTurnID: turnID,
                                    recordType: "event_msg.agent_message", role: .assistant,
                                    date: timestamp, text: text,
                                    workingDirectory: workingDirectory))
                        }
                    case "agent_reasoning", "token_count", "thread_settings_applied", "patch_apply_end", "web_search_end",
                        "context_compacted",
                        "image_generation_end", "exec_command_end", "mcp_tool_call_end",
                        "thread_goal_updated", "thread_rolled_back":
                        pendingStructuralRecords.append(
                            PendingStructuralRecord(
                                sourceRecordID: (payload["call_id"] as? String) ?? turnID,
                                sourceTurnID: turnID,
                                recordType: "event_msg.\(payloadType)", date: timestamp,
                                workingDirectory: workingDirectory, disposition: .control,
                                semanticKind: .control, reason: "codex-known-transport-event"))
                    default:
                        unknownRecordCount += 1
                        pendingStructuralRecords.append(
                            PendingStructuralRecord(
                                sourceRecordID: turnID,
                                sourceTurnID: turnID,
                                recordType: "event_msg.unknown:\(payloadType.isEmpty ? "missing" : payloadType)",
                                date: timestamp, workingDirectory: workingDirectory,
                                disposition: .unresolved, semanticKind: .unknown,
                                reason: "codex-unknown-event-message"))
                    }

                case "response_item":
                    let payload = ConversationJSON.object(object, "payload") ?? [:]
                    let itemType = payload["type"] as? String ?? "missing"
                    guard itemType == "message" else {
                        pendingStructuralRecords.append(
                            PendingStructuralRecord(
                                sourceRecordID: payload["id"] as? String,
                                sourceTurnID: ConversationJSON.string(payload, "turn_id"),
                                recordType: "response_item.\(itemType)", date: timestamp,
                                workingDirectory: workingDirectory, disposition: .control,
                                semanticKind: .control, reason: "codex-response-transport-item"))
                        return
                    }
                    guard let roleValue = payload["role"] as? String,
                        let role = MessageRole(rawValue: roleValue),
                        let text = ConversationJSON.textContent(payload["content"])
                    else {
                        pendingStructuralRecords.append(
                            PendingStructuralRecord(
                                sourceRecordID: payload["id"] as? String,
                                sourceTurnID: ConversationJSON.string(payload, "turn_id"),
                                recordType: "response_item.message.unsupported-role-or-content",
                                date: timestamp, workingDirectory: workingDirectory,
                                disposition: .control, semanticKind: .control,
                                reason: "codex-non-work-response-message"))
                        return
                    }
                    let sourceMessageID = payload["id"] as? String
                    let sourceTurnID =
                        ConversationJSON.string(payload, "turn_id")
                        ?? ConversationJSON.string(payload, "internal_chat_message_metadata_passthrough", "turn_id")
                    pendingMessages.append(
                        PendingMessage(
                            sourceRecordID: sourceMessageID,
                            sourceMessageID: sourceMessageID,
                            sourceTurnID: sourceTurnID,
                            recordType: "response_item.message", role: role,
                            date: timestamp, text: text,
                            workingDirectory: workingDirectory))

                case "world_state", "compacted":
                    break
                default:
                    unknownRecordCount += 1
                    pendingStructuralRecords.append(
                        PendingStructuralRecord(
                            sourceRecordID: nil, sourceTurnID: nil,
                            recordType: "unknown:\(type.isEmpty ? "missing" : type)",
                            date: timestamp, workingDirectory: workingDirectory,
                            disposition: .unresolved, semanticKind: .unknown,
                            reason: "codex-unknown-record-family"))
                }
            }
        }

        let sessionID = ConversationRecordFactory.sessionID(source: .codex, externalID: externalSessionID)
        let messages = pendingMessages.map { pending in
            let classification = classification(
                role: pending.role, text: pending.text,
                workingDirectory: pending.workingDirectory)
            let logicalTurnID = ConversationRecordFactory.logicalTurnID(
                source: .codex, sourceTurnID: pending.sourceTurnID)
            let logicalMessageID = ConversationRecordFactory.logicalMessageID(
                source: .codex,
                // Codex may expose one message through event_msg and
                // response_item with different wrapper IDs. Within an
                // authoritative turn, role + content is the documented dual-
                // family identity; outside a turn the provider ID remains
                // authoritative.
                sourceMessageID: pending.sourceTurnID == nil ? pending.sourceMessageID : nil,
                sourceTurnID: pending.sourceTurnID,
                role: pending.role,
                occurredAt: pending.date,
                text: pending.text)
            let canonicalState: CanonicalRecordState = logicalMessageID == nil ? .unresolved : .primary
            let provenance = ConversationProvenance(
                sourceRecordID: pending.sourceRecordID,
                sourceRecordType: pending.recordType,
                sourceTurnID: pending.sourceTurnID,
                sourceResponseID: pending.sourceMessageID,
                entrypoint: "codex",
                workingDirectory: pending.workingDirectory,
                origin: classification.origin,
                semanticKind: classification.kind,
                disposition: logicalMessageID == nil ? .unresolved : classification.disposition,
                canonicalState: canonicalState,
                classificationReason: logicalMessageID == nil
                    ? "codex-message-missing-logical-identity" : classification.reason,
                logicalTurnID: logicalTurnID,
                logicalMessageID: logicalMessageID)
            return ConversationRecordFactory.message(
                source: .codex,
                sessionID: sessionID,
                sourceMessageID: pending.sourceMessageID,
                role: pending.role,
                occurredAt: pending.date,
                text: pending.text,
                provenance: provenance
            )
        }
        let normalizedRecords =
            messages.map {
                ConversationRecordFactory.normalizedRecord(
                    source: .codex, sessionID: sessionID,
                    occurredAt: $0.occurredAt, observedAt: observedAt,
                    role: $0.role, text: $0.normalizedText,
                    provenance: $0.provenance, adapterVersion: Self.adapterVersion)
            }
            + pendingStructuralRecords.map { pending in
                let provenance = ConversationProvenance(
                    sourceRecordID: pending.sourceRecordID,
                    sourceRecordType: pending.recordType,
                    sourceTurnID: pending.sourceTurnID,
                    entrypoint: "codex",
                    workingDirectory: pending.workingDirectory,
                    origin: pending.disposition == .diagnostic ? .provider : .system,
                    semanticKind: pending.semanticKind,
                    disposition: pending.disposition,
                    canonicalState: pending.disposition == .unresolved ? .unresolved : .primary,
                    classificationReason: pending.reason,
                    logicalTurnID: ConversationRecordFactory.logicalTurnID(
                        source: .codex, sourceTurnID: pending.sourceTurnID))
                return ConversationRecordFactory.normalizedRecord(
                    source: .codex, sessionID: sessionID,
                    occurredAt: pending.date, observedAt: observedAt,
                    role: nil, text: nil, provenance: provenance,
                    adapterVersion: Self.adapterVersion)
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
            normalizedRecords: normalizedRecords,
            records: (lifecycleRecords + messageRecords).sorted {
                $0.event.occurredAt == $1.event.occurredAt
                    ? $0.event.id.rawValue < $1.event.id.rawValue
                    : $0.event.occurredAt < $1.event.occurredAt
            },
            unknownRecordCount: unknownRecordCount,
            parserState: ConversationParserState(
                externalSessionID: externalSessionID, startedAt: startedAt,
                lastObservedAt: lastObservedAt, workingDirectory: workingDirectory,
                sourceVersion: sourceVersion, observedState: state,
                currentTurnID: currentTurnID)
        )
    }

    private func classification(
        role: MessageRole,
        text: String,
        workingDirectory: String?
    ) -> (
        origin: ConversationOrigin,
        kind: ConversationSemanticKind,
        disposition: EvidenceDisposition,
        reason: String
    ) {
        if isTrackifyInternal(workingDirectory) {
            return (.trackify, .diagnostic, .diagnostic, "trackify-internal-provider-operation")
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let controls = [
            "<codex_internal_context", "<app-context>", "<environment_context>",
            "<permissions instructions>", "<skills_instructions>", "<developer",
            "<turn_aborted>", "# agents.md instructions", "<local-command-",
        ]
        if controls.contains(where: value.hasPrefix) {
            return (.system, .control, .control, "codex-transport-or-internal-context")
        }
        if role == .user {
            return (.human, .intent, .work, "codex-user-message")
        }
        if value.contains("out of") && value.contains("usage")
            || value.contains("invalid api key")
            || value.contains("session limit")
        {
            return (.provider, .failure, .diagnostic, "codex-provider-failure")
        }
        return (.assistant, .progress, .work, "codex-assistant-message")
    }

    private func isTrackifyInternal(_ path: String?) -> Bool {
        guard let path else { return false }
        return URL(filePath: path).pathComponents.contains {
            $0.hasPrefix("trackify-internal-")
                || $0.hasPrefix("trackify-codex-report-")
        }
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
