import Foundation
import Testing
@testable import ForkyCore

private actor Signal {
    private var fired = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if fired { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func send() { fired = true; waiter?.resume(); waiter = nil }
}

/// A missing signal is a test failure, not an indefinitely hanging test process.
private func awaitSignal(_ signal: Signal, timeout: Duration = .seconds(5)) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask { await signal.wait(); return true }
        group.addTask { try? await Task.sleep(for: timeout); return false }
        let received = await group.next() ?? false
        // `wait()` uses a non-cancellable checked continuation. Resume it explicitly on
        // timeout so the task group can finish instead of hanging the test process.
        if !received { await signal.send() }
        group.cancelAll()
        return received
    }
}

@Suite struct WriteLifecycleTests {
    @Test func activeCancellationStillReconcilesOnUncancelledTask() async throws {
        let lifecycle = WriteLifecycle(), began = Signal()
        let owner = Task {
            try await lifecycle.execute(operation: {
                await began.send()
                try await Task.sleep(for: .seconds(20))
            }, reconcile: { try Task.checkCancellation(); return "fresh" })
        }
        guard await awaitSignal(began) else {
            owner.cancel(); Issue.record("The operation never started."); return
        }
        #expect(await lifecycle.cancel())
        let result = try await owner.value
        #expect(throws: CancellationError.self) { try result.operation.get() }
        #expect(try result.reconciliation.get() == "fresh")
        #expect(await lifecycle.phase == .finished)
    }

    @Test func callerCancellationDuringFinalizationCannotCancelOrSkipCleanup() async throws {
        let lifecycle = WriteLifecycle(), began = Signal(), release = Signal()
        let owner = Task {
            try await lifecycle.execute(operation: {}, reconcile: {
                await began.send()
                await release.wait()
                try Task.checkCancellation()
                return 42
            })
        }
        guard await awaitSignal(began) else {
            owner.cancel(); Issue.record("Reconciliation never started."); return
        }
        #expect(await lifecycle.phase == .reconciling)
        owner.cancel()
        #expect(await lifecycle.cancel() == false)
        await release.send()
        let result = try await owner.value
        try result.operation.get()
        #expect(try result.reconciliation.get() == 42)
        #expect(await lifecycle.phase == .finished)
    }

    @Test func cancellationBeforeExecutionPreventsWriteButStillReadsState() async throws {
        let lifecycle = WriteLifecycle()
        #expect(await lifecycle.cancel())
        let result = try await lifecycle.execute(operation: { Issue.record("A queued cancelled operation executed") },
                                                 reconcile: { "checked" })
        #expect(throws: CancellationError.self) { try result.operation.get() }
        #expect(try result.reconciliation.get() == "checked")
    }

    @Test func writeAndCleanupFailuresAreBothRetainedAndSessionCannotBeReused() async throws {
        let lifecycle = WriteLifecycle()
        let result: WriteCompletion<String> = try await lifecycle.execute(
            operation: { throw GitError.invalidInput("write failure") },
            reconcile: { throw GitError.invalidInput("refresh failure") })
        if case .failure(let error) = result.operation { #expect(error.localizedDescription == "write failure") }
        else { Issue.record("Write failure was lost") }
        if case .failure(let error) = result.reconciliation { #expect(error.localizedDescription == "refresh failure") }
        else { Issue.record("Reconciliation failure was lost") }
        await #expect(throws: GitError.self) {
            try await lifecycle.execute(operation: { Issue.record("Reused lifecycle") }, reconcile: { "unexpected" })
        }
    }
}
