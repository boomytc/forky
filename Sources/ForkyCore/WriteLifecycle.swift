import Foundation

public struct WriteCompletion<Value: Sendable>: Sendable {
    public let operation: Result<Void, Error>
    public let reconciliation: Result<Value, Error>
}

/// Single-use owner. Cancel the operation, never its final reconciliation.
public actor WriteLifecycle {
    public enum Phase: Sendable { case pending, running, reconciling, finished }
    public private(set) var phase = Phase.pending
    private var child: Task<Void, Error>?
    private var cancellationRequested = false

    public init() {}

    @discardableResult
    public func cancel() -> Bool {
        guard (phase == .pending || phase == .running), !cancellationRequested else { return false }
        cancellationRequested = true
        child?.cancel()
        return true
    }

    public func execute<Value: Sendable>(
        operation: @escaping @Sendable () async throws -> Void,
        reconcile: @escaping @Sendable () async throws -> Value,
        willReconcile: @escaping @Sendable () async -> Void = {}
    ) async throws -> WriteCompletion<Value> {
        guard phase == .pending else { throw GitError.invalidInput("This operation lifecycle has already been used.") }
        phase = .running
        let task = Task { try Task.checkCancellation(); try await operation() }
        child = task
        if cancellationRequested { task.cancel() }
        return await withTaskCancellationHandler {
            let result = await task.result
            child = nil; phase = .reconciling
            await willReconcile()
            // Unstructured by design: caller cancellation cannot poison final state reads.
            let finalizer = Task { try await reconcile() }
            let state = await finalizer.result
            phase = .finished
            return WriteCompletion(operation: result, reconciliation: state)
        } onCancel: { Task { await self.cancel() } }
    }
}
