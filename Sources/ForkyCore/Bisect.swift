import Foundation

public enum BisectStep: String, CaseIterable, Sendable { case good, bad, skip, reset }
extension GitRepository {
    public func startBisect(good: String, bad: String, expected: RepositorySnapshot) async throws -> String {
        guard GitParsers.isOID(good), GitParsers.isOID(bad), good != bad else { throw GitError.invalidInput("Choose different known good/bad commit OIDs.") }
        return try await gate.withPermit {
            let fresh = try await checkReviewed(expected, clean: true)
            guard let head = fresh.head, fresh.branch != nil else { throw GitError.invalidInput("Start bisect from an existing local branch.") }
            _ = try await command(["merge-base", "--is-ancestor", good, bad])
            let candidates = try await boundedRevisions(["rev-list", "--max-count=201", good + ".." + bad])
            try await protectIgnored(revisions: candidates + [good], transitions: [(head, good), (head, bad)])
            let result = try await command(["-c", "submodule.recurse=false", "bisect", "start", bad, good], write: true, timeout: 300)
            return try GitParsers.string(result.stdout)
        }
    }
    public func bisectLog() async throws -> String {
        try await gate.withPermit { try GitParsers.string(try await command(["bisect", "log"]).stdout) }
    }
    public func stepBisect(_ step: BisectStep, expected: RepositorySnapshot) async throws -> String {
        try await gate.withPermit {
            let fresh = try await checkReviewed(expected, clean: true, allowOperation: true)
            guard fresh.operation.kind == .bisect, let head = fresh.head else { throw GitError.invalidInput("No known bisect is active.") }
            if step == .reset {
                guard let restore = fresh.operation.restoreOID else { throw GitError.staleRepository }
                try await protectIgnored(transitions: [(head, restore)])
            } else {
                let goods = try await command(["for-each-ref", "--format=%(objectname)", "refs/bisect/good-*"]).stdout
                let goodIDs = try GitParsers.string(goods).split(separator: "\n").map(String.init)
                guard goodIDs.allSatisfy(GitParsers.isOID) else { throw GitError.malformedOutput("Invalid bisect refs.") }
                let candidates = try await boundedRevisions(["rev-list", "--max-count=201", "refs/bisect/bad", "--not"] + goodIDs)
                try await protectIgnored(revisions: candidates, transitions: candidates.map { (head, $0) })
            }
            let result = try await command(["-c", "submodule.recurse=false", "bisect", step.rawValue], write: true, timeout: 300)
            return try GitParsers.string(result.stdout) + GitParsers.string(result.stderr)
        }
    }
    private func boundedRevisions(_ args: [String]) async throws -> [String] {
        let values = try GitParsers.string(try await command(args + ["--"]).stdout).split(separator: "\n").map(String.init)
        guard values.count <= 200, values.allSatisfy(GitParsers.isOID) else {
            throw GitError.invalidInput("Review a bisect range of at most 200 commits. No bisect write was started.")
        }
        return values
    }
}
