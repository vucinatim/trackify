import Foundation

public struct GitCommit: Codable, Equatable, Sendable {
    public let id: String
    public let repositoryID: RepositoryID
    public let hash: String
    public let authorTime: Date
    public let message: String
    public let additions: Int?
    public let deletions: Int?
    public let filesChanged: Int?
    public let firstObservedAt: Date
    public let lastObservedAt: Date
    public let isReachable: Bool

    public init(
        id: String,
        repositoryID: RepositoryID,
        hash: String,
        authorTime: Date,
        message: String,
        additions: Int?,
        deletions: Int?,
        filesChanged: Int? = nil,
        firstObservedAt: Date,
        lastObservedAt: Date,
        isReachable: Bool
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.hash = hash
        self.authorTime = authorTime
        self.message = message
        self.additions = additions
        self.deletions = deletions
        self.filesChanged = filesChanged
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
        self.isReachable = isReachable
    }
}
