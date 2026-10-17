import Foundation
import Testing
@testable import ForkyCore

struct QueryTests {
    @Test func reflogRetainsRepeatedCommitEntries() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        try await f.git(["branch", "other"]); try await f.git(["switch", "other"]); try await f.git(["switch", "main"])
        let page = try await f.repository().reflog()
        #expect(page.entries.count >= 3)
        #expect(Set(page.entries.map(\.id)).count == page.entries.count)
    }
    @Test func literalSearchModesAndOptionsBelongToCursor() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repo = try await f.repository()
        var options = HistoryOptions(); options.search = .author
        #expect(try await repo.history(query: "Forky Test", options: options).commits.count == 1)
        options.search = .path
        #expect(try await repo.history(query: "README.md", options: options).commits.count == 1)
        options.search = .content
        #expect(try await repo.history(query: "# Hello", options: options).commits.count == 1)
        options.search = .oid
        let head = try #require(try await repo.snapshot().head)
        #expect(try await repo.history(query: String(head.prefix(9)), options: options).commits.map(\.oid) == [head])
    }
    @Test func fileHistoryFollowsRenameWithoutInventingPath() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        try await f.git(["mv", "README.md", "renamed\nñ.md"]); try await f.git(["commit", "-m", "Rename"])
        try f.write("renamed\nñ.md", "next\n"); try await f.git(["commit", "-am", "Update"])
        let repo = try await f.repository(), head = try #require(try await repo.snapshot().head)
        let page = try await repo.fileHistory(at: head, path: GitPath("renamed\nñ.md"))
        #expect(page.entries.count == 3)
        #expect(page.entries.last?.path.value == "README.md")
        #expect(page.entries.first?.path.value == "renamed\nñ.md")
        let old = try #require(page.entries.last)
        #expect(try await repo.text(at: old.commit.oid, path: old.path) == "# Hello\n")
    }
    @Test func reflogPagesWithoutGapsOrDuplicates() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let tree = String(decoding: try await f.git(["rev-parse", "HEAD^{tree}"]).stdout, as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        var tip = String(decoding: try await f.git(["rev-parse", "HEAD"]).stdout, as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        for number in 1...204 {
            tip = String(decoding: try await f.git(["commit-tree", tree, "-p", tip, "-m", "Reflog \(number)"]).stdout,
                         as: UTF8.self).trimmingCharacters(in: .newlines)
            try await f.git(["update-ref", "refs/heads/main", tip])
        }
        let repository = try await f.repository()
        let first = try await repository.reflog()
        #expect(first.entries.count == GitRepository.queryPageSize)
        let cursor = try #require(first.nextCursor)
        let second = try await repository.reflog(after: cursor)
        #expect(second.entries.count == 5 && !second.hasMore)
        let all = first.entries + second.entries
        #expect(all.count == 205)
        #expect(Set(all.map(\.id)).count == 205)
        #expect(all.map(\.selector) == (0..<205).map { "HEAD@{\($0)}" })
        // A moved HEAD invalidates offsets, so a captured cursor must refuse instead of repeating entries.
        try await f.git(["commit", "--allow-empty", "-m", "Between pages"])
        await #expect(throws: GitError.self) { try await repository.reflog(after: cursor) }
    }
    @Test func fileHistoryPagesWithoutGapsOrDuplicates() async throws {
        let f = try await GitFixture(); defer { f.remove() }
        try f.write("history.txt", "0\n")
        try await f.git(["add", "--", "history.txt"])
        try await f.git(["commit", "-qm", "Revision 0"])
        for number in 1...204 {
            try f.write("history.txt", "\(number)\n")
            try await f.git(["commit", "-aqm", "Revision \(number)"])
        }
        let repository = try await f.repository(), head = try #require(try await repository.snapshot().head)
        let path = try GitPath("history.txt")
        let first = try await repository.fileHistory(at: head, path: path)
        #expect(first.entries.count == GitRepository.queryPageSize)
        let cursor = try #require(first.nextCursor)
        let second = try await repository.fileHistory(at: head, path: path, after: cursor)
        #expect(second.entries.count == 5 && !second.hasMore)
        let all = first.entries + second.entries
        #expect(all.count == 205 && Set(all.map(\.id)).count == 205)
        #expect(all.first?.commit.subject == "Revision 204")
        #expect(all.last?.commit.subject == "Revision 0")
        await #expect(throws: GitError.self) {
            try await repository.fileHistory(at: head, path: try GitPath("other.txt"), after: cursor)
        }
    }
    @Test func immutableAndWorktreeComparisonAreDistinct() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repo = try await f.repository(), head = try #require(try await repo.snapshot().head)
        try f.write("README.md", "working\n")
        #expect(try await repo.compare(from: head, to: head).files.isEmpty)
        #expect(try await repo.compare(from: head, to: nil).files.count == 1)
        #expect(try await repo.overview().contains("Forky Test"))
    }
}
