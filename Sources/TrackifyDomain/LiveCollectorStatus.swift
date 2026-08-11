import Foundation

public enum LiveCollectorMode: String, Codable, Sendable {
    case upToDate = "up-to-date"
    case pending
    case collecting
    case degraded
    case stopped
}

public struct LiveCollectorRuntimeStatus: Codable, Equatable, Sendable {
    public let mode: LiveCollectorMode
    public let pendingTriggerCount: Int
    public let pendingPathCount: Int
    public let lastTriggerAt: Date?
    public let lastCollectionStartedAt: Date?
    public let lastCollectionFinishedAt: Date?
    public let lastMutationAt: Date?
    public let lastLatencySeconds: Double?
    public let medianLatencySeconds: Double?
    public let p95LatencySeconds: Double?
    public let consecutiveFailures: Int
    public let lastError: String?

    public init(
        mode: LiveCollectorMode,
        pendingTriggerCount: Int = 0,
        pendingPathCount: Int = 0,
        lastTriggerAt: Date? = nil,
        lastCollectionStartedAt: Date? = nil,
        lastCollectionFinishedAt: Date? = nil,
        lastMutationAt: Date? = nil,
        lastLatencySeconds: Double? = nil,
        medianLatencySeconds: Double? = nil,
        p95LatencySeconds: Double? = nil,
        consecutiveFailures: Int = 0,
        lastError: String? = nil
    ) {
        self.mode = mode
        self.pendingTriggerCount = pendingTriggerCount
        self.pendingPathCount = pendingPathCount
        self.lastTriggerAt = lastTriggerAt
        self.lastCollectionStartedAt = lastCollectionStartedAt
        self.lastCollectionFinishedAt = lastCollectionFinishedAt
        self.lastMutationAt = lastMutationAt
        self.lastLatencySeconds = lastLatencySeconds
        self.medianLatencySeconds = medianLatencySeconds
        self.p95LatencySeconds = p95LatencySeconds
        self.consecutiveFailures = consecutiveFailures
        self.lastError = lastError
    }
}
