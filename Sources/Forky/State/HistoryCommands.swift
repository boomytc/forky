import AppKit
import ForkyCore

enum HistoryCommand: String, CaseIterable {
    case tree = "Browse Tree / Blame…"
    case cherryPick = "Cherry-pick…"
    case revert = "Revert…"
    case rebase = "Interactive Rebase After Here…"
    case branch = "Create Branch Here…"
    case copySHA = "Copy Commit SHA"
    case copyMessage = "Copy Commit Message"
}
struct HistoryMenuAction {
    let command: HistoryCommand
    let commit: GitCommit
}
extension RepositoryStore {
    func canExecuteHistory(_ command: HistoryCommand, commit: GitCommit) -> Bool {
        switch command {
        case .tree, .copySHA, .copyMessage: !isBusy
        case .branch: canWrite
        case .rebase: canEditHistory && commit.oid != snapshot?.head
        case .cherryPick, .revert: canEditHistory
        }
    }
    func executeHistory(_ command: HistoryCommand, commit: GitCommit) {
        guard commits.contains(commit), canExecuteHistory(command, commit: commit) else { return }
        switch command {
        case .tree: requestAdvanced(.tree(commit))
        case .cherryPick: requestAdvanced(.commit(.cherryPick, commit))
        case .revert: requestAdvanced(.commit(.revert, commit))
        case .rebase: requestAdvanced(.rebase(commit))
        case .branch: requestBranch(startingAt: commit.oid)
        case .copySHA, .copyMessage:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command == .copySHA ? commit.oid : commit.subject + "\n\n" + commit.body, forType: .string)
        }
    }
}
