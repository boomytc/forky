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

    public static func branches(_ data: Data) throws -> [GitBranch] {
        try string(data).split(separator: "\n").map { line in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard fields.count == 4, fields[3].isEmpty, isOID(String(fields[1])),
                  fields[0].hasPrefix("refs/heads/") || fields[0].hasPrefix("refs/remotes/") else {
                throw GitError.malformedOutput("Invalid ref record.")
            }
            let ref = String(fields[0])
            let remote = ref.hasPrefix("refs/remotes/")
            return GitBranch(fullName: ref, name: String(ref.dropFirst(remote ? 13 : 11)),
                             oid: String(fields[1]), isCurrent: fields[2] == "*", isRemote: remote)
        }
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
