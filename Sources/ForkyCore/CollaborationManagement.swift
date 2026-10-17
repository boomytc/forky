import Foundation

public struct GitWorktree: Identifiable, Equatable, Sendable {
    public let root: URL
    public let directoryIdentity: DirectoryIdentity?
    public func matchesDirectory(_ url: URL) throws -> Bool? {
        guard let directoryIdentity, let other = try DirectoryIdentity.read(url) else { return nil }
        return directoryIdentity == other
    }
    public let head: String?
    public let branch: String?
    public let locked: Bool
    public let prunable: Bool
    public var id: String { root.path }
}
extension GitRepository {
    public func saveSelectedStash(paths: [GitPath], message: String, includeUntracked: Bool, expected: RepositorySnapshot) async throws {
        guard !paths.isEmpty, !message.utf8.contains(0), message.utf8.count <= 65536 else { throw GitError.invalidInput("Choose files and a valid stash message.") }
        try await gate.withPermit {
            let fresh = try await checkReviewed(expected)
            guard !fresh.hasConflicts, fresh.head != nil else { throw GitError.conflicts }
            guard fresh.changes == expected.changes, paths.allSatisfy({ path in
                fresh.changes.contains { $0.path == path && (includeUntracked || !$0.isUntracked) }
            }) else { throw GitError.staleRepository }
            // Per-path literal magic, not global literal mode (which breaks stash's internal cleanup).
            var specs = Data()
            for path in Set(paths).sorted(by: { $0.value < $1.value }) { specs.append(Data((":(literal)" + path.value).utf8)); specs.append(0) }
            try await TemporaryInput.withFile(specs) { file in
                _ = try await command(["stash", "push"] + (includeUntracked ? ["--include-untracked"] : []) +
                    ["--message", message, "--pathspec-from-file=" + file.path, "--pathspec-file-nul"], write: true)
            }
        }
    }
    public func renameStash(_ stash: GitStash, message: String, expected: RepositorySnapshot) async throws {
        guard !message.isEmpty, !message.utf8.contains(0), message.utf8.count <= 65536 else { throw GitError.invalidMessage }
        try await gate.withPermit {
            let fresh = try await checkReviewed(expected)
            let old = try collaboration(expected).stashes
            guard try collaboration(fresh).stashes == old, let index = old.firstIndex(of: stash) else { throw GitError.staleStash }
            if old.first?.oid == stash.oid {
                // store/update-ref deliberately do not append same-OID no-op reflogs.
                // Native reflog write (Git 2.51+) appends explicitly without replacing file bytes.
                _ = try await command(["reflog", "write", "--", "refs/stash", stash.oid, stash.oid, message], write: true)
            } else { _ = try await command(["stash", "store", "--message", message, stash.oid], write: true) }
            let inserted = try await readStashes()
            guard inserted.count == old.count + 1, inserted.first?.oid == stash.oid,
                  zip(inserted.dropFirst(), old).allSatisfy({ $0.oid == $1.oid && $0.subject == $1.subject }) else {
                throw GitError.invalidInput("A renamed recovery entry was stored, but the list changed. The original was not removed.")
            }
            // Store first, then drop the shifted original. Errors retain at least the stored recovery entry.
            try await dropReviewedStash(inserted[index + 1], expected: inserted)
        }
    }
    public func worktrees() async throws -> [GitWorktree] { try await gate.withPermit { try await readWorktrees() } }
    func readWorktrees() async throws -> [GitWorktree] {
        let fields = try GitParsers.terminatedFields(try await command(["worktree", "list", "--porcelain", "-z"]).stdout)
        var result: [GitWorktree] = [], path: String?, head: String?, branch: String?, locked = false, prunable = false
        func finish() throws {
            guard let path else { return }
            guard path.hasPrefix("/"), head.map(GitParsers.isOID) ?? true else { throw GitError.malformedOutput("Invalid worktree identity.") }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            result.append(GitWorktree(root: url, directoryIdentity: try DirectoryIdentity.read(url), head: head, branch: branch, locked: locked, prunable: prunable))
        }
        for data in fields {
            let field = try GitParsers.string(data)
            if field.isEmpty { try finish(); path = nil; head = nil; branch = nil; locked = false; prunable = false }
            else if field.hasPrefix("worktree ") { path = String(field.dropFirst(9)) }
            else if field.hasPrefix("HEAD ") { head = String(field.dropFirst(5)) }
            else if field.hasPrefix("branch ") { branch = String(field.dropFirst(7)) }
            else if field == "locked" || field.hasPrefix("locked ") { locked = true }
            else if field == "prunable" || field.hasPrefix("prunable ") { prunable = true }
        }
        if path != nil { try finish() }
        return result
    }
    public func addWorktree(at destination: URL, oid: String, branch: String?, expected: RepositorySnapshot) async throws {
        guard destination.isFileURL, destination.path.hasPrefix("/"), GitParsers.isOID(oid) else { throw GitError.unsupportedPath }
        try await gate.withPermit {
            _ = try await checkReviewed(expected)
            _ = try await readCommit(oid)
            if let branch {
                guard !branch.isEmpty, !branch.hasPrefix("-"), !branch.utf8.contains(0) else { throw GitError.invalidBranchName }
                _ = try await command(["check-ref-format", "refs/heads/" + branch])
            }
            // Reserve exclusively. A failed worktree addition retains the destination for inspection.
            guard destination.path.withCString({ mkdir($0, 0o755) }) == 0 else { throw GitError.invalidInput("Choose a new worktree directory in an existing parent. Nothing was adopted.") }
            do {
                _ = try await command(["-c", "submodule.recurse=false", "worktree", "add"] +
                    (branch.map { ["-b", $0] } ?? ["--detach"]) + ["--", destination.path, oid], write: true, timeout: 300)
            } catch { throw GitError.creationFailed(destination.path, error.localizedDescription) }
        }
    }
    public func removeWorktree(_ worktree: GitWorktree, expected: RepositorySnapshot) async throws {
        try await gate.withPermit {
            _ = try await checkReviewed(expected)
            guard try await readWorktrees().contains(worktree), !worktree.locked, !worktree.prunable,
                  try worktree.matchesDirectory(root) == false else {
                throw GitError.invalidInput("Cannot remove this active, locked, missing or changed worktree.")
            }
            let other = try await GitRepository.open(worktree.root, runner: runner)
            guard other.gate === gate else { throw GitError.staleRepository }
            let state = try await other.readSnapshot()
            guard state.head == worktree.head, !state.operationInProgress, state.changes.isEmpty else { throw GitError.dirtyWorktree }
            let ignored = try await other.command(["ls-files", "--others", "--ignored", "--exclude-standard", "-z"]).stdout
            guard ignored.isEmpty else { throw GitError.invalidInput("This worktree contains ignored local data. Move it aside explicitly; Forky will not force removal.") }
            _ = try await command(["worktree", "remove", "--", worktree.root.path], write: true, timeout: 300)
        }
    }
    public func fetchRemotes(_ remotes: [GitRemote], expected: RepositorySnapshot) async throws {
        guard !remotes.isEmpty else { throw GitError.invalidInput("Select remotes to fetch.") }
        try await gate.withPermit {
            let fresh = try await checkReviewed(expected)
            for remote in remotes {
                let metadata = try checkedRemote(remote, expected: expected, fresh: fresh)
                try await transport(fetchArguments(remote), metadata: metadata)
            }
        }
    }
    public func pushReferences(_ references: [GitReference], remote: GitRemote, expected: RepositorySnapshot) async throws {
        guard !references.isEmpty else { throw GitError.invalidInput("Select explicit branches/tags.") }
        try await gate.withPermit {
            let fresh = try await checkReviewed(expected), metadata = try checkedRemote(remote, expected: expected, fresh: fresh)
            guard references.allSatisfy({ fresh.references.contains($0) && $0.symbolicTarget == nil && $0.kind != .remoteBranch }) else { throw GitError.staleRepository }
            let refspecs = references.map { $0.objectOID + ":" + $0.fullName }
            try await transport(["-c", "push.followTags=false", "push", "--porcelain", "--no-progress",
                "--no-force", "--no-mirror", "--recurse-submodules=no", "--", remote.name] + refspecs, metadata: metadata)
        }
    }
}
