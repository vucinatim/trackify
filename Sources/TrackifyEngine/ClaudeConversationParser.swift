import Foundation
import TrackifyDomain

public struct ClaudeConversationParser: Sendable {
    public static let adapterVersion = 6
    private static let maximumRememberedRecordTurns = 256

    private struct PendingMessage {
        let sourceRecordID: String?
        let sourceMessageID: String?
        let sourceTurnID: String?
        let parentSourceRecordID: String?
        let recordType: String
        let role: MessageRole
        let date: Date?
        let text: String
        let workingDirectory: String?
        let entrypoint: String?
        let isMeta: Bool
        let isProviderGeneratedContext: Bool
        let isSidechain: Bool
        let hasToolResult: Bool
        let hasSourceTool: Bool
    }

    private struct PendingStructuralRecord {
        let sourceRecordID: String?
        let sourceTurnID: String?
        let parentSourceRecordID: String?
        let recordType: String
        let date: Date?
        let workingDirectory: String?
        let entrypoint: String?
        let origin: ConversationOrigin
        let disposition: EvidenceDisposition
        let semanticKind: ConversationSemanticKind
        let reason: String
        let isMeta: Bool
        let isSidechain: Bool
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
        var pendingMessages: [PendingMessage] = []
        var pendingStructuralRecords: [PendingStructuralRecord] = []
        var currentTurnID: String? = previousState.currentTurnID
        var lifecycleValues: [(recordID: String, date: Date, kind: EventKind, state: ObservedState, payload: [String: String])] = []
        var unknownRecordCount = 0
        var currentSidechainTurnID = previousState.currentSidechainTurnID
        var recordTurnIDs = previousState.recordTurnIDs
        var recordTurnOrder = previousState.recordTurnOrder

        func rememberedTurnID(parentRecordID: String?, fallback: String?) -> String? {
            parentRecordID.flatMap { recordTurnIDs[$0] } ?? fallback
        }

        func rememberTurn(_ turnID: String?, for recordID: String?) {
            guard let turnID, let recordID else { return }
            if recordTurnIDs[recordID] == nil { recordTurnOrder.append(recordID) }
            recordTurnIDs[recordID] = turnID
            let overflow = recordTurnOrder.count - Self.maximumRememberedRecordTurns
            if overflow > 0 {
                for expired in recordTurnOrder.prefix(overflow) { recordTurnIDs.removeValue(forKey: expired) }
                recordTurnOrder.removeFirst(overflow)
            }
        }

        for line in lines {
            try autoreleasepool {
                let object = try ConversationJSON.object(line)
                let type = ConversationJSON.string(object, "type") ?? ""
                externalSessionID = ConversationJSON.string(object, "sessionId") ?? externalSessionID
                workingDirectory = ConversationJSON.string(object, "cwd") ?? workingDirectory
                sourceVersion = ConversationJSON.string(object, "version") ?? sourceVersion
                let sourceRecordID = ConversationJSON.string(object, "uuid")
                let parentSourceRecordID = ConversationJSON.string(object, "parentUuid")
                let entrypoint = ConversationJSON.string(object, "entrypoint")
                let isProviderGeneratedContext =
                    object["isCompactSummary"] as? Bool == true
                    || object["isVisibleInTranscriptOnly"] as? Bool == true
                let isMeta = object["isMeta"] as? Bool == true || isProviderGeneratedContext
                let isSidechain = object["isSidechain"] as? Bool ?? false
                let timestamp = ConversationJSON.date(ConversationJSON.string(object, "timestamp"), formatter: formatter)
                if let timestamp {
                    startedAt = min(startedAt ?? timestamp, timestamp)
                    lastObservedAt = max(lastObservedAt, timestamp)
                }

                switch type {
                case "user":
                    guard let timestamp else { return }
                    let content = ConversationJSON.object(object, "message")?["content"]
                    let promptID = ConversationJSON.string(object, "promptId")
                    let hasToolResult =
                        Self.containsContentType(content, "tool_result")
                        || object["toolUseResult"] != nil
                    let hasSourceTool = object["sourceToolAssistantUUID"] != nil
                    let laneTurnID = isSidechain ? currentSidechainTurnID : currentTurnID
                    let providerTurnID = promptID ?? sourceRecordID
                    let turnSourceID: String?
                    if hasToolResult || hasSourceTool {
                        turnSourceID = rememberedTurnID(
                            parentRecordID: parentSourceRecordID,
                            fallback: laneTurnID ?? providerTurnID)
                    } else if isSidechain {
                        turnSourceID = sourceRecordID ?? providerTurnID
                        currentSidechainTurnID = turnSourceID ?? currentSidechainTurnID
                    } else {
                        turnSourceID = providerTurnID
                        currentTurnID = turnSourceID ?? currentTurnID
                    }
                    rememberTurn(turnSourceID, for: sourceRecordID)
                    if let text = ConversationJSON.textContent(content) {
                        pendingMessages.append(
                            PendingMessage(
                                sourceRecordID: sourceRecordID,
                                sourceMessageID: sourceRecordID,
                                sourceTurnID: turnSourceID,
                                parentSourceRecordID: parentSourceRecordID,
                                recordType: "user", role: .user, date: timestamp,
                                text: text, workingDirectory: workingDirectory,
                                entrypoint: entrypoint, isMeta: isMeta,
                                isProviderGeneratedContext: isProviderGeneratedContext,
                                isSidechain: isSidechain,
                                hasToolResult: hasToolResult,
                                hasSourceTool: hasSourceTool))
                        if !hasToolResult && !hasSourceTool && !isMeta {
                            let turnID = turnSourceID ?? "timestamp:\(timestamp.timeIntervalSince1970)"
                            lifecycleValues.append(
                                (
                                    "session:\(externalSessionID):turn:\(turnID):started", timestamp, .agentRunStarted, .inProgress,
                                    ["turnID": turnID]
                                ))
                            state = .inProgress
                        }
                    } else {
                        pendingStructuralRecords.append(
                            PendingStructuralRecord(
                                sourceRecordID: sourceRecordID, sourceTurnID: turnSourceID,
                                parentSourceRecordID: parentSourceRecordID,
                                recordType: hasToolResult ? "user.tool_result" : "user.non_text",
                                date: timestamp, workingDirectory: workingDirectory,
                                entrypoint: entrypoint,
                                origin: hasToolResult ? .tool : (isMeta ? .system : .unknown),
                                disposition: hasToolResult || isMeta ? .control : .unresolved,
                                semanticKind: hasToolResult ? .control : .unknown,
                                reason: hasToolResult ? "claude-tool-result" : "claude-user-non-text",
                                isMeta: isMeta, isSidechain: isSidechain))
                    }

                case "assistant":
                    guard let timestamp else { return }
                    let message = ConversationJSON.object(object, "message") ?? [:]
                    let responseID = message["id"] as? String
                    let sourceID = sourceRecordID ?? responseID
                    let laneTurnID = isSidechain ? currentSidechainTurnID : currentTurnID
                    let messageTurnID = rememberedTurnID(
                        parentRecordID: parentSourceRecordID,
                        fallback: laneTurnID)
                    rememberTurn(messageTurnID, for: sourceRecordID)
                    if let text = ConversationJSON.textContent(message["content"]) {
                        pendingMessages.append(
                            PendingMessage(
                                sourceRecordID: sourceRecordID,
                                sourceMessageID: responseID ?? sourceID,
                                sourceTurnID: messageTurnID,
                                parentSourceRecordID: parentSourceRecordID,
                                recordType: "assistant", role: .assistant,
                                date: timestamp, text: text,
                                workingDirectory: workingDirectory,
                                entrypoint: entrypoint, isMeta: isMeta,
                                isProviderGeneratedContext: isProviderGeneratedContext,
                                isSidechain: isSidechain,
                                hasToolResult: false, hasSourceTool: false))
                    }
                    let stopReason = message["stop_reason"] as? String
                    if stopReason == "end_turn" {
                        let turnID = messageTurnID ?? sourceID ?? "timestamp:\(timestamp.timeIntervalSince1970)"
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
                    guard let timestamp else { return }
                    let subtype = ConversationJSON.string(object, "subtype") ?? "unknown"
                    let recordTurnID = rememberedTurnID(
                        parentRecordID: parentSourceRecordID,
                        fallback: isSidechain ? currentSidechainTurnID : currentTurnID)
                    rememberTurn(recordTurnID, for: sourceRecordID)
                    if subtype == "api_error" {
                        let identity = sourceRecordID ?? "timestamp:\(timestamp.timeIntervalSince1970)"
                        lifecycleValues.append(
                            ("session:\(externalSessionID):error:\(identity)", timestamp, .agentRunFinished, .failed, [:]))
                        state = .failed
                    }
                    pendingStructuralRecords.append(
                        PendingStructuralRecord(
                            sourceRecordID: sourceRecordID, sourceTurnID: recordTurnID,
                            parentSourceRecordID: parentSourceRecordID,
                            recordType: "system.\(subtype)", date: timestamp,
                            workingDirectory: workingDirectory, entrypoint: entrypoint,
                            origin: .provider,
                            disposition: subtype == "api_error" ? .diagnostic : .control,
                            semanticKind: subtype == "api_error" ? .failure : .control,
                            reason: "claude-system-\(subtype)",
                            isMeta: isMeta, isSidechain: isSidechain))

                case "queue-operation", "attachment", "ai-title", "custom-title", "last-prompt", "mode", "pr-link", "frame-link":
                    let recordTurnID = rememberedTurnID(
                        parentRecordID: parentSourceRecordID,
                        fallback: isSidechain ? currentSidechainTurnID : currentTurnID)
                    rememberTurn(recordTurnID, for: sourceRecordID)
                    pendingStructuralRecords.append(
                        PendingStructuralRecord(
                            sourceRecordID: sourceRecordID, sourceTurnID: recordTurnID,
                            parentSourceRecordID: parentSourceRecordID,
                            recordType: type, date: timestamp,
                            workingDirectory: workingDirectory, entrypoint: entrypoint,
                            origin: .system, disposition: .control,
                            semanticKind: .control, reason: "claude-transport-record",
                            isMeta: isMeta, isSidechain: isSidechain))
                default:
                    unknownRecordCount += 1
                    let recordTurnID = rememberedTurnID(
                        parentRecordID: parentSourceRecordID,
                        fallback: isSidechain ? currentSidechainTurnID : currentTurnID)
                    rememberTurn(recordTurnID, for: sourceRecordID)
                    pendingStructuralRecords.append(
                        PendingStructuralRecord(
                            sourceRecordID: sourceRecordID, sourceTurnID: recordTurnID,
                            parentSourceRecordID: parentSourceRecordID,
                            recordType: "unknown:\(type.isEmpty ? "missing" : type)",
                            date: timestamp, workingDirectory: workingDirectory,
                            entrypoint: entrypoint, origin: .unknown,
                            disposition: .unresolved, semanticKind: .unknown,
                            reason: "claude-unknown-record-family",
                            isMeta: isMeta, isSidechain: isSidechain))
                }
            }
        }

        let sessionID = ConversationRecordFactory.sessionID(source: .claude, externalID: externalSessionID)
        let messages = pendingMessages.map { pending in
            let classification = classification(pending)
            let logicalTurnID = ConversationRecordFactory.logicalTurnID(
                source: .claude, sourceTurnID: pending.sourceTurnID)
            let logicalMessageID = ConversationRecordFactory.logicalMessageID(
                source: .claude,
                sourceMessageID: pending.sourceMessageID,
                sourceTurnID: pending.sourceTurnID,
                role: pending.role,
                occurredAt: pending.date,
                text: pending.text)
            let canonicalState: CanonicalRecordState = logicalMessageID == nil ? .unresolved : .primary
            let provenance = ConversationProvenance(
                sourceRecordID: pending.sourceRecordID,
                sourceRecordType: pending.recordType,
                sourceTurnID: pending.sourceTurnID,
                parentSourceRecordID: pending.parentSourceRecordID,
                sourceResponseID: pending.sourceMessageID,
                entrypoint: pending.entrypoint,
                workingDirectory: pending.workingDirectory,
                isMeta: pending.isMeta,
                isSidechain: pending.isSidechain,
                origin: classification.origin,
                semanticKind: classification.kind,
                disposition: logicalMessageID == nil ? .unresolved : classification.disposition,
                canonicalState: canonicalState,
                classificationReason: logicalMessageID == nil
                    ? "claude-message-missing-logical-identity" : classification.reason,
                logicalTurnID: logicalTurnID,
                logicalMessageID: logicalMessageID)
            return ConversationRecordFactory.message(
                source: .claude,
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
                    source: .claude, sessionID: sessionID,
                    occurredAt: $0.occurredAt, observedAt: observedAt,
                    role: $0.role, text: $0.normalizedText,
                    provenance: $0.provenance, adapterVersion: Self.adapterVersion)
            }
            + pendingStructuralRecords.map { pending in
                let provenance = ConversationProvenance(
                    sourceRecordID: pending.sourceRecordID,
                    sourceRecordType: pending.recordType,
                    sourceTurnID: pending.sourceTurnID,
                    parentSourceRecordID: pending.parentSourceRecordID,
                    entrypoint: pending.entrypoint,
                    workingDirectory: pending.workingDirectory,
                    isMeta: pending.isMeta, isSidechain: pending.isSidechain,
                    origin: pending.origin, semanticKind: pending.semanticKind,
                    disposition: pending.disposition,
                    canonicalState: pending.disposition == .unresolved ? .unresolved : .primary,
                    classificationReason: pending.reason,
                    logicalTurnID: ConversationRecordFactory.logicalTurnID(
                        source: .claude, sourceTurnID: pending.sourceTurnID))
                return ConversationRecordFactory.normalizedRecord(
                    source: .claude, sessionID: sessionID,
                    occurredAt: pending.date, observedAt: observedAt,
                    role: nil, text: nil, provenance: provenance,
                    adapterVersion: Self.adapterVersion)
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
                currentTurnID: currentTurnID,
                currentSidechainTurnID: currentSidechainTurnID,
                recordTurnIDs: recordTurnIDs,
                recordTurnOrder: recordTurnOrder)
        )
    }

    private static func containsContentType(_ content: Any?, _ type: String) -> Bool {
        guard let items = content as? [[String: Any]] else { return false }
        return items.contains { $0["type"] as? String == type }
    }

    private func classification(_ pending: PendingMessage) -> (
        origin: ConversationOrigin,
        kind: ConversationSemanticKind,
        disposition: EvidenceDisposition,
        reason: String
    ) {
        let value = pending.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if isTrackifyInternal(pending.workingDirectory) {
            return (.trackify, .diagnostic, .diagnostic, "trackify-internal-provider-operation")
        }
        if pending.hasToolResult || pending.hasSourceTool {
            return (.tool, .control, .control, "claude-tool-transport")
        }
        if pending.isProviderGeneratedContext {
            return (.system, .control, .control, "claude-provider-generated-context")
        }
        if value.hasPrefix("stop hook feedback:") {
            return (.hook, .control, .diagnostic, "claude-stop-hook-feedback")
        }
        if value.hasPrefix("<task-notification>") {
            return (.agent, .progress, .work, "claude-agent-task-notification")
        }
        if value.hasPrefix("[request interrupted by user") {
            return (.system, .lifecycle, .diagnostic, "claude-interruption-envelope")
        }
        if pending.isMeta {
            return (.system, .control, .control, "claude-meta-record")
        }
        if pending.role == .user {
            if value == "auth" {
                return (.human, .control, .diagnostic, "claude-auth-command")
            }
            return (
                pending.isSidechain ? .agent : .human,
                .intent, .work,
                pending.isSidechain ? "claude-sidechain-intent" : "claude-user-intent"
            )
        }
        if isProviderFailureText(value) {
            return (.provider, .failure, .diagnostic, "claude-provider-failure")
        }
        return (.assistant, .progress, .work, "claude-assistant-message")
    }

    private func isProviderFailureText(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.contains("invalid api key")
            || value.contains("out of extra usage")
            || value.contains("session limit")
            || value == "no response requested."
    }

    private func isTrackifyInternal(_ path: String?) -> Bool {
        guard let path else { return false }
        return URL(filePath: path).pathComponents.contains {
            $0.hasPrefix("trackify-internal-")
                || $0.hasPrefix("trackify-claude-report-")
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
