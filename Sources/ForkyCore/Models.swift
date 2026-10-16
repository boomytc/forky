import Foundation

public struct GitPath: Hashable, Sendable, Identifiable {
    public let value: String
    public var id: String { value }
    public var name: String { (value as NSString).lastPathComponent }
    public var directory: String { (value as NSString).deletingLastPathComponent }

    public init(_ value: String) throws {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.utf8.contains(0),
              !value.split(separator: "/").contains("..") else { throw GitError.unsupportedPath }
        self.value = value
    }
}

public struct FileChange: Identifiable, Hashable, Sendable {
    public let path: GitPath
    public let originalPath: GitPath?
    public let index: Character
    public let worktree: Character
    public var id: String { path.value }
    public var isUntracked: Bool { index == "?" && worktree == "?" }
    public var isConflict: Bool { ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains("\(index)\(worktree)") }
    public var isStaged: Bool { !isUntracked && index != " " && index != "!" && !isConflict }
    public var isUnstaged: Bool { isUntracked || worktree != " " || isConflict }
    public var stagePaths: [String] {
        if worktree == "R", let originalPath { [path.value, originalPath.value] } else { [path.value] }
    }
    public var unstagePaths: [String] {
        if index == "R", let originalPath { [path.value, originalPath.value] } else { [path.value] }
    }
    public var statusLabel: String {
        if isConflict { return "Conflict" }
        if isUntracked { return "New" }
        let code = isStaged ? index : worktree
        return switch code {
        case "A": "Added"
        case "D": "Deleted"
        case "R": "Renamed"
        case "C": "Copied"
        case "T": "Type changed"
        default: "Modified"
        }
    }
}

public struct GitBranch: Identifiable, Equatable, Sendable {
    public let fullName: String
    public let name: String
    public let oid: String
    public let isCurrent: Bool
    public let isRemote: Bool
    public var id: String { fullName }
}

public struct GitCommit: Identifiable, Equatable, Sendable {
    public let oid: String
    public let parents: [String]
    public let author: String
    public let email: String
    public let date: Date
    public let subject: String
    public let body: String
    public var id: String { oid }
    public var shortOID: String { String(oid.prefix(8)) }
}

public struct CommitFile: Identifiable, Hashable, Sendable {
    public let path: GitPath
    public let originalPath: GitPath?
    public let status: String
    public var id: String { path.value }
    public var pathspecs: [String] { [path.value] + (originalPath.map { [$0.value] } ?? []) }
}

public struct RepositorySnapshot: Sendable {
    public let root: URL
    public let head: String?
    public let branch: String?
    public let changes: [FileChange]
    public let branches: [GitBranch]
    public let indexFingerprint: String
    public let operationInProgress: Bool
    public var staged: [FileChange] { changes.filter(\.isStaged) }
    public var unstaged: [FileChange] { changes.filter(\.isUnstaged) }
    public var hasConflicts: Bool { changes.contains(where: \.isConflict) }
    public var branchLabel: String { branch ?? (head.map { "Detached · \($0.prefix(8))" } ?? "Unborn HEAD") }
}

public struct HistoryPage: Sendable {
    public let commits: [GitCommit]
    public let hasMore: Bool
}

public enum DiffSide: String, Hashable, Sendable { case worktree, staged }
