import Foundation
import TrackifyDomain
import TrackifyStore

public enum ContextQueryError: Error, Equatable, LocalizedError {
    case noCurrentRepository(String)
    case repositoryNotFound(String)
    case ambiguousRepository(String, [String])

    public var errorDescription: String? {
        switch self {
        case .noCurrentRepository(let path):
            return "No tracked repository contains the current directory: \(path)"
        case .repositoryNotFound(let selector):
            return "No tracked repository matches '\(selector)'."
        case .ambiguousRepository(let selector, let matches):
            return "Repository '\(selector)' is ambiguous: \(matches.joined(separator: ", "))"
        }
    }
}

public struct RepositoryContext: Codable, Equatable, Sendable {
    public let repository: Repository
    public let workingCopies: [WorkingCopy]
    public let rangeStart: Date
    public let rangeEnd: Date
    public let activeHours: Int
    public let llmTurns: Int
    public let evidenceCount: Int
    public let firstEvidenceAt: Date?
    public let lastEvidenceAt: Date?
    public let commits: [GitCommit]
    public let messages: [ConversationMessage]
    public let latestWorkingTreeEvent: LedgerEvent?
    public let rendered: String

    public init(
        repository: Repository,
        workingCopies: [WorkingCopy],
        rangeStart: Date,
        rangeEnd: Date,
        activeHours: Int,
        llmTurns: Int,
        evidenceCount: Int,
        firstEvidenceAt: Date?,
        lastEvidenceAt: Date?,
        commits: [GitCommit],
        messages: [ConversationMessage],
        latestWorkingTreeEvent: LedgerEvent?,
        rendered: String
    ) {
        self.repository = repository
        self.workingCopies = workingCopies
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.activeHours = activeHours
        self.llmTurns = llmTurns
        self.evidenceCount = evidenceCount
        self.firstEvidenceAt = firstEvidenceAt
        self.lastEvidenceAt = lastEvidenceAt
        self.commits = commits
        self.messages = messages
        self.latestWorkingTreeEvent = latestWorkingTreeEvent
        self.rendered = rendered
    }
}

public struct PortfolioContext: Equatable, Sendable {
    public let rangeStart: Date
    public let rangeEnd: Date
    public let activity: ActivitySnapshot
    public let repositories: [RepositoryContext]
    public let rendered: String

    public init(
        rangeStart: Date,
        rangeEnd: Date,
        activity: ActivitySnapshot,
        repositories: [RepositoryContext],
        rendered: String
    ) {
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.activity = activity
        self.repositories = repositories
        self.rendered = rendered
    }
}

public struct ContextQueries: Sendable {
    public init() {}

    public func context(
        store: LedgerStore,
        repository selector: String,
        currentDirectory: URL,
        since: Date,
        cutoff: Date,
        maximumCharacters: Int = 12_000
    ) throws -> RepositoryContext {
        precondition(maximumCharacters >= 1_000)
        let repository = try resolve(
            store: store,
            selector: selector,
            currentDirectory: currentDirectory
        )
        let copies = try store.workingCopies(repositoryID: repository.id)
        let events = try store.events(
            repositoryID: repository.id,
            from: since,
            through: cutoff
        )
        let periodEvents = try CanonicalWorkEvidenceService().events(
            store: store,
            events: events.filter { $0.occurredAt < cutoff && CoreEvidence.includes($0) })
        let activity = try ActivityQueries().snapshot(
            store: store, range: DateInterval(start: since, end: cutoff),
            cutoff: cutoff, repositoryIDs: Set([repository.id]))
        let commits = try store.commits(repositoryID: repository.id, since: since, limit: 50)
            .filter { $0.authorTime < cutoff }
        let messages = CanonicalWorkEvidenceService().messages(
            try store.messages(repositoryID: repository.id, since: since, limit: 200)
                .filter { ($0.occurredAt ?? .distantPast) < cutoff }
        )
        let latestTree = periodEvents.last { $0.kind == .gitWorkingTreeChanged }
        let rendered = render(
            repository: repository,
            copies: copies,
            since: since,
            cutoff: cutoff,
            activeHours: activity.activeHours,
            llmTurns: activity.llmTurns,
            evidenceCount: activity.evidenceCount,
            firstEvidenceAt: activity.firstEvidenceAt,
            lastEvidenceAt: activity.lastEvidenceAt,
            commits: commits,
            messages: messages,
            latestTree: latestTree,
            maximumCharacters: maximumCharacters
        )
        return RepositoryContext(
            repository: repository,
            workingCopies: copies,
            rangeStart: since,
            rangeEnd: cutoff,
            activeHours: activity.activeHours,
            llmTurns: activity.llmTurns,
            evidenceCount: activity.evidenceCount,
            firstEvidenceAt: activity.firstEvidenceAt,
            lastEvidenceAt: activity.lastEvidenceAt,
            commits: commits,
            messages: messages,
            latestWorkingTreeEvent: latestTree,
            rendered: rendered
        )
    }

    public func portfolioContext(
        store: LedgerStore,
        since: Date,
        cutoff: Date,
        maximumCharacters: Int = 12_000
    ) throws -> PortfolioContext {
        precondition(maximumCharacters >= 1_000)
        let range = DateInterval(start: since, end: cutoff)
        let activity = try ActivityQueries().snapshot(store: store, range: range, cutoff: cutoff)
        let repositories = try store.repositories()
        let repositoriesByID = Dictionary(uniqueKeysWithValues: repositories.map { ($0.id, $0) })
        let contextBudget = max(1_000, maximumCharacters / max(activity.repositoryIDs.count, 1))
        let contexts = try activity.repositoryIDs.compactMap { id -> RepositoryContext? in
            guard let repository = repositoriesByID[id] else { return nil }
            return try context(
                store: store,
                repository: repository.id.rawValue,
                currentDirectory: URL(filePath: "/"),
                since: since,
                cutoff: cutoff,
                maximumCharacters: contextBudget
            )
        }
        .sorted {
            if $0.evidenceCount == $1.evidenceCount {
                return $0.repository.displayName.localizedStandardCompare($1.repository.displayName) == .orderedAscending
            }
            return $0.evidenceCount > $1.evidenceCount
        }
        let rendered = renderPortfolio(
            activity: activity,
            contexts: contexts,
            since: since,
            cutoff: cutoff,
            maximumCharacters: maximumCharacters
        )
        return PortfolioContext(
            rangeStart: since,
            rangeEnd: cutoff,
            activity: activity,
            repositories: contexts,
            rendered: rendered
        )
    }

    private func resolve(
        store: LedgerStore,
        selector: String,
        currentDirectory: URL
    ) throws -> Repository {
        let repositories = try store.repositories()
        let copies = try store.workingCopies()
        if selector == "current" {
            let path = currentDirectory.standardizedFileURL.resolvingSymlinksInPath().path
            guard
                let copy =
                    copies
                    .filter({ path == $0.canonicalPath || path.hasPrefix($0.canonicalPath + "/") })
                    .max(by: { $0.canonicalPath.count < $1.canonicalPath.count }),
                let repository = repositories.first(where: { $0.id == copy.repositoryID })
            else {
                throw ContextQueryError.noCurrentRepository(path)
            }
            return repository
        }

        let lowered = selector.lowercased()
        let matches = repositories.filter { repository in
            repository.id.rawValue == selector
                || repository.id.rawValue.hasPrefix(selector)
                || repository.displayName.lowercased() == lowered
                || copies.contains { $0.repositoryID == repository.id && $0.canonicalPath == selector }
        }
        guard !matches.isEmpty else { throw ContextQueryError.repositoryNotFound(selector) }
        guard matches.count == 1 else {
            throw ContextQueryError.ambiguousRepository(selector, matches.map(\.displayName))
        }
        return matches[0]
    }

    private func render(
        repository: Repository,
        copies: [WorkingCopy],
        since: Date,
        cutoff: Date,
        activeHours: Int,
        llmTurns: Int,
        evidenceCount: Int,
        firstEvidenceAt: Date?,
        lastEvidenceAt: Date?,
        commits: [GitCommit],
        messages: [ConversationMessage],
        latestTree: LedgerEvent?,
        maximumCharacters: Int
    ) -> String {
        var lines = [
            "Project: \(repository.displayName)",
            "Period: \(since.ISO8601Format()) through \(cutoff.ISO8601Format())",
            "",
            "Current state:",
        ]
        if let copy = copies.max(by: { $0.lastObservedAt < $1.lastObservedAt }) {
            lines.append("- Branch: \(copy.branch ?? "detached or unknown")")
            lines.append("- HEAD: \(copy.headCommit.map { String($0.prefix(12)) } ?? "unknown")")
        }
        if let latestTree {
            let clean = latestTree.payload["clean"] == "true"
            let count = latestTree.payload["changedFiles"] ?? "0"
            let additions = latestTree.payload["additions"] ?? "0"
            let deletions = latestTree.payload["deletions"] ?? "0"
            lines.append(
                clean
                    ? "- Working tree clean"
                    : "- Working tree has \(count) changed files (+\(additions)/-\(deletions) uncommitted lines)"
            )
        }
        lines.append("- Evidence records: \(evidenceCount) across \(activeHours) clock hour(s); \(llmTurns) LLM turn(s)")
        if let firstEvidenceAt, let lastEvidenceAt {
            lines.append("- Observed window: \(firstEvidenceAt.ISO8601Format()) through \(lastEvidenceAt.ISO8601Format())")
        } else {
            lines.append("- No development evidence detected in this period")
        }

        lines.append(contentsOf: ["", "Recent commits:"])
        if commits.isEmpty {
            lines.append("- No commits detected in this period")
        } else {
            for commit in commits.prefix(20) {
                lines.append(
                    "- \(String(commit.hash.prefix(10))) \(oneLine(commit.message, limit: 180)) (+\(commit.additions ?? 0)/-\(commit.deletions ?? 0))"
                )
            }
        }

        lines.append(contentsOf: ["", "Recent agent conversation evidence:"])
        if messages.isEmpty {
            lines.append("- No associated Codex or Claude messages detected")
        } else {
            for message in messages.prefix(16) {
                lines.append("- [\(message.role.rawValue)] \(oneLine(message.normalizedText, limit: 320))")
            }
        }

        return bounded(lines.joined(separator: "\n"), maximumCharacters: maximumCharacters)
    }

    private func renderPortfolio(
        activity: ActivitySnapshot,
        contexts: [RepositoryContext],
        since: Date,
        cutoff: Date,
        maximumCharacters: Int
    ) -> String {
        var lines = [
            "Work ledger",
            "Period: \(since.ISO8601Format()) through \(cutoff.ISO8601Format())",
            "Summary: \(activity.activeHours) evidence hour(s), \(activity.llmTurns) LLM turn(s), \(activity.commits) commit(s), +\(activity.additions)/-\(activity.deletions) committed lines, \(contexts.count) active project(s)",
        ]

        for context in contexts {
            lines.append(contentsOf: ["", "Project: \(context.repository.displayName)"])
            if let copy = context.workingCopies.max(by: { $0.lastObservedAt < $1.lastObservedAt }) {
                lines.append(
                    "- Branch: \(copy.branch ?? "detached or unknown"); HEAD: \(copy.headCommit.map { String($0.prefix(12)) } ?? "unknown")"
                )
            }
            if let tree = context.latestWorkingTreeEvent {
                if tree.payload["clean"] == "true" {
                    lines.append("- Working tree clean")
                } else {
                    lines.append(
                        "- Uncommitted: \(tree.payload["changedFiles"] ?? "0") files (+\(tree.payload["additions"] ?? "0")/-\(tree.payload["deletions"] ?? "0"))"
                    )
                }
            }
            lines.append(
                "- Evidence: \(context.activeHours) hour(s), \(context.llmTurns) turn(s), \(context.commits.count) commit(s)"
            )
            for commit in context.commits.prefix(5) {
                lines.append("- Commit \(String(commit.hash.prefix(10))): \(oneLine(commit.message, limit: 150))")
            }
            for message in context.messages.prefix(4) {
                lines.append("- [\(message.role.rawValue)] \(oneLine(message.normalizedText, limit: 220))")
            }
        }
        return bounded(lines.joined(separator: "\n"), maximumCharacters: maximumCharacters)
    }

    private func oneLine(_ value: String, limit: Int) -> String {
        let normalized = SensitiveText.redact(value).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return normalized.count <= limit ? normalized : String(normalized.prefix(limit - 1)) + "…"
    }

    private func bounded(_ value: String, maximumCharacters: Int) -> String {
        guard value.count > maximumCharacters else { return value }
        let marker = "\n… output budget reached"
        let prefixCount = max(0, maximumCharacters - marker.count)
        return String(value.prefix(prefixCount)) + marker
    }
}
