import Foundation
import Testing
@testable import ForkyCore

struct ManagementTests {
    @Test func amendOnlyMessagePreservesIndexAndWorktree() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        try f.write("README.md", "staged\n"); try await f.git(["add", "README.md"])
        try f.write("README.md", "unstaged\n")
        let repo = try await f.repository(), before = try await repo.snapshot()
        try await repo.amend(message: "New subject\n\nNew body", includeStaged: false, expected: before)
        #expect(try String(contentsOf: f.root.appendingPathComponent("README.md"), encoding: .utf8) == "unstaged\n")
        #expect(try GitParsers.string(try await f.git(["show", "HEAD:README.md"]).stdout) == "# Hello\n")
        #expect(try GitParsers.string(try await f.git(["show", ":README.md"]).stdout) == "staged\n")
        let info = try await repo.commitInfo(try #require(try await repo.snapshot().head))
        #expect(info.subject == "New subject")
    }
    @Test func amendStagedAndStaleGuard() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repo = try await f.repository(), old = try await repo.snapshot()
        try f.write("README.md", "new\n"); try await f.git(["add", "README.md"])
        await #expect(throws: GitError.self) { try await repo.amend(message: "no", includeStaged: true, expected: old) }
        try await repo.amend(message: "yes", includeStaged: true, expected: repo.snapshot())
        #expect(try GitParsers.string(try await f.git(["show", "HEAD:README.md"]).stdout) == "new\n")
    }
    @Test func referenceLifecycleAndStaleIdentity() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repo = try await f.repository()
        try await f.git(["branch", "topic"])
        var s = try await repo.snapshot()
        let ref = try #require(s.references.first { $0.name == "topic" })
        try await repo.changeReference(.rename(ref, "renamed"), expected: s)
        await #expect(throws: GitError.self) { try await repo.changeReference(.delete(ref), expected: s) }
        s = try await repo.snapshot()
        try await repo.changeReference(.delete(try #require(s.references.first { $0.name == "renamed" })), expected: s)
        s = try await repo.snapshot()
        try await repo.changeReference(.tag(name: "v1", oid: try #require(s.head), message: "Release"), expected: s)
        s = try await repo.snapshot()
        let tag = try #require(s.tags.first); #expect(tag.objectOID != tag.commitOID)
        try await repo.changeReference(.rename(tag, "renamed-tag"), expected: s)
        s = try await repo.snapshot()
        let renamed = try #require(s.tags.first)
        #expect(renamed.objectOID == tag.objectOID)
        try await repo.changeReference(.delete(renamed), expected: s)
        #expect(try await repo.snapshot().tags.isEmpty)
    }
    @Test func configurationEditsAreReviewed() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repo = try await f.repository()
        try await repo.addRemote(name: "origin", url: "/tmp/nowhere", expected: repo.snapshot())
        var s = try await repo.snapshot(); let remote = try #require(s.collaboration.value?.remotes.first)
        try await repo.changeReference(.remoteURL(remote, "/tmp/elsewhere"), expected: s)
        await #expect(throws: GitError.self) { try await repo.changeReference(.removeRemote(remote), expected: s) }
        s = try await repo.snapshot()
        try await repo.changeReference(.remotePushURL(try #require(s.collaboration.value?.remotes.first), "/tmp/push-only"), expected: s)
        s = try await repo.snapshot()
        #expect(s.collaboration.value?.remotes.first?.effectivePushURLs == ["/tmp/push-only"])
        try await repo.changeReference(.removeRemote(try #require(s.collaboration.value?.remotes.first)), expected: s)
        #expect(try await repo.snapshot().collaboration.value?.remotes.isEmpty == true)
    }
    @Test(arguments: MergeMode.allCases) func mergeModes(mode: MergeMode) async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repo = try await f.repository()
        try await f.git(["switch", "-c", "topic"]); try f.write("topic", "yes\n")
        try await f.git(["add", "topic"]); try await f.git(["commit", "-m", "Topic"])
        let target = try #require(try await repo.snapshot().head)
        try await f.git(["switch", "main"]); let before = try await repo.snapshot()
        try await repo.merge(target, mode: mode, expected: before)
        let after = try await repo.snapshot()
        switch mode {
        case .fastForward: #expect(after.head == target)
        case .noFastForward:
            let info = try await repo.commitInfo(try #require(after.head)); #expect(info.parents.count == 2)
        case .squash: #expect(after.head == before.head && !after.staged.isEmpty && !after.operationInProgress)
        case .noCommit: #expect(after.head == before.head && !after.staged.isEmpty && after.operation.kind == .merge)
        }
    }
    @Test func mergeIgnoredObstructionRefuses() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repo = try await f.repository()
        try await f.git(["switch", "-c", "topic"]); try f.write("secret", "tracked\n")
        try await f.git(["add", "secret"]); try await f.git(["commit", "-m", "Topic"])
        let oid = try #require(try await repo.snapshot().head); try await f.git(["switch", "main"])
        try f.write(".git/info/exclude", "secret\n"); try f.write("secret", "local\n")
        await #expect(throws: GitError.self) { try await repo.merge(oid, mode: .fastForward, expected: repo.snapshot()) }
        #expect(try String(contentsOf: f.root.appendingPathComponent("secret"), encoding: .utf8) == "local\n")
    }
    @Test func sessionsShareCommonDirectoryGate() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let a = try await f.repository(), b = try await f.repository()
        #expect(a.gate === b.gate)
        let other = f.directory.appendingPathComponent("linked")
        try await f.git(["worktree", "add", "-b", "linked", other.path])
        let c = try await GitRepository.open(other, runner: f.runner)
        #expect(a.gate === c.gate && a.gitDirectory != c.gitDirectory)
    }
    @Test func monitorObservesThenStops() async throws {
        actor Probe { var count = 0; func fire() { count += 1 } }
        let f = try await GitFixture(); defer { f.remove() }; let p = Probe()
        let monitor = try RepositoryMonitor(paths: [f.root]) { Task { await p.fire() } }
        defer { monitor.stop() }
        try f.write("external", "changed")
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await p.count == 0 && clock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        #expect(await p.count > 0)
        monitor.stop(); monitor.stop()
        try await Task.sleep(for: .milliseconds(100)); let before = await p.count
        try f.write("external", "later"); try await Task.sleep(for: .milliseconds(400))
        #expect(await p.count == before)
    }
}
