import Darwin
import Foundation
import TrackifyDomain

public enum HookPhase: String, Codable, CaseIterable, Sendable {
    case started
    case waiting
    case completed
    case failed
    case interrupted
}

public struct HookEnvelope: Codable, Equatable, Sendable {
    public let source: SourceKind
    public let sessionID: String
    public let turnID: String
    public let phase: HookPhase
    public let occurredAt: Date
    public let workingDirectory: String?

    public init(
        source: SourceKind,
        sessionID: String,
        turnID: String,
        phase: HookPhase,
        occurredAt: Date,
        workingDirectory: String?
    ) {
        precondition(source == .codex || source == .claude)
        self.source = source
        self.sessionID = sessionID
        self.turnID = turnID
        self.phase = phase
        self.occurredAt = occurredAt
        self.workingDirectory = workingDirectory
    }
}

public struct HookInboxWriter: Sendable {
    public static let maximumEnvelopeBytes = 64 * 1_024

    public init() {}

    public func append(_ envelope: HookEnvelope, to fileURL: URL) throws {
        guard
            !envelope.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !envelope.turnID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw HookInboxError.emptyIdentifier
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(envelope)
        data.append(0x0A)
        guard data.count <= Self.maximumEnvelopeBytes else {
            throw HookInboxError.envelopeTooLarge(limit: Self.maximumEnvelopeBytes)
        }

        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            guard
                FileManager.default.createFile(
                    atPath: fileURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
            else { throw CocoaError(.fileWriteUnknown) }
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        guard flock(handle.fileDescriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(handle.fileDescriptor, LOCK_UN) }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

public enum HookInboxError: Error, Equatable, LocalizedError {
    case emptyIdentifier
    case envelopeTooLarge(limit: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyIdentifier:
            "Hook session and turn identifiers must not be empty."
        case .envelopeTooLarge(let limit):
            "Hook event exceeded the \(limit)-byte safety limit."
        }
    }
}

public struct HookInboxSource: SourceAdapter {
    public let sourceKey: String
    private let fileURL: URL
    private let reader: JSONLReader
    private let maximumRecords: Int

    public init(fileURL: URL, maximumRecords: Int = 2_000) {
        precondition(maximumRecords > 0)
        self.fileURL = fileURL.standardizedFileURL
        sourceKey = "hook-inbox:\(self.fileURL.path)"
        reader = JSONLReader(maximumLineBytes: 64 * 1_024)
        self.maximumRecords = maximumRecords
    }

    public func collect(request: CollectionRequest, cursor: Data?) async throws -> CollectionBatch {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return CollectionBatch(sourceKey: sourceKey, records: [])
        }
        let previous = try cursor.map { try JSONDecoder().decode(JSONLFileCursor.self, from: $0) }
        let result = try reader.read(fileURL, after: previous, maximumRecords: maximumRecords)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var sessions: [ConversationSession] = []
        var records: [CollectedRecord] = []
        var acceptedRecords = 0
        for line in result.lines {
            let envelope = try decoder.decode(HookEnvelope.self, from: line)
            guard envelope.source == .codex || envelope.source == .claude else { continue }
            if let range = request.range,
                !(envelope.occurredAt >= range.start && envelope.occurredAt < range.end)
            {
                continue
            }
            acceptedRecords += 1
            let sessionID = ConversationRecordFactory.sessionID(
                source: envelope.source,
                externalID: envelope.sessionID
            )
            let state = observedState(envelope.phase)
            sessions.append(
                ConversationSession(
                    id: sessionID,
                    source: envelope.source,
                    sourceSessionID: envelope.sessionID,
                    startedAt: envelope.phase == .started ? envelope.occurredAt : nil,
                    lastObservedAt: request.cutoff,
                    workingDirectory: envelope.workingDirectory,
                    state: state
                ))
            let sourceRecordID = "session:\(envelope.sessionID):turn:\(envelope.turnID):\(recordSuffix(envelope.phase))"
            let canonical = "\(envelope.source.rawValue):\(sourceRecordID)"
            let evidence = SourceEvidence(
                id: EvidenceID(StableHash.sha256("evidence:\(canonical)")),
                source: envelope.source,
                ingestionPath: .hook,
                sourceRecordID: sourceRecordID,
                fingerprint: StableHash.sha256(canonical),
                occurredAt: envelope.occurredAt,
                observedAt: request.cutoff,
                adapterVersion: 1
            )
            records.append(
                CollectedRecord(
                    evidence: evidence,
                    event: LedgerEvent(
                        id: EventID(StableHash.sha256("event:\(canonical)")),
                        evidenceID: evidence.id,
                        occurredAt: envelope.occurredAt,
                        observedAt: request.cutoff,
                        source: envelope.source,
                        kind: eventKind(envelope.phase),
                        sessionID: sessionID,
                        state: state,
                        payload: ["turnID": envelope.turnID]
                    )
                ))
        }
        return CollectionBatch(
            sourceKey: sourceKey,
            sessions: sessions,
            records: records,
            processedSourceRecords: result.processedRecordCount,
            readMetrics: CollectionReadMetrics(
                unit: .file,
                candidatesConsidered: 1,
                openedUnitFingerprints: result.processedBytes > 0
                    ? [StableHash.sha256(fileURL.path)] : [],
                bytesRead: result.processedBytes,
                recordsObserved: result.processedRecordCount,
                recordsAccepted: acceptedRecords),
            nextCursor: try JSONEncoder().encode(result.cursor)
        )
    }

    private func eventKind(_ phase: HookPhase) -> EventKind {
        switch phase {
        case .started: .agentRunStarted
        case .waiting: .agentRunWaiting
        case .completed, .failed, .interrupted: .agentRunFinished
        }
    }

    private func observedState(_ phase: HookPhase) -> ObservedState {
        switch phase {
        case .started: .inProgress
        case .waiting: .waiting
        case .completed: .completed
        case .failed: .failed
        case .interrupted: .interrupted
        }
    }

    private func recordSuffix(_ phase: HookPhase) -> String {
        switch phase {
        case .started: "started"
        case .waiting: "waiting"
        case .completed: "completed"
        case .failed: "failed"
        case .interrupted: "interrupted"
        }
    }
}
