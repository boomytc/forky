import Foundation
import Testing
@testable import ForkyCore

@Suite struct WorkflowTests {
    private func run(_ fixture: GitFixture, _ args: [String]) async throws -> String {
        let result = try await fixture.runner.run(args)
        guard result.status == 0 else { throw GitError.commandFailed(result.status, String(decoding: result.stderr, as: UTF8.self)) }
        return try GitParsers.string(result.stdout).trimmingCharacters(in: .newlines)
    }

    private func server(_ fixture: GitFixture) async throws -> URL {
        let url = fixture.directory.appendingPathComponent("local remote.git")
        _ = try await run(fixture, ["init", "--bare", "--initial-branch=main", url.path])
        return url
    }

    private func published(_ fixture: GitFixture, remote: URL) async throws -> GitRepository {
        try await fixture.initialCommit()
        let repo = try await fixture.repository()
        try await repo.addRemote(name: "origin", url: remote.path, expected: repo.snapshot())
        let snapshot = try await repo.snapshot()
        let origin = try #require(snapshot.collaboration.value?.remotes.first)
        try await repo.push(origin, branch: "main", setUpstream: true, expected: snapshot)
        return repo
    }

    private func peer(_ fixture: GitFixture, remote: URL) async throws -> URL {
        let path = fixture.directory.appendingPathComponent("peer worktree")
        _ = try await GitRepository.create(.clone(remote.path), at: path, runner: fixture.runner)
        _ = try await run(fixture, ["-C", path.path, "config", "user.name", "Peer"])
        _ = try await run(fixture, ["-C", path.path, "config", "user.email", "peer@example.invalid"])
        _ = try await run(fixture, ["-C", path.path, "config", "commit.gpgSign", "false"])
        _ = try await run(fixture, ["-C", path.path, "config", "core.hooksPath", "/dev/null"])
        return path
    }

    private func advancePeer(_ fixture: GitFixture, peer: URL) async throws {
        try Data("Incoming\n".utf8).write(to: peer.appendingPathComponent("incoming.txt"))
        _ = try await run(fixture, ["-C", peer.path, "add", "--", "incoming.txt"])
        _ = try await run(fixture, ["-C", peer.path, "commit", "-m", "Incoming change"])
        _ = try await run(fixture, ["-C", peer.path, "push", "origin", "main"])
    }

    @Test func publishCloneFetchPullAndPushWithRealBareRemote() async throws {
        let f = try await GitFixture(); defer { f.remove() }
        let remote = try await server(f)
        let repo = try await published(f, remote: remote)
        var s = try await repo.snapshot()
        #expect(s.collaboration.value?.tracking?.ahead == 0)
        #expect(s.collaboration.value?.tracking?.behind == 0)
        let p = try await peer(f, remote: remote)
        try await advancePeer(f, peer: p)
        let origin = try #require(s.collaboration.value?.remotes.first)
        try await repo.fetch(origin, expected: s)
        s = try await repo.snapshot()
        #expect(s.collaboration.value?.tracking?.behind == 1)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("incoming.txt").path))
        try await repo.pullFastForward(origin, expected: s)
        s = try await repo.snapshot()
        #expect(s.collaboration.value?.tracking?.behind == 0)
        #expect(try String(contentsOf: f.root.appendingPathComponent("incoming.txt"), encoding: .utf8) == "Incoming\n")
        try f.write("outgoing.txt", "Outgoing\n")
        try await f.git(["add", "--", "outgoing.txt"]); try await f.git(["commit", "-m", "Outgoing change"])
        s = try await repo.snapshot()
        #expect(s.collaboration.value?.tracking?.ahead == 1)
        try await repo.push(origin, branch: "main", setUpstream: false, expected: s)
        #expect(try await run(f, ["--git-dir", remote.path, "rev-parse", "refs/heads/main"]) == s.head)
    }

    @Test func divergenceRefusesPullAndNonFastForwardPushWithoutChangingHead() async throws {
        let f = try await GitFixture(); defer { f.remove() }
        let remote = try await server(f), repo = try await published(f, remote: remote)
        let p = try await peer(f, remote: remote)
        try await advancePeer(f, peer: p)
        try f.write("local.txt", "Local\n")
        try await f.git(["add", "--", "local.txt"]); try await f.git(["commit", "-m", "Local divergence"])
        let s = try await repo.snapshot(), origin = try #require(s.collaboration.value?.remotes.first)
        await #expect(throws: GitError.self) { try await repo.pullFastForward(origin, expected: s) }
        let after = try await repo.snapshot()
        #expect(after.head == s.head && after.changes.isEmpty && !after.operationInProgress)
        #expect(after.collaboration.value?.tracking?.ahead == 1 && after.collaboration.value?.tracking?.behind == 1)
        await #expect(throws: GitError.self) { try await repo.push(origin, branch: "main", setUpstream: false, expected: after) }
        #expect(try await run(f, ["--git-dir", remote.path, "rev-parse", "main"]) != s.head)
    }

    @Test func pushDoesNotFollowTagsOrConfiguredExtraRefspecs() async throws {
        let f = try await GitFixture(); defer { f.remove() }
        let remote = try await server(f), repo = try await published(f, remote: remote)
        try await f.git(["config", "push.followTags", "true"])
        try await f.git(["config", "remote.origin.push", "refs/heads/main:refs/heads/unrequested"])
        try await f.git(["tag", "-a", "not-requested", "-m", "Keep local"])
        let s = try await repo.snapshot(), origin = try #require(s.collaboration.value?.remotes.first)
        try await repo.push(origin, branch: "main", setUpstream: false, expected: s)
        #expect(try await run(f, ["--git-dir", remote.path, "for-each-ref", "--format=%(refname)"]) == "refs/heads/main")
    }

    @Test func staleRemoteConfigurationAndUnsafeFetchMappingsFailClosed() async throws {
        let f = try await GitFixture(); defer { f.remove() }
        let remote = try await server(f), repo = try await published(f, remote: remote)
        let s = try await repo.snapshot(), origin = try #require(s.collaboration.value?.remotes.first)
        try await f.git(["config", "remote.origin.url", f.directory.appendingPathComponent("missing.git").path])
        await #expect(throws: GitError.self) { try await repo.fetch(origin, expected: s) }
        try await f.git(["config", "remote.origin.url", remote.path])
        try await f.git(["config", "--replace-all", "remote.origin.fetch", "+refs/heads/*:refs/heads/*"])
        let current = try await repo.snapshot(), unsafe = try #require(current.collaboration.value?.remotes.first)
        #expect(unsafe.limitation != nil)
        await #expect(throws: GitError.self) { try await repo.fetch(unsafe, expected: current) }
        try await f.git(["config", "remote.origin.mirror", "true"])
        let mirror = try await repo.snapshot()
        await #expect(throws: GitError.self) { try await repo.push(try #require(mirror.collaboration.value?.remotes.first), branch: "main", setUpstream: false, expected: mirror) }
    }

    @Test func dirtyPullAndStalePushAreRejected() async throws {
        let f = try await GitFixture(); defer { f.remove() }
        let remote = try await server(f), repo = try await published(f, remote: remote)
        let s = try await repo.snapshot(), origin = try #require(s.collaboration.value?.remotes.first)
        try f.write("untracked", "Keep")
        await #expect(throws: GitError.self) { try await repo.pullFastForward(origin, expected: s) }
        try await f.git(["commit", "--allow-empty", "-m", "HEAD advanced"])
        await #expect(throws: GitError.self) { try await repo.push(origin, branch: "main", setUpstream: false, expected: s) }
        #expect(try await run(f, ["--git-dir", remote.path, "rev-parse", "main"]) == s.head)
    }

    @Test func stashPreservesIndexAndUntrackedByExplicitChoice() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repo = try await f.repository()
        try f.write("README.md", "Staged\n"); try await f.git(["add", "--", "README.md"])
        try f.write("README.md", "Staged\nUnstaged\n"); try f.write("new.txt", "Untracked\n")
        try await repo.saveStash(message: "Reviewed work", includeUntracked: true, expected: repo.snapshot())
        var s = try await repo.snapshot()
        #expect(s.changes.isEmpty)
        let stash = try #require(s.collaboration.value?.stashes.first)
        #expect(try await repo.stashDiff(stash).contains("Untracked"))
        try await repo.applyStash(stash, restoreIndex: true, expected: s)
        s = try await repo.snapshot()
        #expect(s.staged.count == 1 && s.unstaged.count == 2)
        #expect(s.collaboration.value?.stashes.count == 1)
        #expect(try String(contentsOf: f.root.appendingPathComponent("new.txt"), encoding: .utf8) == "Untracked\n")
        try await repo.dropStash(stash, expected: s)
        #expect(try await repo.snapshot().collaboration.value?.stashes.isEmpty == true)
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("new.txt").path))
    }

    @Test func stashDoesNotImplicitlyIncludeUntrackedAndRejectsDirtyApply() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repo = try await f.repository()
        try f.write("new.txt", "Keep")
        await #expect(throws: GitError.self) { try await repo.saveStash(message: "\0", includeUntracked: true, expected: repo.snapshot()) }
        await #expect(throws: GitError.self) { try await repo.saveStash(message: "", includeUntracked: false, expected: repo.snapshot()) }
        try f.write("README.md", "Changed\n")
        try await repo.saveStash(message: "", includeUntracked: false, expected: repo.snapshot())
        let s = try await repo.snapshot(), stash = try #require(s.collaboration.value?.stashes.first)
        #expect(s.unstaged.count == 1 && s.unstaged.first?.isUntracked == true)
        await #expect(throws: GitError.self) { try await repo.applyStash(stash, restoreIndex: true, expected: s) }
        #expect(try await repo.snapshot().collaboration.value?.stashes.count == 1)
    }

    @Test func staleStashDropRefusesRenumberedSelectors() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repo = try await f.repository()
        try f.write("README.md", "First"); try await repo.saveStash(message: "First", includeUntracked: false, expected: repo.snapshot())
        let s = try await repo.snapshot(), stash = try #require(s.collaboration.value?.stashes.first)
        try f.write("README.md", "Second"); try await repo.saveStash(message: "Second", includeUntracked: false, expected: repo.snapshot())
        await #expect(throws: GitError.self) { try await repo.dropStash(stash, expected: s) }
        #expect(try await repo.snapshot().collaboration.value?.stashes.count == 2)
    }

    @Test func conflictedStashApplyRetainsRecoveryEntry() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repo = try await f.repository()
        try f.write("README.md", "Stashed replacement\n")
        try await repo.saveStash(message: "Conflict recovery", includeUntracked: false, expected: repo.snapshot())
        try f.write("README.md", "Committed replacement\n")
        try await f.git(["add", "--", "README.md"]); try await f.git(["commit", "-m", "Different base"])
        let s = try await repo.snapshot(), stash = try #require(s.collaboration.value?.stashes.first)
        await #expect(throws: GitError.self) { try await repo.applyStash(stash, restoreIndex: false, expected: s) }
        let result = try await repo.snapshot()
        #expect(result.hasConflicts && result.collaboration.value?.stashes.count == 1)
    }

    @Test func exclusiveCreationNeverAdoptsExistingDirectoryOrCredentialURL() async throws {
        let f = try await GitFixture(); defer { f.remove() }
        let existing = f.directory.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        await #expect(throws: GitError.self) { try await GitRepository.create(.initialize("main"), at: existing, runner: f.runner) }
        #expect(!FileManager.default.fileExists(atPath: existing.appendingPathComponent(".git").path))
        let target = f.directory.appendingPathComponent("created")
        let repo = try await GitRepository.create(.initialize("main"), at: target, runner: f.runner)
        #expect(try await repo.snapshot().head == nil)
        let invalid = f.directory.appendingPathComponent("credentials")
        await #expect(throws: GitError.self) { try await GitRepository.create(.clone("https://user:secret@example.invalid/repo"), at: invalid, runner: f.runner) }
        #expect(!FileManager.default.fileExists(atPath: invalid.path))
        let failed = f.directory.appendingPathComponent("failed clone")
        await #expect(throws: GitError.self) { try await GitRepository.create(.clone(f.directory.appendingPathComponent("missing.git").path), at: failed, runner: f.runner) }
        #expect(FileManager.default.fileExists(atPath: failed.path))
    }

    @Test func auxiliaryFailureDoesNotPretendEmptyOrBlockLocalStaging() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        try await f.git(["config", "remote.origin.mirror", "invalid-bool"])
        try f.write("README.md", "Changed")
        let repo = try await f.repository(), s = try await repo.snapshot()
        #expect(s.head != nil && s.changes.count == 1)
        #expect(s.collaboration.value == nil && s.collaboration.error != nil)
        try await repo.stage(try #require(s.changes.first))
        #expect(try await repo.snapshot().staged.count == 1)
    }

    @Test func checkoutRemoteCreatesAndTracksReviewedBranch() async throws {
        let f = try await GitFixture(); defer { f.remove() }
        let remote = try await server(f), repo = try await published(f, remote: remote)
        let p = try await peer(f, remote: remote)
        _ = try await run(f, ["-C", p.path, "switch", "-c", "feature/server"])
        _ = try await run(f, ["-C", p.path, "commit", "--allow-empty", "-m", "Server feature"])
        _ = try await run(f, ["-C", p.path, "push", "origin", "feature/server"])
        var s = try await repo.snapshot()
        try await repo.fetch(try #require(s.collaboration.value?.remotes.first), expected: s)
        s = try await repo.snapshot()
        let target = try #require(s.references.first { $0.name == "origin/feature/server" })
        try await repo.checkoutRemote(target, as: "feature/local", expected: s)
        let result = try await repo.snapshot()
        #expect(result.branch == "feature/local" && result.head == target.objectOID && result.changes.isEmpty)
        #expect(result.collaboration.value?.tracking?.upstream == target.fullName)
        #expect(result.collaboration.value?.tracking?.mergeRef == "refs/heads/feature/server")
    }

    @Test func remoteCheckoutRejectsDirtyStaleAliasAndExistingBranches() async throws {
        let f = try await GitFixture(); defer { f.remove() }
        let remote = try await server(f), repo = try await published(f, remote: remote)
        let p = try await peer(f, remote: remote)
        _ = try await run(f, ["-C", p.path, "switch", "-c", "feature/server"])
        _ = try await run(f, ["-C", p.path, "commit", "--allow-empty", "-m", "Different tip"])
        _ = try await run(f, ["-C", p.path, "push", "origin", "feature/server"])
        var s = try await repo.snapshot()
        try await repo.fetch(try #require(s.collaboration.value?.remotes.first), expected: s)
        try await f.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
        s = try await repo.snapshot()
        let alias = try #require(s.references.first { $0.name == "origin/HEAD" })
        #expect(alias.symbolicTarget == "refs/remotes/origin/main")
        await #expect(throws: GitError.self) { try await repo.checkoutRemote(alias, as: "alias", expected: s) }
        let target = try #require(s.references.first { $0.name == "origin/feature/server" })
        try f.write("keep.txt", "Keep")
        await #expect(throws: GitError.self) { try await repo.checkoutRemote(target, as: "dirty", expected: s) }
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("keep.txt"))
        try await f.git(["branch", "keep", "HEAD"])
        await #expect(throws: GitError.self) { try await repo.checkoutRemote(target, as: "keep", expected: repo.snapshot()) }
        #expect(try await run(f, ["-C", f.root.path, "rev-parse", "keep"]) == s.head)
        try await f.git(["update-ref", target.fullName, "HEAD"])
        await #expect(throws: GitError.self) { try await repo.checkoutRemote(target, as: "stale", expected: s) }
        #expect(try await repo.snapshot().branch == "main")
    }

    @Test func createBranchAtHistoricalCommitDoesNotSwitchOrUseHeadInstead() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repo = try await f.repository(), original = try #require(try await repo.snapshot().head)
        try await f.git(["commit", "--allow-empty", "-m", "Newer HEAD"])
        let s = try await repo.snapshot(), head = try #require(s.head)
        try await repo.createBranch(name: "historical", expectedHead: head, startingAt: original)
        let result = try await repo.snapshot()
        #expect(result.head == head && result.branch == "main")
        #expect(result.references.first { $0.name == "historical" }?.objectOID == original)
    }

    @Test func transportRedactsOnlyKnownHTTPAuthentication() throws {
        let source = "https://alice:p%40ss@example.invalid/path?ordinary=visible"
        let shown = TransportPresentation.display(source)
        #expect(shown == "https://example.invalid/path?ordinary=visible")
        #expect(TransportPresentation.display("git@example.invalid:path") == "git@example.invalid:path")
        #expect(throws: GitError.self) { try TransportPresentation.validateNewSource("../ambiguous") }
        #expect(throws: GitError.self) { try TransportPresentation.validateNewSource("~/not-expanded") }
        try TransportPresentation.validateNewSource("git@example.invalid:path")
        let redacted = TransportPresentation.sanitize(source + " password p@ss ordinary=visible", using: TransportPresentation.redactions([source]))
        #expect(!redacted.contains("p@ss") && !redacted.contains("p%40ss") && redacted.contains("ordinary=visible"))
        #expect(throws: GitError.self) { try GitParsers.stashes(Data("invalid".utf8)) }
        let config = try GitConfiguration(Data("remote.team.url\nfile:///space repo\0remote.team.fetch\n+refs/heads/*:refs/remotes/team/*\0remote.team.mirror\nfalse\0".utf8))
        #expect(try config.remotes().first?.limitation == nil)
    }
}
