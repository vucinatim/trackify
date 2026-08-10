import Darwin
import Foundation

public struct JSONLFileCursor: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let offset: UInt64

    public init(device: UInt64, inode: UInt64, offset: UInt64) {
        self.device = device
        self.inode = inode
        self.offset = offset
    }
}

public struct JSONLReadResult: Equatable, Sendable {
    public let lines: [Data]
    public let cursor: JSONLFileCursor
    public let ignoredPartialTailBytes: Int
    public let hasMoreData: Bool
    public let oversizedLineCount: Int
    public let processedBytes: Int

    public init(
        lines: [Data],
        cursor: JSONLFileCursor,
        ignoredPartialTailBytes: Int,
        hasMoreData: Bool,
        oversizedLineCount: Int = 0,
        processedBytes: Int = 0
    ) {
        self.lines = lines
        self.cursor = cursor
        self.ignoredPartialTailBytes = ignoredPartialTailBytes
        self.hasMoreData = hasMoreData
        self.oversizedLineCount = oversizedLineCount
        self.processedBytes = processedBytes
    }

    public var processedRecordCount: Int { lines.count + oversizedLineCount }
}

public enum JSONLReaderError: Error, Equatable, LocalizedError {
    case lineTooLarge(limit: Int)

    public var errorDescription: String? {
        switch self {
        case .lineTooLarge(let limit):
            "JSONL record exceeded the \(limit)-byte safety limit."
        }
    }
}

public struct JSONLReader: Sendable {
    public let maximumLineBytes: Int
    public let chunkBytes: Int
    public let skipOversizedLines: Bool

    public init(
        maximumLineBytes: Int = 16 * 1_024 * 1_024,
        chunkBytes: Int = 64 * 1_024,
        skipOversizedLines: Bool = false
    ) {
        self.maximumLineBytes = maximumLineBytes
        self.chunkBytes = chunkBytes
        self.skipOversizedLines = skipOversizedLines
    }

    /// `Data.firstIndex(of:)` dispatches through the generic Collection
    /// implementation and becomes disproportionately expensive for large JSONL
    /// records. JSONL delimiters are single bytes, so use libc's linear byte
    /// search over the contiguous storage instead.
    private func firstNewline(in data: Data) -> Data.Index? {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress,
                let match = memchr(base, Int32(0x0A), bytes.count)
            else { return nil }
            let distance = base.distance(to: UnsafeRawPointer(match))
            return data.index(data.startIndex, offsetBy: distance)
        }
    }

    public func read(
        _ url: URL,
        after previous: JSONLFileCursor? = nil,
        maximumRecords: Int = .max,
        maximumBytes: Int = .max
    ) throws -> JSONLReadResult {
        precondition(maximumRecords > 0)
        precondition(maximumBytes > 0)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let canResume = previous?.device == device && previous?.inode == inode && (previous?.offset ?? 0) <= fileSize
        let startOffset = canResume ? previous?.offset ?? 0 : 0

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: startOffset)

        var lines: [Data] = []
        var lineByteLengths: [Int] = []
        var pending = Data()
        var committedBytes: UInt64 = 0
        var reachedRecordLimit = false
        var discardedOversizedBytes = 0
        var oversizedLineCount = 0

        readLoop: while let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty {
            pending.append(chunk)
            while true {
                if discardedOversizedBytes > 0 {
                    guard let newline = firstNewline(in: pending) else {
                        discardedOversizedBytes += pending.count
                        pending.removeAll(keepingCapacity: true)
                        continue readLoop
                    }
                    let consumed = pending.distance(from: pending.startIndex, to: newline) + 1
                    committedBytes += UInt64(discardedOversizedBytes + consumed)
                    discardedOversizedBytes = 0
                    oversizedLineCount += 1
                    pending.removeFirst(consumed)
                    if lines.count + oversizedLineCount >= maximumRecords {
                        reachedRecordLimit = true
                        break readLoop
                    }
                    if committedBytes >= UInt64(maximumBytes) {
                        reachedRecordLimit = true
                        break readLoop
                    }
                    continue
                }

                guard let newline = firstNewline(in: pending) else { break }
                let line = pending[..<newline]
                let consumed = pending.distance(from: pending.startIndex, to: newline) + 1
                if line.count > maximumLineBytes {
                    guard skipOversizedLines else {
                        throw JSONLReaderError.lineTooLarge(limit: maximumLineBytes)
                    }
                    oversizedLineCount += 1
                    pending.removeFirst(consumed)
                    committedBytes += UInt64(consumed)
                    if lines.count + oversizedLineCount >= maximumRecords {
                        reachedRecordLimit = true
                        break readLoop
                    }
                    if committedBytes >= UInt64(maximumBytes) {
                        reachedRecordLimit = true
                        break readLoop
                    }
                    continue
                }
                if !line.isEmpty {
                    lines.append(Data(line))
                    lineByteLengths.append(consumed)
                }
                pending.removeFirst(consumed)
                committedBytes += UInt64(consumed)
                if lines.count + oversizedLineCount >= maximumRecords {
                    reachedRecordLimit = true
                    break readLoop
                }
                if committedBytes >= UInt64(maximumBytes) {
                    reachedRecordLimit = true
                    break readLoop
                }
            }
            if pending.count > maximumLineBytes {
                guard skipOversizedLines else {
                    throw JSONLReaderError.lineTooLarge(limit: maximumLineBytes)
                }
                discardedOversizedBytes = pending.count
                pending.removeAll(keepingCapacity: true)
            }
        }

        var ignoredTailBytes = reachedRecordLimit ? 0 : pending.count + discardedOversizedBytes
        if !reachedRecordLimit,
            let last = lines.last,
            (try? JSONSerialization.jsonObject(with: last)) == nil,
            let byteLength = lineByteLengths.last
        {
            lines.removeLast()
            lineByteLengths.removeLast()
            committedBytes -= UInt64(byteLength)
            ignoredTailBytes += byteLength
        }

        return JSONLReadResult(
            lines: lines,
            cursor: JSONLFileCursor(device: device, inode: inode, offset: startOffset + committedBytes),
            ignoredPartialTailBytes: ignoredTailBytes,
            hasMoreData: reachedRecordLimit || startOffset + committedBytes < fileSize,
            oversizedLineCount: oversizedLineCount,
            processedBytes: Int(clamping: committedBytes)
        )
    }

    public func readFirstLine(_ url: URL) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var pending = Data()
        while let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty {
            pending.append(chunk)
            if let newline = firstNewline(in: pending) {
                let line = pending[..<newline]
                guard line.count <= maximumLineBytes else {
                    throw JSONLReaderError.lineTooLarge(limit: maximumLineBytes)
                }
                return line.isEmpty ? nil : Data(line)
            }
            guard pending.count <= maximumLineBytes else {
                throw JSONLReaderError.lineTooLarge(limit: maximumLineBytes)
            }
        }
        return nil
    }
}
