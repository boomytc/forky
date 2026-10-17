import Foundation
import Testing
@testable import ForkyCore

struct CommitCompositionTests {
    @Test func templatePrefillStripsCommentsAndEdgeBlanks() {
        #expect(GitRepository.templatePrefill("Subject\n\nBody\n# note\n\n\n", comment: "#") == "Subject\n\nBody")
        #expect(GitRepository.templatePrefill("# only a comment\n", comment: "#") == nil)
        #expect(GitRepository.templatePrefill("A\r\nB \r\n", comment: "#") == "A\nB")
        #expect(GitRepository.templatePrefill("Keep; semicolon\n; drop\n", comment: ";") == "Keep; semicolon")
    }

    @Test func compositionReadsTemplateWithConfiguredCommentCharacter() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        try Data("Subject line\n# kept: comment char is a semicolon\n; removed\n\n".utf8)
            .write(to: f.root.appendingPathComponent(".gitmessage"))
        try await f.git(["config", "commit.template", ".gitmessage"])
        try await f.git(["config", "core.commentChar", ";"])
        let composition = try await f.repository().commitComposition()
        #expect(composition.templatePath?.hasSuffix("/space repo/.gitmessage") == true)
        #expect(composition.templateText == "Subject line\n# kept: comment char is a semicolon")
        #expect(composition.note == nil)
    }

    @Test func absentOrUnreadableTemplateIsReportedWithoutFailing() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repository = try await f.repository()
        let unset = try await repository.commitComposition()
        #expect(unset.templatePath == nil && unset.templateText == nil && unset.note == nil)
        try await f.git(["config", "commit.template", "missing-template.txt"])
        let missing = try await repository.commitComposition()
        #expect(missing.templateText == nil)
        #expect(missing.note?.contains("could not be read") == true)
    }

    @Test func oversizedTemplateIsRefusedWithoutReadingItIntoTheEditor() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        try Data(String(repeating: "a", count: GitRepository.commitTemplateLimit + 1).utf8)
            .write(to: f.root.appendingPathComponent("big-template.txt"))
        try await f.git(["config", "commit.template", "big-template.txt"])
        let composition = try await f.repository().commitComposition()
        #expect(composition.templateText == nil)
        #expect(composition.note?.contains("64 KiB") == true)
    }

    @Test func signOffTrailerIsExplicitPerCommit() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repository = try await f.repository()
        let expected = "Signed-off-by: Forky Test <forky@example.invalid>"
        func body() async throws -> String { try String(decoding: try await f.git(["log", "-1", "--format=%B"]).stdout, as: UTF8.self) }
        func stageAndCommit(_ message: String, _ signOff: CommitSignOff) async throws {
            try f.write("README.md", message + "\n")
            try await f.git(["add", "--", "README.md"])
            let snapshot = try await repository.snapshot()
            try await repository.commit(message: message, signOff: signOff, expectedFingerprint: snapshot.indexFingerprint)
        }
        try await stageAndCommit("Included", .include)
        #expect(try await body().contains(expected))
        try await stageAndCommit("Omitted", .omit)
        let omitted = try await body()
        #expect(!omitted.contains(expected))
        try await stageAndCommit("Configured", .configured)
        // format.signoff only seeds format-patch, so a plain commit stays unsigned.
        let configured = try await body()
        #expect(!configured.contains(expected))
    }
}
