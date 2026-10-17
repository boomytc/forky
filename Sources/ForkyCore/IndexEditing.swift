import Foundation

public struct ConflictReview: Sendable {
    let root: URL
    let expected: RepositorySnapshot
    let stages: Data
    let workingBytes: Data?
    public let path: GitPath
    public let base: String?
    public let ours: String?
    public let theirs: String?
    public let working: String?
}
public enum ConflictResolution: Sendable { case text(String), delete }

extension GitRepository {
    public func reviewPartial(_ change: FileChange, side: DiffSide, expected: RepositorySnapshot) async throws -> PartialReview {
        try await reviewSelectedPatch(change, side: side, expected: expected, discard: false)
    }
    public func reviewDiscard(_ change: FileChange, expected: RepositorySnapshot) async throws -> PartialReview {
        try await reviewSelectedPatch(change, side: .worktree, expected: expected, discard: true)
    }
    private func reviewSelectedPatch(_ change: FileChange, side: DiffSide, expected: RepositorySnapshot, discard: Bool) async throws -> PartialReview {
        try await gate.withPermit {
            let fresh = try await checkReviewed(expected, allowOperation: true)
            guard change.canReviewPartial(on: side), fresh.changes.contains(change) else {
                throw GitError.invalidInput("Select a regular modified tracked file for line staging.")
            }
            var entry = try await command(["ls-files", "--stage", "-z", "--", change.path.value], literalPaths: true).stdout
            if change.isUntracked {
                guard try SafeWorktree.read(root: root, path: change.path, limit: runner.outputLimit) != nil else { throw GitError.staleRepository }
            } else {
                if entry.isEmpty, side == .staged, change.index == "D", let head = fresh.head {
                    entry = try await command(["ls-tree", "-z", head, "--", change.path.value], literalPaths: true).stdout
                }
                guard let first = entry.split(separator: 0).first, entry.split(separator: 0).count == 1,
                      let tab = first.firstIndex(of: 9) else { throw GitError.staleRepository }
                let fields = try GitParsers.string(Data(first[..<tab])).split(separator: " ")
                guard fields.count == 3, ["100644", "100755"].contains(String(fields[0])) else {
                    throw GitError.invalidInput("Partial staging requires a regular text file, not a symlink/submodule.")
                }
                _ = try SafeWorktree.read(root: root, path: change.path, limit: runner.outputLimit)
            }
            return PartialReview(root: root, expected: fresh, change: change, side: side, writesWorktree: discard,
                                 patch: try PartialPatch(try await partialText(change, side: side, discard: discard)))
        }
    }
    private func partialText(_ change: FileChange, side: DiffSide, discard: Bool = false) async throws -> String {
        let result = try await command(["-c", "diff.suppressBlankEmpty=false", "diff", "--no-ext-diff", "--no-textconv", "--no-color",
            "--output-indicator-new=+", "--output-indicator-old=-", "--output-indicator-context= ", "--no-renames", "--full-index", "--no-relative", "--src-prefix=a/", "--dst-prefix=b/", "--unified=3"]
            + (change.isUntracked ? ["--no-index"] : side == .staged ? ["--cached", "-R"] : [])
            + (discard ? ["-R"] : []) + ["--"] + (change.isUntracked ? ["/dev/null", change.path.value] : [change.path.value]), accepted: [0, 1], literalPaths: true)
        return try GitParsers.string(result.stdout)
    }
    public func applyPartial(_ review: PartialReview, selected: Set<Int>, approveDiscard: Bool = false) async throws {
        try await gate.withPermit {
            guard review.root == root else { throw GitError.staleRepository }
            guard !review.writesWorktree || approveDiscard else { throw GitError.invalidInput("Working file discard requires explicit approval.") }
            _ = try await checkReviewed(review.expected, allowOperation: true)
            guard try await partialText(review.change, side: review.side, discard: review.writesWorktree) == review.patch.raw else { throw GitError.staleRepository }
            let data = Data(try review.patch.selecting(selected).utf8)
            try await TemporaryInput.withFile(data) { file in
                _ = try await command(["apply"] + (review.writesWorktree ? [] : ["--cached"]) + ["--check", "--whitespace=nowarn", "--", file.path])
                try Task.checkCancellation()
                _ = try await command(["apply"] + (review.writesWorktree ? [] : ["--cached"]) + ["--whitespace=nowarn", "--", file.path], write: true)
            }
        }
    }

    public func runMergetool(_ review: ConflictReview) async throws {
        try await gate.withPermit {
            guard review.root == root else { throw GitError.staleRepository }
            let fresh = try await checkReviewed(review.expected, allowOperation: true)
            let current = try await conflict(review.path, snapshot: fresh)
            guard current.stages == review.stages, current.workingBytes == review.workingBytes else { throw GitError.staleRepository }
            _ = try await command(["mergetool", "--no-prompt", "--", review.path.value], write: true, literalPaths: true, timeout: 300)
        }
    }

    public func reviewConflict(_ path: GitPath, expected: RepositorySnapshot) async throws -> ConflictReview {
        try await gate.withPermit {
            let fresh = try await checkReviewed(expected, allowOperation: true)
            return try await conflict(path, snapshot: fresh)
        }
    }
    func conflict(_ path: GitPath, snapshot: RepositorySnapshot) async throws -> ConflictReview {
        guard snapshot.changes.contains(where: { $0.path == path && $0.isConflict }) else { throw GitError.staleRepository }
        let stages = try await command(["ls-files", "--unmerged", "-z", "--", path.value], literalPaths: true).stdout
        var versions: [Int: String] = [:]
        for record in stages.split(separator: 0) {
            guard let tab = record.firstIndex(of: 9) else { throw GitError.malformedOutput("Invalid conflict entry.") }
            let fields = try GitParsers.string(Data(record[..<tab])).split(separator: " ")
            let name = try GitParsers.string(Data(record[record.index(after: tab)...]))
            guard fields.count == 3, name == path.value, ["100644", "100755"].contains(String(fields[0])),
                  GitParsers.isOID(String(fields[1])), let stage = Int(fields[2]), (1...3).contains(stage),
                  versions[stage] == nil else { throw GitError.invalidInput("Conflict editing supports regular UTF-8 text files, not symlinks, submodules or malformed stages.") }
            let data = try await command(["cat-file", "blob", String(fields[1])]).stdout
            guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw GitError.invalidInput("This conflict contains binary or non-UTF-8 data. Use an external tool.") }
            versions[stage] = text
        }
        guard !versions.isEmpty else { throw GitError.staleRepository }
        let bytes = try SafeWorktree.read(root: root, path: path, limit: runner.outputLimit)
        let working: String?
        if let bytes {
            guard !bytes.contains(0), let text = String(data: bytes, encoding: .utf8) else { throw GitError.invalidInput("The working file is not UTF-8 text.") }
            working = text
        } else { working = nil }
        return ConflictReview(root: root, expected: snapshot, stages: stages, workingBytes: bytes, path: path,
                              base: versions[1], ours: versions[2], theirs: versions[3], working: working)
    }

    public func resolveConflict(_ review: ConflictReview, resolution: ConflictResolution, stage: Bool,
                                allowMarkers: Bool = false) async throws {
        let data: Data?
        switch resolution {
        case .delete: data = nil
        case .text(let text):
            guard !text.utf8.contains(0), text.utf8.count <= runner.outputLimit else { throw GitError.invalidInput("Resolution exceeds the UTF-8 file editing budget or contains NUL.") }
            if stage && !allowMarkers && text.components(separatedBy: "\n").contains(where: { line in
                ["<<<<<<<", "=======", ">>>>>>>", "|||||||"].contains(where: line.hasPrefix)
            }) { throw GitError.invalidInput("Conflict markers remain. Review them or explicitly allow literal marker lines.") }
            data = Data(text.utf8)
        }
        try await gate.withPermit {
            guard review.root == root else { throw GitError.staleRepository }
            let fresh = try await checkReviewed(review.expected, allowOperation: true)
            guard fresh.operation.kind != .unknown else { throw GitError.operationInProgress }
            let current = try await conflict(review.path, snapshot: fresh)
            guard current.stages == review.stages, current.workingBytes == review.workingBytes else { throw GitError.staleRepository }
            try Task.checkCancellation()
            try SafeWorktree.replace(root: root, path: review.path, data: data)
            if stage {
                // No check-marker guess substitutes for the caller's explicit resolution approval.
                let stages = try await command(["ls-files", "--unmerged", "-z", "--", review.path.value], literalPaths: true).stdout
                guard stages == review.stages else { throw GitError.staleRepository }
                _ = try await command(["add", "--", review.path.value], write: true, literalPaths: true)
            }
        }
    }
}
