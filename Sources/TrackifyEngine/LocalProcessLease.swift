import Foundation
import TrackifyStore

enum LocalProcessLease {
    static func acquire(
        store: LedgerStore,
        name: String,
        ownerID: String,
        ownerKinds: Set<String>,
        now: Date,
        duration: TimeInterval
    ) throws -> Bool {
        if try store.acquireLease(
            name: name, ownerID: ownerID, now: now, duration: duration)
        {
            return true
        }
        guard let previousOwner = try store.leaseOwner(name: name),
            isDead(previousOwner, ownerKinds: ownerKinds)
        else {
            return false
        }
        try store.releaseLease(name: name, ownerID: previousOwner)
        return try store.acquireLease(
            name: name, ownerID: ownerID, now: now, duration: duration)
    }

    private static func isDead(_ ownerID: String, ownerKinds: Set<String>) -> Bool {
        let components = ownerID.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count >= 3,
            ownerKinds.contains(String(components[0])),
            let processID = Int32(components[1])
        else {
            return false
        }
        errno = 0
        return kill(processID, 0) == -1 && errno == ESRCH
    }
}
