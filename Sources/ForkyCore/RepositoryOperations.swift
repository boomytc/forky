import Foundation
import Darwin

public enum RepositoryCreation: Sendable {
    case clone(String)
    case initialize(String)
}

extension GitRepository {
    func readCollaboration(head: String?, branch: String?, references: [GitReference]) async throws -> CollaborationSnapshot {
        let config = try GitConfiguration(try await command(["config", "--null", "--list"]).stdout)
        let remotes = try config.remotes()
        let stashes = try await readStashes()
        var tracking: BranchTracking?
        if let branch, let head {
            let fields = try await command(["for-each-ref",
                "--format=%(refname)%00%(upstream)%00%(upstream:remotename)%00%(upstream:remoteref)%00", "refs/heads/" + branch])
            if let (upstream, remote, mergeRef) = try GitParsers.trackingFields(fields.stdout, branch: branch) {
                let oid = references.first { $0.fullName == upstream }?.commitOID
                var counts: (Int, Int)?
                if let oid { counts = try GitParsers.divergence(try await command(["rev-list", "--left-right", "--count", head + "..." + oid]).stdout) }
                tracking = BranchTracking(upstream: upstream, remote: remote, mergeRef: mergeRef,
                                          upstreamOID: oid, ahead: counts?.0, behind: counts?.1)
            }
        }
        return CollaborationSnapshot(remotes: remotes, tracking: tracking, stashes: stashes,
                                     configurationDigest: config.digest, credentials: config.credentials)
    }

    func readStashes() async throws -> [GitStash] {
        try GitParsers.stashes(try await command(["stash", "list", "-z", "--format=%H%x00%gd%x00%ct%x00%gs"]).stdout)
    }

    func collaboration(_ snapshot: RepositorySnapshot) throws -> CollaborationSnapshot {
        guard let value = snapshot.collaboration.value else {
            throw GitError.invalidInput("Repository tools metadata is unavailable. " + (snapshot.collaboration.error ?? "Refresh before retrying."))
        }
        return value
    }

    private func reviewed(_ expected: RepositorySnapshot, clean: Bool) async throws -> RepositorySnapshot {
        guard expected.root == root else { throw GitError.staleRepository }
        let fresh = try await readSnapshot()
        guard fresh.head == expected.head, fresh.branch == expected.branch else { throw GitError.staleRepository }
        guard !fresh.operationInProgress else { throw GitError.operationInProgress }
        guard !fresh.hasConflicts else { throw GitError.conflicts }
        if clean && !fresh.changes.isEmpty { throw GitError.dirtyWorktree }
        return fresh
    }

    func checkedRemote(_ remote: GitRemote, expected: RepositorySnapshot, fresh: RepositorySnapshot) throws -> CollaborationSnapshot {
        let old = try collaboration(expected), current = try collaboration(fresh)
        guard current.configurationDigest == old.configurationDigest, current.remotes.contains(remote) else {
            throw GitError.staleRepository
        }
        if let limitation = remote.limitation { throw GitError.unsupportedRemote(limitation) }
        return current
    }

    func transport(_ args: [String], metadata: CollaborationSnapshot) async throws {
        do { _ = try await command(args, write: true, network: true) }
        catch GitError.commandFailed(let code, let text) {
            throw GitError.commandFailed(code, TransportPresentation.sanitize(text, using: metadata.credentials))
        }
    }

    func fetchArguments(_ remote: GitRemote) -> [String] {
        ["fetch", "--no-progress", "--no-tags", "--no-prune", "--no-prune-tags",
         "--no-recurse-submodules", "--no-auto-maintenance", "--no-write-commit-graph", "--", remote.name]
    }

    public func fetch(_ remote: GitRemote, expected: RepositorySnapshot) async throws {
        try await gate.withPermit {
            guard expected.root == root else { throw GitError.staleRepository }
            let fresh = try await readSnapshot()
            let metadata = try checkedRemote(remote, expected: expected, fresh: fresh)
            try await transport(fetchArguments(remote), metadata: metadata)
        }
    }

    /// Fetch then fast-forward only. No rebase, merge commit, autostash or ignored-file overwrite.
    public func pullFastForward(_ remote: GitRemote, expected: RepositorySnapshot) async throws {
        try await gate.withPermit {
            let fresh = try await reviewed(expected, clean: true)
            let metadata = try checkedRemote(remote, expected: expected, fresh: fresh)
            guard let tracking = metadata.tracking, tracking.remote == remote.name else {
                throw GitError.invalidInput("This branch does not track the selected remote. Publish it or configure its upstream first.")
            }
            try await transport(fetchArguments(remote), metadata: metadata)
            let afterFetch = try await reviewed(expected, clean: true)
            let updated = try checkedRemote(remote, expected: expected, fresh: afterFetch)
            guard let target = updated.tracking, target.remote == tracking.remote,
                  target.mergeRef == tracking.mergeRef, let oid = target.upstreamOID else {
                throw GitError.invalidInput("The upstream branch is unavailable after fetch. Fetched refs may already have changed.")
            }
            _ = try await command(["-c", "submodule.recurse=false", "merge", "--ff-only", "--no-autostash",
                                   "--no-overwrite-ignore", "--no-edit", oid], write: true)
        }
    }

    /// Always one explicit branch, reviewed immutable source OID, no tags/mirror/force.
    public func push(_ remote: GitRemote, branch destination: String, setUpstream: Bool,
                     expected: RepositorySnapshot) async throws {
        guard !destination.isEmpty, !destination.hasPrefix("-"), !destination.utf8.contains(0) else {
            throw GitError.invalidBranchName
        }
        try await gate.withPermit {
            let fresh = try await reviewed(expected, clean: false)
            let metadata = try checkedRemote(remote, expected: expected, fresh: fresh)
            guard let branch = fresh.branch, let head = fresh.head else {
                throw GitError.invalidInput("Push requires a local branch with a commit, not detached or unborn HEAD.")
            }
            _ = try await command(["check-ref-format", "refs/heads/" + destination])
            try await transport(["-c", "push.followTags=false", "push", "--porcelain", "--no-progress",
                                 "--no-force", "--no-mirror", "--recurse-submodules=no", "--",
                                 remote.name, head + ":refs/heads/" + destination], metadata: metadata)
            if setUpstream {
                // A push can succeed even if this subsequent local configuration update fails.
                let afterPush = try await reviewed(expected, clean: false)
                let current = try checkedRemote(remote, expected: expected, fresh: afterPush)
                guard current.remotes.contains(remote) else { throw GitError.staleRepository }
                _ = try await command(["branch", "--set-upstream-to=refs/remotes/" + remote.name + "/" + destination,
                                       "--", branch], write: true)
            }
        }
    }

    public func checkoutRemote(_ reference: GitReference, as name: String, expected: RepositorySnapshot) async throws {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.utf8.contains(0) else { throw GitError.invalidBranchName }
        try await gate.withPermit {
            let fresh = try await reviewed(expected, clean: true)
            guard reference.kind == .remoteBranch, reference.symbolicTarget == nil,
                  fresh.references.contains(reference) else { throw GitError.staleRepository }
            let old = try collaboration(expected)
            guard let remote = old.remotes.sorted(by: { $0.name.count > $1.name.count })
                .first(where: { $0.ownsTrackingReference(reference) }) else {
                throw GitError.invalidInput("This tracking ref has no configured owning remote.")
            }
            _ = try checkedRemote(remote, expected: expected, fresh: fresh)
            _ = try await command(["check-ref-format", "refs/heads/" + name])
            _ = try await command(["switch", "--create", name, "--track", "--no-guess",
                                   "--no-overwrite-ignore", "--no-recurse-submodules", "--", reference.fullName], write: true)
        }
    }

    public func addRemote(name: String, url: String, expected: RepositorySnapshot) async throws {
        try TransportPresentation.validateNewSource(url)
        guard !name.isEmpty, !name.hasPrefix("-"), name != ".", !name.utf8.contains(0) else {
            throw GitError.invalidInput("Enter a valid remote name.")
        }
        try await gate.withPermit {
            guard expected.root == root else { throw GitError.staleRepository }
            let current = try collaboration(try await readSnapshot())
            guard current.configurationDigest == (try collaboration(expected)).configurationDigest else { throw GitError.staleRepository }
            _ = try await command(["check-ref-format", "refs/remotes/" + name + "/validation"])
            _ = try await command(["remote", "add", "--", name, url], write: true)
        }
    }

    public func saveStash(message: String, includeUntracked: Bool, expected: RepositorySnapshot) async throws {
        guard !message.utf8.contains(0), message.utf8.count <= 64 * 1024 else {
            throw GitError.invalidInput("Stash messages may be empty, but must be at most 64 KiB without NUL characters.")
        }
        try await gate.withPermit {
            let fresh = try await reviewed(expected, clean: false)
            guard fresh.head != nil else { throw GitError.invalidInput("Create an initial commit before stashing.") }
            guard fresh.indexFingerprint == expected.indexFingerprint, fresh.changes == expected.changes else { throw GitError.staleIndex }
            guard fresh.changes.contains(where: { includeUntracked || !$0.isUntracked }) else { throw GitError.nothingToStash }
            var args = ["stash", "push"]
            if includeUntracked { args.append("--include-untracked") }
            if !message.isEmpty { args += ["--message", message] }
            _ = try await command(args, write: true)
        }
    }

    public func applyStash(_ stash: GitStash, restoreIndex: Bool, expected: RepositorySnapshot, dropAfterSuccess: Bool = false) async throws {
        try await gate.withPermit {
            let fresh = try await reviewed(expected, clean: true)
            guard GitParsers.isOID(stash.oid), try collaboration(fresh).stashes.contains(where: { $0.oid == stash.oid }) else {
                throw GitError.staleStash
            }
            let commit = try await readCommit(stash.oid)
            guard (2...3).contains(commit.parents.count), let head = fresh.head else { throw GitError.invalidInput("Unknown stash topology or unborn destination.") }
            try await protectIgnored(revisions: Array(commit.parents.dropFirst(2)), transitions: [(head, stash.oid)])
            _ = try await command(["-c", "submodule.recurse=false", "stash", "apply"]
                                  + (restoreIndex ? ["--index"] : []) + [stash.oid], write: true)
            if dropAfterSuccess {
                do { try await dropReviewedStash(stash, expected: collaboration(fresh).stashes) }
                catch is CancellationError { throw CancellationError() }
                catch { throw GitError.invalidInput("Stash apply succeeded; deletion did not complete. Inspect the retained list before retrying. " + error.localizedDescription) }
            }
        }
    }

    public func dropStash(_ stash: GitStash, expected: RepositorySnapshot) async throws {
        try await gate.withPermit {
            guard expected.root == root else { throw GitError.staleRepository }
            try await dropReviewedStash(stash, expected: collaboration(expected).stashes)
        }
    }

    func dropReviewedStash(_ stash: GitStash, expected: [GitStash]) async throws {
        let current = try await readStashes()
        guard current == expected, current.contains(stash) else { throw GitError.staleStash }
        let resolved = try await command(["rev-parse", "--verify", stash.selector])
        var oid = try GitParsers.string(resolved.stdout)
        if oid.hasSuffix("\n") { oid.removeLast() }
        guard oid == stash.oid else { throw GitError.staleStash }
        _ = try await command(["stash", "drop", "--", stash.selector], write: true)
    }

    public func stashDiff(_ stash: GitStash) async throws -> String {
        guard GitParsers.isOID(stash.oid) else { throw GitError.staleStash }
        return try await gate.withPermit {
            try GitParsers.string(try await command(["stash", "show", "--patch", "--include-untracked",
                "--no-ext-diff", "--no-textconv", "--no-color", stash.oid]).stdout)
        }
    }

    /// Exclusively reserves a NEW directory. Never adopts or recursively removes an existing path.
    public static func create(_ creation: RepositoryCreation, at destination: URL,
                              runner: GitProcessRunner = .init()) async throws -> GitRepository {
        let args: [String]
        switch creation {
        case .clone(let source):
            try TransportPresentation.validateNewSource(source)
            args = ["clone", "--no-hardlinks", "--no-recurse-submodules", "--no-progress", "--", source, destination.path]
        case .initialize(let branch):
            guard !branch.isEmpty, !branch.hasPrefix("-"), !branch.utf8.contains(0) else { throw GitError.invalidBranchName }
            let checked = try await runner.run(["check-ref-format", "refs/heads/" + branch])
            guard checked.status == 0 else { throw GitError.invalidBranchName }
            args = ["init", "--initial-branch=" + branch, "--", destination.path]
        }
        try Task.checkCancellation()
        guard destination.isFileURL, destination.path.hasPrefix("/") else { throw GitError.unsupportedPath }
        let reserved = destination.path.withCString { mkdir($0, 0o755) }
        guard reserved == 0 else {
            throw GitError.invalidInput("Choose a new folder in an existing writable parent directory. The destination was not reserved: " + String(cString: strerror(errno)))
        }
        do {
            let result = try await runner.withTimeout(900).run(["--no-pager"] + args)
            guard result.status == 0 else { throw GitError.commandFailed(result.status, String(decoding: result.stderr, as: UTF8.self)) }
            return try await open(destination, runner: runner)
        } catch is CancellationError { throw CancellationError() }
        catch { throw GitError.creationFailed(destination.path, error.localizedDescription) }
    }
}
