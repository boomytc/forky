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

    public func history(ref: String? = nil, query: String = "", cursor: HistoryCursor? = nil) async throws -> HistoryPage {
        try await gate.withPermit {
            let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.utf8.contains(0), query.utf8.count <= 4096 else {
                throw GitError.malformedOutput("History query is too large or contains NUL.")
            }
            let roots: [String], references: [GitReference], offset: Int
            if let cursor {
                guard cursor.ref == ref, cursor.query == query else {
                    throw GitError.malformedOutput("History cursor belongs to another query.")
                }
                roots = cursor.revisions; references = cursor.references; offset = cursor.offset
            } else {
                references = try await readReferences()
                offset = 0
                if let ref {
                    guard let selected = references.first(where: { $0.fullName == ref }) else { throw GitError.staleRepository }
                    // Resolve the observed object, never reread a mutable name after capturing its facts.
                    let resolved = try await command(["rev-parse", "--verify", selected.objectOID + "^{commit}"])
                    let oid = try GitParsers.string(resolved.stdout).trimmingCharacters(in: .newlines)
                    guard GitParsers.isOID(oid) else { throw GitError.malformedOutput("Invalid history root.") }
                    roots = [oid]
                } else {
                    let head = try await headOID()
                    roots = Array(Set(references.map(\.objectOID) + (head.map { [$0] } ?? []))).sorted()
                }
            }
            guard !roots.isEmpty else { return HistoryPage(commits: [], nextCursor: nil, references: references) }
            var args = ["log", "--topo-order", "--max-count=\(Self.historyPageSize + 1)",
                        "--skip=\(offset)", "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00%b", "-z"]
            if !query.isEmpty { args += ["--fixed-strings", "--regexp-ignore-case", "--grep=" + query] }
            let output = try await command(args + roots + ["--"])
            let commits = try GitParsers.commits(output.stdout)
            let page = Array(commits.prefix(Self.historyPageSize))
            let next = commits.count > Self.historyPageSize
                ? HistoryCursor(revisions: roots, offset: offset + page.count, query: query, ref: ref, references: references) : nil
            return HistoryPage(commits: page, nextCursor: next, references: references)
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

    public func stage(_ change: FileChange) async throws { try await stage([change]) }

    public func stage(_ changes: [FileChange]) async throws {
        guard !changes.isEmpty else { return }
        try await gate.withPermit {
            let paths = Array(Set(changes.flatMap(\.stagePaths))).sorted()
            _ = try await command(["add", "--"] + paths, write: true)
        }
    }

    public func unstage(_ change: FileChange) async throws { try await unstage([change]) }

    public func unstage(_ changes: [FileChange]) async throws {
        guard !changes.isEmpty else { return }
        try await gate.withPermit {
            let paths = Array(Set(changes.flatMap(\.unstagePaths))).sorted()
            if try await headOID() == nil {
                _ = try await command(["rm", "--cached", "--ignore-unmatch", "--"] + paths, write: true)
            } else {
                _ = try await command(["restore", "--staged", "--"] + paths, write: true)
            }
        }
    }

    public func createBranch(name: String, expectedHead: String) async throws {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.utf8.contains(0) else { throw GitError.invalidBranchName }
        try await gate.withPermit {
            let fresh = try await readSnapshot()
            guard !fresh.operationInProgress else { throw GitError.operationInProgress }
            guard fresh.head == expectedHead, GitParsers.isOID(expectedHead) else { throw GitError.staleRepository }
            // Validate the literal ref, not --branch's @{-1} shorthand expansion.
            _ = try await command(["check-ref-format", "refs/heads/" + name])
            _ = try await command(["branch", "--", name, expectedHead], write: true)
        }
    }

    public func checkout(_ branch: GitReference, expectedHead: String) async throws {
        try await gate.withPermit {
            let fresh = try await readSnapshot()
            guard !fresh.operationInProgress else { throw GitError.operationInProgress }
            guard fresh.head == expectedHead, branch.kind == .localBranch,
                  let destination = fresh.branches.first(where: { $0.id == branch.id }),
                  destination.objectOID == branch.objectOID else { throw GitError.staleRepository }
            guard fresh.changes.isEmpty else { throw GitError.dirtyWorktree }
            // Never discard, overwrite ignored files, recurse into submodules or override worktree ownership.
            _ = try await command(["switch", "--no-guess", "--no-overwrite-ignore",
                                   "--no-recurse-submodules", "--", destination.name], write: true)
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

    private func readReferences() async throws -> [GitReference] {
        let output = try await command(["for-each-ref",
            "--format=%(refname)%00%(objectname)%00%(HEAD)%00%(*objectname)%00%(objecttype)%00%(*objecttype)%00",
            "refs/heads/", "refs/remotes/", "refs/tags/"])
        return try GitParsers.references(output.stdout)
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
        let references = try await readReferences()
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
                                  references: references, indexFingerprint: fingerprint,
                                  operationInProgress: inProgress)
    }
}
