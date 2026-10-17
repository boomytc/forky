import ForkyCore

struct HistoryLocation {
    let section: NavigationSection
    let query: String
    let options: HistoryOptions
    let commits: [GitCommit]
    let cursor: HistoryCursor?
    let graph: CommitGraph
    let decorations: [String: [GitReference]]
    let commitID: String?
    let filePath: GitPath?
    let parentOID: String?
    let change: ChangeSelection?
    let more: Bool
    var messageBytes: Int { commits.reduce(0) { $0 + $1.subject.utf8.count + $1.body.utf8.count } }
}
