import Foundation
import Testing
@testable import ForkyCore

struct SubmoduleAndLFSTests {
    @Test func submoduleStatusReportsRecordedHeadAndDivergence() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let child = f.directory.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        _ = try await f.runner.run(["init", "-b", "main", child.path])
        for (key, value) in [("user.name", "Child"), ("user.email", "child@example.invalid"),
                             ("commit.gpgSign", "false"), ("core.hooksPath", "/dev/null")] {
            _ = try await f.runner.run(["-C", child.path, "config", key, value])
        }
        try Data("one\n".utf8).write(to: child.appendingPathComponent("file.txt"))
        _ = try await f.runner.run(["-C", child.path, "add", "file.txt"])
        _ = try await f.runner.run(["-C", child.path, "commit", "-m", "Child one"])
        try await f.git(["-c", "protocol.file.allow=always", "submodule", "add", "--", child.path, "sub"])
        try await f.git(["commit", "-m", "Add submodule"])
        let repository = try await f.repository()
        let initial = try await repository.submoduleStatuses()
        #expect(initial.entries.count == 1)
        #expect(initial.entries[0].path.value == "sub")
        #expect(initial.entries[0].state == .upToDate)
        #expect(initial.entries[0].ahead == 0 && initial.entries[0].behind == 0)

        let sub = f.root.appendingPathComponent("sub")
        try Data("two\n".utf8).write(to: sub.appendingPathComponent("file.txt"))
        _ = try await f.runner.run(["-C", sub.path, "commit", "-am", "Child two"])
        let advanced = try await repository.submoduleStatuses()
        #expect(advanced.entries[0].state == .different)
        #expect(advanced.entries[0].ahead == 1 && advanced.entries[0].behind == 0)

        let oid = string(try await f.runner.run(["-C", child.path, "rev-parse", "HEAD"]).stdout)
        try await f.git(["update-index", "--add", "--cacheinfo", "160000,\(oid),ghost"])
        let withGhost = try await repository.submoduleStatuses()
        let ghost = try #require(withGhost.entries.first { $0.path.value == "ghost" })
        #expect(ghost.state == .uninitialized && ghost.checkedOutOID == nil)
    }

    @Test func lfsLocksParseArraysAndWrappedObjects() throws {
        let array = Data("""
        [{"id":"1","path":"assets/a.png","owner":{"name":"Ann"},"locked_at":"2026-01-01T00:00:00Z"},
         {"id":2,"path":"b.bin","owner":"Bob"}]
        """.utf8)
        let locks = try GitParsers.lfsLocks(array)
        #expect(locks.count == 2 && locks[0].owner == "Ann" && locks[1].id == "2" && locks[1].owner == "Bob")
        let wrapped = Data(#"{"locks":[{"id":"3","path":"c.txt"}]}"#.utf8)
        #expect(try GitParsers.lfsLocks(wrapped).map(\.path) == ["c.txt"])
        #expect(throws: GitError.self) { try GitParsers.lfsLocks(Data(#"{"unexpected":true}"#.utf8)) }
        #expect(throws: GitError.self) { try GitParsers.lfsLocks(Data(#"[{"id":"1","path":"/absolute"}]"#.utf8)) }
        let tooMany = try JSONSerialization.data(withJSONObject: (0...GitRepository.lfsLockLimit).map {
            ["id": String($0), "path": "p\($0)"]
        })
        #expect(throws: GitError.self) { try GitParsers.lfsLocks(tooMany) }
    }

    @Test func lfsPointerOnlyResolvesObjectsAlreadyOnDisk() async throws {
        let f = try await GitFixture(); defer { f.remove() }; try await f.initialCommit()
        let repository = try await f.repository()
        let oid = String(repeating: "ab", count: 32)
        let pointer = Data("version https://git-lfs.github.com/spec/v1\noid sha256:\(oid)\nsize 5\n".utf8)
        #expect(GitParsers.lfsPointer(pointer) == LFSPointer(oid: oid, size: 5))
        #expect(GitParsers.lfsPointer(Data("hello".utf8)) == nil)
        #expect(GitParsers.lfsPointer(Data("version https://git-lfs.github.com/spec/v1\noid sha256:short\nsize 5\n".utf8)) == nil)

        let missing = repository.resolveLFSImage(pointer)
        #expect(missing.bytes == nil && missing.isPointer)
        #expect(missing.note?.contains("not stored locally") == true)
        #expect(repository.resolveLFSImage(Data("hello".utf8)).bytes == Data("hello".utf8))

        let object = repository.commonDirectory.appendingPathComponent("lfs/objects/ab/ab/\(oid)")
        try FileManager.default.createDirectory(at: object.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: object)
        #expect(repository.resolveLFSImage(pointer).bytes == Data("hello".utf8))
    }

    private func string(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}
