import Foundation
import CryptoKit

public struct OperationReview: Sendable {
    let root: URL
    public let snapshot: RepositorySnapshot
    let worktreeDigest: String
    public let message: String
}

extension GitRepository {
    public func applyCommit(_ commit: GitCommit, action: CommitAction, expected: RepositorySnapshot) async throws {
        guard GitParsers.isOID(commit.oid), commit.parents.count <= 1 else {
            throw GitError.invalidInput("Merge commits need an explicit mainline policy; this action supports non-merge commits only.")
        }
        try await gate.withPermit {
            let fresh = try await checkReviewed(expected, clean: true)
            guard fresh.head != nil, fresh.branch != nil else { throw GitError.invalidInput("Checkout a local branch before changing history.") }
            try await protectIgnored(revisions: [commit.oid])
            _ = try await command(["-c", "submodule.recurse=false", action == .cherryPick ? "cherry-pick" : "revert", "--no-edit",
                                   "--no-rerere-autoupdate", commit.oid], write: true, timeout: 300)
        }
    }

    public func rebasePlan(after baseOID: String, expected: RepositorySnapshot) async throws -> RebasePlan {
        guard GitParsers.isOID(baseOID) else { throw GitError.staleRepository }
        return try await gate.withPermit {
            let fresh = try await checkReviewed(expected, clean: true)
            guard let head = fresh.head, fresh.branch != nil, head != baseOID else { throw GitError.invalidInput("Select an ancestor before HEAD; at least one later commit is required.") }
            let ancestor = try await command(["merge-base", "--is-ancestor", baseOID, head], accepted: [0, 1])
            guard ancestor.status == 0 else { throw GitError.invalidInput("The selected base is not an ancestor of this branch.") }
            let result = try await command(["log", "--reverse", "--topo-order", "--max-count=201",
                "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00%b", "-z", baseOID + ".." + head, "--"])
            let commits = try GitParsers.commits(result.stdout)
            guard !commits.isEmpty, commits.count <= 200 else { throw GitError.invalidInput("Review at most 200 commits per interactive rebase; select a nearer base.") }
            var parent = baseOID
            for commit in commits {
                guard commit.parents == [parent] else { throw GitError.invalidInput("This range is not linear. Merge-preserving rebase is not available; no history was changed.") }
                parent = commit.oid
            }
            guard parent == head else { throw GitError.staleRepository }
            return RebasePlan(root: root, expected: fresh, baseOID: baseOID,
                              items: commits.map { RebaseItem(commit: $0, command: .pick) })
        }
    }

    public func startRebase(_ plan: RebasePlan, items: [RebaseItem], onto: GitReference? = nil) async throws {
        guard plan.root == root, items.count == plan.items.count,
              Set(items.map(\.id)) == Set(plan.items.map(\.id)), Set(items.map(\.id)).count == items.count else { throw GitError.invalidInput("Every reviewed commit must occur exactly once in the plan.") }
        var kept = false
        for item in items {
            if [.squash, .fixup].contains(item.command) && !kept { throw GitError.invalidInput("Squash/fixup needs a preceding kept commit.") }
            if item.command != .drop { kept = true }
        }
        guard kept else { throw GitError.invalidInput("Keep at least one commit. Dropping the entire range is not supported.") }
        try await gate.withPermit {
            let fresh = try await checkReviewed(plan.expected, clean: true)
            let target: String
            if let onto {
                guard fresh.references.contains(onto), onto.symbolicTarget == nil else { throw GitError.staleRepository }
                let resolved = try await command(["rev-parse", "--verify", onto.objectOID + "^{commit}"])
                target = try GitParsers.string(resolved.stdout).trimmingCharacters(in: .newlines)
                guard GitParsers.isOID(target) else { throw GitError.staleRepository }
            } else { target = plan.baseOID }
            guard let oldHead = fresh.head else { throw GitError.staleRepository }
            try await protectIgnored(revisions: items.filter { $0.command != .drop }.map(\.id), transitions: [(oldHead, target)])
            let todo = items.map { $0.command.rawValue + " " + $0.commit.oid + "\n" }.joined()
            try await TemporaryInput.withFile(Data(todo.utf8)) { source in
                // Git's editor protocol is a fixed command, never interpolated caller code.
                // The only variable is a quoted, app-owned input pathname. No exec commands.
                _ = try await command(["-c", "sequence.editor=/bin/cp -- \"$FORKY_REBASE_TODO\"",
                    "-c", "core.editor=/usr/bin/true", "-c", "submodule.recurse=false",
                    "rebase", "--interactive", "--no-autostash", "--no-autosquash", "--no-update-refs",
                    "--no-rebase-merges", "--no-rerere-autoupdate", "--keep-empty",
                    "--onto", target, plan.baseOID], write: true, timeout: 300, sequenceEditor: source)
            }
        }
    }

    private func operationDigest(_ snapshot: RepositorySnapshot) throws -> String {
        var hash = SHA256(), total = 0
        for file in snapshot.changes.sorted(by: { $0.path.value < $1.path.value }) {
            let data = try SafeWorktree.read(root: root, path: file.path, limit: runner.outputLimit)
            total += data?.count ?? 0
            guard total <= 16 * 1024 * 1024 else { throw GitError.invalidInput("Operation review exceeds the 16 MiB worktree verification budget. Use Git directly.") }
            hash.update(data: Data((file.path.value + "\0" + String(data?.count ?? -1) + "\0").utf8))
            if let data { hash.update(data: data) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func reviewOperation(expected: RepositorySnapshot) async throws -> OperationReview {
        try await gate.withPermit {
            let fresh = try await checkReviewed(expected, allowOperation: true)
            guard let kind = fresh.operation.kind, kind != .unknown else { throw GitError.invalidInput("No supported operation is active. " + (fresh.operation.detail ?? "")) }
            let message = try GitParsers.string(try await command(["log", "-1", "--format=%B", "HEAD", "--"]).stdout)
            return OperationReview(root: root, snapshot: fresh, worktreeDigest: try operationDigest(fresh), message: message)
        }
    }
    private func checkedOperation(_ review: OperationReview) async throws -> RepositorySnapshot {
        guard review.root == root else { throw GitError.staleRepository }
        let fresh = try await checkReviewed(review.snapshot, allowOperation: true)
        guard fresh.operation.kind != nil, fresh.operation.kind != .unknown,
              try operationDigest(fresh) == review.worktreeDigest else { throw GitError.staleRepository }
        return fresh
    }

    public func stepOperation(_ review: OperationReview, step: OperationStep) async throws {
        try await gate.withPermit {
            let fresh = try await checkedOperation(review)
            guard let kind = fresh.operation.kind else { throw GitError.staleRepository }
            if step == .resume {
                guard !fresh.hasConflicts else { throw GitError.conflicts }
                guard !fresh.changes.contains(where: { !$0.isUntracked && $0.isUnstaged }) else { throw GitError.dirtyWorktree }
            }
            guard kind != .merge || step != .skip else { throw GitError.invalidInput("A merge cannot be skipped.") }
            if step == .abort {
                guard let head = fresh.head, let original = fresh.operation.restoreOID else { throw GitError.invalidInput("The operation restore identity is unavailable; inspect Git state externally.") }
                try await protectIgnored(transitions: [(head, original)], additional: fresh.changes.map(\.path))
            } else {
                guard fresh.operation.supportedTodo else { throw GitError.invalidInput("The pending external todo contains unsupported commands/options. Inspect/complete it in Git; Forky will not silently execute it.") }
                try await protectIgnored(revisions: fresh.operation.pendingRevisions, additional: fresh.changes.map(\.path))
            }
            _ = try await command(["-c", "core.editor=/usr/bin/true", "-c", "submodule.recurse=false",
                                   kind.rawValue, "--" + step.rawValue], write: true, timeout: 300)
        }
    }

    public func amendRebase(_ review: OperationReview, message: String) async throws {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, message.utf8.count <= 64 * 1024,
              !message.utf8.contains(0) else { throw GitError.invalidMessage }
        try await gate.withPermit {
            let fresh = try await checkedOperation(review)
            guard fresh.operation.canAmend, !fresh.hasConflicts,
                  !fresh.changes.contains(where: { !$0.isUntracked && $0.isUnstaged }) else { throw GitError.invalidInput("Stage or stash changes first; amendment requires a rebase edit stop without conflicts.") }
            _ = try await command(["commit", "--amend", "--allow-empty", "-m", message], write: true, timeout: 300)
        }
    }
}
