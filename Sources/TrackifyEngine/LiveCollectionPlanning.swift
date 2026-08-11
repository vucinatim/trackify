import Foundation
import TrackifyDomain

public struct LiveWatchCatalog: Equatable, Sendable {
    public let gitRoots: [GitCollectionRoot]
    public let workingCopies: [WorkingCopy]
    public let codexRoots: [URL]
    public let claudeRoot: URL
    public let claudeDesktopRoot: URL
    public let hookInboxURL: URL
    public let ledgerURL: URL
    public let settingsURL: URL
    public let priorityRepositoryIDs: [RepositoryID]

    public init(
        gitRoots: [GitCollectionRoot],
        workingCopies: [WorkingCopy],
        codexRoots: [URL],
        claudeRoot: URL,
        claudeDesktopRoot: URL,
        hookInboxURL: URL,
        ledgerURL: URL,
        settingsURL: URL,
        priorityRepositoryIDs: [RepositoryID] = []
    ) {
        self.gitRoots = gitRoots
        self.workingCopies = workingCopies
        self.codexRoots = codexRoots.map(\.standardizedFileURL)
        self.claudeRoot = claudeRoot.standardizedFileURL
        self.claudeDesktopRoot = claudeDesktopRoot.standardizedFileURL
        self.hookInboxURL = hookInboxURL.standardizedFileURL
        self.ledgerURL = ledgerURL.standardizedFileURL
        self.settingsURL = settingsURL.standardizedFileURL
        self.priorityRepositoryIDs = priorityRepositoryIDs
    }

    public var monitoredRoots: [URL] {
        var roots = gitRoots.map(\.path) + codexRoots + [claudeRoot, claudeDesktopRoot]
        roots.append(hookInboxURL.deletingLastPathComponent())
        var seen = Set<String>()
        return roots.filter { FileManager.default.fileExists(atPath: $0.path) }
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

public struct LiveCollectionPlan: Equatable, Sendable {
    public let gitRoots: [GitCollectionRoot]
    public let includeCodex: Bool
    public let includeClaude: Bool
    public let includeHook: Bool
    public let codexFiles: Set<URL>?
    public let claudeFiles: Set<URL>?
    public let claudeDesktopFiles: Set<URL>?
    public let presentationOnly: Bool

    public init(
        gitRoots: [GitCollectionRoot] = [],
        includeCodex: Bool = false,
        includeClaude: Bool = false,
        includeHook: Bool = false,
        codexFiles: Set<URL>? = [],
        claudeFiles: Set<URL>? = [],
        claudeDesktopFiles: Set<URL>? = [],
        presentationOnly: Bool = false
    ) {
        self.gitRoots = gitRoots
        self.includeCodex = includeCodex
        self.includeClaude = includeClaude
        self.includeHook = includeHook
        self.codexFiles = codexFiles
        self.claudeFiles = claudeFiles
        self.claudeDesktopFiles = claudeDesktopFiles
        self.presentationOnly = presentationOnly
    }
}

public struct LiveCollectionPlanner: Sendable {
    private static let ignoredGitDirectoryNames: Set<String> = [
        ".build", ".cache", "DerivedData", "Pods", "node_modules", "vendor",
    ]

    public init() {}

    public func classify(
        _ changes: [FileSystemChange],
        catalog: LiveWatchCatalog
    ) -> LiveCollectionTrigger? {
        var families = Set<LiveSourceFamily>()
        var paths = Set<String>()
        var requiresReconciliation = false
        var observedAt: Date?

        for change in changes {
            let path = URL(filePath: change.path).standardizedFileURL.path
            observedAt = max(observedAt ?? change.observedAt, change.observedAt)
            requiresReconciliation = requiresReconciliation || change.requiresReconciliation

            if path == catalog.hookInboxURL.path {
                families.insert(.hook)
                paths.insert(path)
                continue
            }
            if isLedgerPath(path, ledgerURL: catalog.ledgerURL) {
                // App-owned writes share the hook-inbox parent directory. Cross-process
                // ledger invalidation arrives through LedgerMutationSignal instead, so
                // treating SQLite WAL churn as a filesystem trigger would feed back into
                // status persistence indefinitely.
                continue
            }
            if catalog.codexRoots.contains(where: { isDescendant(path, of: $0.path) }) {
                families.insert(.codex)
                paths.insert(path)
                continue
            }
            if isDescendant(path, of: catalog.claudeRoot.path) {
                families.insert(.claude)
                paths.insert(path)
                continue
            }
            if isDescendant(path, of: catalog.claudeDesktopRoot.path) {
                families.insert(.claudeDesktop)
                paths.insert(path)
                continue
            }
            guard let root = deepestRoot(containing: path, roots: catalog.gitRoots) else { continue }
            guard !isExcluded(path, root: root) else { continue }
            families.insert(.git)
            paths.insert(path)
            if !catalog.workingCopies.contains(where: { isDescendant(path, of: $0.canonicalPath) }) {
                families.insert(.discovery)
            }
        }

        guard !families.isEmpty, let observedAt else { return nil }
        return LiveCollectionTrigger(
            families: families, paths: paths, observedAt: observedAt,
            reason: families.contains(.hook) ? .hook : .filesystem,
            requiresReconciliation: requiresReconciliation)
    }

    public func plan(
        _ batch: LiveCollectionBatch,
        catalog: LiveWatchCatalog
    ) -> LiveCollectionPlan {
        if batch.onlyRequiresPresentationRefresh {
            return LiveCollectionPlan(presentationOnly: true)
        }

        let broad =
            batch.requiresReconciliation
            || batch.reasons.contains(.wake)
            || batch.reasons.contains(.reconciliation)
        let jsonlPaths = Set(
            batch.paths.lazy.map { URL(filePath: $0).standardizedFileURL }
                .filter { $0.pathExtension.lowercased() == "jsonl" })
        let includeCodex = batch.families.contains(.codex)
        let includeClaude =
            batch.families.contains(.claude)
            || batch.families.contains(.claudeDesktop)

        let codexFiles = targetedFiles(
            enabled: includeCodex, broad: broad, familyPresent: batch.families.contains(.codex),
            candidates: jsonlPaths, roots: catalog.codexRoots)
        let claudeFiles = targetedFiles(
            enabled: includeClaude, broad: broad, familyPresent: batch.families.contains(.claude),
            candidates: jsonlPaths, roots: [catalog.claudeRoot])
        let claudeDesktopFiles = targetedFiles(
            enabled: includeClaude, broad: broad, familyPresent: batch.families.contains(.claudeDesktop),
            candidates: jsonlPaths, roots: [catalog.claudeDesktopRoot])

        let gitRoots: [GitCollectionRoot]
        if broad && !batch.families.isDisjoint(with: [.git, .discovery]) {
            gitRoots = catalog.gitRoots
        } else if batch.families.contains(.git) || batch.families.contains(.discovery) {
            gitRoots = catalog.gitRoots.compactMap { root in
                let pathsInRoot = batch.paths.filter { isDescendant($0, of: root.path.path) }
                guard !pathsInRoot.isEmpty else { return nil }
                let repositories = Set(
                    catalog.workingCopies.filter { copy in
                        pathsInRoot.contains { isDescendant($0, of: copy.canonicalPath) }
                    }.map { URL(filePath: $0.canonicalPath) })
                let hasUnresolvedPath = pathsInRoot.contains { path in
                    !catalog.workingCopies.contains { isDescendant(path, of: $0.canonicalPath) }
                }
                return GitCollectionRoot(
                    path: root.path, discoveryRootID: root.discoveryRootID,
                    excludedPaths: root.excludedPaths,
                    includedRepositories: hasUnresolvedPath ? nil : repositories)
            }
        } else {
            gitRoots = []
        }

        return LiveCollectionPlan(
            gitRoots: gitRoots,
            includeCodex: includeCodex,
            includeClaude: includeClaude,
            includeHook: batch.families.contains(.hook),
            codexFiles: codexFiles,
            claudeFiles: claudeFiles,
            claudeDesktopFiles: claudeDesktopFiles)
    }

    private func targetedFiles(
        enabled: Bool,
        broad: Bool,
        familyPresent: Bool,
        candidates: Set<URL>,
        roots: [URL]
    ) -> Set<URL>? {
        guard enabled else { return [] }
        if broad { return nil }
        let selected = candidates.filter { candidate in
            roots.contains { isDescendant(candidate.path, of: $0.path) }
        }
        return familyPresent && selected.isEmpty ? nil : selected
    }

    private func deepestRoot(containing path: String, roots: [GitCollectionRoot]) -> GitCollectionRoot? {
        roots.filter { isDescendant(path, of: $0.path.path) }
            .max { $0.path.path.count < $1.path.path.count }
    }

    private func isExcluded(_ path: String, root: GitCollectionRoot) -> Bool {
        let absoluteExcluded = root.excludedPaths.map { excluded -> String in
            let url = URL(filePath: excluded)
            return (url.path.hasPrefix("/") ? url : root.path.appending(path: excluded))
                .standardizedFileURL.path
        }
        if absoluteExcluded.contains(where: { isDescendant(path, of: $0) }) { return true }
        let relative = path == root.path.path ? "" : String(path.dropFirst(root.path.path.count + 1))
        return relative.split(separator: "/").contains {
            Self.ignoredGitDirectoryNames.contains(String($0))
        }
    }

    private func isLedgerPath(_ path: String, ledgerURL: URL) -> Bool {
        path == ledgerURL.path || path == ledgerURL.path + "-wal" || path == ledgerURL.path + "-shm"
    }

    private func isDescendant(_ candidate: String, of root: String) -> Bool {
        candidate == root || candidate.hasPrefix(root + "/")
    }
}
