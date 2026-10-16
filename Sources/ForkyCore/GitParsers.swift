import Foundation

public enum GitParsers {
    public static func string(_ bytes: Data) throws -> String {
        guard let value = String(data: bytes, encoding: .utf8) else { throw GitError.unsupportedPath }
        return value
    }

    public static func terminatedFields(_ data: Data) throws -> [Data] {
        if data.isEmpty { return [] }
        guard data.last == 0 else { throw GitError.malformedOutput("Missing NUL terminator.") }
        return data.dropLast().split(separator: 0, omittingEmptySubsequences: false).map(Data.init)
    }

    public static func status(_ data: Data) throws -> [FileChange] {
        let fields = try terminatedFields(data)
        var result: [FileChange] = []
        var i = 0
        let allowed = Set(" MADRCUT?!")
        while i < fields.count {
            let record = fields[i]
            guard record.count >= 4, record[record.startIndex + 2] == 32 else {
                throw GitError.malformedOutput("Invalid porcelain v1 record.")
            }
            let prefix = Array(record.prefix(2))
            let index = Character(UnicodeScalar(prefix[0]))
            let worktree = Character(UnicodeScalar(prefix[1]))
            guard allowed.contains(index), allowed.contains(worktree) else {
                throw GitError.malformedOutput("Unknown porcelain status.")
            }
            let path = try GitPath(string(Data(record.dropFirst(3))))
            var original: GitPath?
            if index == "R" || index == "C" || worktree == "R" || worktree == "C" {
                i += 1
                guard i < fields.count else { throw GitError.malformedOutput("Missing rename source.") }
                original = try GitPath(string(fields[i]))
            }
            result.append(FileChange(path: path, originalPath: original, index: index, worktree: worktree))
            i += 1
        }
        guard Set(result.map(\.id)).count == result.count else {
            throw GitError.malformedOutput("Duplicate status paths.")
        }
        return result
    }

    public static func commits(_ data: Data) throws -> [GitCommit] {
        let fields = try terminatedFields(data)
        guard fields.count.isMultiple(of: 7) else { throw GitError.malformedOutput("Invalid log record framing.") }
        return try stride(from: 0, to: fields.count, by: 7).map { i in
            let values = try fields[i ..< i + 7].map(string)
            guard isOID(values[0]), values[1].split(separator: " ").allSatisfy({ isOID(String($0)) }),
                  let timestamp = TimeInterval(values[4]), timestamp.isFinite else {
                throw GitError.malformedOutput("Invalid commit identity or timestamp.")
            }
            return GitCommit(oid: values[0], parents: values[1].split(separator: " ").map(String.init),
                             author: values[2], email: values[3], date: Date(timeIntervalSince1970: timestamp),
                             subject: values[5], body: values[6])
        }
    }

    public static func references(_ data: Data) throws -> [GitReference] {
        let result = try string(data).split(separator: "\n").map { line -> GitReference in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 7, fields[6].isEmpty, isOID(fields[1]),
                  ["*", " "].contains(fields[2]),
                  ["commit", "tag", "tree", "blob"].contains(fields[4]),
                  fields[3].isEmpty || isOID(fields[3]),
                  ["", "commit", "tag", "tree", "blob"].contains(fields[5]),
                  fields[3].isEmpty == fields[5].isEmpty else {
                throw GitError.malformedOutput("Invalid ref record.")
            }
            let kind: GitReference.Kind
            let prefix: String
            if fields[0].hasPrefix("refs/heads/") { kind = .localBranch; prefix = "refs/heads/" }
            else if fields[0].hasPrefix("refs/remotes/") { kind = .remoteBranch; prefix = "refs/remotes/" }
            else if fields[0].hasPrefix("refs/tags/") { kind = .tag; prefix = "refs/tags/" }
            else { throw GitError.malformedOutput("Unsupported ref namespace.") }
            guard fields[0].count > prefix.count else { throw GitError.malformedOutput("Empty ref name.") }
            let commitOID = fields[4] == "commit" ? fields[1] : (fields[5] == "commit" ? fields[3] : nil)
            return GitReference(fullName: fields[0], name: String(fields[0].dropFirst(prefix.count)),
                                objectOID: fields[1], commitOID: commitOID, kind: kind, isCurrent: fields[2] == "*")
        }
        guard Set(result.map(\.id)).count == result.count else { throw GitError.malformedOutput("Duplicate refs.") }
        return result
    }

    public static func commitFiles(_ data: Data) throws -> [CommitFile] {
        let fields = try terminatedFields(data)
        var result: [CommitFile] = []
        var i = 0
        while i < fields.count {
            let status = try string(fields[i])
            guard let code = status.first, "AMDRCTUXB".contains(code), i + 1 < fields.count else {
                throw GitError.malformedOutput("Invalid name-status record.")
            }
            i += 1
            let first = try GitPath(string(fields[i]))
            var path = first
            var original: GitPath?
            if code == "R" || code == "C" {
                guard i + 1 < fields.count else { throw GitError.malformedOutput("Missing rename destination.") }
                original = first
                i += 1
                path = try GitPath(string(fields[i]))
            }
            result.append(CommitFile(path: path, originalPath: original, status: status))
            i += 1
        }
        return result
    }

    public static func isOID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
