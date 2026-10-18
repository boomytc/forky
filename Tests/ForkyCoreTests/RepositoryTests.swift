import Foundation
import Testing
@testable import ForkyCore

@Suite(.serialized) struct RepositoryTests {
    @Test func commitOnlyIncludesExplicitIndexAndLoadsRealHistory() async throws {
        let fixture = try await GitFixture(); defer { fixture.remove() }
        try await fixture.initialCommit()
        try fixture.write("README.md", "# Hello\nAn actual change\n")
        try fixture.write("private-not-staged.txt", "Keep outside the commit\n")
        let repo = try await fixture.repository()
        let first = try await repo.snapshot()
        let change = try #require(first.unstaged.first { $0.path.value == "README.md" })
        let diff = try await repo.diff(change, side: .worktree)
        #expect(diff.contains("+An actual change"))
        try await repo.stage(change)
        let staged = try await repo.snapshot()
        try await repo.commit(message: "Add a useful line", expectedFingerprint: staged.indexFingerprint)
        let after = try await repo.snapshot()
        #expect(after.staged.isEmpty)
        #expect(after.unstaged.map(\.path.value) == ["private-not-staged.txt"])
        let commits = try await repo.history().commits
        #expect(commits.count == 2)
        #expect(commits[0].subject == "Add a useful line")
        #expect(commits[1].body.contains("with another line."))
        let files = try await repo.files(in: commits[0])
        #expect(files.map(\.path.value) == ["README.md"])
        #expect(try await repo.diff(try #require(files.first), in: commits[0]).contains("+An actual change"))
    }

    @Test func staleIndexIsRejectedAndChangesStayStaged() async throws {
        let fixture = try await GitFixture(); defer { fixture.remove() }
        try await fixture.initialCommit()
        try fixture.write("first.txt", "one")
        let repo = try await fixture.repository()
        try await repo.stage(try #require(try await repo.snapshot().unstaged.first))
        let reviewed = try await repo.snapshot()
        try fixture.write("second.txt", "two")
        try await fixture.git(["add", "--", "second.txt"])
        await #expect(throws: GitError.self) {
            try await repo.commit(message: "Must not commit an unseen file", expectedFingerprint: reviewed.indexFingerprint)
        }
        #expect(try await repo.snapshot().staged.count == 2)
        #expect(try await repo.history().commits.count == 1)
    }

    @Test func literalPathsCannotExpandPathspecsOrBecomeOptions() async throws {
        let fixture = try await GitFixture(); defer { fixture.remove() }
        let names = [":(glob)*.txt", "--option.txt", "line\nname ü.txt", "other.txt"]
        for name in names { try fixture.write(name, name) }
        let repo = try await fixture.repository()
        let before = try await repo.snapshot()
        let exact = try #require(before.unstaged.first { $0.path.value == names[0] })
        #expect(try await repo.diff(exact, side: .worktree).contains(names[0]))
        try await repo.stage(exact)
        #expect(try await repo.snapshot().staged.map(\.path.value) == [names[0]])
        for name in names.dropFirst().dropLast() {
            let change = try #require(try await repo.snapshot().unstaged.first { $0.path.value == name })
            try await repo.stage(change)
        }
        let staged = try await repo.snapshot()
        try await repo.commit(message: "Literal paths", expectedFingerprint: staged.indexFingerprint)
        #expect(try await repo.snapshot().unstaged.map(\.path.value) == ["other.txt"])
    }

    @Test func stagedRenameUnstagesBothSides() async throws {
        let fixture = try await GitFixture(); defer { fixture.remove() }
        try await fixture.initialCommit()
        try await fixture.git(["mv", "--", "README.md", "new name.md"])
        let repo = try await fixture.repository()
        let change = try #require(try await repo.snapshot().staged.first)
        #expect(change.originalPath?.value == "README.md")
        try await repo.unstage(change)
        let after = try await repo.snapshot()
        #expect(after.staged.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("new name.md").path))
    }

    @Test func linkedWorktreeAndSubdirectoryResolveCorrectly() async throws {
        let fixture = try await GitFixture(); defer { fixture.remove() }
        try await fixture.initialCommit()
        let linked = fixture.directory.appendingPathComponent("linked tree")
        try await fixture.git(["worktree", "add", "-b", "feature", linked.path])
        let nested = linked.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let repo = try await GitRepository.open(nested, runner: fixture.runner)
        #expect(repo.root.standardizedFileURL == linked.standardizedFileURL)
        #expect(try await repo.snapshot().branch == "feature")
    }

    @Test func failedCommitHookIsNotReportedAsSuccess() async throws {
        let fixture = try await GitFixture(); defer { fixture.remove() }
        try await fixture.initialCommit()
        let hooks = fixture.directory.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let hook = hooks.appendingPathComponent("pre-commit")
        try Data("#!/bin/sh\nprintf 'Rejected by test hook' >&2\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try await fixture.git(["config", "core.hooksPath", hooks.path])
        try fixture.write("README.md", "a change")
        let repo = try await fixture.repository()
        try await repo.stage(try #require(try await repo.snapshot().unstaged.first))
        let before = try await repo.snapshot()
        await #expect(throws: GitError.self) {
            try await repo.commit(message: "Hook rejects this", expectedFingerprint: before.indexFingerprint)
        }
        #expect(try await repo.history().commits.count == 1)
        #expect(try await repo.snapshot().staged.count == 1)
    }

    @Test func activeOperationAndEmptyMessageAreRejected() async throws {
        let fixture = try await GitFixture(); defer { fixture.remove() }
        try await fixture.initialCommit()
        try fixture.write("README.md", "modified")
        let repo = try await fixture.repository()
        try await repo.stage(try #require(try await repo.snapshot().unstaged.first))
        let before = try await repo.snapshot()
        await #expect(throws: GitError.self) { try await repo.commit(message: " \n", expectedFingerprint: before.indexFingerprint) }
        let marker = fixture.root.appendingPathComponent(".git/MERGE_HEAD")
        try Data((before.head! + "\n").utf8).write(to: marker)
        #expect(try await repo.snapshot().operationInProgress)
        await #expect(throws: GitError.self) { try await repo.commit(message: "Not a merge UI", expectedFingerprint: before.indexFingerprint) }
    }

    @Test func configuredExternalDiffIsNotExecuted() async throws {
        let fixture = try await GitFixture(); defer { fixture.remove() }
        try await fixture.initialCommit()
        // If Git invokes this deliberately invalid external driver, the preview fails.
        try await fixture.git(["config", "diff.external", "/this/driver/must/not/run"])
        try fixture.write("README.md", "# Hello\nMore\n")
        let repo = try await fixture.repository()
        let change = try #require(try await repo.snapshot().unstaged.first)
        #expect(try await repo.diff(change, side: .worktree).contains("+More"))
    }

    @Test func ambientGitDirectoryCannotRedirectTheTarget() async throws {
        let fixture = try await GitFixture(); defer { fixture.remove() }
        var environment = ["HOME": fixture.directory.appendingPathComponent("home").path,
                           "PATH": "/usr/bin:/bin", "GIT_DIR": "/does/not/exist",
                           "GIT_WORK_TREE": "/does/not/exist", "GIT_INDEX_FILE": "/does/not/exist"]
        environment["GIT_CONFIG_COUNT"] = "1"
        environment["GIT_CONFIG_KEY_0"] = "alias.status"
        environment["GIT_CONFIG_VALUE_0"] = "!false"
        let runner = GitProcessRunner(environment: environment)
        let repo = try await GitRepository.open(fixture.root, runner: runner)
        #expect(try await repo.snapshot().branch == "main")
    }

    @Test func invalidDirectoryFailsWithoutInitializingIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Forky-invalid-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: GitError.self) { try await GitRepository.open(directory) }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path))
    }
}
