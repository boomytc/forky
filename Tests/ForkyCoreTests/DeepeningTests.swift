import Foundation
import Testing
@testable import ForkyCore

struct DeepeningTests {
    @Test func discardHasSeparateAuthorityAndKeepsIndex() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        try f.write("README.md", "# Hello\nadded\n")
        let repo = try await f.repository(), before = try await repo.snapshot()
        let review = try await repo.reviewDiscard(try #require(before.changes.first), expected: before)
        await #expect(throws: GitError.self) { try await repo.applyPartial(review, selected: review.patch.changeIDs) }
        try await repo.applyPartial(review, selected: review.patch.changeIDs, approveDiscard: true)
        #expect(try String(contentsOf: f.root.appendingPathComponent("README.md"), encoding: .utf8) == "# Hello\n")
        #expect(try await repo.snapshot().indexFingerprint == before.indexFingerprint)
    }
    @Test func hardResetApprovalsAndChangedReview() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repo = try await f.repository(), head = try #require(try await repo.snapshot().head)
        try f.write("README.md", "old review\n")
        let review = try await repo.reviewReset(to: head, mode: .hard, expected: repo.snapshot())
        await #expect(throws: GitError.self) { try await repo.reset(review) }
        try f.write("README.md", "changed after review\n")
        await #expect(throws: GitError.self) { try await repo.reset(review, approveHardDiscard: true) }
        let updated = try await repo.reviewReset(to: head, mode: .hard, expected: repo.snapshot())
        try await repo.reset(updated, approveHardDiscard: true)
        #expect(try await repo.snapshot().changes.isEmpty)
    }
    @Test(arguments: ResetMode.allCases) func resetModes(mode: ResetMode) async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repo = try await f.repository(), original = try #require(try await repo.snapshot().head)
        try f.write("README.md", "second\n"); try await f.git(["commit", "-am", "Second"])
        let review = try await repo.reviewReset(to: original, mode: mode, expected: repo.snapshot())
        try await repo.reset(review, approveHardDiscard: mode == .hard)
        let result = try await repo.snapshot()
        #expect(result.head == original)
        #expect(mode == .hard ? result.changes.isEmpty : !result.changes.isEmpty)
    }
    @Test func conflictChunkChoicesPreserveByteBoundaries() throws {
        let raw = "prefix\r\n<<<<<<< ours\r\nours\r\n||||||| base\r\nbase\r\n=======\r\ntheirs\r\n>>>>>>> theirs\r\nsuffix\r\n"
        let doc = try ConflictDocument(raw)
        #expect(doc.chunks.count == 1 && doc.render([:]) == raw)
        #expect(doc.render([0: .both]) == "prefix\r\nours\r\ntheirs\r\nsuffix\r\n")
        #expect(doc.render([0: .base]) == "prefix\r\nbase\r\nsuffix\r\n")
        #expect(try ConflictDocument("<<<<<<<not-marker\n=======x\n").chunks.isEmpty)
        #expect(throws: GitError.self) { try ConflictDocument("<<<<<<< a\nmissing") }
    }
    @Test func conflictChunkNavigationCountsOnlyResolvedChunks() throws {
        let raw = """
        <<<<<<< HEAD
        a
        =======
        b
        >>>>>>> other
        middle
        <<<<<<< HEAD
        c
        =======
        d
        >>>>>>> other
        end
        <<<<<<< HEAD
        e
        =======
        f
        >>>>>>> other
        """
        let doc = try ConflictDocument(raw)
        #expect(doc.chunks.count == 3)
        #expect(doc.progress([:]) == ConflictProgress(resolved: 0, total: 3))
        #expect(doc.progress([1: .ours]) == ConflictProgress(resolved: 1, total: 3))
        #expect(doc.progress([9: .ours]) == ConflictProgress(resolved: 0, total: 3))
        #expect(doc.nextUnresolvedID(after: nil, choices: [:]) == 0)
        #expect(doc.nextUnresolvedID(after: 0, choices: [1: .ours]) == 2)
        #expect(doc.nextUnresolvedID(after: 2, choices: [:]) == nil)
        #expect(doc.previousUnresolvedID(before: nil, choices: [1: .theirs]) == 2)
        #expect(doc.previousUnresolvedID(before: 2, choices: [1: .theirs]) == 0)
        #expect(doc.previousUnresolvedID(before: 0, choices: [:]) == nil)
        #expect(doc.choices(.both).count == 3)
        // No chunk in this document has a ``|||||||`` base section; choosing Base would
        // leave the original markers in the rendered result, so it must stay unresolved.
        #expect(doc.progress(doc.choices(.base)) == ConflictProgress(resolved: 0, total: 3))
        #expect(doc.nextUnresolvedID(after: nil, choices: doc.choices(.base)) == 0)
    }
    @Test func conflictBaseChoiceRequiresABaseSection() throws {
        let withoutBase = try ConflictDocument("""
        <<<<<<< ours
        ours
        =======
        theirs
        >>>>>>> theirs
        """)
        #expect(withoutBase.progress([0: .base]) == ConflictProgress(resolved: 0, total: 1))
        #expect(withoutBase.render([0: .base]).contains("<<<<<<<"))

        let withBase = try ConflictDocument("""
        <<<<<<< ours
        ours
        ||||||| base
        base
        =======
        theirs
        >>>>>>> theirs
        """)
        #expect(withBase.progress([0: .base]) == ConflictProgress(resolved: 1, total: 1))
        #expect(withBase.render([0: .base]) == "base\n")
    }
    @Test func rebaseBackupAndExplicitUpdateRefs() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repo = try await f.repository(), base = try #require(try await repo.snapshot().head)
        try f.write("README.md", "two\n"); try await f.git(["commit", "-am", "Two"]); try await f.git(["branch", "middle"])
        try f.write("README.md", "three\n"); try await f.git(["commit", "-am", "Three"])
        let snapshot = try await repo.snapshot(), plan = try await repo.rebasePlan(after: base, expected: snapshot)
        var options = RebaseOptions(); options.backupTag = "approved-backup"; options.updateReferences = true
        var rows = plan.items; rows[0].command = .edit
        try await repo.startRebase(plan, items: rows, options: options)
        let refs = try await repo.snapshot().references
        #expect(refs.first { $0.name == "approved-backup" }?.commitOID == snapshot.head)
        let pause = try await repo.reviewOperation(expected: repo.snapshot())
        try await repo.amendRebase(pause, message: "New two")
        try await repo.stepOperation(repo.reviewOperation(expected: repo.snapshot()), step: .resume)
        let after = try await repo.snapshot()
        #expect(after.tags.first { $0.name == "approved-backup" }?.commitOID == snapshot.head)
        #expect(after.references.first { $0.name == "middle" }?.commitOID != snapshot.references.first { $0.name == "middle" }?.commitOID)
    }
    @Test func cherryPickMergeMainlineAndNoCommit() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repo = try await f.repository(), base = try #require(try await repo.snapshot().head)
        try await f.git(["switch", "-c", "feature"]); try f.write("feature", "yes")
        try await f.git(["add", "feature"]); try await f.git(["commit", "-m", "Feature"])
        try await f.git(["switch", "main"]); try await f.git(["merge", "--no-ff", "--no-edit", "feature"])
        let merge = try await repo.commitInfo(try #require(try await repo.snapshot().head))
        try await f.git(["switch", "-c", "target", base])
        var options = CommitApplyOptions(); options.mainline = 1; options.createCommit = false
        try await repo.applyCommit(merge, action: .cherryPick, expected: repo.snapshot(), options: options)
        let after = try await repo.snapshot(); #expect(after.head == base && after.staged.count == 1)
    }
    @Test func stashIgnoredCollisionRefusesWithoutDrop() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repo = try await f.repository()
        try f.write("local", "stored")
        try await repo.saveStash(message: "new", includeUntracked: true, expected: repo.snapshot())
        try f.write(".git/info/exclude", "local\n"); try f.write("local", "do not overwrite")
        let state = try await repo.snapshot(), stash = try #require(state.collaboration.value?.stashes.first)
        await #expect(throws: GitError.self) { try await repo.applyStash(stash, restoreIndex: false, expected: state, dropAfterSuccess: true) }
        #expect(try String(contentsOf: f.root.appendingPathComponent("local"), encoding: .utf8) == "do not overwrite")
        #expect(try await repo.snapshot().collaboration.value?.stashes.count == 1)
    }
    @Test func statisticsCountAndMissingImageAreReported() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repo = try await f.repository(), head = try #require(try await repo.snapshot().head)
        let stats = try await repo.statistics()
        #expect(stats.total == 1 && stats.months.reduce(0) { $0 + $1.count } == 1)
        let absent = try await repo.imageComparison(from: head, to: head, path: GitPath("missing.png"))
        #expect(absent.before == nil && absent.after == nil)
    }
    @Test func imageComparisonReadsBlobsBeyondTheTextOutputBudget() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let payload = Data(repeating: 0x89, count: 4 * 1024 * 1024 + 1024)
        try payload.write(to: f.root.appendingPathComponent("large.png"))
        try await f.git(["add", "--", "large.png"]); try await f.git(["commit", "-m", "Large image"])
        let repo = try await f.repository(), head = try #require(try await repo.snapshot().head)
        let committed = try await repo.imageComparison(from: head, to: head, path: GitPath("large.png"))
        #expect(committed.before?.count == payload.count && committed.after?.count == payload.count)

        let working = Data(repeating: 0x42, count: 4 * 1024 * 1024 + 2048)
        try working.write(to: f.root.appendingPathComponent("large.png"))
        let worktree = try await repo.imageComparison(from: head, to: nil, path: GitPath("large.png"))
        #expect(worktree.after?.count == working.count)
    }
    @Test func externalInputFileIsLiteralData() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repo = try await f.repository()
        let text = "payload\n$(not executed); Unicode ñ"
        let result = try await repo.runTrustedTool(executable: URL(fileURLWithPath: "/bin/cat"),
            arguments: ["{input_file}"], input: text, expected: repo.snapshot())
        #expect(result == text)
    }
}
