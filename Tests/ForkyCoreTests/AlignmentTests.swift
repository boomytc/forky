import Foundation
import Testing
@testable import ForkyCore

@Suite(.serialized) struct AlignmentTests {
    @Test func graphDrawsRealMergeParentsAndKeepsPagePrefixesStable() {
        func commit(_ id: Int, _ parents: [Int]) -> GitCommit {
            GitCommit(oid: String(format: "%040x", id), parents: parents.map { String(format: "%040x", $0) },
                      author: "Test", email: "test@example.invalid", date: .distantPast, subject: "C\(id)", body: "")
        }
        let commits = [commit(4, [2, 3]), commit(3, [1]), commit(2, [1]), commit(1, [])]
        let graph = CommitGraph(commits: commits)
        #expect(graph.laneCount == 2)
        #expect(graph.rows[0].isMerge)
        #expect(graph.rows[0].segments.filter { $0.fromLevel == .node && $0.toLevel == .bottom }.count == 2)
        #expect(!graph.rows.last!.segments.contains { $0.toLevel == .bottom })
        #expect(Array(graph.rows.prefix(2)) == CommitGraph(commits: Array(commits.prefix(2))).rows)
        #expect(graph.rows.map(\.oid) == commits.map(\.oid))
    }

    @Test func disconnectedRootsDoNotInventEdges() {
        let data = (1...2).map {
            GitCommit(oid: String(format: "%040x", $0), parents: [], author: "", email: "",
                      date: .distantPast, subject: "", body: "")
        }
        #expect(CommitGraph(commits: data).rows.allSatisfy { $0.segments.isEmpty })
    }

    @Test func referencesPreserveAnnotatedTagIdentityAndUnknownCommitTargets() throws {
        let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40)
        let records = [
            ["refs/heads/main", a, "*", "", "commit", ""],
            ["refs/tags/v1", b, " ", a, "tag", "commit"],
            ["refs/tags/tree", b, " ", "", "tree", ""],
            ["refs/tags/nested", b, " ", a, "tag", "tag"]
        ].map { $0.joined(separator: "\0") + "\0\n" }.joined()
        let refs = try GitParsers.references(Data(records.utf8))
        #expect(refs[0].isCurrent)
        #expect(refs[1].kind == .tag && refs[1].objectOID == b && refs[1].commitOID == a)
        #expect(refs[2].commitOID == nil && refs[3].commitOID == nil)
        #expect(throws: GitError.self) { try GitParsers.references(Data("refs/heads/main\0oops\0".utf8)) }
        #expect(throws: GitError.self) { try GitParsers.references(Data((records + records).utf8)) }
    }

    @Test func splitDiffPairsChangesWithoutCrossingHunksOrLosingLines() {
        let document = DiffDocument(text: "@@ -1,3 +1,4 @@\n-old\n+new\n+extra\n same\n-end\n+finish\n@@ -9 +10 @@\n-last\n+next\n")
        let split = SplitDiff(document: document)
        let paired = split.rows.filter { $0.old?.kind == .deletion && $0.new?.kind == .addition }
        #expect(paired.count == 3)
        #expect(split.rows.contains { $0.old == nil && $0.new?.text == "+extra" })
        #expect(split.rows.compactMap { $0.old?.oldNumber } == document.lines.compactMap(\.oldNumber))
        #expect(split.rows.compactMap { $0.new?.newNumber } == document.lines.compactMap(\.newNumber))
        let marker = SplitDiff(document: DiffDocument(text: "@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file\n"))
        #expect(marker.rows.filter { $0.old?.text.hasPrefix("\\ No newline") == true }.count == 1)
        #expect(marker.rows.filter { $0.new?.text.hasPrefix("\\ No newline") == true }.count == 1)
    }

    @Test func batchOperationsAffectOnlyExplicitPathsEvenInUnbornRepositories() async throws {
        let fixture = try await GitFixture(); defer { fixture.remove() }
        for name in ["one.txt", "two.txt", "leave.txt"] { try fixture.write(name, name) }
        let repository = try await fixture.repository()
        let chosen = try await repository.snapshot().unstaged.filter { $0.path.value != "leave.txt" }
        try await repository.stage(chosen)
        let staged = try await repository.snapshot()
        #expect(staged.staged.count == 2)
        #expect(staged.unstaged.map(\.id) == ["leave.txt"])
        try await repository.unstage(staged.staged)
        #expect(try await repository.snapshot().staged.isEmpty)
        for name in ["one.txt", "two.txt", "leave.txt"] {
            #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(name).path))
        }
    }

    @Test func branchCreationDoesNotCheckoutAndDirtyCheckoutCannotLoseFiles() async throws {
        let fixture = try await GitFixture(); defer { fixture.remove() }
        try await fixture.initialCommit()
        let repository = try await fixture.repository()
        let head = try #require(try await repository.snapshot().head)
        try await repository.createBranch(name: "feature/ui", expectedHead: head)
        #expect(try await repository.snapshot().branch == "main")
        let branch = try #require(try await repository.snapshot().branches.first { $0.name == "feature/ui" })
        try fixture.write("untracked.txt", "keep this")
        await #expect(throws: GitError.self) { try await repository.checkout(branch, expectedHead: head) }
        #expect(try await repository.snapshot().branch == "main")
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("untracked.txt"))
        try await repository.checkout(branch, expectedHead: head)
        #expect(try await repository.snapshot().branch == "feature/ui")
        await #expect(throws: GitError.self) { try await repository.createBranch(name: "bad name", expectedHead: head) }
        await #expect(throws: GitError.self) { try await repository.createBranch(name: "@{-1}", expectedHead: head) }
        await #expect(throws: GitError.self) { try await repository.createBranch(name: "--help", expectedHead: head) }
        #expect(try await repository.snapshot().branches.count == 2)
    }

    @Test func checkoutProtectsIgnoredFilesAndOtherWorktreeOwnership() async throws {
        let fixture = try await GitFixture(); defer { fixture.remove() }
        try await fixture.initialCommit()
        try await fixture.git(["switch", "-c", "target"])
        try fixture.write("ignored.txt", "tracked on target")
        try await fixture.git(["add", "--", "ignored.txt"])
        try await fixture.git(["commit", "-m", "Track on target"])
        try await fixture.git(["switch", "main"])
        try Data("ignored.txt\n".utf8).write(to: fixture.root.appendingPathComponent(".git/info/exclude"))
        try fixture.write("ignored.txt", "important ignored content")
        let repository = try await fixture.repository()
        let snapshot = try await repository.snapshot()
        #expect(snapshot.changes.isEmpty)
        let target = try #require(snapshot.branches.first { $0.name == "target" })
        await #expect(throws: GitError.self) { try await repository.checkout(target, expectedHead: snapshot.head!) }
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("ignored.txt"), encoding: .utf8) == "important ignored content")
        #expect(try await repository.snapshot().branch == "main")
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("ignored.txt"))
        let linked = fixture.directory.appendingPathComponent("other-worktree")
        try await fixture.git(["worktree", "add", linked.path, "target"])
        await #expect(throws: GitError.self) { try await repository.checkout(target, expectedHead: snapshot.head!) }
        #expect(try await repository.snapshot().branch == "main")
    }

    @Test func staleDestinationAndHeadAreRejected() async throws {
        let fixture = try await GitFixture(); defer { fixture.remove() }
        try await fixture.initialCommit()
        let repository = try await fixture.repository()
        let snapshot = try await repository.snapshot()
        try await repository.createBranch(name: "target", expectedHead: snapshot.head!)
        let target = try #require(try await repository.snapshot().branches.first { $0.name == "target" })
        try await fixture.git(["commit", "--allow-empty", "-m", "External write"])
        await #expect(throws: GitError.self) { try await repository.createBranch(name: "not-created", expectedHead: snapshot.head!) }
        await #expect(throws: GitError.self) { try await repository.checkout(target, expectedHead: snapshot.head!) }
        let current = try #require(try await repository.snapshot().head)
        try await fixture.git(["branch", "-f", "target", current])
        await #expect(throws: GitError.self) { try await repository.checkout(target, expectedHead: current) }
        #expect(try await repository.snapshot().branch == "main")
    }

    @Test func searchIsLiteralCaseInsensitiveAndTagsResolveToCommits() async throws {
        let fixture = try await GitFixture(); defer { fixture.remove() }
        try await fixture.initialCommit()
        try await fixture.git(["commit", "--allow-empty", "-m", "Literal .* NEEDLE", "-m", "A searchable body"])
        try await fixture.git(["tag", "-a", "v1", "-m", "Annotated tag"])
        try await fixture.git(["commit", "--allow-empty", "-m", "Other message"])
        let repository = try await fixture.repository()
        let snapshot = try await repository.snapshot()
        #expect(snapshot.tags.count == 1)
        let tagged = try await repository.history(ref: "refs/tags/v1")
        #expect(tagged.commits.count == 2)
        #expect(snapshot.tags[0].objectOID != snapshot.tags[0].commitOID)
        #expect(tagged.commits[0].oid == snapshot.tags[0].commitOID)
        #expect(try await repository.history(query: ".*").commits.count == 1)
        #expect(try await repository.history(query: "needle").commits.count == 1)
        #expect(try await repository.history(query: "searchable body").commits.count == 1)
        #expect(try await repository.history(query: "not found").commits.isEmpty)
    }

    @Test func selectedReferenceUsesCapturedObjectWhenRefMovesDuringRead() async throws {
        let fixture = try await GitFixture(); defer { fixture.remove() }
        try await fixture.initialCommit()
        let original = String(decoding: try await fixture.git(["rev-parse", "HEAD"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        let tree = String(decoding: try await fixture.git(["rev-parse", "HEAD^{tree}"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        let advanced = String(decoding: try await fixture.git(["commit-tree", tree, "-p", original, "-m", "Advanced during ref read"]).stdout,
                              as: UTF8.self).trimmingCharacters(in: .newlines)
        let wrapper = fixture.directory.appendingPathComponent("git-ref-race")
        // Real Git emits old ref facts, then another writer advances the real temporary ref
        // before the read completes. No simulated log or parser output.
        let script = """
        #!/bin/sh
        mutate=0
        for arg do
          if [ "$arg" = "for-each-ref" ]; then mutate=1; fi
        done
        /usr/bin/git "$@"
        result=$?
        if [ "$result" -eq 0 ] && [ "$mutate" -eq 1 ]; then
          /usr/bin/git -C "$FORKY_TEST_ROOT" update-ref refs/heads/main "$FORKY_TEST_TIP" || exit 1
        fi
        exit "$result"
        """
        try Data((script + "\n").utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let runner = GitProcessRunner(executable: wrapper, environment: [
            "HOME": fixture.directory.appendingPathComponent("home").path, "PATH": "/usr/bin:/bin",
            "FORKY_TEST_ROOT": fixture.root.path, "FORKY_TEST_TIP": advanced
        ])
        let repository = try await GitRepository.open(fixture.root, runner: runner)
        let page = try await repository.history(ref: "refs/heads/main")
        #expect(page.references.first?.objectOID == original)
        #expect(page.commits.first?.oid == original)
        #expect(String(decoding: try await fixture.git(["rev-parse", "HEAD"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines) == advanced)
    }

    @Test func frozenCursorSurvivesExternalRefChangesWithoutGapsOrDuplicates() async throws {
        let fixture = try await GitFixture(); defer { fixture.remove() }
        try await fixture.initialCommit()
        let tree = String(decoding: try await fixture.git(["rev-parse", "HEAD^{tree}"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        var tip = String(decoding: try await fixture.git(["rev-parse", "HEAD"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        for number in 1...204 {
            tip = String(decoding: try await fixture.git(["commit-tree", tree, "-p", tip, "-m", "History \(number)"]).stdout,
                         as: UTF8.self).trimmingCharacters(in: .newlines)
        }
        try await fixture.git(["update-ref", "refs/heads/main", tip])
        let repository = try await fixture.repository()
        let first = try await repository.history()
        let cursor = try #require(first.nextCursor)
        #expect(first.commits.count == 200)
        let newTip = String(decoding: try await fixture.git(["commit-tree", tree, "-p", tip, "-m", "New between pages"]).stdout,
                            as: UTF8.self).trimmingCharacters(in: .newlines)
        try await fixture.git(["update-ref", "refs/heads/main", newTip])
        let second = try await repository.history(cursor: cursor)
        let all = first.commits + second.commits
        #expect(all.count == 205 && Set(all.map(\.id)).count == 205)
        #expect(second.commits.count == 5 && !second.hasMore)
        #expect(!all.contains { $0.oid == newTip })
        #expect(second.references == first.references)
        #expect(try await repository.history().commits.first?.oid == newTip)
        await #expect(throws: GitError.self) { try await repository.history(query: "different", cursor: cursor) }
    }
}
