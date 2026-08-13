import Foundation

public enum RepositoryPathPolicy {
    public static let generatedDirectoryNames: Set<String> = [
        ".build", ".cache", ".dart_tool", ".gradle", ".next", ".nuxt",
        ".pytest_cache", ".tox", ".turbo", ".venv", "DerivedData", "Pods",
        "__pycache__", "build", "coverage", "dist", "node_modules", "out",
        "target", "vendor", "venv",
    ]
}

public enum GitRepositoryKind: String, Codable, Sendable {
    case regular
    case worktree
    case bare
}

public struct RepositoryCandidate: Equatable, Sendable {
    public let path: URL
    public let kind: GitRepositoryKind

    public init(path: URL, kind: GitRepositoryKind) {
        self.path = path.standardizedFileURL
        self.kind = kind
    }
}

public struct RepositoryDiscoveryOptions: Equatable, Sendable {
    public var maximumDepth: Int
    public var maximumDirectories: Int
    public var excludedDirectoryNames: Set<String>
    public var excludedPaths: Set<String>

    public init(
        maximumDepth: Int = 12,
        maximumDirectories: Int = 100_000,
        excludedDirectoryNames: Set<String> = RepositoryPathPolicy.generatedDirectoryNames
            .union([".git", ".Trash", "Library"]),
        excludedPaths: Set<String> = []
    ) {
        self.maximumDepth = maximumDepth
        self.maximumDirectories = maximumDirectories
        self.excludedDirectoryNames = excludedDirectoryNames
        self.excludedPaths = excludedPaths
    }
}

public struct RepositoryDiscovery: Sendable {
    private let options: RepositoryDiscoveryOptions

    public init(options: RepositoryDiscoveryOptions = .init()) {
        self.options = options
    }

    public func discover(under root: URL) throws -> [RepositoryCandidate] {
        let fileManager = FileManager.default
        let root = root.standardizedFileURL
        let excludedPaths = Set(
            options.excludedPaths.map { path in
                let url = URL(filePath: path)
                return (url.path.hasPrefix("/") ? url : root.appending(path: path))
                    .standardizedFileURL.path
            })
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { return [] }

        var candidates: [RepositoryCandidate] = []
        var visitedDirectories = 0
        var pending: [(url: URL, depth: Int)] = [(root, 0)]

        while let current = pending.popLast() {
            guard !isExcluded(current.url.path, excludedPaths: excludedPaths) else { continue }
            visitedDirectories += 1
            guard visitedDirectories <= options.maximumDirectories else { break }

            if let kind = repositoryKind(at: current.url) {
                candidates.append(RepositoryCandidate(path: current.url, kind: kind))
            }

            guard current.depth < options.maximumDepth else { continue }
            let children = try fileManager.contentsOfDirectory(
                at: current.url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )

            for child in children.reversed() {
                guard !options.excludedDirectoryNames.contains(child.lastPathComponent) else { continue }
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                pending.append((child, current.depth + 1))
            }
        }

        return candidates.sorted { $0.path.path < $1.path.path }
    }

    private func isExcluded(_ path: String, excludedPaths: Set<String>) -> Bool {
        excludedPaths.contains { excluded in
            path == excluded || path.hasPrefix(excluded + "/")
        }
    }

    private func repositoryKind(at directory: URL) -> GitRepositoryKind? {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let dotGit = directory.appending(path: ".git")
        if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue ? .regular : .worktree
        }

        let head = directory.appending(path: "HEAD").path
        let objects = directory.appending(path: "objects", directoryHint: .isDirectory).path
        let refs = directory.appending(path: "refs", directoryHint: .isDirectory).path
        if fileManager.fileExists(atPath: head),
            fileManager.fileExists(atPath: objects, isDirectory: &isDirectory), isDirectory.boolValue,
            fileManager.fileExists(atPath: refs, isDirectory: &isDirectory), isDirectory.boolValue
        {
            return .bare
        }
        return nil
    }
}
