import Foundation
import Testing
@testable import ForkyCore

@Suite struct ProcessTests {
    @Test func drainsBothStreamsWithoutDeadlock() async throws {
        let runner = GitProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/python3"))
        let result = try await runner.run(["-c", "import sys; sys.stdout.buffer.write(b'x'*300000); sys.stderr.buffer.write(b'y'*300000)"])
        #expect(result.status == 0)
        #expect(result.stdout.count == 300000)
        #expect(result.stderr.count == 300000)
    }

    @Test func outputLimitIsAnErrorNotTruncatedSuccess() async {
        let runner = GitProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/python3"), outputLimit: 1024)
        await #expect(throws: GitError.self) {
            try await runner.run(["-c", "import sys; sys.stdout.buffer.write(b'x'*1000000)"])
        }
    }

    @Test func timeoutFinishesAfterOwnedChildExit() async {
        let runner = GitProcessRunner(executable: URL(fileURLWithPath: "/bin/sleep"), timeout: 0.1)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await runner.run(["10"])
            Issue.record("A timed-out child must not return a result.")
        } catch GitError.timedOut {
            #expect(start.duration(to: clock.now) >= .milliseconds(90))
        } catch {
            Issue.record("Expected a timeout, received \(error).")
        }
        #expect(start.duration(to: clock.now) < .seconds(4))
    }

    @Test func cancellationIsNotAnExitCodeSuccess() async throws {
        let runner = GitProcessRunner(executable: URL(fileURLWithPath: "/bin/sleep"))
        let task = Task { try await runner.run(["10"]) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func launchFailureRetainsReason() async {
        let runner = GitProcessRunner(executable: URL(fileURLWithPath: "/Forky-no-such-tool"))
        do {
            _ = try await runner.run([])
            Issue.record("A missing executable must fail.")
        } catch GitError.launch(let reason) {
            #expect(reason.contains("Forky-no-such-tool"))
        } catch {
            Issue.record("Expected GitError.launch, received \(error).")
        }
    }

    @Test func cancelledWaiterDoesNotLeakTheRepositoryGate() async throws {
        let gate = AsyncGate()
        let first = Task { try await gate.withPermit { try await Task.sleep(for: .milliseconds(150)); return 1 } }
        try await Task.sleep(for: .milliseconds(30))
        let waiting = Task { try await gate.withPermit { 2 } }
        try await Task.sleep(for: .milliseconds(30))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(try await first.value == 1)
        #expect(try await gate.withPermit { 3 } == 3)
    }
}
