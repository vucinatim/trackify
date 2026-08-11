import Foundation

public struct Repository: Codable, Equatable, Sendable {
    public let id: RepositoryID
    public var displayName: String
    public var remoteIdentity: String?
    public let firstObservedAt: Date
    public var lastObservedAt: Date

    public init(
        id: RepositoryID,
        displayName: String,
        remoteIdentity: String? = nil,
        firstObservedAt: Date,
        lastObservedAt: Date
    ) {
        self.id = id
        self.displayName = displayName
        self.remoteIdentity = remoteIdentity
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
    }
}

public struct WorkingCopy: Codable, Equatable, Sendable {
    public let id: WorkingCopyID
    public let repositoryID: RepositoryID
    public var canonicalPath: String
    public var branch: String?
    public var headCommit: String?
    public let firstObservedAt: Date
    public var lastObservedAt: Date

    public init(
        id: WorkingCopyID,
        repositoryID: RepositoryID,
        canonicalPath: String,
        branch: String? = nil,
        headCommit: String? = nil,
        firstObservedAt: Date,
        lastObservedAt: Date
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.canonicalPath = canonicalPath
        self.branch = branch
        self.headCommit = headCommit
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
    }
}

public struct RepositoryCatalogItem: Codable, Equatable, Sendable {
    public let repository: Repository
    public let workingCopy: WorkingCopy
    public let discoveryRootID: DiscoveryRootID?
    public let discoveryRootName: String?
    public let relativePath: String?

    public init(
        repository: Repository,
        workingCopy: WorkingCopy,
        discoveryRootID: DiscoveryRootID?,
        discoveryRootName: String?,
        relativePath: String?
    ) {
        self.repository = repository
        self.workingCopy = workingCopy
        self.discoveryRootID = discoveryRootID
        self.discoveryRootName = discoveryRootName
        self.relativePath = relativePath
    }
}
