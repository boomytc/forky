import Foundation

public enum MergeMode: String, CaseIterable, Sendable {
    case fastForward = "Fast-forward if possible", noFastForward = "Always create merge commit"
    case squash = "Squash into staged changes", noCommit = "Merge without committing"
}
public enum ReferenceChange: Sendable {
    case rename(GitReference, String), delete(GitReference)
    case tag(name: String, oid: String, message: String?)
    case remoteURL(GitRemote, String), remotePushURL(GitRemote, String), removeRemote(GitRemote)
    case upstream(GitReference?), renameRemote(GitRemote, String)
}

extension GitRepository {
    public func commitInfo(_ oid: String) async throws -> GitCommit {
        guard GitParsers.isOID(oid) else { throw GitError.staleRepository }
        return try await gate.withPermit { try await readCommit(oid) }
    }
    func readCommit(_ oid: String) async throws -> GitCommit {
        let data = try await command(["log", "-1", "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00%b", "-z", oid, "--"]).stdout
        guard let commit = try GitParsers.commits(data).first else { throw GitError.staleRepository }
        return commit
    }
    public func integrationBase(onto reference: GitReference, expected: RepositorySnapshot) async throws -> GitCommit {
        try await gate.withPermit {
            let fresh = try await checkReviewed(expected, clean: true)
            guard let head = fresh.head, fresh.references.contains(reference), let target = reference.commitOID else { throw GitError.staleRepository }
            var oid = try GitParsers.string(try await command(["merge-base", head, target]).stdout)
            if oid.hasSuffix("\n") { oid.removeLast() }
            guard GitParsers.isOID(oid) else { throw GitError.invalidInput("A unique integration base was not established.") }
            return try await readCommit(oid)
        }
    }

    public func amend(message: String, includeStaged: Bool, expected: RepositorySnapshot) async throws {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !message.utf8.contains(0), message.utf8.count <= 65536 else { throw GitError.invalidMessage }
        try await gate.withPermit {
            let fresh = try await checkReviewed(expected)
            guard fresh.head != nil, fresh.branch != nil else { throw GitError.invalidInput("Amend requires an existing local branch commit.") }
            guard !fresh.hasConflicts else { throw GitError.conflicts }
            // --only without paths is Git's amend-message-only operation; staged bytes remain staged.
            _ = try await command(["commit", "--amend"] + (includeStaged ? [] : ["--only"]) + ["-m", message], write: true)
        }
    }
    public func merge(_ oid: String, mode: MergeMode, expected: RepositorySnapshot) async throws {
        guard GitParsers.isOID(oid) else { throw GitError.staleRepository }
        try await gate.withPermit {
            let fresh = try await checkReviewed(expected, clean: true)
            guard let head = fresh.head, fresh.branch != nil else { throw GitError.invalidInput("Checkout an existing local branch first.") }
            _ = try await readCommit(oid)
            try await protectIgnored(revisions: [oid], transitions: [(head, oid)])
            let flags: [String]
            switch mode {
            case .fastForward: flags = ["--ff"]
            case .noFastForward: flags = ["--no-ff"]
            case .squash: flags = ["--squash", "--no-commit"]
            case .noCommit: flags = ["--no-ff", "--no-commit"]
            }
            _ = try await command(["-c", "submodule.recurse=false", "merge", "--no-autostash",
                "--no-overwrite-ignore", "--no-edit", "--no-rerere-autoupdate"] + flags + [oid], write: true, timeout: 300)
        }
    }
    func checkConfiguration(_ expected: RepositorySnapshot, _ fresh: RepositorySnapshot) throws -> CollaborationSnapshot {
        guard let old = expected.collaboration.value, let current = fresh.collaboration.value else {
            throw GitError.invalidInput("Configuration could not be observed. Refresh before editing it.")
        }
        guard old.configurationDigest == current.configurationDigest else { throw GitError.staleRepository }
        return current
    }
    public func changeReference(_ action: ReferenceChange, expected: RepositorySnapshot) async throws {
        try await gate.withPermit {
            let fresh = try await checkReviewed(expected)
            let config = try checkConfiguration(expected, fresh)
            func observed(_ ref: GitReference) throws {
                guard ref.symbolicTarget == nil, fresh.references.contains(ref) else { throw GitError.staleRepository }
            }
            func validateName(_ name: String, prefix: String) async throws {
                guard !name.isEmpty, !name.hasPrefix("-"), !name.utf8.contains(0), name.utf8.count <= 4096 else { throw GitError.invalidBranchName }
                _ = try await command(["check-ref-format", prefix + name])
            }
            switch action {
            case .rename(let ref, let name):
                try observed(ref)
                if ref.kind == .localBranch {
                    try await validateName(name, prefix: "refs/heads/")
                    _ = try await command(["branch", "--move", "--", ref.name, name], write: true)
                } else if ref.kind == .tag {
                    try await validateName(name, prefix: "refs/tags/")
                    _ = try await command(["update-ref", "refs/tags/" + name, ref.objectOID, String(repeating: "0", count: ref.objectOID.count)], write: true)
                    do { _ = try await command(["update-ref", "--no-deref", "-d", ref.fullName, ref.objectOID], write: true) }
                    catch { throw GitError.invalidInput("New tag ref was created; the old ref was not confirmed removed. Both may remain. " + error.localizedDescription) }
                } else { throw GitError.invalidInput("Rename a local branch or tag, not a remote tracking alias.") }
            case .delete(let ref):
                try observed(ref)
                switch ref.kind {
                case .localBranch:
                    guard !ref.isCurrent else { throw GitError.invalidInput("Cannot delete the checked-out branch.") }
                    // Git also refuses branches held by another worktree, and unmerged branches.
                    _ = try await command(["branch", "--delete", "--", ref.name], write: true)
                case .tag:
                    _ = try await command(["update-ref", "--no-deref", "-d", ref.fullName, ref.objectOID], write: true)
                case .remoteBranch:
                    throw GitError.invalidInput("This is a local tracking ref. Remote deletion requires a separately reviewed server operation.")
                }
            case .tag(let name, let oid, let message):
                try await validateName(name, prefix: "refs/tags/")
                guard GitParsers.isOID(oid) else { throw GitError.staleRepository }
                _ = try await readCommit(oid)
                if let message {
                    guard !message.isEmpty, !message.utf8.contains(0), message.utf8.count <= 65536 else { throw GitError.invalidMessage }
                    _ = try await command(["tag", "--annotate", "--message", message, "--", name, oid], write: true)
                } else {
                    // Explicit lightweight choice: do not accidentally create an annotated tag from config.
                    _ = try await command(["-c", "tag.gpgSign=false", "tag", "--", name, oid], write: true)
                }
            case .remoteURL(let remote, let url):
                guard config.remotes.contains(remote) else { throw GitError.staleRepository }
                try TransportPresentation.validateNewSource(url)
                _ = try await command(["remote", "set-url", "--", remote.name, url], write: true)
            case .remotePushURL(let remote, let url):
                guard config.remotes.contains(remote) else { throw GitError.staleRepository }
                try TransportPresentation.validateNewSource(url)
                _ = try await command(["remote", "set-url", "--push", "--", remote.name, url], write: true)
            case .removeRemote(let remote):
                guard config.remotes.contains(remote) else { throw GitError.staleRepository }
                _ = try await command(["remote", "remove", "--", remote.name], write: true)
            case .renameRemote(let remote, let name):
                guard config.remotes.contains(remote) else { throw GitError.staleRepository }
                try await validateName(name, prefix: "refs/remotes/")
                _ = try await command(["remote", "rename", "--", remote.name, name], write: true)
            case .upstream(let target):
                guard let branch = fresh.branch else { throw GitError.invalidInput("Checkout a local branch first.") }
                if let target {
                    try observed(target)
                    guard target.kind != .tag else { throw GitError.invalidInput("Upstream must be a branch.") }
                    _ = try await command(["branch", "--set-upstream-to=" + target.fullName, "--", branch], write: true)
                } else { _ = try await command(["branch", "--unset-upstream", "--", branch], write: true) }
            }
        }
    }
}
