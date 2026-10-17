import Foundation

public enum GitflowTask: String, CaseIterable, Sendable {
    case version = "Version", initialize = "Initialize Defaults", startFeature = "Start Feature", finishFeature = "Finish Feature"
    case startRelease = "Start Release", finishRelease = "Finish Release", startHotfix = "Start Hotfix", finishHotfix = "Finish Hotfix"
    var arguments: [String] {
        switch self {
        case .version: ["version"]
        case .initialize: ["init", "-d"]
        case .startFeature: ["feature", "start"]
        case .finishFeature: ["feature", "finish"]
        case .startRelease: ["release", "start"]
        case .finishRelease: ["release", "finish"]
        case .startHotfix: ["hotfix", "start"]
        case .finishHotfix: ["hotfix", "finish"]
        }
    }
    public var requiresName: Bool { self != .version && self != .initialize }
}
extension GitRepository {
    /// Bring-your-own git-flow plugin. Its configured code/side effects are not sandboxed.
    public func gitflow(_ task: GitflowTask, name: String, expected: RepositorySnapshot) async throws -> String {
        try await gate.withPermit {
            let fresh = try await checkReviewed(expected, clean: task != .version, allowOperation: task == .version)
            if task.requiresName {
                guard !name.isEmpty, !name.hasPrefix("-"), !name.utf8.contains(0), name.utf8.count <= 4096 else { throw GitError.invalidBranchName }
                _ = try await command(["check-ref-format", "refs/heads/" + name])
            }
            do {
                let result = try await command(["flow"] + task.arguments + (task.requiresName ? [name] : []), write: task != .version, timeout: 300)
                return try GitParsers.string(result.stdout) + GitParsers.string(result.stderr)
            } catch GitError.commandFailed(let code, let text) {
                throw GitError.commandFailed(code, TransportPresentation.sanitize(text, using: fresh.collaboration.value?.credentials ?? []))
            }
        }
    }
}
