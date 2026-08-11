import Foundation
import TrackifyDomain

public enum TrackifyChangeKind: String, Sendable {
    case ledger
    case settings
}

public enum TrackifyChangeSignal {
    public static let notificationName = Notification.Name("com.zoulabs.trackify.local-state-changed")

    public static func identifier(for ledgerURL: URL) -> String {
        StableHash.sha256(ledgerURL.standardizedFileURL.path)
    }

    public static func post(for ledgerURL: URL, kind: TrackifyChangeKind) {
        DistributedNotificationCenter.default().post(
            name: notificationName,
            object: identifier(for: ledgerURL),
            userInfo: [
                "kind": kind.rawValue,
                "processID": Int(ProcessInfo.processInfo.processIdentifier),
            ])
    }
}
