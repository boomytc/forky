import Foundation

public enum CustomCommandScope: String, Codable, CaseIterable, Sendable {
    case repository = "Repository"
    case file = "File"
    case revision = "Revision"
}

public struct CustomCommand: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var scope: CustomCommandScope
    public var executable: String
    public var arguments: [String]
    public var input: String
    public init(id: UUID = UUID(), name: String, scope: CustomCommandScope,
                executable: String, arguments: [String], input: String) {
        self.id = id; self.name = name; self.scope = scope
        self.executable = executable; self.arguments = arguments; self.input = input
    }
}

public struct CustomCommandContext: Sendable {
    public let path: String?
    public let repository: String
    public let revision: String?
    public init(path: String?, repository: String, revision: String?) {
        self.path = path; self.repository = repository; self.revision = revision
    }
}

public enum CustomCommandError: Error, LocalizedError, Equatable {
    case invalidName
    case duplicateName
    case tooMany
    case invalidExecutable
    case invalidArguments
    case missingPlaceholder(String)
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidName: "Enter a command name of 1–60 characters without control characters."
        case .duplicateName: "A saved command already uses that name."
        case .tooMany: "At most \(CustomCommandArchive.maxCommands) commands are retained; delete one first."
        case .invalidExecutable: "Save an absolute executable path, without NUL characters."
        case .invalidArguments: "Use at most 100 arguments of 64 KiB each, without NUL characters."
        case .missingPlaceholder(let name): "This command uses \(name), but the current selection has no value for it."
        case .tooLarge: "The saved command library exceeds its size budget; nothing was written."
        }
    }
}

public enum CustomCommandArchive {
    public static let maxCommands = 24
    public static let maxArguments = 100
    public static let maxArgumentBytes = 64 * 1024
    public static let maxInputBytes = 4 * 1024 * 1024
    public static let maxBytes = 1024 * 1024

    public static func validatedName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60,
              !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw CustomCommandError.invalidName
        }
        return name
    }

    public static func make(name: String, scope: CustomCommandScope, executable: String,
                            arguments: [String], input: String,
                            existing: [CustomCommand] = [], updating id: UUID? = nil) throws -> CustomCommand {
        let name = try validatedName(name)
        guard executable.hasPrefix("/"), !executable.utf8.contains(0), executable.utf8.count <= 65536 else {
            throw CustomCommandError.invalidExecutable
        }
        guard arguments.count <= maxArguments,
              arguments.allSatisfy({ !$0.utf8.contains(0) && $0.utf8.count <= maxArgumentBytes }),
              input.utf8.count <= maxInputBytes, !input.utf8.contains(0) else {
            throw CustomCommandError.invalidArguments
        }
        guard existing.allSatisfy({ $0.id == id || $0.name.caseInsensitiveCompare(name) != .orderedSame }) else {
            throw CustomCommandError.duplicateName
        }
        return CustomCommand(id: id ?? UUID(), name: name, scope: scope,
                             executable: executable, arguments: arguments, input: input)
    }

    public static func upserting(_ commands: [CustomCommand], command: CustomCommand) throws -> [CustomCommand] {
        var copy = commands
        if let index = copy.firstIndex(where: { $0.id == command.id }) {
            guard copy.allSatisfy({ $0.id == command.id || $0.name.caseInsensitiveCompare(command.name) != .orderedSame }) else {
                throw CustomCommandError.duplicateName
            }
            copy[index] = command
            return copy
        }
        guard copy.count < maxCommands else { throw CustomCommandError.tooMany }
        guard copy.allSatisfy({ $0.name.caseInsensitiveCompare(command.name) != .orderedSame }) else {
            throw CustomCommandError.duplicateName
        }
        copy.append(command)
        return copy
    }

    public static func removing(_ commands: [CustomCommand], id: UUID) -> [CustomCommand] {
        commands.filter { $0.id != id }
    }

    public static func encode(_ commands: [CustomCommand]) throws -> Data {
        guard commands.count <= maxCommands else { throw CustomCommandError.tooMany }
        let data = try JSONEncoder().encode(commands)
        guard data.count <= maxBytes else { throw CustomCommandError.tooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> [CustomCommand] {
        guard data.count <= maxBytes else { throw CustomCommandError.tooLarge }
        let commands = try JSONDecoder().decode([CustomCommand].self, from: data)
        guard commands.count <= maxCommands, Set(commands.map(\.id)).count == commands.count,
              commands.allSatisfy({ (try? validatedName($0.name)) != nil }) else {
            throw CustomCommandError.tooLarge
        }
        return commands
    }
}

/// Literal placeholder replacement only. No shell, no environment expansion, no recursion.
public enum CustomCommandSubstitution {
    public static let placeholders = ["{path}", "{repository}", "{revision}"]

    public static func resolve(_ template: String, context: CustomCommandContext) throws -> String {
        var result = ""
        var remainder = Substring(template)
        while let open = remainder.firstIndex(of: "{") {
            result += remainder[..<open]
            let rest = remainder[open...]
            guard let match = placeholders.first(where: { rest.hasPrefix($0) }) else {
                result.append("{")
                remainder = rest.dropFirst()
                continue
            }
            result += try value(for: match, context: context)
            remainder = rest.dropFirst(match.count)
        }
        result += remainder
        guard result.utf8.count <= CustomCommandArchive.maxInputBytes else { throw CustomCommandError.tooLarge }
        return result
    }

    private static func value(for placeholder: String, context: CustomCommandContext) throws -> String {
        switch placeholder {
        case "{path}":
            guard let path = context.path else { throw CustomCommandError.missingPlaceholder(placeholder) }
            return path
        case "{revision}":
            guard let revision = context.revision else { throw CustomCommandError.missingPlaceholder(placeholder) }
            return revision
        default:
            return context.repository
        }
    }

    public static func arguments(_ command: CustomCommand, context: CustomCommandContext) throws -> [String] {
        try command.arguments.map { try resolve($0, context: context) }
    }

    public static func input(_ command: CustomCommand, context: CustomCommandContext) throws -> String {
        try resolve(command.input, context: context)
    }
}
