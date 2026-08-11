import CoreServices
import Foundation

public struct FileSystemChange: Equatable, Sendable {
    public let path: String
    public let rawFlags: UInt32
    public let eventID: UInt64
    public let observedAt: Date

    public init(path: String, rawFlags: UInt32, eventID: UInt64, observedAt: Date) {
        self.path = URL(filePath: path).standardizedFileURL.path
        self.rawFlags = rawFlags
        self.eventID = eventID
        self.observedAt = observedAt
    }

    public var requiresReconciliation: Bool {
        let recoveryFlags =
            FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
        return FSEventStreamEventFlags(rawFlags) & recoveryFlags != 0
    }
}

public protocol FileSystemChangeMonitoring: AnyObject, Sendable {
    var monitoredRoots: [URL] { get }
    func start() throws
    func stop()
}

public enum FileSystemChangeMonitorError: Error, LocalizedError {
    case streamCreationFailed

    public var errorDescription: String? {
        switch self {
        case .streamCreationFailed: "macOS could not create the filesystem event stream."
        }
    }
}

public final class FSEventsChangeMonitor: FileSystemChangeMonitoring, @unchecked Sendable {
    public typealias Handler = @Sendable ([FileSystemChange]) -> Void

    private final class CallbackBox: @unchecked Sendable {
        let handler: Handler
        init(handler: @escaping Handler) { self.handler = handler }
    }

    public let monitoredRoots: [URL]
    private let latency: TimeInterval
    private let handler: Handler
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var callbackBox: CallbackBox?

    public init(
        roots: [URL],
        latency: TimeInterval = 0.25,
        handler: @escaping Handler
    ) {
        precondition(latency >= 0)
        var seen = Set<String>()
        monitoredRoots = roots.map(\.standardizedFileURL)
            .filter { seen.insert($0.path).inserted }
            .sorted { $0.path < $1.path }
        self.latency = latency
        self.handler = handler
        queue = DispatchQueue(label: "com.zoulabs.trackify.fs-events", qos: .utility)
    }

    deinit { stop() }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil, !monitoredRoots.isEmpty else { return }

        let box = CallbackBox(handler: handler)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil)
        let callback: FSEventStreamCallback = {
            _, info, eventCount, eventPaths, eventFlags, eventIDs in
            guard let info else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
            let pathPointers = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
            let now = Date()
            var changes: [FileSystemChange] = []
            changes.reserveCapacity(eventCount)
            for index in 0..<eventCount {
                guard let path = pathPointers[index] else { continue }
                changes.append(
                    FileSystemChange(
                        path: String(cString: path),
                        rawFlags: eventFlags[index],
                        eventID: eventIDs[index],
                        observedAt: now))
            }
            if !changes.isEmpty { box.handler(changes) }
        }
        let flags =
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
            | FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        guard
            let created = FSEventStreamCreate(
                nil, callback, &context,
                monitoredRoots.map(\.path) as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency, flags)
        else { throw FileSystemChangeMonitorError.streamCreationFailed }

        callbackBox = box
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            stream = nil
            callbackBox = nil
            throw FileSystemChangeMonitorError.streamCreationFailed
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        callbackBox = nil
    }
}
