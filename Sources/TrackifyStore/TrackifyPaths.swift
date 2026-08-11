import Foundation

public struct TrackifyPaths: Equatable, Sendable {
    public let dataRoot: URL

    public init(dataRoot: URL) {
        self.dataRoot = dataRoot.standardizedFileURL
    }

    public static func `default`(fileManager: FileManager = .default) throws -> Self {
        if let override = ProcessInfo.processInfo.environment["TRACKIFY_DATA_ROOT"], !override.isEmpty {
            return Self(dataRoot: URL(filePath: override))
        }
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return Self(dataRoot: applicationSupport.appending(path: "Trackify", directoryHint: .isDirectory))
    }

    public var ledgerURL: URL { dataRoot.appending(path: "trackify.sqlite") }
    public var settingsURL: URL { dataRoot.appending(path: "settings.json") }
    public var backupsDirectory: URL { dataRoot.appending(path: "Backups", directoryHint: .isDirectory) }
    public var logsDirectory: URL { dataRoot.appending(path: "Logs", directoryHint: .isDirectory) }
    public var runtimeDirectory: URL { dataRoot.appending(path: "Runtime", directoryHint: .isDirectory) }
    public var hookInboxDirectory: URL { dataRoot.appending(path: "Inbox", directoryHint: .isDirectory) }
    public var hookInboxURL: URL { hookInboxDirectory.appending(path: "events.jsonl") }
}
