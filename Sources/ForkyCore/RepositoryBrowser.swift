import Foundation

public struct GitTreeEntry: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case tree, blob, commit }
    let root: URL
    public let commitOID: String
    public let oid: String
    public let mode: String
    public let kind: Kind
    public let path: GitPath
    public var id: String { path.value }
    public var isSymlink: Bool { mode == "120000" }
}
public enum BlobPreview: Sendable {
    case text(String), binary(Int)
}
public struct BlameLine: Identifiable, Sendable {
    public let oid: String
    public let originalLine: Int
    public let line: Int
    public let author: String
    public let authorMail: String
    public let date: Date
    public let summary: String
    /// Git's original presentation; never used as a lookup path.
    public let sourceFilename: String
    public let text: String
    public var id: Int { line }
}

extension GitRepository {
    public func tree(in commit: GitCommit, directory: GitTreeEntry? = nil) async throws -> [GitTreeEntry] {
        guard GitParsers.isOID(commit.oid) else { throw GitError.staleRepository }
        if let directory {
            guard directory.root == root, directory.commitOID == commit.oid, directory.kind == .tree else { throw GitError.staleRepository }
        }
        return try await gate.withPermit {
            let output = try await command(["ls-tree", "-z", directory?.oid ?? commit.oid])
            var entries: [GitTreeEntry] = []
            for record in output.stdout.split(separator: 0) {
                guard let tab = record.firstIndex(of: 9) else { throw GitError.malformedOutput("Invalid tree record.") }
                let fields = try GitParsers.string(Data(record[..<tab])).split(separator: " ")
                let name = try GitParsers.string(Data(record[record.index(after: tab)...]))
                guard fields.count == 3, let kind = GitTreeEntry.Kind(rawValue: String(fields[1])),
                      ["040000", "100644", "100755", "120000", "160000"].contains(String(fields[0])),
                      GitParsers.isOID(String(fields[2])), !name.contains("/") else { throw GitError.malformedOutput("Invalid tree entry.") }
                let path = try GitPath((directory.map { $0.path.value + "/" } ?? "") + name)
                entries.append(GitTreeEntry(root: root, commitOID: commit.oid, oid: String(fields[2]),
                    mode: String(fields[0]), kind: kind, path: path))
            }
            return entries.sorted { lhs, rhs in
                if (lhs.kind == .tree) != (rhs.kind == .tree) { return lhs.kind == .tree }
                return lhs.path.value.localizedStandardCompare(rhs.path.value) == .orderedAscending
            }
        }
    }

    public func blob(_ entry: GitTreeEntry) async throws -> BlobPreview {
        guard entry.root == root, entry.kind == .blob, GitParsers.isOID(entry.oid) else { throw GitError.staleRepository }
        return try await gate.withPermit {
            let data = try await command(["cat-file", "blob", entry.oid]).stdout
            if !data.contains(0), let text = String(data: data, encoding: .utf8) { return .text(text) }
            return .binary(data.count)
        }
    }

    public func blame(_ entry: GitTreeEntry) async throws -> [BlameLine] {
        guard entry.root == root, entry.kind == .blob, !entry.isSymlink,
              GitParsers.isOID(entry.commitOID) else { throw GitError.invalidInput("Blame requires a regular file at a captured commit.") }
        return try await gate.withPermit {
            let data = try await command(["blame", "--line-porcelain", "--no-textconv", entry.commitOID, "--", entry.path.value], literalPaths: true).stdout
            return try Self.parseBlame(data)
        }
    }

    static func parseBlame(_ data: Data) throws -> [BlameLine] {
        if data.isEmpty { return [] }
        guard data.last == 10, !data.contains(0) else { throw GitError.malformedOutput("Incomplete blame response.") }
        let rows = try data.split(separator: 10, omittingEmptySubsequences: false).dropLast().map { try GitParsers.string(Data($0)) }
        var result: [BlameLine] = [], index = 0
        while index < rows.count {
            let header = rows[index].split(separator: " ")
            guard (3...4).contains(header.count), GitParsers.isOID(String(header[0])),
                  let original = Int(header[1]), original > 0, let line = Int(header[2]), line == result.count + 1 else {
                throw GitError.malformedOutput("Invalid blame line identity.")
            }
            index += 1
            var author: String?, mail: String?, timestamp: TimeInterval?, summary: String?, filename: String?
            while index < rows.count && rows[index].utf8.first != 9 {
                let bytes = rows[index].utf8
                if let space = bytes.firstIndex(of: 32) {
                    let key = String(decoding: bytes[..<space], as: UTF8.self)
                    let value = String(decoding: bytes[bytes.index(after: space)...], as: UTF8.self)
                    switch key {
                    case "author": author = value
                    case "author-mail": mail = value
                    case "author-time": timestamp = TimeInterval(value)
                    case "summary": summary = value
                    case "filename": filename = value
                    default: break
                    }
                }
                index += 1
            }
            guard index < rows.count, let author, let mail, let timestamp, timestamp.isFinite, let summary, let filename else { throw GitError.malformedOutput("Incomplete blame metadata.") }
            guard result.count < 20_000 else { throw GitError.invalidInput("Blame exceeds the 20,000-line preview budget.") }
            result.append(BlameLine(oid: String(header[0]), originalLine: original, line: line,
                                   author: author, authorMail: mail, date: Date(timeIntervalSince1970: timestamp), summary: summary, sourceFilename: filename, text: String(decoding: rows[index].utf8.dropFirst(), as: UTF8.self)))
            index += 1
        }
        return result
    }
}
