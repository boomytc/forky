import Foundation
import ForkyCore

enum RemoteAction: String { case fetch, pull, push, add }
struct RemoteRequest: Identifiable {
    let id = UUID()
    let action: RemoteAction
    let expected: RepositorySnapshot
    let initialRemote: String?
}
enum StashAction { case save, apply(GitStash), drop(GitStash) }
struct StashRequest: Identifiable {
    let id = UUID()
    let action: StashAction
    let expected: RepositorySnapshot
}
enum CreationKind: String { case clone, initialize }
enum WorkspaceSheet: Identifiable {
    case branch(BranchRequest), remote(RemoteRequest), stash(StashRequest), creation(CreationKind), activity, advanced(AdvancedRequest)
    var id: String {
        switch self {
        case .branch(let request): "branch:" + request.id.uuidString
        case .remote(let request): "remote:" + request.id.uuidString
        case .stash(let request): "stash:" + request.id.uuidString
        case .creation(let kind): kind.rawValue
        case .activity: "activity"
        case .advanced(let request): "advanced:" + request.id.uuidString
        }
    }
}
enum OperationPhase { case idle, running, reconciling }
struct OperationRecord: Identifiable {
    enum Outcome { case running, succeeded, failed, cancelled }
    let id = UUID()
    let title: String
    let repositoryRoot: URL?
    let started: Date
    var finished: Date?
    var outcome: Outcome = .running
    var detail = ""
}
