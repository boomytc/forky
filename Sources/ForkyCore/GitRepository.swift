import Foundation
import CryptoKit

public struct GitRepository: Sendable {
    public let root: URL
    let runner: GitProcessRunner
    let gate: AsyncGate
    public let gitDirectory: URL
    public let commonDirectory: URL
    public static let historyPageSize = 200
    /// Page size for reflog and file-history listings; each page probes one extra record
    /// so "has more" never guesses.
    public static let queryPageSize = 200

    private init(root: URL, runner: GitProcessRunner, gate: AsyncGate, gitDirectory: URL, commonDirectory: URL) {
        self.root = root; self.runner = runner; self.gate = gate
        self.gitDirectory = gitDirectory; self.commonDirectory = commonDirectory
    }

    public static func open(_ directory: URL, runner: GitProcessRunner = .init()) async throws -> GitRepository {
        guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.path.utf8.contains(0) else { throw GitError.unsupportedPath }
        let output = try await runner.run(["--no-pager", "-C", directory.path, "rev-parse", "--show-toplevel"])
        guard output.status == 0 else {
            throw GitError.invalidRepository(String(decoding: output.stderr, as: UTF8.self))
        }
        var path = try GitParsers.string(output.stdout)
        if path.hasSuffix("\n") { path.removeLast() }
        guard path.hasPrefix("/") else { throw GitError.invalidRepository("Git did not return an absolute worktree path.") }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        func resolvedDirectory(_ flag: String) async throws -> URL {
            let result = try await runner.run(["--no-pager", "-C", root.path, "rev-parse", "--path-format=absolute", flag])
            guard result.status == 0 else { throw GitError.invalidRepository(String(decoding: result.stderr, as: UTF8.self)) }
            var value = try GitParsers.string(result.stdout)
            if value.hasSuffix("\n") { value.removeLast() }
            guard value.hasPrefix("/") else { throw GitError.unsupportedPath }
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        let gitDirectory = try await resolvedDirectory("--git-dir"), commonDirectory = try await resolvedDirectory("--git-common-dir")
        let gate = await RepositoryGates.shared.gate(for: commonDirectory.resolvingSymlinksInPath().path)
        let repository = GitRepository(root: root, runner: runner, gate: gate, gitDirectory: gitDirectory, commonDirectory: commonDirectory)
        let bare = try await repository.command(["rev-parse", "--is-bare-repository"])
        guard bare.stdout == Data("false\n".utf8) else { throw GitError.invalidRepository("Bare repositories are not supported.") }
        return repository
    }

    public func snapshot() async throws -> RepositorySnapshot {
        try await gate.withPermit { try await readSnapshot() }
    }

    public func history(ref: String? = nil, query: String = "", cursor: HistoryCursor? = nil, options: HistoryOptions = .init()) async throws -> HistoryPage {
        try await gate.withPermit {
            let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.utf8.contains(0), query.utf8.count <= 4096 else {
                throw GitError.malformedOutput("History query is too large or contains NUL.")
            }
            guard options.after?.timeIntervalSince1970.isFinite ?? true, options.before?.timeIntervalSince1970.isFinite ?? true else { throw GitError.invalidInput("History dates must be finite.") }
            if let after = options.after, let before = options.before, after > before { throw GitError.invalidInput("History date range is reversed.") }
            let roots: [String], references: [GitReference], offset: Int
            if let cursor {
                guard cursor.ref == ref, cursor.query == query, cursor.options == options else {
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
                    roots = Array(Set(references.compactMap(\.commitOID) + (head.map { [$0] } ?? []))).sorted()
                }
            }
            guard !roots.isEmpty else { return HistoryPage(commits: [], nextCursor: nil, references: references) }
            var args = ["log", "--topo-order", "--max-count=\(Self.historyPageSize + 1)",
                        "--skip=\(offset)", "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00%b", "-z"]
            if options.firstParent { args += ["--first-parent"] }
            if let after = options.after { args += ["--since=" + after.ISO8601Format()] }
            if let before = options.before { args += ["--until=" + before.ISO8601Format()] }
            var selectedRoots = roots, paths: [String] = []
            if !query.isEmpty {
                switch options.search {
                case .message: args += ["--fixed-strings", "--regexp-ignore-case", "--grep=" + query]
                case .author: args += ["--fixed-strings", "--regexp-ignore-case", "--author=" + query]
                case .committer: args += ["--fixed-strings", "--regexp-ignore-case", "--committer=" + query]
                case .path: paths = [try GitPath(query).value]
                case .content: args += ["--no-ext-diff", "--no-textconv", "-S" + query]
                case .oid:
                    guard (4...64).contains(query.utf8.count), query.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }) else { throw GitError.invalidInput("SHA lookup requires 4–64 hexadecimal digits; it is not branch-filtered.") }
                    var oid = try GitParsers.string(try await command(["rev-parse", "--verify", query + "^{commit}"]).stdout)
                    if oid.hasSuffix("\n") { oid.removeLast() }
                    guard GitParsers.isOID(oid) else { throw GitError.staleRepository }
                    selectedRoots = [oid]; args += ["--no-walk"]
                }
            }
            let output = try await command(args + selectedRoots + ["--"] + paths, literalPaths: !paths.isEmpty)
            let commits = try GitParsers.commits(output.stdout)
            let page = Array(commits.prefix(Self.historyPageSize))
            let next = commits.count > Self.historyPageSize
                ? HistoryCursor(revisions: roots, offset: offset + page.count, query: query, ref: ref, references: references, options: options) : nil
            return HistoryPage(commits: page, nextCursor: next, references: references)
        }
    }

    public func diff(_ change: FileChange, side: DiffSide, options: DiffOptions = .init()) async throws -> String {
        try await gate.withPermit {
            let common = ["diff", "--no-ext-diff", "--no-textconv", "--no-color"] + options.arguments
            let result: GitProcessResult
            if change.isUntracked {
                guard side == .worktree else { return "" }
                result = try await command(common + ["--no-index", "--", "/dev/null", change.path.value], accepted: [0, 1], literalPaths: true)
            } else {
                let paths = side == .staged ? change.unstagePaths : change.stagePaths
                result = try await command(common + (side == .staged ? ["--cached"] : []) + ["--"] + paths, literalPaths: true)
            }
            return try GitParsers.string(result.stdout)
        }
    }

    public func files(in commit: GitCommit, parent: String? = nil) async throws -> [CommitFile] {
        try await gate.withPermit {
            try validate(commit)
            if let parent, !commit.parents.contains(parent) { throw GitError.staleRepository }
            let revisions = (parent ?? commit.parents.first).map { [$0, commit.oid] } ?? [commit.oid]
            let result = try await command(["diff-tree", "--root", "--no-commit-id", "--name-status",
                                            "-r", "-z", "-M"] + revisions + ["--"])
            return try GitParsers.commitFiles(result.stdout)
        }
    }

    public func diff(_ file: CommitFile, in commit: GitCommit, parent: String? = nil, options: DiffOptions = .init()) async throws -> String {
        try await gate.withPermit {
            try validate(commit)
            let safety = ["--no-ext-diff", "--no-textconv", "--no-color"] + options.arguments
            let args: [String]
            if let parent, !commit.parents.contains(parent) { throw GitError.staleRepository }
            if let parent = parent ?? commit.parents.first {
                args = ["diff"] + safety + [parent, commit.oid, "--"] + file.pathspecs
            } else {
                args = ["show", "--format=", "--root"] + safety + [commit.oid, "--"] + file.pathspecs
            }
            return try GitParsers.string(try await command(args, literalPaths: true).stdout)
        }
    }

    public func stage(_ change: FileChange) async throws { try await stage([change]) }

    public func stage(_ changes: [FileChange]) async throws {
        guard !changes.isEmpty else { return }
        try await gate.withPermit {
            let paths = Array(Set(changes.flatMap(\.stagePaths))).sorted()
            _ = try await command(["add", "--"] + paths, write: true, literalPaths: true)
        }
    }

    public func unstage(_ change: FileChange) async throws { try await unstage([change]) }

    public func unstage(_ changes: [FileChange]) async throws {
        guard !changes.isEmpty else { return }
        try await gate.withPermit {
            let paths = Array(Set(changes.flatMap(\.unstagePaths))).sorted()
            if try await headOID() == nil {
                _ = try await command(["rm", "--cached", "--ignore-unmatch", "--"] + paths, write: true, literalPaths: true)
            } else {
                _ = try await command(["restore", "--staged", "--"] + paths, write: true, literalPaths: true)
            }
        }
    }

    public func createBranch(name: String, expectedHead: String, startingAt startOID: String? = nil) async throws {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.utf8.contains(0) else { throw GitError.invalidBranchName }
        try await gate.withPermit {
            let fresh = try await readSnapshot()
            guard !fresh.operationInProgress else { throw GitError.operationInProgress }
            guard fresh.head == expectedHead, GitParsers.isOID(expectedHead) else { throw GitError.staleRepository }
            // Validate the literal ref, not --branch's @{-1} shorthand expansion.
            _ = try await command(["check-ref-format", "refs/heads/" + name])
            let start = startOID ?? expectedHead
            guard GitParsers.isOID(start) else { throw GitError.invalidInput("Select a valid commit identity.") }
            _ = try await command(["branch", "--", name, start], write: true)
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

    public func commit(message: String, signOff: CommitSignOff = .configured, expectedFingerprint: String) async throws {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              message.utf8.count <= 64 * 1024, !message.utf8.contains(0) else { throw GitError.invalidMessage }
        try await gate.withPermit {
            let fresh = try await readSnapshot()
            guard !fresh.operationInProgress else { throw GitError.operationInProgress }
            guard !fresh.hasConflicts else { throw GitError.conflicts }
            guard !fresh.staged.isEmpty else { throw GitError.nothingStaged }
            guard fresh.indexFingerprint == expectedFingerprint else { throw GitError.staleIndex }
            // No implicit add, --all, amend or hook bypass. Signed-off-by is only what the caller selected.
            _ = try await command(["commit"] + signOff.arguments + ["-m", message], write: true)
        }
    }

    private func validate(_ commit: GitCommit) throws {
        guard GitParsers.isOID(commit.oid), commit.parents.allSatisfy(GitParsers.isOID) else {
            throw GitError.malformedOutput("Invalid selected commit identity.")
        }
    }

    func command(_ arguments: [String], accepted: Set<Int32> = [0], write: Bool = false, network: Bool = false, literalPaths: Bool = false, timeout: TimeInterval? = nil, sequenceEditor: URL? = nil) async throws -> GitProcessResult {
        var args = ["--no-pager", "-c", "color.ui=false", "-c", "core.quotepath=false",
                    "-c", "core.fsmonitor=false", "-C", root.path]
        // Only caller-owned file arguments are literal. Exporting this mode globally
        // breaks stash's internal :/ (top) cleanup pathspec and can leave saved files behind.
        if literalPaths { args.insert("--literal-pathspecs", at: 0) }
        if !write { args.insert("--no-optional-locks", at: 0) }
        let execution = timeout.map { runner.withTimeout($0) } ?? (network ? runner.withTimeout(300) : runner)
        let output: GitProcessResult
        if let sequenceEditor { output = try await execution.runWithSequenceEditor(args + arguments, source: sequenceEditor) }
        else { output = try await execution.run(args + arguments) }
        guard accepted.contains(output.status) else {
            var details = String(decoding: output.stderr, as: UTF8.self)
            if !output.stdout.isEmpty { details += "\n\n[Git stdout — may describe partial successes]\n" + String(decoding: output.stdout, as: UTF8.self) }
            throw GitError.commandFailed(output.status, details)
        }
        return output
    }

    func readReferences() async throws -> [GitReference] {
        let output = try await command(["for-each-ref",
            "--format=%(refname)%00%(objectname)%00%(HEAD)%00%(*objectname)%00%(objecttype)%00%(*objecttype)%00%(symref)%00",
            "refs/heads/", "refs/remotes/", "refs/tags/"])
        return try GitParsers.references(output.stdout)
    }

    func headOID() async throws -> String? {
        let output = try await command(["rev-parse", "--verify", "--quiet", "HEAD"], accepted: [0, 1])
        guard output.status == 0 else { return nil }
        let oid = try GitParsers.string(output.stdout).trimmingCharacters(in: .newlines)
        guard GitParsers.isOID(oid) else { throw GitError.malformedOutput("Invalid HEAD.") }
        return oid
    }

    func readSnapshot() async throws -> RepositorySnapshot {
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
        let operation = try readOperation(gitDirectory: gitDirectory, head: head, references: references)
        let collaboration: Observed<CollaborationSnapshot>
        do { collaboration = .available(try await readCollaboration(head: head, branch: branch, references: references)) }
        catch is CancellationError { throw CancellationError() }
        catch { collaboration = .unavailable(error.localizedDescription) }
        return RepositorySnapshot(root: root, head: head, branch: branch, changes: changes,
                                  references: references, indexFingerprint: fingerprint,
                                  operation: operation, collaboration: collaboration)
    }
}
