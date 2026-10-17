import Foundation
import ForkyCore

enum AdvancedAction {
    case partial(FileChange, DiffSide), discard(FileChange), conflict(FileChange), commit(CommitAction, GitCommit)
    case rebase(GitCommit), operation, tree(GitCommit)
}
struct AdvancedRequest: Identifiable {
    let id = UUID()
    let repository: GitRepository
    let expected: RepositorySnapshot
    let action: AdvancedAction
}

extension RepositoryStore {
    var canEditHistory: Bool {
        canWrite && snapshot?.head != nil && snapshot?.branch != nil
            && snapshot?.operationInProgress == false && snapshot?.changes.isEmpty == true
    }
    func requestAdvanced(_ action: AdvancedAction) {
        guard let repository, let snapshot, !isBusy else { return }
        if case .tree = action {} else { guard canWrite else { return } }
        sheet = .advanced(AdvancedRequest(repository: repository, expected: snapshot, action: action))
    }
    func performAdvanced(_ request: AdvancedRequest, title: String,
                         operation: @escaping @Sendable (GitRepository) async throws -> Void) {
        guard repository?.root == request.expected.root, canWrite else { return }
        sheet = nil
        mutate(title, operation: operation)
    }
    func conflictDraftKey(_ request: AdvancedRequest, path: GitPath) -> String {
        request.expected.root.path + "\0" + path.value
    }
    func saveResolution(_ request: AdvancedRequest, review: ConflictReview, text: String,
                        delete: Bool, stage: Bool, allowMarkers: Bool) {
        let key = conflictDraftKey(request, path: review.path)
        guard retainEditDraft(key, text: text) else { return }
        performAdvanced(request, title: stage ? "Saving and staging conflict resolution…" : "Saving conflict worktree…") { repo in
            try await repo.resolveConflict(review, resolution: delete ? .delete : .text(text), stage: stage, allowMarkers: allowMarkers)
            await MainActor.run { _ = self.editDrafts.removeValue(forKey: key) }
        }
    }
    func retainEditDraft(_ key: String, text: String) -> Bool {
        let retained = editDrafts.filter { $0.key != key }.values.reduce(0) { $0 + $1.utf8.count }
        guard retained + text.utf8.count <= 16 * 1024 * 1024 else {
            show(GitError.invalidInput("Edit drafts reached the 16 MiB session budget. Finish or explicitly discard another retained draft first."), title: "Draft capacity reached"); return false
        }
        editDrafts[key] = text
        return true
    }
    func rewordDraftKey(_ request: AdvancedRequest) -> String {
        request.expected.root.path + "\0reword\0" + (request.expected.head ?? "unknown")
    }
    func performAmend(_ request: AdvancedRequest, review: OperationReview, message: String) {
        let key = rewordDraftKey(request)
        guard retainEditDraft(key, text: message) else { return }
        performAdvanced(request, title: "Amending reviewed rebase commit…") { repo in
            try await repo.amendRebase(review, message: message)
            await MainActor.run { _ = self.editDrafts.removeValue(forKey: key) }
        }
    }
}
