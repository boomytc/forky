import Foundation
import CryptoKit

public struct RepositoryOperation: Sendable {
    public enum Kind: String, Sendable { case merge, cherryPick = "cherry-pick", revert, rebase, unknown }
    public let kind: Kind?
    public let token: String
    public let canAmend: Bool
    public let detail: String?
    public let pendingTodo: String?
    public let pendingRevisions: [String]
    public let supportedTodo: Bool
    public let restoreOID: String?
    public let branchRef: String?
    public var isActive: Bool { kind != nil }
}

public enum OperationStep: String, CaseIterable, Sendable { case resume = "continue", skip, abort }
public enum CommitAction: String, Sendable { case cherryPick = "Cherry-pick", revert = "Revert" }
public enum RebaseCommand: String, CaseIterable, Sendable {
    case pick, edit, squash, fixup, drop
    public var title: String { self == .edit ? "edit / reword" : rawValue }
}
public struct RebaseItem: Identifiable, Sendable {
    public let commit: GitCommit
    public var command: RebaseCommand
    public var id: String { commit.oid }
}
public struct RebasePlan: Sendable {
    let root: URL
    let expected: RepositorySnapshot
    public let baseOID: String
    public let items: [RebaseItem]
}

extension GitRepository {
    func readOperation(gitDirectory: URL, head: String?) throws -> RepositoryOperation {
        var bytes = Data(), detected: [RepositoryOperation.Kind] = [], amend = false, rebaseMarkers = 0
        let groups: [(RepositoryOperation.Kind, String, [String])] = [
            (.merge, "MERGE_HEAD", []), (.cherryPick, "CHERRY_PICK_HEAD", []), (.revert, "REVERT_HEAD", []),
            (.rebase, "rebase-merge", ["head-name", "orig-head", "onto", "git-rebase-todo", "done", "amend", "stopped-sha"]),
            (.rebase, "rebase-apply", ["head-name", "orig-head", "onto", "next", "last"]),
            (.unknown, "sequencer", ["head", "abort-safety", "todo"])
        ]
        var problem: String?, pendingTodo: String?, restoreOID: String?, branchRef: String?
        func append(_ label: String, _ value: Data) {
            bytes.append(Data((label + "\0" + String(value.count) + "\0").utf8)); bytes.append(value)
        }
        for (kind, name, children) in groups {
            let url = gitDirectory.appendingPathComponent(name)
            do {
                let state = try SafeWorktree.metadata(at: url)
                guard let state else { continue }
                guard state.isDirectory == !children.isEmpty else { throw GitError.invalidInput("Unexpected Git operation marker type: " + name) }
                detected.append(kind)
                if kind == .rebase { rebaseMarkers += 1 }
                append(name, Data())
                if children.isEmpty {
                    guard let value = try SafeWorktree.readAbsolute(url, limit: 1024 * 1024) else { throw GitError.staleRepository }
                    let oids = try GitParsers.string(value).split(separator: "\n")
                    guard !oids.isEmpty, oids.allSatisfy({ GitParsers.isOID(String($0)) }), kind == .merge || oids.count == 1 else {
                        throw GitError.malformedOutput("Invalid operation marker: " + name)
                    }
                    append(name, value)
                } else {
                    var values: [String: Data] = [:]
                    for child in children {
                        if let value = try SafeWorktree.readAbsolute(url.appendingPathComponent(child), limit: 1024 * 1024) {
                            values[child] = value; append(child, value)
                        }
                    }
                    if kind == .rebase {
                        for required in ["head-name", "orig-head", "onto"] {
                            guard let value = values[required] else { throw GitError.malformedOutput("Incomplete rebase state (or unsupported git-am): " + name) }
                            let text = try GitParsers.string(value).trimmingCharacters(in: .newlines)
                            if required == "head-name" {
                                guard !text.utf8.contains(0), text == "detached HEAD" || text.hasPrefix("refs/heads/") else { throw GitError.malformedOutput("Invalid rebase branch identity.") }
                                branchRef = text
                            } else {
                                guard GitParsers.isOID(text) else { throw GitError.malformedOutput("Invalid rebase identity.") }
                            }
                        }
                    }
                    if let value = values["git-rebase-todo"] ?? values["todo"] { pendingTodo = try GitParsers.string(value) }
                    if let value = values["orig-head"] ?? (name == "sequencer" ? values["head"] : nil) {
                        let oid = try GitParsers.string(value).trimmingCharacters(in: .newlines)
                        guard GitParsers.isOID(oid) else { throw GitError.malformedOutput("Invalid operation restore identity.") }
                        restoreOID = oid
                    }
                    if name == "rebase-merge", let value = values["amend"] {
                        guard GitParsers.isOID(try GitParsers.string(value).trimmingCharacters(in: .newlines)) else { throw GitError.malformedOutput("Invalid rebase edit identity.") }
                        amend = true
                    }
                }
            } catch { detected.append(.unknown); problem = error.localizedDescription }
        }
        var kind: RepositoryOperation.Kind?
        if problem != nil { kind = .unknown }
        else if rebaseMarkers > 1 || (!detected.contains(.rebase) && Set(detected.filter { $0 != .unknown }).count > 1) {
            kind = .unknown; problem = "Contradictory Git operation markers. Inspect repository state externally."
        }
        else if detected.contains(.rebase) { kind = .rebase }
        else if detected.contains(.cherryPick) { kind = .cherryPick }
        else if detected.contains(.revert) { kind = .revert }
        else if detected.contains(.merge) { kind = .merge }
        else if detected.contains(.unknown) { kind = .unknown }
        else { kind = nil }
        if kind == .merge {
            do {
                if let value = try SafeWorktree.readAbsolute(gitDirectory.appendingPathComponent("ORIG_HEAD"), limit: 1024 * 1024) {
                    let oid = try GitParsers.string(value).trimmingCharacters(in: .newlines)
                    guard GitParsers.isOID(oid) else { throw GitError.malformedOutput("Invalid original merge HEAD.") }
                    restoreOID = oid; append("ORIG_HEAD", value)
                }
            } catch { kind = .unknown; problem = error.localizedDescription }
        }
        if kind == .cherryPick || kind == .revert { restoreOID = restoreOID ?? head }
        var pending: [String] = [], supported = true
        for row in (pendingTodo ?? "").components(separatedBy: "\n") {
            let fields = row.utf8.split(whereSeparator: { $0 == 32 || $0 == 9 || $0 == 13 }).map { String(decoding: $0, as: UTF8.self) }
            guard let command = fields.first, command.utf8.first != 35 else { continue }
            if command == "noop" { continue }
            guard ["pick", "p", "edit", "e", "squash", "s", "fixup", "f", "drop", "d"].contains(String(command)),
                  fields.count >= 2, (4...64).contains(fields[1].utf8.count),
                  fields[1].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { supported = false; continue }
            if command != "drop" && command != "d" { pending.append(String(fields[1])) }
        }
        return RepositoryOperation(kind: kind, token: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                                   canAmend: kind == .rebase && amend, detail: problem, pendingTodo: pendingTodo,
                                   pendingRevisions: pending, supportedTodo: supported, restoreOID: restoreOID, branchRef: branchRef)
    }

    func checkReviewed(_ expected: RepositorySnapshot, clean: Bool = false, allowOperation: Bool = false) async throws -> RepositorySnapshot {
        let fresh = try await readSnapshot()
        guard expected.root == root, expected.head == fresh.head, expected.branch == fresh.branch,
              expected.indexFingerprint == fresh.indexFingerprint,
              expected.operation.token == fresh.operation.token, expected.operation.kind == fresh.operation.kind else { throw GitError.staleRepository }
        guard allowOperation || !fresh.operationInProgress else { throw GitError.operationInProgress }
        if clean && !fresh.changes.isEmpty { throw GitError.dirtyWorktree }
        return fresh
    }
}
