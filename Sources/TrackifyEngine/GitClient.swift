import Foundation

public struct GitWorkingTreeState: Equatable, Sendable {
    public let branch: String?
    public let headCommit: String?
    public let changedFiles: [String]
    public let additions: Int
    public let deletions: Int

    public init(
        branch: String?,
        headCommit: String?,
        changedFiles: [String],
        additions: Int,
        deletions: Int
    ) {
        self.branch = branch
        self.headCommit = headCommit
        self.changedFiles = changedFiles
        self.additions = additions
        self.deletions = deletions
    }

    public var isClean: Bool { changedFiles.isEmpty }
}

public struct GitRepositoryInspection: Equatable, Sendable {
    public let root: URL
    public let commonDirectory: URL
    public let remoteIdentity: String?
    public let state: GitWorkingTreeState

    public init(root: URL, commonDirectory: URL, remoteIdentity: String?, state: GitWorkingTreeState) {
        self.root = root.standardizedFileURL
        self.commonDirectory = commonDirectory.standardizedFileURL
        self.remoteIdentity = remoteIdentity
        self.state = state
    }
}

public struct GitCommitInspection: Equatable, Sendable {
    public let hash: String
    public let authorTime: Date
    public let message: String
    public let additions: Int
    public let deletions: Int
    public let filesChanged: Int

    public init(hash: String, authorTime: Date, message: String, additions: Int, deletions: Int, filesChanged: Int) {
        self.hash = hash
        self.authorTime = authorTime
        self.message = message
        self.additions = additions
        self.deletions = deletions
        self.filesChanged = filesChanged
    }
}

public struct GitClient: Sendable {
    private let runner: any CommandRunning
    private let executable = URL(filePath: "/usr/bin/git")

    public init(runner: any CommandRunning = ProcessRunner()) {
        self.runner = runner
    }

    public func inspect(_ candidate: RepositoryCandidate) throws -> GitRepositoryInspection {
        let root = candidate.path.standardizedFileURL
        let topLevel = try requiredString(["-C", root.path, "rev-parse", "--show-toplevel"])
        let canonicalRoot = URL(filePath: topLevel).standardizedFileURL
        let commonDirectoryValue = try requiredString(["-C", canonicalRoot.path, "rev-parse", "--path-format=absolute", "--git-common-dir"])
        let commonDirectory = URL(filePath: commonDirectoryValue).standardizedFileURL
        let remote = optionalString(["-C", canonicalRoot.path, "remote", "get-url", "origin"])
        let branch = optionalString(["-C", canonicalRoot.path, "branch", "--show-current"])
        let head = optionalString(["-C", canonicalRoot.path, "rev-parse", "--verify", "HEAD"])
        let statusData = try requiredData(["-C", canonicalRoot.path, "status", "--porcelain=v1", "-z", "--untracked-files=all"])
        let changedFiles = Self.parsePorcelainV1(statusData)
        let numstatArguments: [String]
        if head == nil {
            numstatArguments = ["-C", canonicalRoot.path, "diff", "--cached", "--numstat"]
        } else {
            numstatArguments = ["-C", canonicalRoot.path, "diff", "HEAD", "--numstat"]
        }
        let (additions, deletions) = Self.parseNumstat(try requiredData(numstatArguments))

        return GitRepositoryInspection(
            root: canonicalRoot,
            commonDirectory: commonDirectory,
            remoteIdentity: remote.map(Self.normalizeRemote),
            state: GitWorkingTreeState(
                branch: branch?.isEmpty == true ? nil : branch,
                headCommit: head,
                changedFiles: changedFiles,
                additions: additions,
                deletions: deletions
            )
        )
    }

    public func commits(at repository: URL, in range: DateInterval?) throws -> [GitCommitInspection] {
        var arguments = [
            "-C", repository.path, "log", "--all", "--no-renames",
            "--format=%x1e%H%x1f%ct%x1f%s", "--numstat",
        ]
        if let range {
            arguments.append("--since=@\(Int(range.start.timeIntervalSince1970))")
            arguments.append("--until=@\(Int(range.end.timeIntervalSince1970))")
        }
        let data = try requiredData(arguments, outputLimit: 32 * 1_024 * 1_024)
        return Self.parseLog(data)
    }

    public func reachableCommitHashes(at repository: URL) throws -> Set<String> {
        let data = try requiredData(
            ["-C", repository.path, "rev-list", "--all"],
            outputLimit: 32 * 1_024 * 1_024
        )
        return Set(
            String(decoding: data, as: UTF8.self)
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
        )
    }

    private func requiredData(_ arguments: [String], outputLimit: Int = 8 * 1_024 * 1_024) throws -> Data {
        let output = try runner.run(
            executable: executable,
            arguments: arguments,
            workingDirectory: nil,
            environment: nil,
            outputLimit: outputLimit
        )
        guard output.status == 0 else {
            throw ProcessRunnerError.failed(
                executable: executable.path,
                status: output.status,
                output: output.utf8.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return output.data
    }

    private func requiredString(_ arguments: [String]) throws -> String {
        String(decoding: try requiredData(arguments), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func optionalString(_ arguments: [String]) -> String? {
        guard
            let output = try? runner.run(
                executable: executable,
                arguments: arguments,
                workingDirectory: nil,
                environment: nil,
                outputLimit: 1 * 1_024 * 1_024
            ), output.status == 0
        else { return nil }
        let value = output.utf8.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func parsePorcelainV1(_ data: Data) -> [String] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: true)
        var paths: [String] = []
        var index = 0

        while index < fields.count {
            let field = String(decoding: fields[index], as: UTF8.self)
            guard field.count >= 3 else {
                index += 1
                continue
            }
            let status = field.prefix(2)
            let path = String(field.dropFirst(3))
            paths.append(path)
            if status.contains("R") || status.contains("C") {
                index += 1
            }
            index += 1
        }
        return paths.sorted()
    }

    static func parseNumstat(_ data: Data) -> (additions: Int, deletions: Int) {
        var additions = 0
        var deletions = 0
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3,
                let added = Int(fields[0]),
                let deleted = Int(fields[1])
            else { continue }
            additions += added
            deletions += deleted
        }
        return (additions, deletions)
    }

    static func normalizeRemote(_ remote: String) -> String {
        var value = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("git@"), let colon = value.firstIndex(of: ":") {
            let host = value[value.index(value.startIndex, offsetBy: 4)..<colon]
            let path = value[value.index(after: colon)...]
            value = "https://\(host)/\(path)"
        }
        if value.hasSuffix(".git") {
            value.removeLast(4)
        }
        return value.lowercased()
    }

    static func parseLog(_ data: Data) -> [GitCommitInspection] {
        String(decoding: data, as: UTF8.self)
            .split(separator: "\u{1e}", omittingEmptySubsequences: true)
            .compactMap { record in
                let lines = record.split(separator: "\n", omittingEmptySubsequences: true)
                guard let header = lines.first else { return nil }
                let fields = header.split(separator: "\u{1f}", maxSplits: 2, omittingEmptySubsequences: false)
                guard fields.count == 3, let timestamp = TimeInterval(fields[1]) else { return nil }
                var additions = 0
                var deletions = 0
                var filesChanged = 0
                for line in lines.dropFirst() {
                    let values = line.split(separator: "\t", omittingEmptySubsequences: false)
                    guard values.count >= 3 else { continue }
                    filesChanged += 1
                    additions += Int(values[0]) ?? 0
                    deletions += Int(values[1]) ?? 0
                }
                return GitCommitInspection(
                    hash: String(fields[0]),
                    authorTime: Date(timeIntervalSince1970: timestamp),
                    message: String(fields[2]),
                    additions: additions,
                    deletions: deletions,
                    filesChanged: filesChanged
                )
            }
            .sorted { $0.authorTime < $1.authorTime }
    }
}
