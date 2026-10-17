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
/// Reflog positions are only stable while HEAD stays at the same commit. The cursor
/// captures that commit so an older page cannot silently duplicate or skip entries.
public struct ReflogCursor: Sendable {
    let head: String?
    let offset: Int
}
public struct ReflogPage: Sendable {
    public let entries: [ReflogEntry]
    public let nextCursor: ReflogCursor?
    public var hasMore: Bool { nextCursor != nil }
}
public struct FileRevision: Identifiable, Sendable {
    public let commit: GitCommit
    public let path: GitPath
    public var id: String { commit.oid }
}
/// File history pages over one immutable anchor commit, so a later page cannot drift.
public struct FileHistoryCursor: Sendable {
    let oid: String
    let path: GitPath
    let offset: Int
}
public struct FileHistoryPage: Sendable {
    public let entries: [FileRevision]
    public let nextCursor: FileHistoryCursor?
    public var hasMore: Bool { nextCursor != nil }
}
public struct CommitComparison: Sendable {
    public let from: String
    public let to: String?
    public let files: [CommitFile]
    public let patch: String
}
extension GitRepository {
    public func reflog(after cursor: ReflogCursor? = nil) async throws -> ReflogPage {
        try await gate.withPermit {
            // Capture before reading so a HEAD move during the read is detectable, not baked into the next page.
            let head = try await headOID()
            let offset: Int
            if let cursor {
                guard cursor.offset >= 0, cursor.offset <= 1_000_000 else { throw GitError.malformedOutput("Invalid reflog offset.") }
                guard cursor.head == head else { throw GitError.staleRepository }
                offset = cursor.offset
            } else { offset = 0 }
            let output = try await command(["reflog", "show", "-z", "--skip=\(offset)",
                "--max-count=\(Self.queryPageSize + 1)", "--format=%H%x00%gD%x00%gs", "HEAD"])
            let fields = try GitParsers.terminatedFields(output.stdout)
            guard fields.count.isMultiple(of: 3) else { throw GitError.malformedOutput("Incomplete reflog records.") }
            var entries: [ReflogEntry] = []
            for i in stride(from: 0, to: fields.count, by: 3) {
                let oid = try GitParsers.string(fields[i]), selector = try GitParsers.string(fields[i + 1])
                guard GitParsers.isOID(oid), selector.hasPrefix("HEAD@{") else { throw GitError.malformedOutput("Invalid reflog identity.") }
                entries.append(ReflogEntry(oid: oid, selector: selector, message: try GitParsers.string(fields[i + 2])))
            }
            guard try await headOID() == head else { throw GitError.staleRepository }
            let page = Array(entries.prefix(Self.queryPageSize))
            let next = entries.count > Self.queryPageSize
                ? ReflogCursor(head: head, offset: offset + page.count) : nil
            return ReflogPage(entries: page, nextCursor: next)
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
    public func fileHistory(at oid: String, path: GitPath, after cursor: FileHistoryCursor? = nil) async throws -> FileHistoryPage {
        guard GitParsers.isOID(oid) else { throw GitError.staleRepository }
        let offset: Int
        if let cursor {
            guard cursor.oid == oid, cursor.path == path else {
                throw GitError.malformedOutput("File-history cursor belongs to another query.")
            }
            guard cursor.offset >= 0, cursor.offset <= 1_000_000 else { throw GitError.malformedOutput("Invalid file-history offset.") }
            offset = cursor.offset
        } else { offset = 0 }
        return try await gate.withPermit {
            let data = try await command(["log", "--follow", "--skip=\(offset)", "--max-count=\(Self.queryPageSize + 1)", "--name-status", "-z",
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
            let page = Array(entries.prefix(Self.queryPageSize))
            let next = entries.count > Self.queryPageSize
                ? FileHistoryCursor(oid: oid, path: path, offset: offset + page.count) : nil
            return FileHistoryPage(entries: page, nextCursor: next)
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
