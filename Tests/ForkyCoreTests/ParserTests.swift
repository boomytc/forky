import Foundation
import Testing
@testable import ForkyCore

@Suite struct ParserTests {
    @Test func statusPreservesSpecialNames() throws {
        let text = " M space name\0?? line\nname → ü.txt\0A  :(glob)*.txt\0"
        let changes = try GitParsers.status(Data(text.utf8))
        #expect(changes.map(\.path.value) == ["space name", "line\nname → ü.txt", ":(glob)*.txt"])
        #expect(changes[0].isUnstaged)
        #expect(changes[1].isUntracked)
        #expect(changes[2].isStaged)
    }

    @Test func renameFramingIsDestinationThenSource() throws {
        let change = try #require(GitParsers.status(Data("R  new → file\0old file\0".utf8)).first)
        #expect(change.path.value == "new → file")
        #expect(change.originalPath?.value == "old file")
        #expect(change.unstagePaths == ["new → file", "old file"])
    }

    @Test func malformedStatusFailsClosed() {
        for bytes in [Data(" M missing terminator".utf8), Data("R  new\0".utf8),
                      Data("ZZ file\0".utf8), Data([63, 63, 32, 255, 0]),
                      Data("?? ../escape\0".utf8), Data("?? same\0?? same\0".utf8)] {
            #expect(throws: (any Error).self) { try GitParsers.status(bytes) }
        }
    }

    @Test func conflictStatusesAreNotOrdinaryStagedChanges() throws {
        let changes = try GitParsers.status(Data("UU file\0AA both\0".utf8))
        #expect(changes.allSatisfy { $0.isConflict })
        #expect(changes.allSatisfy { !$0.isStaged })
    }

    @Test func logPreservesBodyAndEmptyParent() throws {
        let oid = String(repeating: "a", count: 40)
        let text = "\(oid)\0\0Author\0a@example.invalid\01700000000\0Subject\0Body\nnext\n\0"
        let commits = try GitParsers.commits(Data(text.utf8))
        #expect(commits.count == 1)
        #expect(commits[0].parents.isEmpty)
        #expect(commits[0].body == "Body\nnext\n")
        #expect(throws: (any Error).self) { try GitParsers.commits(Data("invalid\0".utf8)) }
    }

    @Test func commitRenameAndDeletion() throws {
        let files = try GitParsers.commitFiles(Data("R100\0old\0new\0D\0deleted\0".utf8))
        #expect(files[0].path.value == "new")
        #expect(files[0].originalPath?.value == "old")
        #expect(files[1].status == "D")
    }

    @Test func diffNumbersAndMalformedHunks() {
        let diff = DiffDocument(text: "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -3,2 +3,2 @@\n same\n-old\n+new\n")
        #expect(diff.additions == 1)
        #expect(diff.deletions == 1)
        #expect(diff.lines.first { $0.kind == .deletion }?.oldNumber == 4)
        #expect(diff.lines.first { $0.kind == .addition }?.newNumber == 4)
        let malformed = DiffDocument(text: "@@ - + @@\n+not a valid hunk")
        #expect(malformed.additions == 0)
    }

    @Test func diffPreviewReportsTruncation() {
        let diff = DiffDocument(text: String(repeating: "x", count: 500_020))
        #expect(diff.truncated)
        #expect(diff.text.count == 500_000)
    }
}
