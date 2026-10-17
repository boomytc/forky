import Foundation

public enum ResetMode: String, CaseIterable, Sendable { case soft, mixed, hard }
public struct ResetReview: Sendable {
    let expected: RepositorySnapshot
    let digest: String
    public let target: String
    public let mode: ResetMode
    public let changes: [FileChange]
    public let patch: String
}
extension GitRepository {
    public func reviewReset(to oid: String, mode: ResetMode, expected: RepositorySnapshot) async throws -> ResetReview {
        guard GitParsers.isOID(oid) else { throw GitError.staleRepository }
        return try await gate.withPermit {
            let fresh = try await checkReviewed(expected)
            guard fresh.branch != nil, fresh.head != nil, !fresh.hasConflicts else { throw GitError.invalidInput("Reset requires an existing local branch without conflicts.") }
            _ = try await readCommit(oid)
            let patch = try GitParsers.string(try await command(["diff", "--no-ext-diff", "--no-textconv", "--no-color", "HEAD", "--"]).stdout)
            return ResetReview(expected: fresh, digest: try worktreeDigest(fresh), target: oid, mode: mode, changes: fresh.changes, patch: patch)
        }
    }
    public func reset(_ review: ResetReview, approveHardDiscard: Bool = false) async throws {
        try await gate.withPermit {
            let fresh = try await checkReviewed(review.expected)
            guard fresh.changes == review.changes, try worktreeDigest(fresh) == review.digest else { throw GitError.staleRepository }
            if review.mode == .hard {
                guard approveHardDiscard else { throw GitError.invalidInput("Hard reset needs explicit tracked-data discard approval.") }
                guard !fresh.changes.contains(where: \.isUntracked) else { throw GitError.invalidInput("Move untracked data aside before hard reset; Forky does not remove it.") }
                guard let head = fresh.head else { throw GitError.staleRepository }
                try await protectIgnored(transitions: [(head, review.target)], additional: fresh.changes.map(\.path))
            }
            _ = try await command(["-c", "submodule.recurse=false", "reset", "--" + review.mode.rawValue,
                                   "--no-recurse-submodules", review.target], write: true)
        }
    }
}
