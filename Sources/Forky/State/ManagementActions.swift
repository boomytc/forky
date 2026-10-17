import Foundation
import ForkyCore

enum ManagementTool: String, CaseIterable, Identifiable {
    case amend = "Amend / Reword HEAD"
    case references = "Branches, Tags & Remotes"
    case merge = "Merge into Current Branch"
    case worktrees = "Worktree Manager", settings = "Repository Settings & Git"
    case stash = "Selected Stash / Rename / Pop", sync = "Selected Remotes & Ref Push"
    case patches = "Import / Export Patch", submodules = "Submodule Manager", lfs = "Git LFS & Locks"
    case images = "Image Comparison", reset = "Reset Current Branch (Reviewed)", integrate = "Integrate Fetched Upstream"
    case gitflow = "Gitflow (Bring Your Own)"
    case bisect = "Bisect", external = "Trusted Tools / Optional AI"
    var isBasic: Bool { [.amend, .references, .merge].contains(self) }
    var id: Self { self }
}
struct ManagementRequest: Identifiable {
    let id = UUID()
    let repository: GitRepository
    let expected: RepositorySnapshot
    let initialTool: ManagementTool
    let commitOID: String?
    let path: GitPath?
}
extension RepositoryStore {
    func performTool(_ request: ManagementRequest, title: String,
                     operation: @escaping @Sendable (GitRepository) async throws -> String) {
        performManagement(request, title: title) { [weak self] repo in
            let result = try await operation(repo)
            await MainActor.run {
                self?.lastToolBody = result
                self?.lastToolOutput = title + "\n" + request.expected.root.path + "\n\n" + result
            }
        }
    }
    func requestManagement(_ tool: ManagementTool = .references) {
        guard canWrite, let repository, let snapshot else { return }
        sheet = .management(ManagementRequest(repository: repository, expected: snapshot, initialTool: tool,
                                               commitOID: selectedCommit?.oid ?? snapshot.head,
                                               path: selectedChange.flatMap { try? GitPath($0.path) } ?? commitFiles.first { $0.id == selectedCommitFileID }?.path))
    }
    func performManagement(_ request: ManagementRequest, title: String,
                           operation: @escaping @Sendable (GitRepository) async throws -> Void) {
        guard repository?.root == request.expected.root else {
            show(GitError.staleRepository, title: "Repository changed"); return
        }
        guard canWrite else { return }
        sheet = nil
        mutate(title, operation: operation)
    }
}
