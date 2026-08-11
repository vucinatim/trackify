import Foundation
import TrackifyDomain

public enum ConversationProvider: String, Codable, Sendable {
    case codex
    case claude
    case claudeDesktop = "claude-desktop"
}

public struct ConversationDirectoryCursor: Codable, Equatable, Sendable {
    public var files: [String: JSONLFileCursor]
    public var parserStates: [String: ConversationParserState]
    public var adapterVersion: Int

    public init(
        files: [String: JSONLFileCursor] = [:],
        parserStates: [String: ConversationParserState] = [:],
        adapterVersion: Int = 5
    ) {
        self.files = files
        self.parserStates = parserStates
        self.adapterVersion = adapterVersion
    }

    private enum CodingKeys: String, CodingKey {
        case files
        case parserStates
        case adapterVersion
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        files = try container.decodeIfPresent([String: JSONLFileCursor].self, forKey: .files) ?? [:]
        parserStates =
            try container.decodeIfPresent(
                [String: ConversationParserState].self, forKey: .parserStates) ?? [:]
        adapterVersion = try container.decodeIfPresent(Int.self, forKey: .adapterVersion) ?? 1
    }
}

public struct ConversationDirectorySource: SourceAdapter {
    public let sourceKey: String
    private let baseSourceKey: String
    private let provider: ConversationProvider
    private let root: URL
    private let reader: JSONLReader
    private let maximumRecordsPerCollection: Int
    private let maximumBytesPerCollection: Int
    private let includedFiles: Set<String>?

    public init(
        provider: ConversationProvider,
        root: URL,
        cursorScope: String? = nil,
        includedFiles: Set<URL>? = nil,
        reader: JSONLReader = JSONLReader(skipOversizedLines: true),
        maximumRecordsPerCollection: Int = 64,
        maximumBytesPerCollection: Int = 1 * 1_024 * 1_024
    ) {
        precondition(maximumRecordsPerCollection > 0)
        precondition(maximumBytesPerCollection > 0)
        let standardizedRoot = root.standardizedFileURL
        self.provider = provider
        self.root = standardizedRoot
        self.reader = reader
        self.maximumRecordsPerCollection = maximumRecordsPerCollection
        self.maximumBytesPerCollection = maximumBytesPerCollection
        self.includedFiles = includedFiles.map { files in
            Set(
                files.compactMap { file in
                    let standardized = file.standardizedFileURL
                    guard Self.isDescendant(standardized, of: standardizedRoot),
                        standardized.pathExtension.lowercased() == "jsonl"
                    else { return nil }
                    return standardized.path
                })
        }
        let base = "\(provider.rawValue)-directory:\(standardizedRoot.path)"
        baseSourceKey = base
        sourceKey = cursorScope.map { "\(base):\($0)" } ?? base
    }

    public func makeForwardCursorSeed(from boundedCursor: Data?) throws -> (
        sourceKey: String, cursor: Data, audit: EvidenceSourceReadAudit
    ) {
        var forward =
            try boundedCursor.map {
                try JSONDecoder().decode(ConversationDirectoryCursor.self, from: $0)
            } ?? ConversationDirectoryCursor()
        let files = try jsonlFiles(overlapping: nil)
        let currentKeys = Set(files.map(relativePath))
        forward.files = forward.files.filter { currentKeys.contains($0.key) }
        forward.parserStates = forward.parserStates.filter { currentKeys.contains($0.key) }

        for file in files {
            let key = relativePath(for: file)
            guard forward.files[key] == nil else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            forward.files[key] = JSONLFileCursor(
                device: (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
                inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                offset: (attributes[.size] as? NSNumber)?.uint64Value ?? 0)
        }
        let audit = EvidenceSourceReadAudit(
            sourceKey: "\(baseSourceKey):forward-cursor-seed",
            unit: .file,
            candidatesConsidered: files.count,
            unitsOpened: 0,
            bytesRead: 0,
            recordsObserved: 0,
            recordsAccepted: 0)
        return (baseSourceKey, try JSONEncoder().encode(forward), audit)
    }

    public func collect(request: CollectionRequest, cursor: Data?) async throws -> CollectionBatch {
        var directoryCursor =
            try cursor.map {
                try JSONDecoder().decode(ConversationDirectoryCursor.self, from: $0)
            } ?? ConversationDirectoryCursor()
        if directoryCursor.adapterVersion < 5 {
            directoryCursor = ConversationDirectoryCursor()
        }
        let files = try jsonlFiles(overlapping: request.range)
        if includedFiles == nil {
            let currentKeys = Set(files.map(relativePath))
            directoryCursor.files = directoryCursor.files.filter { currentKeys.contains($0.key) }
            directoryCursor.parserStates = directoryCursor.parserStates.filter { currentKeys.contains($0.key) }
        }
        var sessions: [ConversationSession] = []
        var messages: [ConversationMessage] = []
        var conversationRecords: [NormalizedConversationRecord] = []
        var records: [CollectedRecord] = []
        var remainingRecords = maximumRecordsPerCollection
        var remainingBytes = maximumBytesPerCollection
        var openedUnitFingerprints: [String] = []
        var bytesRead = 0
        var recordsObserved = 0
        var recordsAccepted = 0

        for file in files where remainingRecords > 0 && remainingBytes > 0 {
            let key = relativePath(for: file)
            let read = try reader.read(
                file,
                after: directoryCursor.files[key],
                maximumRecords: remainingRecords,
                maximumBytes: remainingBytes
            )
            let previousFileCursor = directoryCursor.files[key]
            let parserState: ConversationParserState
            if let previousFileCursor,
                previousFileCursor.device == read.cursor.device,
                previousFileCursor.inode == read.cursor.inode,
                previousFileCursor.offset <= read.cursor.offset
            {
                parserState = directoryCursor.parserStates[key] ?? ConversationParserState()
            } else {
                parserState = ConversationParserState()
            }
            directoryCursor.files[key] = read.cursor
            remainingRecords -= read.processedRecordCount
            remainingBytes = max(0, remainingBytes - read.processedBytes)
            if read.processedBytes > 0 {
                openedUnitFingerprints.append(StableHash.sha256("\(provider.rawValue):\(key)"))
            }
            bytesRead += read.processedBytes
            recordsObserved += read.processedRecordCount
            guard !read.lines.isEmpty else { continue }

            let parsed: ConversationParseResult
            switch provider {
            case .codex:
                var lines = read.lines
                if let first = try? reader.readFirstLine(file), first != lines.first {
                    lines.insert(first, at: 0)
                }
                parsed = try CodexConversationParser().parse(
                    lines: lines,
                    fallbackSessionID: StableHash.sha256(file.path),
                    observedAt: request.cutoff,
                    previousState: parserState
                )
            case .claude:
                parsed = try ClaudeConversationParser().parse(
                    lines: read.lines,
                    fallbackSessionID: StableHash.sha256(file.path),
                    observedAt: request.cutoff,
                    previousState: parserState
                )
            case .claudeDesktop:
                parsed = try ClaudeDesktopConversationParser().parse(
                    lines: read.lines,
                    metadata: try claudeDesktopMetadata(for: file),
                    fallbackSessionID: StableHash.sha256(file.path),
                    observedAt: request.cutoff,
                    previousState: parserState
                )
            }
            directoryCursor.parserStates[key] =
                read.hasMoreData
                ? parsed.parserState
                : parsed.parserState.retainingRecentRecordTurns(16)
            guard !isInternalReportSession(parsed.session) else { continue }
            let selectedMessages = parsed.messages.filter { message in
                guard let range = request.range, let occurredAt = message.occurredAt else {
                    return request.range == nil
                }
                return occurredAt >= range.start && occurredAt < range.end
            }
            let selectedRecords = parsed.records.filter { record in
                guard let range = request.range else { return true }
                return record.event.occurredAt >= range.start && record.event.occurredAt < range.end
            }
            let selectedConversationRecords = parsed.normalizedRecords.filter { record in
                guard let range = request.range, let occurredAt = record.occurredAt else {
                    return request.range == nil
                }
                return occurredAt >= range.start && occurredAt < range.end
            }
            recordsAccepted += selectedConversationRecords.count
            if !selectedMessages.isEmpty || !selectedRecords.isEmpty
                || !selectedConversationRecords.isEmpty
            {
                sessions.append(parsed.session)
                messages.append(contentsOf: selectedMessages)
                conversationRecords.append(contentsOf: selectedConversationRecords)
                records.append(contentsOf: selectedRecords)
            }
        }

        return CollectionBatch(
            sourceKey: sourceKey,
            sessions: sessions,
            messages: messages,
            conversationRecords: conversationRecords,
            records: records,
            processedSourceRecords: maximumRecordsPerCollection - remainingRecords,
            readMetrics: CollectionReadMetrics(
                unit: .file,
                candidatesConsidered: files.count,
                openedUnitFingerprints: openedUnitFingerprints,
                bytesRead: bytesRead,
                recordsObserved: recordsObserved,
                recordsAccepted: recordsAccepted),
            nextCursor: try JSONEncoder().encode(directoryCursor)
        )
    }

    private func jsonlFiles(overlapping range: DateInterval?) throws -> [URL] {
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
        ]
        if let includedFiles {
            return includedFiles.compactMap { path -> (url: URL, modifiedAt: Date)? in
                let url = URL(filePath: path).standardizedFileURL
                guard FileManager.default.fileExists(atPath: url.path),
                    let values = try? url.resourceValues(
                        forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                    values.isRegularFile == true,
                    values.isSymbolicLink != true
                else { return nil }
                return (url, values.contentModificationDate ?? .distantPast)
            }.filter { file in
                guard let range else { return true }
                guard file.modifiedAt >= range.start else { return false }
                guard provider == .codex, let startedAt = codexFileStartDate(file.url) else { return true }
                return startedAt < range.end
            }.sorted {
                $0.modifiedAt == $1.modifiedAt
                    ? $0.url.path < $1.url.path
                    : $0.modifiedAt > $1.modifiedAt
            }.map(\.url)
        }

        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else { return [] }

        var files: [(url: URL, modifiedAt: Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: resourceKeys)
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            files.append((url.standardizedFileURL, values?.contentModificationDate ?? .distantPast))
        }
        return files.filter { file in
            guard let range else { return true }
            guard file.modifiedAt >= range.start else { return false }
            guard provider == .codex, let startedAt = codexFileStartDate(file.url) else { return true }
            return startedAt < range.end
        }.sorted {
            $0.modifiedAt == $1.modifiedAt
                ? $0.url.path < $1.url.path
                : $0.modifiedAt > $1.modifiedAt
        }.map(\.url)
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }

    private func codexFileStartDate(_ file: URL) -> Date? {
        let name = file.lastPathComponent
        let prefix = "rollout-"
        guard name.hasPrefix(prefix), name.count >= prefix.count + 10 else { return nil }
        let dateText = String(name.dropFirst(prefix.count).prefix(10))
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: dateText)
    }

    private func relativePath(for file: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard file.path.hasPrefix(rootPath) else { return file.path }
        return String(file.path.dropFirst(rootPath.count))
    }

    private func claudeDesktopMetadata(
        for auditFile: URL
    ) throws -> ClaudeDesktopConversationParser.Metadata? {
        let sessionDirectory = auditFile.deletingLastPathComponent()
        let metadataURL = sessionDirectory.deletingLastPathComponent()
            .appending(path: "\(sessionDirectory.lastPathComponent).json")
        guard FileManager.default.fileExists(atPath: metadataURL.path) else { return nil }
        let values = try metadataURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 2 * 1_024 * 1_024 else {
            return nil
        }
        return try JSONDecoder().decode(
            ClaudeDesktopConversationParser.Metadata.self,
            from: Data(contentsOf: metadataURL)
        )
    }

    private func isInternalReportSession(_ session: ConversationSession) -> Bool {
        guard let path = session.workingDirectory else { return false }
        return URL(filePath: path).pathComponents.contains {
            $0.hasPrefix("trackify-internal-")
                || $0.hasPrefix("trackify-codex-report-")
                || $0.hasPrefix("trackify-claude-report-")
        }
    }
}
