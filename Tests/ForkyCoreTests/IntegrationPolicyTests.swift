import Foundation
import Testing
@testable import ForkyCore

struct IntegrationPolicyTests {
    @Test func integrationBaseCapturesObservedReference() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repo = try await f.repository(), first = try #require(try await repo.snapshot().head)
        try await f.git(["branch", "other"])
        try f.write("README.md", "local\n"); try await f.git(["commit", "-am", "Local"])
        let snapshot = try await repo.snapshot(), target = try #require(snapshot.branches.first { $0.name == "other" })
        #expect(try await repo.integrationBase(onto: target, expected: snapshot).oid == first)
        try await f.git(["update-ref", "refs/heads/other", try #require(snapshot.head)])
        await #expect(throws: GitError.self) { try await repo.integrationBase(onto: target, expected: snapshot) }
    }
    @Test func updateRefsWithoutEligibleBranchesIsNotUnknown() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repo = try await f.repository(), first = try #require(try await repo.snapshot().head)
        try f.write("README.md", "two\n"); try await f.git(["commit", "-am", "Two"])
        let plan = try await repo.rebasePlan(after: first, expected: repo.snapshot())
        var rows = plan.items; rows[0].command = .edit
        var options = RebaseOptions(); options.updateReferences = true
        try await repo.startRebase(plan, items: rows, options: options)
        #expect(try await repo.snapshot().operation.kind == .rebase)
        try await repo.stepOperation(repo.reviewOperation(expected: repo.snapshot()), step: .resume)
        #expect(try await repo.snapshot().operation.kind == nil)
    }
    @Test func rebaseAbortRefusesMovedOriginalBranch() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repo = try await f.repository(), first = try #require(try await repo.snapshot().head)
        try f.write("README.md", "two\n"); try await f.git(["commit", "-am", "Two"])
        let plan = try await repo.rebasePlan(after: first, expected: repo.snapshot())
        var rows = plan.items; rows[0].command = .edit
        try await repo.startRebase(plan, items: rows)
        try await f.git(["update-ref", "refs/heads/main", first])
        let review = try await repo.reviewOperation(expected: repo.snapshot())
        await #expect(throws: GitError.self) { try await repo.stepOperation(review, step: .abort) }
        #expect(try await repo.snapshot().references.first { $0.fullName == "refs/heads/main" }?.objectOID == first)
    }
    @Test func gitflowPlansAreNamedAndDirect() {
        #expect(GitflowTask.startFeature.arguments == ["feature", "start"])
        #expect(GitflowTask.finishRelease.arguments == ["release", "finish"])
        #expect(!GitflowTask.initialize.requiresName && GitflowTask.finishHotfix.requiresName)
    }
}
