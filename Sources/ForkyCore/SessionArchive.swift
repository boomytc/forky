import Foundation

public enum SessionArchiveError: Error, LocalizedError, Equatable {
    case invalidName
    case unknownWorkspace
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidName: "Enter a workspace name of 1–80 characters without control characters."
        case .unknownWorkspace: "That saved workspace no longer exists."
        case .tooLarge: "The saved session data exceeds its size budget; nothing was written."
        }
    }
}

public struct SavedWorkspace: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var paths: [String]
    public init(id: UUID = UUID(), name: String, paths: [String]) {
        self.id = id; self.name = name; self.paths = paths
    }
}

/// Pure workspace list operations plus bounded persistence. Nothing here opens a repository.
public enum WorkspaceArchive {
    public static let maxWorkspaces = 32
    public static let maxPathsPerWorkspace = 16
    public static let maxNameLength = 80
    public static let maxBytes = 1024 * 1024

    public static func validatedName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= maxNameLength,
              !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw SessionArchiveError.invalidName
        }
        return name
    }

    public static func rename(_ workspaces: [SavedWorkspace], id: UUID, to raw: String) throws -> [SavedWorkspace] {
        let name = try validatedName(raw)
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { throw SessionArchiveError.unknownWorkspace }
        var copy = workspaces
        copy[index].name = name
        return copy
    }

    /// Moves one entry by one position; edges are no-ops so a menu action never wraps silently.
    public static func move(_ workspaces: [SavedWorkspace], id: UUID, up: Bool) -> [SavedWorkspace] {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return workspaces }
        let target = up ? index - 1 : index + 1
        guard workspaces.indices.contains(target) else { return workspaces }
        var copy = workspaces
        copy.swapAt(index, target)
        return copy
    }

    /// Replaces the stored path list with an explicit reviewed set. Paths stay ordered and unique.
    public static func replacePaths(_ workspaces: [SavedWorkspace], id: UUID, paths: [String]) throws -> [SavedWorkspace] {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { throw SessionArchiveError.unknownWorkspace }
        var copy = workspaces
        copy[index].paths = try reviewedPaths(paths)
        return copy
    }

    public static func appending(_ workspaces: [SavedWorkspace], name: String, paths: [String]) throws -> [SavedWorkspace] {
        let name = try validatedName(name)
        guard workspaces.count < maxWorkspaces else {
            throw GitError.invalidInput("At most \(maxWorkspaces) saved workspaces are retained; delete one first.")
        }
        return workspaces + [SavedWorkspace(name: name, paths: try reviewedPaths(paths))]
    }

    private static func reviewedPaths(_ paths: [String]) throws -> [String] {
        var seen = Set<String>(), unique: [String] = []
        for path in paths {
            let url = try LocalFilePath.absolute(path)
            guard seen.insert(url.path).inserted else { continue }
            unique.append(url.path)
            guard unique.count <= maxPathsPerWorkspace else {
                throw GitError.invalidInput("A workspace holds at most \(maxPathsPerWorkspace) repositories.")
            }
        }
        return unique
    }

    public static func encode(_ workspaces: [SavedWorkspace]) throws -> Data {
        guard workspaces.count <= maxWorkspaces else { throw SessionArchiveError.tooLarge }
        let data = try JSONEncoder().encode(workspaces)
        guard data.count <= maxBytes else { throw SessionArchiveError.tooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> [SavedWorkspace] {
        guard data.count <= maxBytes else { throw SessionArchiveError.tooLarge }
        let workspaces = try JSONDecoder().decode([SavedWorkspace].self, from: data)
        guard workspaces.count <= maxWorkspaces,
              workspaces.allSatisfy({ (try? validatedName($0.name)) != nil && $0.paths.count <= maxPathsPerWorkspace }) else {
            throw SessionArchiveError.tooLarge
        }
        return workspaces
    }
}

/// Commit-message drafts keyed by repository path. Bounded so a saved session cannot grow without limit.
public enum CommitDraftArchive {
    public static let maxDraftBytes = 64 * 1024
    public static let maxEntries = 16
    public static let maxBytes = 512 * 1024

    public static func bounded(_ drafts: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        var budget = maxBytes
        for (path, text) in drafts.sorted(by: { $0.key < $1.key }).prefix(maxEntries) {
            guard !text.isEmpty, text.utf8.count <= maxDraftBytes, text.utf8.count <= budget,
                  !path.utf8.contains(0) else { continue }
            result[path] = text
            budget -= text.utf8.count
        }
        return result
    }

    public static func encode(_ drafts: [String: String]) -> Data? {
        try? JSONEncoder().encode(bounded(drafts))
    }

    public static func decode(_ data: Data) -> [String: String] {
        guard data.count <= maxBytes, let drafts = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return bounded(drafts)
    }
}
