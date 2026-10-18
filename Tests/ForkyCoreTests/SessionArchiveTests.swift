import Foundation
import Testing
@testable import ForkyCore

struct SessionArchiveTests {
    @Test func workspaceNamesAreTrimmedAndValidated() throws {
        let a = SavedWorkspace(name: "A", paths: ["/tmp/a"])
        let b = SavedWorkspace(name: "B", paths: ["/tmp/b"])
        let list = [a, b]
        #expect(try WorkspaceArchive.rename(list, id: a.id, to: "  Renamed  ").first?.name == "Renamed")
        #expect(throws: SessionArchiveError.self) { try WorkspaceArchive.rename(list, id: a.id, to: "   ") }
        #expect(throws: SessionArchiveError.self) { try WorkspaceArchive.rename(list, id: a.id, to: String(repeating: "x", count: 81)) }
        #expect(throws: SessionArchiveError.self) { try WorkspaceArchive.rename(list, id: a.id, to: "bad\nname") }
        #expect(throws: SessionArchiveError.self) { try WorkspaceArchive.rename(list, id: UUID(), to: "Missing") }
    }

    @Test func workspaceMovesStopAtTheEdges() {
        let a = SavedWorkspace(name: "A", paths: ["/tmp/a"])
        let b = SavedWorkspace(name: "B", paths: ["/tmp/b"])
        #expect(WorkspaceArchive.move([a, b], id: a.id, up: true).map(\.name) == ["A", "B"])
        #expect(WorkspaceArchive.move([a, b], id: b.id, up: true).map(\.name) == ["B", "A"])
        #expect(WorkspaceArchive.move([a, b], id: a.id, up: false).map(\.name) == ["B", "A"])
        #expect(WorkspaceArchive.move([a, b], id: b.id, up: false).map(\.name) == ["A", "B"])
    }

    @Test func workspacePathsStayAbsoluteUniqueAndBounded() throws {
        let workspace = SavedWorkspace(name: "Paths", paths: [])
        let deduped = try WorkspaceArchive.replacePaths([workspace], id: workspace.id,
                                                        paths: ["/tmp/one", "/tmp/one", "/tmp/two"])
        #expect(deduped.first?.paths == ["/tmp/one", "/tmp/two"])
        #expect(throws: GitError.self) {
            try WorkspaceArchive.replacePaths([workspace], id: workspace.id, paths: ["relative/path"])
        }
        let tooMany = (0...WorkspaceArchive.maxPathsPerWorkspace).map { "/tmp/p\($0)" }
        #expect(throws: GitError.self) {
            try WorkspaceArchive.replacePaths([workspace], id: workspace.id, paths: tooMany)
        }
        let many = (0..<WorkspaceArchive.maxWorkspaces).map { SavedWorkspace(name: "W\($0)", paths: ["/tmp/w\($0)"]) }
        #expect(throws: GitError.self) {
            try WorkspaceArchive.appending(many, name: "One More", paths: ["/tmp/extra"])
        }
    }

    @Test func workspaceArchiveRoundTripsAndRejectsUnusableData() throws {
        let workspaces = [SavedWorkspace(name: "One", paths: ["/tmp/one"]),
                          SavedWorkspace(name: "Two", paths: ["/tmp/two", "/tmp/three"])]
        let data = try WorkspaceArchive.encode(workspaces)
        #expect(try WorkspaceArchive.decode(data) == workspaces)
        #expect(throws: (any Error).self) { try WorkspaceArchive.decode(Data("not json".utf8)) }
        #expect(throws: (any Error).self) { try WorkspaceArchive.decode(Data(repeating: 0x20, count: WorkspaceArchive.maxBytes + 1)) }
    }

    @Test func draftArchiveBudgetsEncodedBytesSoDecodeCanReadItBack() throws {
        // Each draft is within the per-entry raw limit, but JSON escaping doubles its size.
        // A raw-text-only budget could write an archive that decode rejects on the next launch.
        let escaped = String(repeating: "\"\\\n", count: 20_000)
        let drafts = Dictionary(uniqueKeysWithValues: (0..<9).map { ("/tmp/\($0)", escaped) })
        let data = try #require(CommitDraftArchive.encode(drafts))
        #expect(data.count <= CommitDraftArchive.maxBytes)
        let decoded = CommitDraftArchive.decode(data)
        #expect(decoded.count == 4)
        #expect(decoded.values.allSatisfy { $0 == escaped })
        let reencoded = try #require(CommitDraftArchive.encode(decoded))
        #expect(CommitDraftArchive.decode(reencoded) == decoded)
    }

    @Test func workspaceDecodeDropsUnusableStoredPaths() throws {
        let workspace = SavedWorkspace(name: "Stored", paths: ["relative", "/tmp/a", "/tmp/a", "/tmp/../b"])
        let data = try WorkspaceArchive.encode([workspace])
        let decoded = try WorkspaceArchive.decode(data)
        #expect(decoded.first?.paths == ["/tmp/a", "/b"])
    }

    @Test func draftArchiveBoundsEntriesBytesAndEmptyText() throws {
        let drafts = ["/tmp/a": "hello", "/tmp/b": "", "/tmp/c": String(repeating: "x", count: CommitDraftArchive.maxDraftBytes + 1)]
        let bounded = CommitDraftArchive.bounded(drafts)
        #expect(bounded == ["/tmp/a": "hello"])
        let data = CommitDraftArchive.encode(drafts)
        let decoded = CommitDraftArchive.decode(data ?? Data())
        #expect(decoded == ["/tmp/a": "hello"])
        #expect(CommitDraftArchive.decode(Data(repeating: 0x20, count: CommitDraftArchive.maxBytes + 1)).isEmpty)
        #expect(CommitDraftArchive.decode(Data("broken".utf8)).isEmpty)
        let many = Dictionary(uniqueKeysWithValues: (0...CommitDraftArchive.maxEntries).map { ("/tmp/\($0)", "draft") })
        #expect(CommitDraftArchive.bounded(many).count == CommitDraftArchive.maxEntries)
    }
}
