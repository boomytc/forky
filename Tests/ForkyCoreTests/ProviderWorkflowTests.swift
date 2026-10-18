import Foundation
import Testing
@testable import ForkyCore

private let availableGitLFS: String? = ["/opt/homebrew/bin/git-lfs", "/usr/local/bin/git-lfs", "/usr/bin/git-lfs"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }

struct ProviderWorkflowTests {
    @Test func actualSubmoduleCloneOpenAndUpdate() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        // Authorization is confined to this newly created fixture HOME, never host/global configuration.
        try Data("[protocol \"file\"]\n\tallow = always\n".utf8).write(to: f.directory.appendingPathComponent("home/.gitconfig"))
        let source = f.directory.appendingPathComponent("submodule-source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        func git(_ args: [String]) async throws {
            let result = try await f.runner.run(["-C", source.path] + args)
            guard result.status == 0 else { throw GitError.commandFailed(result.status, String(decoding: result.stderr, as: UTF8.self)) }
        }
        try await git(["init", "-b", "main"]); try await git(["config", "user.name", "Submodule Test"])
        try await git(["config", "user.email", "sub@example.invalid"]); try await git(["config", "core.hooksPath", "/dev/null"])
        try Data("sub".utf8).write(to: source.appendingPathComponent("file"))
        try await git(["add", "file"]); try await git(["-c", "commit.gpgSign=false", "commit", "-m", "Submodule"])
        let repo = try await f.repository()
        try await repo.addSubmodule(url: source.path, path: GitPath("module"), expected: repo.snapshot())
        #expect(try await repo.snapshot().staged.count == 2)
        try await f.git(["commit", "-m", "Add submodule"])
        let opened = try await repo.submoduleDirectory(GitPath("module"), expected: repo.snapshot())
        #expect(try DirectoryIdentity.read(opened) == DirectoryIdentity.read(f.root.appendingPathComponent("module")))
        try await repo.updateSubmodule(GitPath("module"), expected: repo.snapshot())
        let statuses = try await repo.submoduleStatuses()
        #expect(statuses.entries.contains { $0.path.value == "module" && $0.state == .upToDate })
        let subHead = try await f.git(["-C", opened.path, "rev-parse", "HEAD"]).stdout
        try Data("dirty".utf8).write(to: opened.appendingPathComponent("file"))
        await #expect(throws: GitError.self) { try await repo.updateSubmodule(GitPath("module"), expected: repo.snapshot()) }
        #expect(try await f.git(["-C", opened.path, "rev-parse", "HEAD"]).stdout == subHead)
        #expect(try String(contentsOf: opened.appendingPathComponent("file"), encoding: .utf8) == "dirty")
    }

    @Test(.enabled(if: availableGitLFS != nil))
    func actualLocalLFSFilterTrackAndStatus() async throws {
        guard let lfs = availableGitLFS else { return }
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let lfsDirectory = (lfs as NSString).deletingLastPathComponent
        let runner = GitProcessRunner(environment: ["HOME": f.directory.appendingPathComponent("home").path,
            "XDG_CONFIG_HOME": f.directory.appendingPathComponent("home").path, "PATH": lfsDirectory + ":/usr/bin:/bin"])
        func git(_ args: [String]) async throws -> GitProcessResult {
            let result = try await runner.run(["-C", f.root.path] + args)
            guard result.status == 0 else { throw GitError.commandFailed(result.status, String(decoding: result.stderr, as: UTF8.self)) }
            return result
        }
        // Existing bring-your-own binary; --skip-repo avoids installing hooks even in the fixture.
        _ = try await git(["lfs", "install", "--local", "--skip-repo"])
        let repo = try await GitRepository.open(f.root, runner: runner)
        _ = try await repo.lfs(.track(GitPath("asset[1].bin")), expected: repo.snapshot())
        try f.write("asset[1].bin", "actual LFS payload\n")
        _ = try await git(["add", "--", ".gitattributes", "asset[1].bin"])
        _ = try await git(["commit", "-m", "Track local LFS"])
        let pointer = try await git(["show", "HEAD:asset[1].bin"])
        #expect(try GitParsers.string(pointer.stdout).contains("https://git-lfs.github.com/spec/v1"))
        let status = try await repo.lfs(.status, expected: repo.snapshot())
        #expect(status.contains("On branch main"))
    }

    @Test func mixedPushOutcomesRetainAcceptedRefEvidence() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let server = f.directory.appendingPathComponent("server.git")
        try await f.git(["init", "--bare", server.path]); try await f.git(["remote", "add", "origin", server.path])
        try await f.git(["push", "origin", "main"])
        let base = try GitParsers.string(try await f.git(["rev-parse", "HEAD"]).stdout).trimmingCharacters(in: .newlines)
        try f.write("README.md", "local"); try await f.git(["commit", "-am", "Local"]); try await f.git(["tag", "v2"])
        try await f.git(["switch", "-c", "other", base]); try f.write("other", "server")
        try await f.git(["add", "other"]); try await f.git(["commit", "-m", "Server"])
        try await f.git(["push", "origin", "other:main"]); try await f.git(["switch", "main"])
        let repo = try await f.repository(), s = try await repo.snapshot()
        let remote = try #require(s.collaboration.value?.remotes.first)
        let refs = s.references.filter { $0.fullName == "refs/heads/main" || $0.fullName == "refs/tags/v2" }
        do {
            try await repo.pushReferences(refs, remote: remote, expected: s)
            Issue.record("Divergent branch should reject even though the tag is accepted.")
        } catch GitError.commandFailed(_, let message) {
            #expect(message.contains("v2") && message.contains("stdout"))
        }
        let actual = try await f.runner.run(["--git-dir=" + server.path, "show-ref", "refs/tags/v2"])
        #expect(actual.status == 0)
    }

    @Test func absoluteInputIsNotExpandedAgainstAmbientDirectory() throws {
        #expect(throws: GitError.self) { try LocalFilePath.absolute("relative.patch") }
        #expect(throws: GitError.self) { try LocalFilePath.absolute("~/patch") }
        #expect(throws: GitError.self) { try LocalFilePath.absolute("file:///tmp/patch") }
        #expect(try LocalFilePath.absolute("/tmp/a%20b").path == "/tmp/a%20b")
    }
}
