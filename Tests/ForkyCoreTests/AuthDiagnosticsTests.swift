import Foundation
import Testing
@testable import ForkyCore

struct AuthDiagnosticsTests {
    @Test func diagnosticsRedactCredentialsAndReportLocalTools() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        try await f.git(["remote", "add", "origin", "https://user:secret@example.invalid/team/repo.git"])
        try await f.git(["remote", "add", "peer", "git@example.invalid:team/repo.git"])
        try await f.git(["remote", "add", "query", "https://example.invalid/team/repo.git?private_token=secret&ref=main"])
        try await f.git(["config", "user.signingkey", "ABCDEF0123456789ABCDEF0123456789ABCDEF01"])
        try await f.git(["config", "commit.gpgsign", "true"])
        let home = f.directory.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try Data("ssh-ed25519 AAAA test\n".utf8).write(to: home.appendingPathComponent(".ssh/id_ed25519.pub"))
        try Data("private\n".utf8).write(to: home.appendingPathComponent(".ssh/id_ed25519"))
        let tools = f.directory.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let gpg = tools.appendingPathComponent("gpg")
        try Data("#!/bin/sh\n".utf8).write(to: gpg)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gpg.path)

        let diagnostics = try await f.repository().authenticationDiagnostics(home: home, pathDirectories: [tools.path])
        #expect(diagnostics.gpgExecutable == gpg.path)
        #expect(diagnostics.signingKey == "ABCDEF01…EF01")
        #expect(diagnostics.commitSigningEnabled)
        #expect(diagnostics.publicKeyFiles == ["id_ed25519.pub"])
        #expect(diagnostics.notes.contains { $0.contains("gnupg") } == false)
        let origin = try #require(diagnostics.remotes.first { $0.name == "origin" })
        #expect(origin.displayURL == "https://example.invalid/team/repo.git")
        #expect(origin.embedsCredentials)
        #expect(!origin.displayURL.contains("secret") && !origin.displayURL.contains("user:"))
        let peer = try #require(diagnostics.remotes.first { $0.name == "peer" })
        #expect(peer.scheme == "ssh" && !peer.embedsCredentials)
        let query = try #require(diagnostics.remotes.first { $0.name == "query" })
        #expect(query.embedsCredentials && query.displayURL.contains("ref=main"))
        #expect(!query.displayURL.contains("secret"))
        #expect(diagnostics.lines.joined(separator: "\n").contains("secret") == false)
    }

    @Test func missingGPGAndAbsoluteRemotePathsAreReported() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        try await f.git(["remote", "add", "local", f.directory.appendingPathComponent("peer.git").path])
        let empty = f.directory.appendingPathComponent("empty-tools")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let diagnostics = try await f.repository().authenticationDiagnostics(home: empty, pathDirectories: [empty.path])
        #expect(diagnostics.gpgExecutable == nil)
        #expect(diagnostics.notes.contains { $0.contains("gnupg") })
        #expect(diagnostics.publicKeyFiles.isEmpty)
        let local = try #require(diagnostics.remotes.first { $0.name == "local" })
        #expect(local.displayURL == "local path" && local.scheme == "file")
    }
}
