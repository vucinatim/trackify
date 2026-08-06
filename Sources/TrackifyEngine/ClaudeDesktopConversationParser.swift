import Foundation
import TrackifyDomain

/// Adapts Claude Desktop Code's local audit stream to the same normalized
/// conversation contract as Claude Code. Only the transcript, stable identity,
/// timestamp, and allowlisted session metadata are retained; audit HMACs and
/// account/configuration fields are never copied into the ledger.
public struct ClaudeDesktopConversationParser: Sendable {
    public struct Metadata: Decodable, Equatable, Sendable {
        public let sessionID: String?
        public let cliSessionID: String?
        public let workingDirectory: String?

        public init(
            sessionID: String? = nil,
            cliSessionID: String? = nil,
            workingDirectory: String? = nil
        ) {
            self.sessionID = sessionID
            self.cliSessionID = cliSessionID
            self.workingDirectory = workingDirectory
        }

        private enum CodingKeys: String, CodingKey {
            case sessionID = "sessionId"
            case cliSessionID = "cliSessionId"
            case workingDirectory = "cwd"
        }
    }

    public init() {}

    public func parse(
        lines: [Data],
        metadata: Metadata?,
        fallbackSessionID: String,
        observedAt: Date
    ) throws -> ConversationParseResult {
        let transformed = try lines.map { line -> Data in
            var object = try ConversationJSON.object(line)
            if object["timestamp"] == nil, let timestamp = object["_audit_timestamp"] as? String {
                object["timestamp"] = timestamp
            }
            if object["sessionId"] == nil {
                object["sessionId"] =
                    object["session_id"] as? String
                    ?? metadata?.cliSessionID
                    ?? metadata?.sessionID
            }
            if object["cwd"] == nil, let path = metadata?.workingDirectory {
                object["cwd"] = path
            }
            object["version"] = "claude-desktop-code-audit-v1"
            object.removeValue(forKey: "_audit_hmac")
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        return try ClaudeConversationParser().parse(
            lines: transformed,
            fallbackSessionID: metadata?.cliSessionID ?? metadata?.sessionID ?? fallbackSessionID,
            observedAt: observedAt
        )
    }
}
