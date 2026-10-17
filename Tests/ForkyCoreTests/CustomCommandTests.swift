import Foundation
import Testing
@testable import ForkyCore

struct CustomCommandTests {
    @Test func commandsValidateNamesExecutablesAndArguments() throws {
        let command = try CustomCommandArchive.make(name: "  Review  ", scope: .file, executable: "/usr/bin/git",
                                                    arguments: ["log", "{path}"], input: "{revision}")
        #expect(command.name == "Review")
        #expect(throws: CustomCommandError.self) {
            try CustomCommandArchive.make(name: "   ", scope: .file, executable: "/bin/echo", arguments: [], input: "")
        }
        #expect(throws: CustomCommandError.self) {
            try CustomCommandArchive.make(name: "Relative", scope: .file, executable: "bin/echo", arguments: [], input: "")
        }
        #expect(throws: CustomCommandError.self) {
            try CustomCommandArchive.make(name: "Nul", scope: .file, executable: "/bin/echo", arguments: ["a\0b"], input: "")
        }
        #expect(throws: CustomCommandError.self) {
            try CustomCommandArchive.make(name: "REVIEW", scope: .file, executable: "/bin/echo", arguments: [], input: "",
                                          existing: [command])
        }
    }

    @Test func archiveUpsertsUpdatesAndRejectsDuplicates() throws {
        let first = try CustomCommandArchive.make(name: "One", scope: .repository, executable: "/bin/echo", arguments: [], input: "")
        var list = try CustomCommandArchive.upserting([], command: first)
        #expect(list.count == 1)
        let updated = try CustomCommandArchive.make(name: "One renamed", scope: .file, executable: "/bin/true", arguments: ["x"], input: "",
                                                    existing: list, updating: first.id)
        list = try CustomCommandArchive.upserting(list, command: updated)
        #expect(list.count == 1 && list[0].name == "One renamed" && list[0].scope == .file)
        let second = try CustomCommandArchive.make(name: "Two", scope: .file, executable: "/bin/echo", arguments: [], input: "")
        list = try CustomCommandArchive.upserting(list, command: second)
        // An update cannot take another stored command's name.
        let colliding = CustomCommand(id: first.id, name: "Two", scope: .file, executable: "/bin/echo", arguments: [], input: "")
        #expect(throws: CustomCommandError.self) { try CustomCommandArchive.upserting(list, command: colliding) }
        #expect(CustomCommandArchive.removing(list, id: first.id).map(\.name) == ["Two"])
        let data = try CustomCommandArchive.encode(list)
        #expect(try CustomCommandArchive.decode(data) == list)
        #expect(throws: (any Error).self) { try CustomCommandArchive.decode(Data("broken".utf8)) }
        let many = (0...CustomCommandArchive.maxCommands).map { index in
            CustomCommand(name: "C\(index)", scope: .repository, executable: "/bin/echo", arguments: [], input: "")
        }
        #expect(throws: CustomCommandError.self) { try CustomCommandArchive.encode(many) }
    }

    @Test func substitutionIsLiteralSinglePassAndRefusesMissingSelection() throws {
        let context = CustomCommandContext(path: "src/a.swift", repository: "/repo", revision: "abc123")
        #expect(try CustomCommandSubstitution.resolve("{path} in {repository} at {revision}", context: context)
                == "src/a.swift in /repo at abc123")
        // A value that itself looks like a placeholder is never expanded again.
        #expect(try CustomCommandSubstitution.resolve("{path}", context: CustomCommandContext(path: "{repository}", repository: "/repo", revision: nil))
                == "{repository}")
        // Unknown braces and shell-looking text pass through untouched.
        #expect(try CustomCommandSubstitution.resolve("$(rm -rf {unknown}) {input_file}", context: context)
                == "$(rm -rf {unknown}) {input_file}")
        #expect(throws: CustomCommandError.self) {
            try CustomCommandSubstitution.resolve("{path}", context: CustomCommandContext(path: nil, repository: "/repo", revision: nil))
        }
        #expect(throws: CustomCommandError.self) {
            try CustomCommandSubstitution.resolve("{revision}", context: CustomCommandContext(path: "a", repository: "/repo", revision: nil))
        }
        let command = try CustomCommandArchive.make(name: "Args", scope: .file, executable: "/bin/echo",
                                                    arguments: ["--", "{path}"], input: "{revision}")
        #expect(try CustomCommandSubstitution.arguments(command, context: context) == ["--", "src/a.swift"])
        #expect(try CustomCommandSubstitution.input(command, context: context) == "abc123")
    }
}
