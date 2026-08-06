import Foundation

public struct CodexJSONLSource: SourceAdapter {
    public let sourceKey: String
    private let fileURL: URL
    private let reader: JSONLReader
    private let parser: CodexConversationParser

    public init(fileURL: URL, reader: JSONLReader = JSONLReader()) {
        self.fileURL = fileURL.standardizedFileURL
        sourceKey = "codex-jsonl:\(self.fileURL.path)"
        self.reader = reader
        parser = CodexConversationParser()
    }

    public func collect(request: CollectionRequest, cursor: Data?) async throws -> CollectionBatch {
        let previous = try cursor.map { try JSONDecoder().decode(JSONLFileCursor.self, from: $0) }
        let result = try reader.read(fileURL, after: previous)
        guard !result.lines.isEmpty else {
            return CollectionBatch(sourceKey: sourceKey, records: [], nextCursor: try JSONEncoder().encode(result.cursor))
        }

        var lines = result.lines
        if let first = try reader.readFirstLine(fileURL), first != lines.first {
            lines.insert(first, at: 0)
        }
        let parsed = try parser.parse(
            lines: lines,
            fallbackSessionID: StableHash.sha256(fileURL.path),
            observedAt: request.cutoff
        )
        return CollectionBatch(
            sourceKey: sourceKey,
            sessions: [parsed.session],
            messages: parsed.messages,
            records: parsed.records,
            processedSourceRecords: result.processedRecordCount,
            nextCursor: try JSONEncoder().encode(result.cursor)
        )
    }
}

public struct ClaudeJSONLSource: SourceAdapter {
    public let sourceKey: String
    private let fileURL: URL
    private let reader: JSONLReader
    private let parser: ClaudeConversationParser

    public init(fileURL: URL, reader: JSONLReader = JSONLReader()) {
        self.fileURL = fileURL.standardizedFileURL
        sourceKey = "claude-jsonl:\(self.fileURL.path)"
        self.reader = reader
        parser = ClaudeConversationParser()
    }

    public func collect(request: CollectionRequest, cursor: Data?) async throws -> CollectionBatch {
        let previous = try cursor.map { try JSONDecoder().decode(JSONLFileCursor.self, from: $0) }
        let result = try reader.read(fileURL, after: previous)
        guard !result.lines.isEmpty else {
            return CollectionBatch(sourceKey: sourceKey, records: [], nextCursor: try JSONEncoder().encode(result.cursor))
        }

        let parsed = try parser.parse(
            lines: result.lines,
            fallbackSessionID: StableHash.sha256(fileURL.path),
            observedAt: request.cutoff
        )
        return CollectionBatch(
            sourceKey: sourceKey,
            sessions: [parsed.session],
            messages: parsed.messages,
            records: parsed.records,
            processedSourceRecords: result.processedRecordCount,
            nextCursor: try JSONEncoder().encode(result.cursor)
        )
    }
}
