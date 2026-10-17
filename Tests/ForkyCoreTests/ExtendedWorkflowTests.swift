import Foundation
import Testing
@testable import ForkyCore

struct ExtendedWorkflowTests {
    @Test(arguments: [false, true]) func partialNewAndReverseAdded(includeAll: Bool) async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        try f.write("new[1]\nñ", "one\ntwo\nthree\n")
        let repo = try await f.repository(), s = try await repo.snapshot(), change = try #require(s.changes.first)
        let review = try await repo.reviewPartial(change, side: .worktree, expected: s)
        let first = try #require(review.patch.changeIDs.sorted().first)
        try await repo.applyPartial(review, selected: includeAll ? review.patch.changeIDs : [first])
        let staged = try GitParsers.string(try await f.git(["show", ":new[1]\nñ"]).stdout)
        #expect(staged == (includeAll ? "one\ntwo\nthree\n" : "one\n"))
        let after = try await repo.snapshot(), added = try #require(after.changes.first)
        let reverse = try await repo.reviewPartial(added, side: .staged, expected: after)
        try await repo.applyPartial(reverse, selected: reverse.patch.changeIDs)
        #expect(try await repo.snapshot().staged.isEmpty)
        #expect(try String(contentsOf: f.root.appendingPathComponent("new[1]\nñ"), encoding: .utf8) == "one\ntwo\nthree\n")
    }
    @Test func partialDeletedFileCanLeaveIndexContent() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try f.write("file", "one\ntwo\nthree\n")
        try await f.git(["add", "file"]); try await f.git(["commit", "-m", "File"])
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("file"))
        let repo = try await f.repository(), s = try await repo.snapshot()
        let review = try await repo.reviewPartial(try #require(s.changes.first), side: .worktree, expected: s)
        try await repo.applyPartial(review, selected: [try #require(review.patch.changeIDs.sorted().first)])
        #expect(try GitParsers.string(try await f.git(["show", ":file"]).stdout) == "two\nthree\n")
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("file").path))
    }
    @Test func selectedStashAndRenameThenPop() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        try f.write("new[1]\nñ", "keep"); try f.write("leave", "leave")
        let repo = try await f.repository()
        try await repo.saveSelectedStash(paths: [GitPath("new[1]\nñ")], message: "selected", includeUntracked: true, expected: repo.snapshot())
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("new[1]\nñ").path))
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("leave").path))
        let s = try await repo.snapshot(), original = try #require(s.collaboration.value?.stashes.first)
        try await repo.renameStash(original, message: "renamed", expected: s)
        var state = try await repo.snapshot()
        #expect(state.collaboration.value?.stashes.count == 1)
        #expect(state.collaboration.value?.stashes.first?.subject.contains("renamed") == true)
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("leave"))
        state = try await repo.snapshot()
        try await repo.applyStash(try #require(state.collaboration.value?.stashes.first), restoreIndex: false, expected: state, dropAfterSuccess: true)
        #expect(try await repo.snapshot().collaboration.value?.stashes.isEmpty == true)
        #expect(try String(contentsOf: f.root.appendingPathComponent("new[1]\nñ"), encoding: .utf8) == "keep")
    }
    @Test func worktreeCreateAndSafeRemove() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repo = try await f.repository(), s = try await repo.snapshot(), destination = f.directory.appendingPathComponent("new worktree")
        try await repo.addWorktree(at: destination, oid: try #require(s.head), branch: "worktree", expected: s)
        let entry = try #require(try await repo.worktrees().first { try $0.matchesDirectory(destination) == true })
        #expect(entry.branch == "refs/heads/worktree")
        try Data("local".utf8).write(to: destination.appendingPathComponent("ignored"))
        try await f.git(["config", "core.excludesFile", f.directory.appendingPathComponent("ignore").path])
        try Data("ignored\n".utf8).write(to: f.directory.appendingPathComponent("ignore"))
        await #expect(throws: GitError.self) { try await repo.removeWorktree(entry, expected: repo.snapshot()) }
        try FileManager.default.removeItem(at: destination.appendingPathComponent("ignored"))
        try await repo.removeWorktree(entry, expected: repo.snapshot())
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
    @Test func settingsBackupAndInheritance() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repo = try await f.repository(), s = try await repo.snapshot()
        let backup = try await repo.updateSettings(["user.name": "New User"], expected: s)
        #expect(try String(contentsOf: backup, encoding: .utf8).contains("Forky Test"))
        let attributes = try FileManager.default.attributesOfItem(atPath: backup.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try await repo.settings().first { $0.key == "user.name" }?.effective == "New User")
        await #expect(throws: GitError.self) { try await repo.updateSettings(["core.hooksPath": "/tmp"], expected: repo.snapshot()) }
    }
    @Test func patchReviewFrozenAndExportRefusesOverwrite() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repo = try await f.repository(), before = try await repo.snapshot()
        try f.write("README.md", "changed\n")
        let patch = try await f.git(["diff", "--", "README.md"]).stdout
        try await f.git(["restore", "--", "README.md"])
        let source = f.directory.appendingPathComponent("input.patch"); try patch.write(to: source)
        let review = try await repo.reviewPatch(at: source, expected: before)
        try Data("not this patch".utf8).write(to: source)
        try await repo.applyPatch(review)
        #expect(try String(contentsOf: f.root.appendingPathComponent("README.md"), encoding: .utf8) == "changed\n")
        try await f.git(["commit", "-m", "Changed"])
        let exported = f.directory.appendingPathComponent("output.patch")
        let oid = try #require(try await repo.snapshot().head)
        try await repo.exportPatch(oid: oid, to: exported)
        await #expect(throws: (any Error).self) { try await repo.exportPatch(oid: oid, to: exported) }
    }
    @Test func bisectStepsAndNativeRecovery() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repo = try await f.repository(), good = try #require(try await repo.snapshot().head)
        for i in 1...4 { try f.write("README.md", "version \(i)\n"); try await f.git(["commit", "-am", "Version \(i)"]) }
        let before = try await repo.snapshot()
        _ = try await repo.startBisect(good: good, bad: try #require(before.head), expected: before)
        #expect(try await repo.snapshot().operation.kind == .bisect)
        _ = try await repo.stepBisect(.good, expected: repo.snapshot())
        _ = try await repo.stepBisect(.reset, expected: repo.snapshot())
        let after = try await repo.snapshot()
        #expect(after.head == before.head && after.branch == "main" && !after.operationInProgress)
    }
    @Test func trustedToolPreservesExactArgv() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repo = try await f.repository()
        let result = try await repo.runTrustedTool(executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", "a; $(no-shell)"], input: "explicit", expected: repo.snapshot())
        #expect(result == "a; $(no-shell)")
    }
}
