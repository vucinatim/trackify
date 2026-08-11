import Foundation

public protocol WallClock: Sendable {
    func now() -> Date
}

public struct SystemWallClock: WallClock {
    public init() {}

    public func now() -> Date { Date() }
}

public struct FixedWallClock: WallClock {
    public let instant: Date

    public init(_ instant: Date) {
        self.instant = instant
    }

    public func now() -> Date { instant }
}
