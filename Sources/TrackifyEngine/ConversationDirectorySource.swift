import Foundation
import TrackifyDomain

public enum ConversationProvider: String, Codable, Sendable {
    case codex
    case claude
    case claudeDesktop = "claude-desktop"
}

public struct ConversationDirectoryCursor: Codable, Equatable, Sendable {
    public var files: [String: JSONLFileCursor]
    public var adapterVersion: Int

    public init(files: [String: JSONLFileCursor] = [:], adapterVersion: Int = 2) {
        self.files = files
        self.adapterVersion = adapterVersion
    }

    private enum CodingKeys: String, CodingKey {
        case files
        case adapterVersion
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        files = try container.decodeIfPresent([String: JSONLFileCursor].self, forKey: .files) ?? [:]
        adapterVersion = try container.decodeIfPresent(Int.self, forKey: .adapterVersion) ?? 1
    }
}

public struct ConversationDirectorySource: SourceAdapter {
    public let sourceKey: String
    private let provider: ConversationProvider
    private let root: URL
    private let reader: JSONLReader
    private let maximumRecordsPerCollection: Int

    public init(
        provider: ConversationProvider,
        root: URL,
        cursorScope: String? = nil,
        reader: JSONLReader = JSONLReader(skipOversizedLines: true),
        maximumRecordsPerCollection: Int = 2_000
    ) {
        precondition(maximumRecordsPerCollection > 0)
        self.provider = provider
        self.root = root.standardizedFileURL
        self.reader = reader
        self.maximumRecordsPerCollection = maximumRecordsPerCollection
        let baseSourceKey = "\(provider.rawValue)-directory:\(self.root.path)"
        sourceKey = cursorScope.map { "\(baseSourceKey):\($0)" } ?? baseSourceKey
    }

    public func collect(request: CollectionRequest, cursor: Data?) async throws -> CollectionBatch {
        var directoryCursor =
            try cursor.map {
                try JSONDecoder().decode(ConversationDirectoryCursor.self, from: $0)
            } ?? ConversationDirectoryCursor()
        if directoryCursor.adapterVersion < 2 {
            directoryCursor = ConversationDirectoryCursor()
        }
        let files = try jsonlFiles(overlapping: request.range)
        let currentKeys = Set(files.map(relativePath))
        directoryCursor.files = directoryCursor.files.filter { currentKeys.contains($0.key) }
        var sessions: [ConversationSession] = []
        var messages: [ConversationMessage] = []
        var records: [CollectedRecord] = []
        var remainingRecords = maximumRecordsPerCollection

        for file in files where remainingRecords > 0 {
            let key = relativePath(for: file)
            let read = try reader.read(
                file,
                after: directoryCursor.files[key],
                maximumRecords: remainingRecords
            )
            directoryCursor.files[key] = read.cursor
            remainingRecords -= read.processedRecordCount
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
                    observedAt: request.cutoff
                )
            case .claude:
                parsed = try ClaudeConversationParser().parse(
                    lines: read.lines,
                    fallbackSessionID: StableHash.sha256(file.path),
                    observedAt: request.cutoff
                )
            case .claudeDesktop:
                parsed = try ClaudeDesktopConversationParser().parse(
                    lines: read.lines,
                    metadata: try claudeDesktopMetadata(for: file),
                    fallbackSessionID: StableHash.sha256(file.path),
                    observedAt: request.cutoff
                )
            }
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
            if !selectedMessages.isEmpty || !selectedRecords.isEmpty {
                sessions.append(parsed.session)
                messages.append(contentsOf: selectedMessages)
                records.append(contentsOf: selectedRecords)
            }
        }

        return CollectionBatch(
            sourceKey: sourceKey,
            sessions: sessions,
            messages: messages,
            records: records,
            processedSourceRecords: maximumRecordsPerCollection - remainingRecords,
            nextCursor: try JSONEncoder().encode(directoryCursor)
        )
    }

    private func jsonlFiles(overlapping range: DateInterval?) throws -> [URL] {
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
        ]
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
            $0.hasPrefix("trackify-codex-report-") || $0.hasPrefix("trackify-claude-report-")
        }
    }
}
