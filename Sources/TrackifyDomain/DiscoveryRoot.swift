import Foundation

public struct DiscoveryRoot: Codable, Equatable, Sendable {
    public let id: DiscoveryRootID
    public var canonicalPath: String
    public var displayName: String
    public var isEnabled: Bool
    public var sortOrder: Int
    public var excludedPaths: [String]
    public let createdAt: Date
    public var lastScannedAt: Date?

    public init(
        id: DiscoveryRootID,
        canonicalPath: String,
        displayName: String,
        isEnabled: Bool = true,
        sortOrder: Int = 0,
        excludedPaths: [String] = [],
        createdAt: Date,
        lastScannedAt: Date? = nil
    ) {
        self.id = id
        self.canonicalPath = canonicalPath
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
        self.excludedPaths = excludedPaths
        self.createdAt = createdAt
        self.lastScannedAt = lastScannedAt
    }
}
