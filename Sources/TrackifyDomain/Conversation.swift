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

    public init(
        id: MessageID,
        sessionID: SessionID,
        sourceMessageID: String? = nil,
        role: MessageRole,
        occurredAt: Date? = nil,
        normalizedText: String,
        fingerprint: String
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sourceMessageID = sourceMessageID
        self.role = role
        self.occurredAt = occurredAt
        self.normalizedText = normalizedText
        self.fingerprint = fingerprint
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
