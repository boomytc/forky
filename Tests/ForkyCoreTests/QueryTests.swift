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
    @Test func immutableAndWorktreeComparisonAreDistinct() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repo = try await f.repository(), head = try #require(try await repo.snapshot().head)
        try f.write("README.md", "working\n")
        #expect(try await repo.compare(from: head, to: head).files.isEmpty)
        #expect(try await repo.compare(from: head, to: nil).files.count == 1)
        #expect(try await repo.overview().contains("Forky Test"))
    }
}
