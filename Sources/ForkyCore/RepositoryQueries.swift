import Foundation

public enum HistorySearch: String, CaseIterable, Sendable {
    case message = "Message", author = "Author", committer = "Committer", path = "Path", content = "Changed text", oid = "SHA lookup"
}
public struct HistoryOptions: Equatable, Sendable {
    public var firstParent = false
    public var search = HistorySearch.message
    public var after: Date?
    public var before: Date?
    public init() {}
}
public struct ReflogEntry: Identifiable, Sendable {
    public let oid: String, selector: String, message: String
    public var id: String { selector + ":" + oid }
}
public struct ReflogPage: Sendable {
    public let entries: [ReflogEntry]
    public let hasMore: Bool
}
public struct FileRevision: Identifiable, Sendable {
    public let commit: GitCommit
    public let path: GitPath
    public var id: String { commit.oid }
}
public struct FileHistoryPage: Sendable {
    public let entries: [FileRevision]
    public let hasMore: Bool
}
public struct CommitComparison: Sendable {
    public let from: String
    public let to: String?
    public let files: [CommitFile]
    public let patch: String
}
extension GitRepository {
    public func reflog() async throws -> ReflogPage {
        try await gate.withPermit {
            let fields = try GitParsers.terminatedFields(try await command(["reflog", "show", "-z",
                "--max-count=201", "--format=%H%x00%gD%x00%gs", "HEAD"]).stdout)
            guard fields.count.isMultiple(of: 3) else { throw GitError.malformedOutput("Incomplete reflog records.") }
            var entries: [ReflogEntry] = []
            for i in stride(from: 0, to: fields.count, by: 3) {
                let oid = try GitParsers.string(fields[i]), selector = try GitParsers.string(fields[i + 1])
                guard GitParsers.isOID(oid), selector.hasPrefix("HEAD@{") else { throw GitError.malformedOutput("Invalid reflog identity.") }
                entries.append(ReflogEntry(oid: oid, selector: selector, message: try GitParsers.string(fields[i + 2])))
            }
            return ReflogPage(entries: Array(entries.prefix(200)), hasMore: entries.count > 200)
        }
    }
    public func compare(from: String, to: String?, path: GitPath? = nil) async throws -> CommitComparison {
        guard GitParsers.isOID(from), to.map(GitParsers.isOID) ?? true else { throw GitError.staleRepository }
        return try await gate.withPermit {
            let revisions = [from] + (to.map { [$0] } ?? [])
            let paths = path.map { [$0.value] } ?? []
            let common = ["--no-ext-diff", "--no-textconv", "--no-renames"] + revisions + ["--"] + paths
            let files = try GitParsers.commitFiles(try await command(["diff", "--name-status", "-z"] + common, literalPaths: true).stdout)
            let patch = try GitParsers.string(try await command(["diff", "--no-color"] + common, literalPaths: true).stdout)
            return CommitComparison(from: from, to: to, files: files, patch: patch)
        }
    }
    public func fileHistory(at oid: String, path: GitPath) async throws -> FileHistoryPage {
        guard GitParsers.isOID(oid) else { throw GitError.staleRepository }
        return try await gate.withPermit {
            let data = try await command(["log", "--follow", "--max-count=201", "--name-status", "-z",
                "--no-ext-diff", "--no-textconv", "--format=%x00%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00%b",
                oid, "--", path.value], literalPaths: true).stdout
            let fields = data.split(separator: 0, omittingEmptySubsequences: false).map(Data.init)
            var i = 0, current = path, entries: [FileRevision] = []
            while i < fields.count {
                while i < fields.count && fields[i].isEmpty { i += 1 }
                if i == fields.count { break }
                guard i + 7 <= fields.count else { throw GitError.malformedOutput("Incomplete file history.") }
                var header = Data()
                for field in fields[i..<(i + 7)] { header.append(field); header.append(0) }
                guard let commit = try GitParsers.commits(header).first else { throw GitError.malformedOutput("Missing file-history commit.") }
                i += 7
                let pathAtCommit = current
                while i < fields.count && !fields[i].isEmpty {
                    var status = try GitParsers.string(fields[i]); i += 1
                    if status.utf8.first == 10 { status.removeFirst() }
                    guard let code = status.first, "AMDRCTUXB".contains(code), i < fields.count else {
                        throw GitError.malformedOutput("Invalid file-history status.")
                    }
                    let first = try GitPath(GitParsers.string(fields[i])); i += 1
                    if code == "R" || code == "C" {
                        guard i < fields.count else { throw GitError.malformedOutput("Missing rename path.") }
                        let second = try GitPath(GitParsers.string(fields[i])); i += 1
                        if code == "R" && second == current { current = first }
                    }
                }
                entries.append(FileRevision(commit: commit, path: pathAtCommit))
            }
            return FileHistoryPage(entries: Array(entries.prefix(200)), hasMore: entries.count > 200)
        }
    }
    public func text(at oid: String, path: GitPath) async throws -> String {
        guard GitParsers.isOID(oid) else { throw GitError.staleRepository }
        return try await gate.withPermit {
            try GitParsers.string(try await command(["show", oid + ":" + path.value]).stdout)
        }
    }
    public func overview() async throws -> String {
        try await gate.withPermit {
            let counts = try await command(["rev-list", "--all", "--count"]).stdout
            let authors = try await command(["shortlog", "-sne", "--all", "--no-merges"]).stdout
            let objects = try await command(["count-objects", "-vH"]).stdout
            return "Reachable commits (local refs)\n" + (try GitParsers.string(counts)) +
                "\nAuthors (non-merge commits)\n" + (try GitParsers.string(authors)) +
                "\nObject storage\n" + (try GitParsers.string(objects))
        }
    }
}
