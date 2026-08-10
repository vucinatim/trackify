import Foundation

public struct ConversationSession: Codable, Equatable, Sendable {
    public let id: SessionID
    public let source: SourceKind
    public let sourceSessionID: String
    public let startedAt: Date?
    public var lastObservedAt: Date
    public var workingDirectory: String?
    public var sourceVersion: String?
    public var state: ObservedState

    public init(
        id: SessionID,
        source: SourceKind,
        sourceSessionID: String,
        startedAt: Date? = nil,
        lastObservedAt: Date,
        workingDirectory: String? = nil,
        sourceVersion: String? = nil,
        state: ObservedState
    ) {
        self.id = id
        self.source = source
        self.sourceSessionID = sourceSessionID
        self.startedAt = startedAt
        self.lastObservedAt = lastObservedAt
        self.workingDirectory = workingDirectory
        self.sourceVersion = sourceVersion
        self.state = state
    }
}

public enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

public struct ConversationMessage: Codable, Equatable, Sendable {
    public let id: MessageID
    public let sessionID: SessionID
    public let sourceMessageID: String?
    public let role: MessageRole
    public let occurredAt: Date?
    public let normalizedText: String
    public let fingerprint: String
    public let provenance: ConversationProvenance

    public init(
        id: MessageID,
        sessionID: SessionID,
        sourceMessageID: String? = nil,
        role: MessageRole,
        occurredAt: Date? = nil,
        normalizedText: String,
        fingerprint: String,
        provenance: ConversationProvenance = ConversationProvenance()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sourceMessageID = sourceMessageID
        self.role = role
        self.occurredAt = occurredAt
        self.normalizedText = normalizedText
        self.fingerprint = fingerprint
        self.provenance = provenance
    }
}

public enum ConversationMessageVisibility {
    /// Transport/control envelopes are not authored work evidence. Providers
    /// may expose them as user-role messages, so role alone is insufficient.
    public static func isWorkEvidence(_ message: ConversationMessage) -> Bool {
        workText(message) != nil
    }

    /// Returns only developer-authored work text. Local CLI control records and
    /// application context can be stored with a user role by upstream tools,
    /// but they are transport metadata rather than intent.
    public static func workText(_ message: ConversationMessage) -> String? {
        guard message.provenance.disposition == .work,
            message.provenance.canonicalState == .primary
        else { return nil }
        guard message.role != .system else { return nil }
        let original = message.normalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = original.lowercased()
        let controlPrefixes = [
            "<codex_internal_context", "<app-context>", "<environment_context>",
            "<permissions instructions>", "<skills_instructions>", "<developer",
            "<local-command-caveat", "<command-name>", "<command-message>",
            "<command-args>", "<local-command-stdout>", "<local-command-stderr>",
            "# agents.md instructions", "<instructions>",
        ]
        guard !controlPrefixes.contains(where: value.hasPrefix) else { return nil }

        var cleaned = original
        let embeddedControlPatterns = [
            #"(?is)<local-command-caveat\b[^>]*>.*?</local-command-caveat>"#,
            #"(?is)<command-(?:name|message|args)\b[^>]*>.*?</command-(?:name|message|args)>"#,
            #"(?is)<local-command-(?:stdout|stderr)\b[^>]*>.*?</local-command-(?:stdout|stderr)>"#,
        ]
        for pattern in embeddedControlPatterns {
            cleaned = cleaned.replacingOccurrences(
                of: pattern, with: "", options: .regularExpression)
        }
        if let marker = cleaned.range(of: "## My request for Codex:", options: .caseInsensitive) {
            cleaned = String(cleaned[marker.upperBound...])
        } else if cleaned.lowercased().hasPrefix("# files mentioned by the user:") {
            return nil
        }
        let result = MessageTextSanitizer.removingAttachments(cleaned)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}

public struct RunObservation: Codable, Equatable, Sendable {
    public let id: RunID
    public let sessionID: SessionID
    public let sourceTurnID: String?
    public let parentRunID: RunID?
    public let occurredAt: Date
    public let state: ObservedState

    public init(
        id: RunID,
        sessionID: SessionID,
        sourceTurnID: String? = nil,
        parentRunID: RunID? = nil,
        occurredAt: Date,
        state: ObservedState
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sourceTurnID = sourceTurnID
        self.parentRunID = parentRunID
        self.occurredAt = occurredAt
        self.state = state
    }
}
