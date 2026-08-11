import Foundation
import TrackifyDomain

public final class MutableWallClock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    public init(_ instant: Date) {
        self.instant = instant
    }

    public func now() -> Date {
        lock.withLock { instant }
    }

    @discardableResult
    public func advance(by interval: TimeInterval) -> Date {
        lock.withLock {
            instant = instant.addingTimeInterval(interval)
            return instant
        }
    }

    public func set(_ date: Date) {
        lock.withLock {
            instant = date
        }
    }
}
