import Foundation
import TrackifyDomain
import TrackifyStore

public struct RootRecommendation: Codable, Equatable, Sendable {
    public let path: String
    public let suggestedName: String
    public let repositoryCount: Int
    public let reason: String
}

public struct BootstrapInspection: Codable, Equatable, Sendable {
    public let dataRoot: String
    public let existingRoots: [DiscoveryRoot]
    public let recommendedRoots: [RootRecommendation]
    public let providers: [ProviderHealth]
    public let codexHistoryAvailable: Bool
    public let claudeHistoryAvailable: Bool
    public let backfillPlan: BootstrapBackfillPlan
}

public struct BootstrapBackfillPlan: Codable, Equatable, Sendable {
    public let historyFiles: Int
    public let historyBytes: Int64
    public let initialReportDays: Int
    public let maximumProviderCalls: Int
    public let maximumInputTokens: Int
    public let note: String
}

public struct BootstrapInspector: Sendable {
    public init() {}

    public func inspect(
        paths: TrackifyPaths,
        store: LedgerStore,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> BootstrapInspection {
        let existing = try store.discoveryRoots()
        let existingPaths = Set(existing.map(\.canonicalPath))
        let candidates = candidateDirectories(home: homeDirectory)
        var recommendations: [RootRecommendation] = []

        for candidate in candidates where !existingPaths.contains(candidate.path) {
            let options = RepositoryDiscoveryOptions(maximumDepth: 10, maximumDirectories: 25_000)
            let repositories = (try? RepositoryDiscovery(options: options).discover(under: candidate)) ?? []
            guard !repositories.isEmpty else { continue }
            recommendations.append(
                RootRecommendation(
                    path: candidate.path,
                    suggestedName: suggestedName(candidate.lastPathComponent),
                    repositoryCount: repositories.count,
                    reason: "Recognized development folder containing \(repositories.count) Git repositories."
                ))
        }

        let history = historyFootprint(home: homeDirectory)
        let reportDays = 14
        return BootstrapInspection(
            dataRoot: paths.dataRoot.path,
            existingRoots: existing,
            recommendedRoots: recommendations.sorted { $0.repositoryCount > $1.repositoryCount },
            providers: SummaryProviderFactory.health(),
            codexHistoryAvailable: FileManager.default.fileExists(atPath: homeDirectory.appending(path: ".codex").path),
            claudeHistoryAvailable: FileManager.default.fileExists(atPath: homeDirectory.appending(path: ".claude").path),
            backfillPlan: BootstrapBackfillPlan(
                historyFiles: history.files,
                historyBytes: history.bytes,
                initialReportDays: reportDays,
                maximumProviderCalls: reportDays,
                maximumInputTokens: reportDays * GenerationBudgets().maximumEstimatedInputTokensPerCall,
                note:
                    "Evidence import is local and token-free. Reports run only for active days; the estimate includes provider CLI overhead and smart compilation caps evidence at 20 KiB per call."
            )
        )
    }

    private func candidateDirectories(home: URL) -> [URL] {
        let known = [
            home.appending(path: "Developer"),
            home.appending(path: "Projects"),
            home.appending(path: "Work"),
            home.appending(path: "Desktop/MyProjects"),
            home.appending(path: "Desktop/zerodays"),
        ]
        var unique: [String: URL] = [:]
        for url in known {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                unique[url.standardizedFileURL.resolvingSymlinksInPath().path] = url.standardizedFileURL.resolvingSymlinksInPath()
            }
        }
        return unique.values.sorted { $0.path < $1.path }
    }

    private func suggestedName(_ folderName: String) -> String {
        switch folderName.lowercased() {
        case "zerodays", "work", "company": "Work"
        case "myprojects", "projects", "developer": "Personal"
        default: folderName
        }
    }

    private func historyFootprint(home: URL) -> (files: Int, bytes: Int64) {
        let roots = [
            home.appending(path: ".codex"),
            home.appending(path: ".claude/projects"),
            home.appending(path: "Library/Application Support/Claude/local-agent-mode-sessions"),
        ]
        var files = 0
        var bytes: Int64 = 0
        for root in roots {
            guard
                let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
            else { continue }
            while let url = enumerator.nextObject() as? URL, files < 100_000 {
                guard url.pathExtension == "jsonl",
                    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                    values.isRegularFile == true
                else { continue }
                files += 1
                bytes += Int64(values.fileSize ?? 0)
            }
        }
        return (files, bytes)
    }
}
