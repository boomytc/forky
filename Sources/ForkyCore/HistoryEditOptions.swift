import Foundation

public struct CommitApplyOptions: Sendable {
    public var mainline: Int?
    public var createCommit = true
    public var appendSource = false
    public init() {}
}
public struct RebaseOptions: Sendable {
    public var updateReferences = false
    public var backupTag: String?
    public init() {}
}
