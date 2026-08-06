import Foundation

public enum SearchDocumentKind: String, Codable, Sendable {
    case repository
    case commit
    case message
    case report
}

public struct SearchResult: Codable, Equatable, Sendable {
    public let kind: SearchDocumentKind
    public let entityID: String
    public let repositoryID: RepositoryID?
    public let occurredAt: Date?
    public let excerpt: String

    public init(
        kind: SearchDocumentKind,
        entityID: String,
        repositoryID: RepositoryID?,
        occurredAt: Date?,
        excerpt: String
    ) {
        self.kind = kind
        self.entityID = entityID
        self.repositoryID = repositoryID
        self.occurredAt = occurredAt
        self.excerpt = excerpt
    }
}
