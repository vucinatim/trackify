import Foundation
import TrackifyDomain
import TrackifyStore

public struct DiscoveryRootManager: Sendable {
    public init() {}

    @discardableResult
    public func add(
        path: URL,
        name: String? = nil,
        store: LedgerStore,
        now: Date = Date()
    ) throws -> DiscoveryRoot {
        let canonical = path.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw CocoaError(.fileNoSuchFile)
        }
        let label = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = label.flatMap { $0.isEmpty ? nil : $0 } ?? canonical.lastPathComponent
        let root = DiscoveryRoot(
            id: DiscoveryRootID(StableHash.sha256("discovery-root:\(canonical.path)")),
            canonicalPath: canonical.path,
            displayName: displayName,
            createdAt: now
        )
        try store.upsert(discoveryRoot: root)
        return root
    }
}
