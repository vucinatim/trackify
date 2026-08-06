import Darwin
import Foundation

public struct ProcessOutput: Equatable, Sendable {
    public let status: Int32
    public let data: Data

    public init(status: Int32, data: Data) {
        self.status = status
        self.data = data
    }

    public var utf8: String { String(decoding: data, as: UTF8.self) }
}

public enum ProcessRunnerError: Error, Equatable, LocalizedError {
    case outputLimitExceeded(Int)
    case timedOut(seconds: TimeInterval)
    case failed(executable: String, status: Int32, output: String)

    public var errorDescription: String? {
        switch self {
        case .outputLimitExceeded(let limit):
            "Process output exceeded the \(limit)-byte safety limit."
        case .timedOut(let seconds):
            "Process exceeded its \(seconds.formatted())-second execution deadline."
        case .failed(let executable, let status, let output):
            "\(executable) exited with status \(status): \(output)"
        }
    }
}

public protocol CommandRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        outputLimit: Int
    ) throws -> ProcessOutput
}

public protocol InputCommandRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        input: Data,
        outputLimit: Int
    ) throws -> ProcessOutput

    func runAsync(
        executable: URL,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        input: Data,
        outputLimit: Int
    ) async throws -> ProcessOutput
}

extension InputCommandRunning {
    public func runAsync(
        executable: URL,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        input: Data,
        outputLimit: Int
    ) async throws -> ProcessOutput {
        try run(
            executable: executable, arguments: arguments,
            workingDirectory: workingDirectory, environment: environment,
            input: input, outputLimit: outputLimit)
    }
}

public struct ProcessRunner: CommandRunning, InputCommandRunning {
    public let timeout: TimeInterval
    public let terminationGrace: TimeInterval

    public init(timeout: TimeInterval = 300, terminationGrace: TimeInterval = 2) {
        precondition(timeout > 0)
        precondition(terminationGrace > 0)
        self.timeout = timeout
        self.terminationGrace = terminationGrace
    }

    public func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        outputLimit: Int = 8 * 1_024 * 1_024
    ) throws -> ProcessOutput {
        try execute(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            input: nil,
            outputLimit: outputLimit
        )
    }

    public func runAsync(
        executable: URL,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        input: Data,
        outputLimit: Int
    ) async throws -> ProcessOutput {
        let cancellation = ProcessCancellation()
        return try await withTaskCancellationHandler {
            let task = Task.detached(priority: .utility) {
                try execute(
                    executable: executable, arguments: arguments,
                    workingDirectory: workingDirectory, environment: environment,
                    input: input, outputLimit: outputLimit, cancellation: cancellation)
            }
            let output = try await task.value
            try Task.checkCancellation()
            return output
        } onCancel: {
            cancellation.cancel()
        }
    }

    public func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        input: Data,
        outputLimit: Int
    ) throws -> ProcessOutput {
        try execute(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            input: input,
            outputLimit: outputLimit
        )
    }

    private func execute(
        executable: URL,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        input: Data?,
        outputLimit: Int,
        cancellation: ProcessCancellation? = nil
    ) throws -> ProcessOutput {
        precondition(outputLimit > 0)
        let process = Process()
        let outputPipe = Pipe()
        let inputPipe = input.map { _ in Pipe() }
        let termination = DispatchSemaphore(value: 0)
        let readerFinished = DispatchSemaphore(value: 0)
        let state = ProcessExecutionState(outputLimit: outputLimit)
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        if let environment { process.environment = environment }
        if let inputPipe { process.standardInput = inputPipe }
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.terminationHandler = { _ in termination.signal() }

        try process.run()
        let processID = process.processIdentifier
        cancellation?.attach(processID: processID)
        defer { cancellation?.detach(processID: processID) }
        try outputPipe.fileHandleForWriting.close()
        Thread.detachNewThread {
            defer { readerFinished.signal() }
            do {
                while let chunk = try outputPipe.fileHandleForReading.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                    if !state.append(chunk) {
                        _ = Darwin.kill(processID, SIGTERM)
                    }
                }
            } catch {
                state.recordReadError(error)
            }
        }

        var inputError: Error?
        if let input, let inputPipe {
            do {
                try inputPipe.fileHandleForWriting.write(contentsOf: input)
                try inputPipe.fileHandleForWriting.close()
            } catch {
                _ = Darwin.kill(processID, SIGTERM)
                inputError = error
            }
        }

        let initialDeadline = inputError == nil ? timeout : terminationGrace
        let initialWaitTimedOut = termination.wait(timeout: .now() + initialDeadline) == .timedOut
        let timedOut = inputError == nil && initialWaitTimedOut
        if initialWaitTimedOut {
            _ = Darwin.kill(processID, SIGTERM)
            if termination.wait(timeout: .now() + terminationGrace) == .timedOut {
                _ = Darwin.kill(processID, SIGKILL)
                termination.wait()
            }
        }
        readerFinished.wait()

        if let inputError { throw inputError }
        if timedOut { throw ProcessRunnerError.timedOut(seconds: timeout) }
        if let error = state.error { throw error }
        return ProcessOutput(status: process.terminationStatus, data: state.data)
    }
}

private final class ProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var processID: pid_t?

    func attach(processID: pid_t) {
        lock.lock()
        self.processID = processID
        let shouldCancel = isCancelled
        lock.unlock()
        if shouldCancel { _ = Darwin.kill(processID, SIGTERM) }
    }

    func detach(processID: pid_t) {
        lock.withLock {
            if self.processID == processID { self.processID = nil }
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let processID = processID
        lock.unlock()
        if let processID { _ = Darwin.kill(processID, SIGTERM) }
    }
}

private final class ProcessExecutionState: @unchecked Sendable {
    private let lock = NSLock()
    private let outputLimit: Int
    private var output = Data()
    private var storedError: Error?

    init(outputLimit: Int) {
        self.outputLimit = outputLimit
    }

    func append(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard storedError == nil else { return false }
        guard output.count + data.count <= outputLimit else {
            storedError = ProcessRunnerError.outputLimitExceeded(outputLimit)
            return false
        }
        output.append(data)
        return true
    }

    func recordReadError(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        if storedError == nil { storedError = error }
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return output
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }
}
