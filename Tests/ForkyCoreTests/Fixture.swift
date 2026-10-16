import Foundation
import ForkyCore

struct GitFixture: Sendable {
    let directory: URL
    let root: URL
    let runner: GitProcessRunner

    init() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Forky-tests-\(UUID())", isDirectory: true)
        root = directory.appendingPathComponent("space repo", isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        runner = GitProcessRunner(environment: ["HOME": home.path, "XDG_CONFIG_HOME": home.path, "PATH": "/usr/bin:/bin"])
        do {
            _ = try await git(["init", "-b", "main"])
            _ = try await git(["config", "user.name", "Forky Test"])
            _ = try await git(["config", "user.email", "forky@example.invalid"])
            _ = try await git(["config", "commit.gpgSign", "false"])
            _ = try await git(["config", "core.hooksPath", "/dev/null"])
        } catch { remove(); throw error }
    }

    @discardableResult
    func git(_ args: [String]) async throws -> GitProcessResult {
        let result = try await runner.run(["--literal-pathspecs", "-C", root.path] + args)
        guard result.status == 0 else { throw GitError.commandFailed(result.status, String(decoding: result.stderr, as: UTF8.self)) }
        return result
    }

    func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(name))
    }

    func initialCommit() async throws {
        try write("README.md", "# Hello\n")
        try await git(["add", "--", "README.md"])
        try await git(["commit", "-m", "Initial commit", "-m", "A multiline body\nwith another line."])
    }

    func repository() async throws -> GitRepository { try await GitRepository.open(root, runner: runner) }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
