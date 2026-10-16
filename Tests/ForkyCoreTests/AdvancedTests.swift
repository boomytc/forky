import Foundation
import Testing
import Darwin
@testable import ForkyCore

@Suite struct AdvancedTests {
    private func oid(_ f: GitFixture, _ revision: String = "HEAD") async throws -> String {
        try GitParsers.string(try await f.git(["rev-parse", revision]).stdout).trimmingCharacters(in: .newlines)
    }
    private func commit(_ f: GitFixture, _ file: String, _ text: String, _ message: String) async throws {
        try f.write(file, text); try await f.git(["add", "--", file]); try await f.git(["commit", "-m", message])
    }
    private func conflicted(_ f: GitFixture) async throws -> GitRepository {
        try await commit(f, "conflict.txt", "base\n", "Base")
        try await f.git(["switch", "-c", "other"])
        try await commit(f, "conflict.txt", "theirs\n", "Theirs")
        try await f.git(["switch", "main"])
        try await commit(f, "conflict.txt", "ours\n", "Ours")
        await #expect(throws: GitError.self) { try await f.git(["merge", "--no-edit", "other"]) }
        return try await f.repository()
    }

    @Test func stageAndUnstageIndividualLinesPreserveWorktree() async throws {
        let f = try await GitFixture(); defer { f.remove() }
        try await commit(f, "lines.txt", "one\ntwo\nthree\n", "Base")
        try f.write("lines.txt", "ONE\ntwo\nTHREE\n")
        let repo = try await f.repository(), s = try await repo.snapshot()
        let change = try #require(s.changes.first)
        let review = try await repo.reviewPartial(change, side: .worktree, expected: s)
        let selection = Set(review.patch.hunks.flatMap(\.lines).filter { $0.text == "ONE" }.map(\.id))
        try await repo.applyPartial(review, selected: selection)
        #expect(try GitParsers.string(try await f.git(["show", ":lines.txt"]).stdout) == "one\nONE\ntwo\nthree\n")
        #expect(try String(contentsOf: f.root.appendingPathComponent("lines.txt"), encoding: .utf8) == "ONE\ntwo\nTHREE\n")
        let staged = try await repo.snapshot()
        let back = try await repo.reviewPartial(try #require(staged.changes.first), side: .staged, expected: staged)
        try await repo.applyPartial(back, selected: back.patch.changeIDs)
        #expect(try await repo.snapshot().staged.isEmpty)
        #expect(try String(contentsOf: f.root.appendingPathComponent("lines.txt"), encoding: .utf8) == "ONE\ntwo\nTHREE\n")
    }

    @Test func selectHunkAndNoNewlineWithQuotedLiteralPath() async throws {
        let f = try await GitFixture(); defer { f.remove() }
        let name = ":(literal)unicode-文\nfile.txt"
        let before = (1...30).map { "line\($0)" }.joined(separator: "\n")
        try await commit(f, name, before, "Base")
        try f.write(name, before.replacingOccurrences(of: "line2\n", with: "TWO\n").replacingOccurrences(of: "line30", with: "THIRTY"))
        let repo = try await f.repository(), s = try await repo.snapshot()
        let review = try await repo.reviewPartial(try #require(s.changes.first), side: .worktree, expected: s)
        #expect(review.patch.hunks.count == 2)
        try await repo.applyPartial(review, selected: try #require(review.patch.hunks.last).changeIDs)
        let result = try GitParsers.string(try await f.git(["show", ":" + name]).stdout)
        #expect(result == before.replacingOccurrences(of: "line30", with: "THIRTY"))
        #expect(!result.hasSuffix("\n"))
    }

    @Test func partialSelectionRejectsStaleWorktreeAndIndex() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        try f.write("README.md", "Changed\n")
        let repo = try await f.repository(), s = try await repo.snapshot()
        let review = try await repo.reviewPartial(try #require(s.changes.first), side: .worktree, expected: s)
        try f.write("README.md", "External\n")
        await #expect(throws: GitError.self) { try await repo.applyPartial(review, selected: review.patch.changeIDs) }
        #expect(try await repo.snapshot().staged.isEmpty)
        try f.write("README.md", "Changed\n")
        try await commit(f, "else.txt", "Other\n", "External head")
        await #expect(throws: GitError.self) { try await repo.applyPartial(review, selected: review.patch.changeIDs) }
    }

    @Test func partialRejectsBinarySymlinkAndMalformedPatch() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        try Data([0, 1]).write(to: f.root.appendingPathComponent("README.md"))
        let repo = try await f.repository(), s = try await repo.snapshot()
        await #expect(throws: GitError.self) { try await repo.reviewPartial(try #require(s.changes.first), side: .worktree, expected: s) }
        #expect(throws: GitError.self) { try PartialPatch("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n") }
        try await f.git(["restore", "--", "README.md"])
        try FileManager.default.createSymbolicLink(atPath: f.root.appendingPathComponent("link").path, withDestinationPath: "README.md")
        try await f.git(["add", "link"]); try await f.git(["commit", "-m", "Link"])
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("link"))
        try FileManager.default.createSymbolicLink(atPath: f.root.appendingPathComponent("link").path, withDestinationPath: "elsewhere")
        let link = try await repo.snapshot()
        await #expect(throws: GitError.self) { try await repo.reviewPartial(try #require(link.changes.first), side: .worktree, expected: link) }
    }

    @Test func conflictEditorSaveStageAndContinueMerge() async throws {
        let f = try await GitFixture(); defer { f.remove() }; let repo = try await conflicted(f)
        var s = try await repo.snapshot()
        #expect(s.operation.kind == .merge)
        let path = try GitPath("conflict.txt")
        let location = f.root.appendingPathComponent(path.value).path
        try FileManager.default.setAttributes([.posixPermissions: 0o740], ofItemAtPath: location)
        let attribute = Data("preserve".utf8)
        #expect(attribute.withUnsafeBytes { setxattr(location, "dev.forky.fixture", $0.baseAddress, $0.count, 0, 0) } == 0)
        var review = try await repo.reviewConflict(path, expected: s)
        #expect(review.base == "base\n" && review.ours == "ours\n" && review.theirs == "theirs\n")
        await #expect(throws: GitError.self) { try await repo.resolveConflict(review, resolution: .text(review.working!), stage: true) }
        try await repo.resolveConflict(review, resolution: .text("resolved\n"), stage: false)
        s = try await repo.snapshot(); #expect(s.hasConflicts)
        let mode = try FileManager.default.attributesOfItem(atPath: location)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o740)
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = getxattr(location, "dev.forky.fixture", &buffer, buffer.count, 0, 0)
        #expect(count == attribute.count)
        #expect(Data(buffer.prefix(max(0, count))) == attribute)
        review = try await repo.reviewConflict(path, expected: s)
        try await repo.resolveConflict(review, resolution: .text("resolved\n"), stage: true)
        s = try await repo.snapshot(); #expect(!s.hasConflicts && s.staged.count == 1)
        let operation = try await repo.reviewOperation(expected: s)
        try await repo.stepOperation(operation, step: .resume)
        #expect(try await repo.snapshot().operation.kind == nil)
        #expect(try await repo.history().commits.first?.parents.count == 2)
    }

    @Test func conflictStaleAndSymlinkCannotOverwriteExternalBytes() async throws {
        let f = try await GitFixture(); defer { f.remove() }; let repo = try await conflicted(f)
        let path = try GitPath("conflict.txt"), s = try await repo.snapshot()
        let review = try await repo.reviewConflict(path, expected: s)
        try f.write(path.value, "external edit\n")
        await #expect(throws: GitError.self) { try await repo.resolveConflict(review, resolution: .text("overwrite"), stage: true) }
        let outside = f.directory.appendingPathComponent("outside")
        try Data("preserve".utf8).write(to: outside)
        try FileManager.default.removeItem(at: f.root.appendingPathComponent(path.value))
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent(path.value), withDestinationURL: outside)
        await #expect(throws: GitError.self) { try await repo.reviewConflict(path, expected: s) }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "preserve")
    }

    @Test func resolveModifyDeleteByExplicitDeletion() async throws {
        let f = try await GitFixture(); defer { f.remove() }
        try await commit(f, "conflict.txt", "base\n", "Base"); try await f.git(["switch", "-c", "other"])
        try await f.git(["rm", "conflict.txt"]); try await f.git(["commit", "-m", "Delete"])
        try await f.git(["switch", "main"]); try await commit(f, "conflict.txt", "changed\n", "Modify")
        await #expect(throws: GitError.self) { try await f.git(["merge", "other"]) }
        let repo = try await f.repository(), s = try await repo.snapshot()
        let review = try await repo.reviewConflict(GitPath("conflict.txt"), expected: s)
        #expect(review.theirs == nil)
        try await repo.resolveConflict(review, resolution: .delete, stage: true)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("conflict.txt").path))
        #expect(try await repo.snapshot().hasConflicts == false)
    }

    @Test func cherryPickAndRevertCreateActualCommits() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        try await f.git(["switch", "-c", "source"]); try await commit(f, "feature.txt", "feature\n", "Feature")
        let repo = try await f.repository(), feature = try #require(try await repo.history().commits.first)
        try await f.git(["switch", "main"])
        var s = try await repo.snapshot()
        try await repo.applyCommit(feature, action: .cherryPick, expected: s)
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("feature.txt").path))
        let picked = try #require(try await repo.history().commits.first)
        s = try await repo.snapshot()
        try await repo.applyCommit(picked, action: .revert, expected: s)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("feature.txt").path))
        #expect(try await repo.history().commits.first?.subject == "Revert \"Feature\"")
        try f.write("untracked", "Keep")
        await #expect(throws: GitError.self) { try await repo.applyCommit(feature, action: .cherryPick, expected: repo.snapshot()) }
    }

    @Test func cherryPickConflictAbortRejectsUnreviewedEdits() async throws {
        let f = try await GitFixture(); defer { f.remove() }
        try await commit(f, "x", "base\n", "Base"); try await f.git(["switch", "-c", "source"])
        try await commit(f, "x", "source\n", "Source")
        let repo = try await f.repository(), source = try #require(try await repo.history().commits.first)
        try await f.git(["switch", "main"]); try await commit(f, "x", "main\n", "Main")
        let s = try await repo.snapshot(), head = s.head
        await #expect(throws: GitError.self) { try await repo.applyCommit(source, action: .cherryPick, expected: s) }
        let conflict = try await repo.snapshot(); #expect(conflict.operation.kind == .cherryPick && conflict.hasConflicts)
        let old = try await repo.reviewOperation(expected: conflict)
        try f.write("x", "new resolution\n")
        await #expect(throws: GitError.self) { try await repo.stepOperation(old, step: .abort) }
        let current = try await repo.reviewOperation(expected: repo.snapshot())
        try await repo.stepOperation(current, step: .abort)
        #expect(try await repo.snapshot().head == head)
        #expect(try String(contentsOf: f.root.appendingPathComponent("x"), encoding: .utf8) == "main\n")
    }

    @Test func rebaseReordersFixesDropsWithoutMovingOtherRefs() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let base = try await oid(f)
        for n in 1...3 { try await commit(f, "f\(n)", "\(n)\n", "Commit \(n)") }
        try await f.git(["branch", "untouched", "HEAD~1"])
        let other = try await oid(f, "untouched")
        try await f.git(["config", "rebase.updateRefs", "true"])
        let repo = try await f.repository(), plan = try await repo.rebasePlan(after: base, expected: repo.snapshot())
        var items = [plan.items[2], plan.items[0], plan.items[1]]
        items[1].command = .fixup; items[2].command = .drop
        try await repo.startRebase(plan, items: items)
        #expect(try await oid(f, "untouched") == other)
        #expect(try await repo.snapshot().operation.kind == nil)
        #expect(try await repo.history(ref: "refs/heads/main").commits.count == 2)
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("f1").path))
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("f2").path))
    }

    @Test func rebaseEditAmendAndResumeNeedsNoRetainedEditorFile() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let base = try await oid(f)
        try await commit(f, "feature", "feature\n", "Old message")
        let repo = try await f.repository(), plan = try await repo.rebasePlan(after: base, expected: repo.snapshot())
        var items = plan.items; items[0].command = .edit
        try await repo.startRebase(plan, items: items)
        var s = try await repo.snapshot(); #expect(s.operation.kind == .rebase && s.operation.canAmend)
        var review = try await repo.reviewOperation(expected: s)
        try await repo.amendRebase(review, message: "Reworded")
        s = try await repo.snapshot(); review = try await repo.reviewOperation(expected: s)
        try await repo.stepOperation(review, step: .resume)
        #expect(try await repo.snapshot().operation.kind == nil)
        #expect(try await repo.history().commits.first?.subject == "Reworded")
    }

    @Test func rebaseOntoReviewedReferenceAndRejectsInvalidPlan() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let base = try await oid(f)
        try await f.git(["switch", "-c", "upstream"]); try await commit(f, "upstream", "upstream", "Upstream")
        try await f.git(["switch", "main"]); try await commit(f, "feature", "feature", "Feature")
        let repo = try await f.repository(), s = try await repo.snapshot()
        let plan = try await repo.rebasePlan(after: base, expected: s)
        var invalid = plan.items; invalid[0].command = .squash
        await #expect(throws: GitError.self) { try await repo.startRebase(plan, items: invalid) }
        try await repo.startRebase(plan, items: plan.items, onto: try #require(s.references.first { $0.name == "upstream" }))
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("upstream").path))
        #expect(try await repo.snapshot().branch == "main")
    }

    @Test func frozenTreeBlobAndBlameIgnoreWorkingEditsAndNewHead() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repo = try await f.repository(), commit = try #require(try await repo.history().commits.first)
        let entry = try #require(try await repo.tree(in: commit).first { $0.path.value == "README.md" })
        try await self.commit(f, "README.md", "different\n", "Later")
        if case .text(let text) = try await repo.blob(entry) { #expect(text == "# Hello\n") } else { Issue.record("Expected captured text") }
        let blame = try await repo.blame(entry)
        #expect(blame.count == 1 && blame[0].oid == commit.oid && blame[0].text == "# Hello")
        #expect(blame[0].author == "Forky Test")
    }

    @Test func treeNamesSubdirectoriesBinaryAndSymlinksRemainDistinct() async throws {
        let f = try await GitFixture(); defer { f.remove() }
        try FileManager.default.createDirectory(at: f.root.appendingPathComponent("folder"), withIntermediateDirectories: false)
        try f.write("folder/文\nname", "text\n")
        try Data([0, 255]).write(to: f.root.appendingPathComponent("binary"))
        try FileManager.default.createSymbolicLink(atPath: f.root.appendingPathComponent("link").path, withDestinationPath: "binary")
        try await f.git(["add", "--all"]); try await f.git(["commit", "-m", "Tree"])
        let repo = try await f.repository(), commit = try #require(try await repo.history().commits.first)
        let entries = try await repo.tree(in: commit)
        let folder = try #require(entries.first { $0.kind == .tree })
        let children = try await repo.tree(in: commit, directory: folder)
        #expect(children.first?.path.value == "folder/文\nname")
        let binary = try #require(entries.first { $0.path.value == "binary" })
        if case .binary(let size) = try await repo.blob(binary) { #expect(size == 2) } else { Issue.record("Binary was interpreted as text") }
        let link = try #require(entries.first { $0.isSymlink })
        await #expect(throws: GitError.self) { try await repo.blame(link) }
        #expect(throws: GitError.self) { try GitRepository.parseBlame(Data("not a record\n".utf8)) }
    }

    @Test(arguments: [("", "added\n"), ("old\n", ""), ("old", "new"), ("old\r\n", "new\r\n"), ("\u{0301}old\n", "\u{0301}new\n")])
    func partialWholeHunkPreservesEdgeBytes(pair: (String, String)) async throws {
        let f = try await GitFixture(); defer { f.remove() }
        try await commit(f, "x", pair.0, "Base"); try f.write("x", pair.1)
        try await f.git(["config", "diff.suppressBlankEmpty", "true"])
        try await f.git(["config", "diff.outputIndicatorNew", ">"])
        let repo = try await f.repository(), s = try await repo.snapshot()
        let review = try await repo.reviewPartial(try #require(s.changes.first), side: .worktree, expected: s)
        try await repo.applyPartial(review, selected: review.patch.changeIDs)
        #expect(try GitParsers.string(try await f.git(["show", ":x"]).stdout) == pair.1)
        #expect(try String(contentsOf: f.root.appendingPathComponent("x"), encoding: .utf8) == pair.1)
    }

    @Test func cherryPickEmptySkipAndRevertConflictAbort() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        try await commit(f, "x", "original\n", "Feature")
        let repo = try await f.repository(), feature = try #require(try await repo.history().commits.first)
        await #expect(throws: GitError.self) { try await repo.applyCommit(feature, action: .cherryPick, expected: repo.snapshot()) }
        #expect(try await repo.snapshot().operation.kind == .cherryPick)
        try await repo.stepOperation(try await repo.reviewOperation(expected: repo.snapshot()), step: .skip)
        #expect(try await repo.snapshot().operation.kind == nil)
        try await commit(f, "x", "modified\n", "Later")
        let head = try await oid(f)
        await #expect(throws: GitError.self) { try await repo.applyCommit(feature, action: .revert, expected: repo.snapshot()) }
        #expect(try await repo.snapshot().operation.kind == .revert)
        try await repo.stepOperation(try await repo.reviewOperation(expected: repo.snapshot()), step: .abort)
        #expect(try await repo.snapshot().head == head)
        #expect(try String(contentsOf: f.root.appendingPathComponent("x"), encoding: .utf8) == "modified\n")
    }

    @Test func rebaseConflictResolutionAndSkipUseNativeState() async throws {
        let f = try await GitFixture(); defer { f.remove() }
        try await commit(f, "x", "base\n", "Base"); let base = try await oid(f)
        try await f.git(["switch", "-c", "upstream"]); try await commit(f, "x", "onto\n", "Onto")
        try await f.git(["switch", "main"]); try await commit(f, "x", "replayed\n", "Replay")
        let repo = try await f.repository(), s = try await repo.snapshot()
        let plan = try await repo.rebasePlan(after: base, expected: s)
        let onto = try #require(s.references.first { $0.name == "upstream" })
        await #expect(throws: GitError.self) { try await repo.startRebase(plan, items: plan.items, onto: onto) }
        var current = try await repo.snapshot()
        #expect(current.operation.kind == .rebase && current.hasConflicts)
        let conflict = try await repo.reviewConflict(GitPath("x"), expected: current)
        #expect(conflict.ours == "onto\n" && conflict.theirs == "replayed\n")
        try await repo.resolveConflict(conflict, resolution: .text("combined\n"), stage: true)
        current = try await repo.snapshot()
        try await repo.stepOperation(try await repo.reviewOperation(expected: current), step: .resume)
        #expect(try await repo.snapshot().branch == "main")
        #expect(try String(contentsOf: f.root.appendingPathComponent("x"), encoding: .utf8) == "combined\n")
    }

    @Test func rebaseSkipAndMalformedMarkerAreExplicit() async throws {
        let f = try await GitFixture(); defer { f.remove() }
        try await commit(f, "x", "base\n", "Base"); let base = try await oid(f)
        try await f.git(["switch", "-c", "upstream"]); try await commit(f, "x", "onto\n", "Onto")
        let target = try await oid(f)
        try await f.git(["switch", "main"]); try await commit(f, "x", "replayed\n", "Replay")
        let repo = try await f.repository(), s = try await repo.snapshot()
        let plan = try await repo.rebasePlan(after: base, expected: s)
        await #expect(throws: GitError.self) { try await repo.startRebase(plan, items: plan.items, onto: try #require(s.references.first { $0.name == "upstream" })) }
        try await repo.stepOperation(try await repo.reviewOperation(expected: repo.snapshot()), step: .skip)
        #expect(try await repo.snapshot().head == target)
        try f.write(".git/MERGE_HEAD", "not-an-object\n")
        #expect(try await repo.snapshot().operation.kind == .unknown)
    }

    @Test func temporaryInputCleanupSurvivesCancelledOwner() async throws {
        actor Probe {
            var path: URL?
            func set(_ value: URL) { path = value }
        }
        let probe = Probe()
        let owner = Task {
            try await TemporaryInput.withFile(Data("owned input".utf8)) { file in
                await probe.set(file)
                try await Task.sleep(for: .seconds(20))
            }
        }
        defer { owner.cancel() }
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await probe.path == nil && clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard let input = await probe.path else {
            owner.cancel(); _ = await owner.result
            Issue.record("Temporary input did not become ready before the bounded deadline.")
            return
        }
        owner.cancel()
        await #expect(throws: CancellationError.self) { try await owner.value }
        #expect(!FileManager.default.fileExists(atPath: input.deletingLastPathComponent().path))
    }

    @Test func historyReplayMustNotOverwriteIgnoredObstructions() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let base = try await oid(f)
        try await f.git(["switch", "-c", "upstream"])
        try await commit(f, "obstruction", "server bytes\n", "Server file")
        try await f.git(["switch", "main"])
        try await commit(f, ".gitignore", "obstruction\n", "Ignore local data")
        try f.write("obstruction", "LOCAL DATA\n")
        let repo = try await f.repository(), s = try await repo.snapshot()
        #expect(s.changes.isEmpty)
        let plan = try await repo.rebasePlan(after: base, expected: s)
        await #expect(throws: GitError.self) { try await repo.startRebase(plan, items: plan.items, onto: try #require(s.references.first { $0.name == "upstream" })) }
        #expect(try String(contentsOf: f.root.appendingPathComponent("obstruction"), encoding: .utf8) == "LOCAL DATA\n")
        #expect(try await repo.snapshot().head == s.head)
    }

    @Test(arguments: [CommitAction.cherryPick, .revert])
    func commitReplayPreservesIgnoredFiles(action: CommitAction) async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        if action == .revert { try await commit(f, "x", "tracked", "Tracked") }
        try await f.git(["switch", "-c", "source"])
        if action == .revert { try await f.git(["rm", "x"]); try await f.git(["commit", "-m", "Delete"]) }
        else { try await commit(f, "x", "server", "Add") }
        let repo = try await f.repository(), source = try #require(try await repo.history().commits.first)
        try await f.git(["switch", "main"])
        if action == .revert { try await f.git(["rm", "x"]) }
        try await commit(f, ".gitignore", "x\n", "Ignore")
        try f.write("x", "LOCAL DATA")
        let before = try await repo.snapshot()
        await #expect(throws: GitError.self) { try await repo.applyCommit(source, action: action, expected: before) }
        #expect(try String(contentsOf: f.root.appendingPathComponent("x"), encoding: .utf8) == "LOCAL DATA")
        #expect(try await repo.snapshot().head == before.head)
    }

    @Test func pendingRebaseContinueAndAbortProtectIgnoredNewlinePath() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let path = "fut\nure"
        // Gitignore escapes the embedded LF by matching a wildcard, not by changing the filename.
        try await commit(f, ".gitignore", "fut*\n", "Ignore future")
        let base = try await oid(f)
        try await commit(f, "a", "a", "Edit stop")
        try f.write(path, "tracked later")
        try await f.git(["add", "--force", "--", path]); try await f.git(["commit", "-m", "Future"])
        let repo = try await f.repository(), plan = try await repo.rebasePlan(after: base, expected: repo.snapshot())
        var items = plan.items; items[0].command = .edit
        try await repo.startRebase(plan, items: items)
        try f.write(path, "LOCAL DATA")
        let state = try await repo.snapshot()
        #expect(state.changes.isEmpty && state.operation.pendingRevisions.count == 1)
        let review = try await repo.reviewOperation(expected: state)
        await #expect(throws: GitError.self) { try await repo.stepOperation(review, step: .resume) }
        await #expect(throws: GitError.self) { try await repo.stepOperation(review, step: .abort) }
        #expect(try await repo.snapshot().head == state.head)
        #expect(try String(contentsOf: f.root.appendingPathComponent(path), encoding: .utf8) == "LOCAL DATA")
    }

    @Test func byteFramedPatchAndBlamePreserveCombiningUnicodeAndCRLF() async throws {
        let f = try await GitFixture(); defer { f.remove() }
        let path = "\u{0301}file"
        try await f.git(["config", "user.name", "\u{0301}Author"])
        try await commit(f, path, "old\r\n", "Base")
        try f.write(path, "\u{0301}new\r\n")
        let repo = try await f.repository(), s = try await repo.snapshot()
        let review = try await repo.reviewPartial(try #require(s.changes.first), side: .worktree, expected: s)
        try await repo.applyPartial(review, selected: review.patch.changeIDs)
        try await f.git(["commit", "-m", "\u{0301}Summary"])
        let selected = try #require(try await repo.history().commits.first)
        let entry = try #require(try await repo.tree(in: selected).first)
        let blame = try await repo.blame(entry)
        #expect(blame.first?.text == "\u{0301}new\r")
        #expect(blame.first?.author == "\u{0301}Author" && blame.first?.summary == "\u{0301}Summary")
    }

    @Test func unsafeOperationMarkerIsUnknownNotIdle() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let outside = f.directory.appendingPathComponent("outside")
        try Data("preserve".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent(".git/MERGE_HEAD"), withDestinationURL: outside)
        let repo = try await f.repository(), s = try await repo.snapshot()
        #expect(s.operation.kind == .unknown && s.operationInProgress)
        await #expect(throws: GitError.self) { try await repo.reviewOperation(expected: s) }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "preserve")
        try FileManager.default.removeItem(at: f.root.appendingPathComponent(".git/MERGE_HEAD"))
        let head = try await oid(f)
        try f.write(".git/MERGE_HEAD", head + "\n"); try f.write(".git/CHERRY_PICK_HEAD", head + "\n")
        #expect(try await repo.snapshot().operation.kind == .unknown)
        await #expect(throws: GitError.self) { try await repo.reviewOperation(expected: repo.snapshot()) }
    }
}
