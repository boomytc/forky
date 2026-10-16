import Foundation

public enum GitError: Error, LocalizedError, Sendable {
    case launch(String)
    case commandFailed(Int32, String)
    case timedOut
    case outputLimit(Int)
    case incompleteOutput
    case invalidRepository(String)
    case malformedOutput(String)
    case unsupportedPath
    case nothingStaged
    case conflicts
    case operationInProgress
    case staleIndex
    case invalidMessage
    case dirtyWorktree
    case staleRepository
    case invalidBranchName

    public var errorDescription: String? {
        switch self {
        case .launch(let message): "Could not start Git: \(message)"
        case .commandFailed(let code, let message): "Git exited with status \(code).\n\(message)"
        case .timedOut: "Git exceeded the operation deadline. A write may have completed; refresh before retrying."
        case .outputLimit(let bytes): "Git output exceeded the \(bytes / 1024) KiB preview limit."
        case .incompleteOutput: "Git exited but a subprocess kept its output open. Output is incomplete."
        case .invalidRepository(let reason): "Cannot open this repository: \(reason)"
        case .malformedOutput(let reason): "Could not decode Git output: \(reason)"
        case .unsupportedPath: "This path cannot be represented safely. Non-UTF-8 paths are not supported in this version."
        case .nothingStaged: "Stage at least one change before committing."
        case .conflicts: "Resolve and stage all conflicts before committing."
        case .operationInProgress: "A merge, rebase, cherry-pick or revert is in progress. Complete it in another Git client first."
        case .staleIndex: "The staged changes or HEAD changed since the last refresh. Review the updated changes before committing."
        case .invalidMessage: "Enter a nonempty commit message of at most 64 KiB, without NUL characters."
        case .dirtyWorktree: "Commit or move aside all staged, unstaged and untracked changes before switching branches. Forky will not discard or stash them automatically."
        case .staleRepository: "HEAD or the selected branch changed. Refresh and review the destination before retrying."
        case .invalidBranchName: "Enter a valid branch name, without a leading dash or NUL characters."
        }
    }
}
