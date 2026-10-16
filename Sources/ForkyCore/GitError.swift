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
    case invalidInput(String)
    case unsupportedRemote(String)
    case staleStash
    case nothingToStash
    case creationFailed(String, String)

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
        case .conflicts: "Resolve and stage all conflicts before continuing."
        case .operationInProgress: "A merge, rebase, cherry-pick or revert is in progress. Review and complete that operation before starting another."
        case .staleIndex: "The staged changes or HEAD changed since the last refresh. Review the updated changes before committing."
        case .invalidMessage: "Enter a nonempty commit message of at most 64 KiB, without NUL characters."
        case .dirtyWorktree: "Commit or stash all staged, unstaged and untracked changes before this operation. Forky will not discard or stash them automatically."
        case .staleRepository: "The reviewed repository state, selected reference or configuration changed. Refresh and review the destination before retrying."
        case .invalidBranchName: "Enter a valid branch name, without a leading dash or NUL characters."
        case .invalidInput(let reason): reason
        case .unsupportedRemote(let reason): "Remote operation unavailable: \(reason)"
        case .staleStash: "The stash list changed. Refresh and review the selected stash before retrying."
        case .nothingToStash: "No eligible changes to stash. Enable Include untracked files if that is what you want to save."
        case .creationFailed(let path, let reason): "Repository creation did not finish at \(path).\n\(reason)\nInspect this location before retrying. Forky did not recursively remove it."
        }
    }
}
