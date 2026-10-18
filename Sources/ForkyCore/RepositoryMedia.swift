import Foundation

public struct ImageComparison: Sendable {
    public let before: Data?
    public let after: Data?
}
extension GitRepository {
    public func imageComparison(from: String, to: String?, path: GitPath) async throws -> ImageComparison {
        guard GitParsers.isOID(from), to.map(GitParsers.isOID) ?? true else { throw GitError.staleRepository }
        return try await gate.withPermit {
            func blob(_ oid: String) async throws -> Data? {
                let record = try await command(["ls-tree", "-z", oid, "--", path.value], literalPaths: true).stdout
                if record.isEmpty { return nil } // exact literal lookup examined this path
                guard record.split(separator: 0).count == 1, let tab = record.firstIndex(of: 9) else { throw GitError.malformedOutput("Invalid image tree entry.") }
                let fields = try GitParsers.string(Data(record[..<tab])).split(separator: " ")
                guard fields.count == 3, ["100644", "100755"].contains(String(fields[0])), fields[1] == "blob",
                      GitParsers.isOID(String(fields[2])) else { throw GitError.invalidInput("Image preview needs a regular blob, not a symlink/tree/submodule.") }
                return try await command(["cat-file", "blob", String(fields[2])], outputLimit: Self.lfsObjectReadLimit).stdout
            }
            let before = try await blob(from)
            let after: Data?
            if let to { after = try await blob(to) }
            else { after = try SafeWorktree.read(root: root, path: path, limit: Self.lfsObjectReadLimit) }
            return ImageComparison(before: before, after: after)
        }
    }
}
public struct CountBucket: Identifiable, Sendable {
    public let key: String
    public let count: Int
    public var id: String { key }
}
public struct RepositoryStatistics: Sendable {
    public let total: Int
    public let months: [CountBucket]
    public let authors: [CountBucket]
    public let weekdays: [CountBucket]
}
extension GitRepository {
    public func statistics(after: Date? = nil, before: Date? = nil) async throws -> RepositoryStatistics {
        try await gate.withPermit {
            let refs = try await readReferences(), head = try await headOID()
            let roots = Array(Set(refs.compactMap(\.commitOID) + (head.map { [$0] } ?? []))).sorted()
            guard !roots.isEmpty else { return RepositoryStatistics(total: 0, months: [], authors: [], weekdays: []) }
            var flags: [String] = []
            if let after { flags += ["--since=" + after.ISO8601Format()] }
            if let before { flags += ["--until=" + before.ISO8601Format()] }
            let bytes = try await command(["log", "--format=%at%x00%an%x00%ae", "-z"] + flags + roots + ["--"]).stdout
            let fields = try GitParsers.terminatedFields(bytes)
            guard fields.count.isMultiple(of: 3) else { throw GitError.malformedOutput("Incomplete statistics records.") }
            var months: [String: Int] = [:], authors: [String: Int] = [:], days: [String: Int] = [:]
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            for i in stride(from: 0, to: fields.count, by: 3) {
                guard let stamp = Double(try GitParsers.string(fields[i])), stamp.isFinite else { throw GitError.malformedOutput("Invalid commit date.") }
                let date = Date(timeIntervalSince1970: stamp), parts = calendar.dateComponents([.year, .month, .weekday], from: date)
                guard let year = parts.year, let month = parts.month, let weekday = parts.weekday else { throw GitError.malformedOutput("Unrepresentable commit date.") }
                let key = String(year) + "-" + (month < 10 ? "0" : "") + String(month)
                months[key, default: 0] += 1
                let person = try GitParsers.string(fields[i + 1]) + " <" + GitParsers.string(fields[i + 2]) + ">"
                authors[person, default: 0] += 1; days[String(weekday), default: 0] += 1
            }
            return RepositoryStatistics(total: fields.count / 3,
                months: months.sorted { $0.key < $1.key }.map { CountBucket(key: $0.key, count: $0.value) },
                authors: authors.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { CountBucket(key: $0.key, count: $0.value) },
                weekdays: (1...7).map { CountBucket(key: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][$0 - 1], count: days[String($0)] ?? 0) })
        }
    }
}
