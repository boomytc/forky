import Foundation

extension GitRepository {
    /// Native replay/reset steps can overwrite ignored obstructions. Check the complete
    /// possible write set before invoking them, not only porcelain's "clean" status.
    func protectIgnored(revisions: [String] = [], transitions: [(String, String)] = [],
                        additional: [GitPath] = []) async throws {
        let ignoredData = try await command(["ls-files", "--others", "--ignored", "--exclude-standard", "-z"]).stdout
        guard !ignoredData.isEmpty else { return }
        func paths(_ data: Data) throws -> [GitPath] {
            guard data.isEmpty || data.last == 0 else { throw GitError.malformedOutput("Incomplete path inventory.") }
            return try data.split(separator: 0).map { try GitPath(GitParsers.string(Data($0))) }
        }
        let ignored = try paths(ignoredData)
        var changed = additional
        if !revisions.isEmpty {
            let data = try await command(["log", "-m", "--no-walk", "--format=", "--name-only", "-z",
                "--no-ext-diff", "--no-textconv", "--no-renames", "--no-notes", "--no-show-signature", "--no-decorate", "--root"] + revisions + ["--"]).stdout
            changed += try paths(data)
        }
        for (from, to) in transitions where from != to {
            let data = try await command(["diff", "--name-only", "-z", "--no-ext-diff", "--no-textconv",
                                          "--no-renames", from, to, "--"]).stdout
            changed += try paths(data)
        }
        // Conservative case folding can refuse a harmless pair on case-sensitive volumes.
        // Source values are retained; these keys are only potential-collision lookups.
        func key(_ value: String) -> String { value.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")) }
        let writtenKeys = Set(changed.map { key($0.value) }), ignoredKeys = Set(ignored.map { key($0.value) })
        func prefixes(_ value: String) -> [String] {
            let components = value.split(separator: "/")
            var prefix = "", result: [String] = []
            for part in components { prefix += (prefix.isEmpty ? "" : "/") + part; result.append(prefix) }
            return result
        }
        for path in ignored where prefixes(key(path.value)).contains(where: writtenKeys.contains) {
            throw GitError.invalidInput("Potential ignored-file obstruction: " + path.value + ". Move this local data aside before replaying history. No history command was started.")
        }
        for path in changed where prefixes(key(path.value)).contains(where: ignoredKeys.contains) {
            throw GitError.invalidInput("Potential ignored-file/directory obstruction at " + path.value + ". Move ignored local data aside first. No history command was started.")
        }
    }
}
