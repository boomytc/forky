import Foundation
import Darwin

public struct GitProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
}

/// Direct argv invocation. No shell, external pager, or interactive stdin.
public struct GitProcessRunner: Sendable {
    public let executable: URL
    private let environment: [String: String]
    public let timeout: TimeInterval
    public let outputLimit: Int

    public init(executable: URL = URL(fileURLWithPath: "/usr/bin/git"),
                environment: [String: String] = ProcessInfo.processInfo.environment,
                timeout: TimeInterval = 30, outputLimit: Int = 4 * 1024 * 1024) {
        self.executable = executable
        // Ambient GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE, injected config, etc. must
        // never redirect the caller-selected repository. The environment is not persisted.
        self.environment = environment.filter { !$0.key.hasPrefix("GIT_") }
            .merging(["GIT_TERMINAL_PROMPT": "0", "GIT_PAGER": "cat", "LC_ALL": "C"]) { _, rhs in rhs }
        self.timeout = timeout
        self.outputLimit = outputLimit
    }

    public func run(_ arguments: [String], directory: URL? = nil) async throws -> GitProcessResult {
        try Task.checkCancellation()
        let invocation = ProcessInvocation(executable: executable, arguments: arguments,
                                           directory: directory, environment: environment,
                                           timeout: timeout, outputLimit: outputLimit)
        return try await invocation.result()
    }
}

/// Mutable process state and both nonblocking readers have exactly one queue owner.
/// The unchecked conformance bridges Foundation Process into that ownership boundary.
private final class ProcessInvocation: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.forky.process.\(UUID())")
    private let process = Process()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let timeout: TimeInterval
    private let outputLimit: Int
    private var readers: [DispatchSourceRead?] = [nil, nil]
    private var buffers: [Data] = [Data(), Data()]
    private var ended = [false, false]
    private var exitStatus: Int32?
    private var stopReason: (any Error)?
    private var finished = false
    private var started = false
    private var timer: DispatchSourceTimer?
    private var continuation: CheckedContinuation<GitProcessResult, Error>?

    init(executable: URL, arguments: [String], directory: URL?,
         environment: [String: String], timeout: TimeInterval, outputLimit: Int) {
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outPipe
        process.standardError = errPipe
        self.timeout = max(0.05, timeout)
        self.outputLimit = max(1, outputLimit)
    }

    func result() async throws -> GitProcessResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.continuation = continuation
                    self.begin()
                }
            }
        } onCancel: {
            self.queue.async {
                self.stop(CancellationError())
            }
        }
    }

    private func begin() {
        if stopReason != nil { finish(); return }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.didExit() }
        }
        do {
            for index in 0...1 {
                let fd = readHandle(index).fileDescriptor
                guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else {
                    throw GitError.launch("Could not configure output pipe.")
                }
                let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                reader.setEventHandler { [weak self] in self?.read(index) }
                readers[index] = reader
                reader.resume()
            }
            try process.run()
            started = true
            try outPipe.fileHandleForWriting.close()
            try errPipe.fileHandleForWriting.close()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { [weak self] in self?.stop(GitError.timedOut) }
            self.timer = timer
            timer.resume()
        } catch {
            if started { stop(GitError.launch(error.localizedDescription)) }
            else { stopReason = GitError.launch(error.localizedDescription); finish() }
        }
    }

    private func readHandle(_ index: Int) -> FileHandle {
        index == 0 ? outPipe.fileHandleForReading : errPipe.fileHandleForReading
    }

    private func read(_ index: Int) {
        guard !finished, !ended[index] else { return }
        var bytes = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(readHandle(index).fileDescriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                let remaining = max(0, outputLimit - buffers[index].count)
                buffers[index].append(contentsOf: bytes.prefix(min(count, remaining)))
                if count > remaining { stop(GitError.outputLimit(outputLimit)) }
            } else if count == 0 {
                closeReader(index)
                finishIfReady()
                return
            } else {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    stop(GitError.incompleteOutput)
                    closeReader(index)
                }
                return
            }
        }
    }

    private func closeReader(_ index: Int) {
        guard !ended[index] else { return }
        ended[index] = true
        readers[index]?.cancel()
        readers[index] = nil
        try? readHandle(index).close()
    }

    private func stop(_ error: any Error) {
        guard !finished else { return }
        if stopReason == nil { stopReason = error }
        guard started else { return }
        if process.isRunning {
            process.terminate()
            // Escalate only the still-owned direct child, never an unrelated PID.
            queue.asyncAfter(deadline: .now() + 1) { [self] in
                if !finished && process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    private func didExit() {
        guard !finished else { return }
        exitStatus = process.terminationStatus
        read(0)
        read(1)
        finishIfReady()
        guard !finished else { return }
        // Hooks or helpers can inherit pipes. Never wait indefinitely for those
        // descendants, or claim that their lifetime is controlled by this runner.
        queue.asyncAfter(deadline: .now() + 1) { [self] in
            if !finished {
                if stopReason == nil { stopReason = GitError.incompleteOutput }
                finish()
            }
        }
    }

    private func finishIfReady() {
        if exitStatus != nil && ended.allSatisfy({ $0 }) { finish() }
    }

    private func finish() {
        guard !finished, let continuation else { return }
        finished = true
        timer?.cancel()
        timer = nil
        process.terminationHandler = nil
        closeReader(0)
        closeReader(1)
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        self.continuation = nil
        if let stopReason { continuation.resume(throwing: stopReason) }
        else if let exitStatus {
            continuation.resume(returning: GitProcessResult(status: exitStatus, stdout: buffers[0], stderr: buffers[1]))
        } else { continuation.resume(throwing: GitError.launch("No process result.")) }
    }
}
