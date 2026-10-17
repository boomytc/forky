import Foundation
import ForkyCore

enum QueryTool: String, CaseIterable, Identifiable {
    case reflog = "Reflog / Recover Commit", fileHistory = "File History", compare = "Compare Revisions", overview = "Repository Overview", statistics = "Commit Statistics"
    var id: Self { self }
}
struct QueryRequest: Identifiable {
    let id = UUID()
    let tool: QueryTool
    let repository: GitRepository
    let expected: RepositorySnapshot
    let oid: String?
    let path: GitPath?
}
extension RepositoryStore {
    func requestQuery(_ tool: QueryTool, path: GitPath? = nil, oid: String? = nil) {
        guard let repository, let snapshot, !isMutating else { return }
        let selectedPath = path ?? selectedChange.flatMap { try? GitPath($0.path) }
            ?? commitFiles.first { $0.id == selectedCommitFileID }?.path
        sheet = .query(QueryRequest(tool: tool, repository: repository, expected: snapshot,
                                    oid: oid ?? selectedCommit?.oid ?? snapshot.head, path: selectedPath))
    }
}
