import Foundation
import TrackifyDomain

private struct ConversationFileCursor: Codable {
    let file: JSONLFileCursor
    let parserState: ConversationParserState
}

private func decodeConversationCursor(_ data: Data?) throws -> ConversationFileCursor? {
    guard let data else { return nil }
    if let value = try? JSONDecoder().decode(ConversationFileCursor.self, from: data) {
        return value
    }
    return ConversationFileCursor(
        file: try JSONDecoder().decode(JSONLFileCursor.self, from: data),
        parserState: ConversationParserState())
}

private func resumedParserState(
    _ previous: ConversationFileCursor?,
    result: JSONLReadResult
) -> ConversationParserState {
    guard let previous,
        previous.file.device == result.cursor.device,
        previous.file.inode == result.cursor.inode,
        previous.file.offset <= result.cursor.offset
    else { return ConversationParserState() }
    return previous.parserState
}

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
        let previous = try decodeConversationCursor(cursor)
        let result = try reader.read(fileURL, after: previous?.file)
        let parserState = resumedParserState(previous, result: result)
        guard !result.lines.isEmpty else {
            return CollectionBatch(
                sourceKey: sourceKey, records: [],
                nextCursor: try JSONEncoder().encode(
                    ConversationFileCursor(
                        file: result.cursor,
                        parserState: parserState)))
        }

        var lines = result.lines
        if let first = try reader.readFirstLine(fileURL), first != lines.first {
            lines.insert(first, at: 0)
        }
        let parsed = try parser.parse(
            lines: lines,
            fallbackSessionID: StableHash.sha256(fileURL.path),
            observedAt: request.cutoff,
            previousState: parserState
        )
        return CollectionBatch(
            sourceKey: sourceKey,
            sessions: [parsed.session],
            messages: parsed.messages,
            conversationRecords: parsed.normalizedRecords,
            records: parsed.records,
            processedSourceRecords: result.processedRecordCount,
            nextCursor: try JSONEncoder().encode(
                ConversationFileCursor(file: result.cursor, parserState: parsed.parserState))
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
        let previous = try decodeConversationCursor(cursor)
        let result = try reader.read(fileURL, after: previous?.file)
        let parserState = resumedParserState(previous, result: result)
        guard !result.lines.isEmpty else {
            return CollectionBatch(
                sourceKey: sourceKey, records: [],
                nextCursor: try JSONEncoder().encode(
                    ConversationFileCursor(
                        file: result.cursor,
                        parserState: parserState)))
        }

        let parsed = try parser.parse(
            lines: result.lines,
            fallbackSessionID: StableHash.sha256(fileURL.path),
            observedAt: request.cutoff,
            previousState: parserState
        )
        return CollectionBatch(
            sourceKey: sourceKey,
            sessions: [parsed.session],
            messages: parsed.messages,
            conversationRecords: parsed.normalizedRecords,
            records: parsed.records,
            processedSourceRecords: result.processedRecordCount,
            nextCursor: try JSONEncoder().encode(
                ConversationFileCursor(file: result.cursor, parserState: parsed.parserState))
        )
    }
}
