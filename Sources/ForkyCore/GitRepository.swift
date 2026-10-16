import Foundation
import CryptoKit

public struct GitRepository: Sendable {
    public let root: URL
    private let runner: GitProcessRunner
    private let gate = AsyncGate()
    public static let historyPageSize = 200

    private init(root: URL, runner: GitProcessRunner) {
        self.root = root
        self.runner = runner
    }

    public static func open(_ directory: URL, runner: GitProcessRunner = .init()) async throws -> GitRepository {
        let output = try await runner.run(["--no-pager", "-C", directory.path, "rev-parse", "--show-toplevel"])
        guard output.status == 0 else {
            throw GitError.invalidRepository(String(decoding: output.stderr, as: UTF8.self))
        }
        var path = try GitParsers.string(output.stdout)
        if path.hasSuffix("\n") { path.removeLast() }
        guard path.hasPrefix("/") else { throw GitError.invalidRepository("Git did not return an absolute worktree path.") }
        let repository = GitRepository(root: URL(fileURLWithPath: path, isDirectory: true), runner: runner)
        let bare = try await repository.command(["rev-parse", "--is-bare-repository"])
        guard bare.stdout == Data("false\n".utf8) else { throw GitError.invalidRepository("Bare repositories are not supported.") }
        return repository
    }

    public func snapshot() async throws -> RepositorySnapshot {
        try await gate.withPermit { try await readSnapshot() }
    }

    public func history(ref: String? = nil, offset: Int = 0) async throws -> HistoryPage {
        try await gate.withPermit {
            guard offset >= 0 else { throw GitError.malformedOutput("Negative history offset.") }
            // --all also permits a newly initialized repository with no HEAD.
            var args = ["log", "--date-order", "--max-count=\(Self.historyPageSize + 1)",
                        "--skip=\(offset)", "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00%b", "-z"]
            if let ref {
                guard ref.hasPrefix("refs/heads/") || ref.hasPrefix("refs/remotes/") else {
                    throw GitError.malformedOutput("History requires a full branch ref.")
                }
                args += [ref]
            } else { args += ["--all"] }
            args += ["--"]
            let result = try await command(args)
            let commits = try GitParsers.commits(result.stdout)
            return HistoryPage(commits: Array(commits.prefix(Self.historyPageSize)),
                               hasMore: commits.count > Self.historyPageSize)
        }
    }

    public func diff(_ change: FileChange, side: DiffSide) async throws -> String {
        try await gate.withPermit {
            let common = ["diff", "--no-ext-diff", "--no-textconv", "--no-color"]
            let result: GitProcessResult
            if change.isUntracked {
                guard side == .worktree else { return "" }
                result = try await command(common + ["--no-index", "--", "/dev/null", change.path.value], accepted: [0, 1])
            } else {
                let paths = side == .staged ? change.unstagePaths : change.stagePaths
                result = try await command(common + (side == .staged ? ["--cached"] : []) + ["--"] + paths)
            }
            return try GitParsers.string(result.stdout)
        }
    }

    public func files(in commit: GitCommit) async throws -> [CommitFile] {
        try await gate.withPermit {
            try validate(commit)
            let revisions = commit.parents.first.map { [$0, commit.oid] } ?? [commit.oid]
            let result = try await command(["diff-tree", "--root", "--no-commit-id", "--name-status",
                                            "-r", "-z", "-M"] + revisions + ["--"])
            return try GitParsers.commitFiles(result.stdout)
        }
    }

    public func diff(_ file: CommitFile, in commit: GitCommit) async throws -> String {
        try await gate.withPermit {
            try validate(commit)
            let safety = ["--no-ext-diff", "--no-textconv", "--no-color"]
            let args: [String]
            if let parent = commit.parents.first {
                args = ["diff"] + safety + [parent, commit.oid, "--"] + file.pathspecs
            } else {
                args = ["show", "--format=", "--root"] + safety + [commit.oid, "--"] + file.pathspecs
            }
            return try GitParsers.string(try await command(args).stdout)
        }
    }

    public func stage(_ change: FileChange) async throws {
        try await gate.withPermit {
            _ = try await command(["add", "--"] + change.stagePaths)
        }
    }

    public func unstage(_ change: FileChange) async throws {
        try await gate.withPermit {
            let head = try await headOID()
            if head == nil {
                // Remove from the index only. Never delete the worktree file.
                _ = try await command(["rm", "--cached", "--ignore-unmatch", "--"] + change.unstagePaths)
            } else {
                _ = try await command(["restore", "--staged", "--"] + change.unstagePaths)
            }
        }
    }

    public func commit(message: String, expectedFingerprint: String) async throws {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              message.utf8.count <= 64 * 1024, !message.utf8.contains(0) else { throw GitError.invalidMessage }
        try await gate.withPermit {
            let fresh = try await readSnapshot()
            guard !fresh.operationInProgress else { throw GitError.operationInProgress }
            guard !fresh.hasConflicts else { throw GitError.conflicts }
            guard !fresh.staged.isEmpty else { throw GitError.nothingStaged }
            guard fresh.indexFingerprint == expectedFingerprint else { throw GitError.staleIndex }
            // No implicit add, --all, amend, hook bypass, or signing override.
            _ = try await command(["commit", "-m", message], write: true)
        }
    }

    private func validate(_ commit: GitCommit) throws {
        guard GitParsers.isOID(commit.oid), commit.parents.allSatisfy(GitParsers.isOID) else {
            throw GitError.malformedOutput("Invalid selected commit identity.")
        }
    }

    private func command(_ arguments: [String], accepted: Set<Int32> = [0], write: Bool = false) async throws -> GitProcessResult {
        var args = ["--no-pager", "--literal-pathspecs", "-c", "color.ui=false", "-c", "core.quotepath=false",
                    "-c", "core.fsmonitor=false", "-C", root.path]
        if !write { args.insert("--no-optional-locks", at: 0) }
        let output = try await runner.run(args + arguments)
        guard accepted.contains(output.status) else {
            throw GitError.commandFailed(output.status, String(decoding: output.stderr, as: UTF8.self))
        }
        return output
    }

    private func headOID() async throws -> String? {
        let output = try await command(["rev-parse", "--verify", "--quiet", "HEAD"], accepted: [0, 1])
        guard output.status == 0 else { return nil }
        let oid = try GitParsers.string(output.stdout).trimmingCharacters(in: .newlines)
        guard GitParsers.isOID(oid) else { throw GitError.malformedOutput("Invalid HEAD.") }
        return oid
    }

    private func readSnapshot() async throws -> RepositorySnapshot {
        let status = try await command(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        let changes = try GitParsers.status(status.stdout)
        let head = try await headOID()
        let symbolic = try await command(["symbolic-ref", "--quiet", "--short", "HEAD"], accepted: [0, 1])
        let branch = symbolic.status == 0 ? try GitParsers.string(symbolic.stdout).trimmingCharacters(in: .newlines) : nil
        let refs = try await command(["for-each-ref", "--format=%(refname)%00%(objectname)%00%(HEAD)%00",
                                      "refs/heads/", "refs/remotes/"])
        let rawIndex = try await command(["diff", "--cached", "--no-ext-diff", "--no-textconv",
                                          "--raw", "--full-index", "--no-abbrev", "--no-renames", "-z"])
        var fingerprintBytes = Data((head ?? "unborn").utf8)
        fingerprintBytes.append(0)
        fingerprintBytes.append(rawIndex.stdout)
        let fingerprint = SHA256.hash(data: fingerprintBytes).map { String(format: "%02x", $0) }.joined()
        let gitDirResult = try await command(["rev-parse", "--absolute-git-dir"])
        var gitPath = try GitParsers.string(gitDirResult.stdout)
        if gitPath.hasSuffix("\n") { gitPath.removeLast() }
        let gitDirectory = URL(fileURLWithPath: gitPath, isDirectory: true)
        let inProgress = ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer"]
            .contains { FileManager.default.fileExists(atPath: gitDirectory.appendingPathComponent($0).path) }
        return RepositorySnapshot(root: root, head: head, branch: branch, changes: changes,
                                  branches: try GitParsers.branches(refs.stdout), indexFingerprint: fingerprint,
                                  operationInProgress: inProgress)
    }
}
