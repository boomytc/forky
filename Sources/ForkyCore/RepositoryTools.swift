import Foundation
import Darwin

public struct GitSetting: Identifiable, Sendable {
    public let key: String
    public let local: String?
    public let effective: String?
    public var id: String { key }
}
public struct PatchImport: Sendable {
    let expected: RepositorySnapshot
    let bytes: Data
    public let preview: String
}
public enum LFSTask: Sendable {
    case status, track(GitPath), fetch(GitRemote), pull(GitRemote), lock(GitPath), unlock(GitPath)
}
extension GitRepository {
    public static let editableSettings = ["user.name", "user.email", "user.signingkey", "commit.gpgsign", "format.signoff", "commit.template", "merge.ff"]
    public func settings() async throws -> [GitSetting] {
        try await gate.withPermit {
            func value(_ key: String, local: Bool) async throws -> String? {
                let result = try await command(["config", "--null"] + (local ? ["--local"] : []) + ["--get", key], accepted: [0, 1])
                if result.status == 1 { return nil }
                var bytes = result.stdout
                guard bytes.last == 0 else { throw GitError.malformedOutput("Incomplete configuration value.") }
                bytes.removeLast()
                return try GitParsers.string(bytes)
            }
            var settings: [GitSetting] = []
            for key in Self.editableSettings {
                settings.append(GitSetting(key: key, local: try await value(key, local: true), effective: try await value(key, local: false)))
            }
            return settings
        }
    }
    /// Local config only; explicit backup before the first write. Returns the retained backup path.
    public func updateSettings(_ changes: [String: String?], expected: RepositorySnapshot) async throws -> URL {
        guard !changes.isEmpty, changes.keys.allSatisfy(Self.editableSettings.contains),
              changes.values.allSatisfy({ $0.map { !$0.utf8.contains(0) && $0.utf8.count <= 65536 } ?? true }) else {
            throw GitError.invalidInput("Only the named local repository settings can be edited here.")
        }
        return try await gate.withPermit {
            let fresh = try await checkReviewed(expected)
            _ = try checkConfiguration(expected, fresh)
            let config = commonDirectory.appendingPathComponent("config")
            guard let bytes = try SafeWorktree.readAbsolute(config, limit: runner.outputLimit) else { throw GitError.staleRepository }
            let backup = commonDirectory.appendingPathComponent("forky-config-backup-" + UUID().uuidString)
            let fd = Darwin.open(backup.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw GitError.invalidInput("Could not reserve an owner-only config backup.") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: bytes); try handle.close()
            do {
                for key in changes.keys.sorted() {
                    if let value = changes[key] ?? nil {
                        _ = try await command(["config", "--local", "--replace-all", key, value], write: true)
                    } else {
                        _ = try await command(["config", "--local", "--unset-all", key], accepted: [0, 5], write: true)
                    }
                }
            } catch {
                throw GitError.invalidInput("Configuration may be partly updated. Original backup retained at " + backup.path + ". " + error.localizedDescription)
            }
            return backup
        }
    }
    public func reviewPatch(at url: URL, expected: RepositorySnapshot) async throws -> PatchImport {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw GitError.unsupportedPath }
        return try await gate.withPermit {
            _ = try await checkReviewed(expected, clean: true)
            guard let bytes = try SafeWorktree.readAbsolute(url, limit: runner.outputLimit) else { throw GitError.invalidInput("Patch source is missing.") }
            let text = try GitParsers.string(bytes)
            let rows = bytes.split(separator: 10)
            guard !bytes.contains(0), !rows.contains(where: { $0 == Data("GIT binary patch".utf8) || $0.starts(with: Data("Binary files ".utf8)) }) else {
                throw GitError.invalidInput("This importer accepts bounded text patches, not binary expansion. No patch was applied.")
            }
            try await TemporaryInput.withFile(bytes) { file in
                _ = try await command(["apply", "--index", "--check", "--whitespace=nowarn", "--", file.path])
            }
            return PatchImport(expected: expected, bytes: bytes, preview: text)
        }
    }
    public func applyPatch(_ review: PatchImport) async throws {
        try await gate.withPermit {
            _ = try await checkReviewed(review.expected, clean: true)
            try await TemporaryInput.withFile(review.bytes) { file in
                _ = try await command(["apply", "--index", "--check", "--whitespace=nowarn", "--", file.path])
                try Task.checkCancellation()
                _ = try await command(["apply", "--index", "--whitespace=nowarn", "--", file.path], write: true)
            }
        }
    }
    public func exportPatch(oid: String) async throws -> Data {
        guard GitParsers.isOID(oid) else { throw GitError.staleRepository }
        return try await gate.withPermit {
            try await command(["format-patch", "--stdout", "--no-ext-diff", "--no-textconv", "--binary", "-1", oid, "--"]).stdout
        }
    }
    public func stagedReviewContext(expected: RepositorySnapshot) async throws -> String {
        try await gate.withPermit {
            _ = try await checkReviewed(expected)
            let data = try await command(["diff", "--cached", "--no-ext-diff", "--no-textconv", "--no-color"]).stdout
            let prefix = "Propose a concise commit message for this explicitly staged patch. Return a proposal, do not execute actions.\n\n"
            guard data.count + prefix.utf8.count <= runner.outputLimit else { throw GitError.invalidInput("Staged context exceeds the external-input budget.") }
            return prefix + (try GitParsers.string(data))
        }
    }
    public func exportPatch(oid: String, to destination: URL) async throws {
        guard destination.isFileURL, destination.path.hasPrefix("/") else { throw GitError.unsupportedPath }
        let bytes = try await exportPatch(oid: oid)
        try bytes.write(to: destination, options: .withoutOverwriting)
    }

    public func submoduleDirectory(_ path: GitPath, expected: RepositorySnapshot) async throws -> URL {
        try await gate.withPermit {
            _ = try await checkReviewed(expected)
            let data = try await command(["ls-files", "--stage", "-z", "--", path.value], literalPaths: true).stdout
            guard data.starts(with: Data("160000 ".utf8)), data.split(separator: 0).count == 1 else { throw GitError.invalidInput("Select a known submodule gitlink.") }
            let url = root.appendingPathComponent(path.value)
            let parent = try SafeWorktree.parent(root: root, path: path); close(parent.0)
            _ = try SafeWorktree.metadata(at: url)
            let child = try await GitRepository.open(url, runner: runner)
            guard try DirectoryIdentity.read(child.root) == DirectoryIdentity.read(url), child.gate !== gate else {
                throw GitError.invalidInput("This submodule is not initialized as its own repository.")
            }
            return child.root
        }
    }

    public func updateSubmodule(_ path: GitPath, expected: RepositorySnapshot) async throws {
        try await gate.withPermit {
            _ = try await checkReviewed(expected, clean: true)
            let data = try await command(["ls-files", "--stage", "-z", "--", path.value], literalPaths: true).stdout
            guard data.starts(with: Data("160000 ".utf8)), data.split(separator: 0).count == 1 else {
                throw GitError.invalidInput("Choose one existing submodule gitlink.")
            }
            guard let tab = data.firstIndex(of: 9) else { throw GitError.malformedOutput("Missing gitlink identity.") }
            let fields = try GitParsers.string(Data(data[..<tab])).split(separator: " ")
            guard fields.count == 3, fields[2] == "0", GitParsers.isOID(String(fields[1])) else { throw GitError.malformedOutput("Invalid gitlink identity.") }
            let target = String(fields[1]), directory = root.appendingPathComponent(path.value)
            let parent = try SafeWorktree.parent(root: root, path: path); close(parent.0)
            _ = try SafeWorktree.metadata(at: directory)
            let update = { @Sendable in
                _ = try await command(["submodule", "update", "--init", "--checkout", "--", ":(literal)" + path.value], write: true, network: true)
            }
            let child: GitRepository?
            var childFailure: String?
            do { child = try await GitRepository.open(directory, runner: runner) }
            catch is CancellationError { throw CancellationError() }
            catch { child = nil; childFailure = error.localizedDescription }
            if let child,
               try DirectoryIdentity.read(child.root) == DirectoryIdentity.read(directory), child.gate !== gate {
                try await child.gate.withPermit {
                    let state = try await child.readSnapshot()
                    guard !state.operationInProgress, state.changes.isEmpty else { throw GitError.dirtyWorktree }
                    let ignored = try await child.command(["ls-files", "--others", "--ignored", "--exclude-standard", "-z"]).stdout
                    if !ignored.isEmpty {
                        _ = try await child.readCommit(target) // missing target cannot establish ignored-file safety
                        if let head = state.head { try await child.protectIgnored(revisions: [target], transitions: [(head, target)]) }
                        else { throw GitError.invalidInput("Submodule identity is incomplete; move ignored data aside first.") }
                    }
                    try await update()
                }
            } else {
                if FileManager.default.fileExists(atPath: directory.path) {
                    guard try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else {
                        throw GitError.invalidInput("Uninitialized or unknown submodule directory contains local data; nothing was adopted. " + (childFailure ?? ""))
                    }
                }
                try await update()
            }
        }
    }
    public func addSubmodule(url: String, path: GitPath, expected: RepositorySnapshot) async throws {
        try TransportPresentation.validateNewSource(url)
        try await gate.withPermit {
            _ = try await checkReviewed(expected, clean: true)
            let parent = try SafeWorktree.parent(root: root, path: path); close(parent.0)
            guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(path.value).path) else { throw GitError.invalidInput("Submodule destination already exists.") }
            // Git owns .gitmodules/index changes; approval explicitly includes that staging.
            _ = try await command(["submodule", "add", "--", url, path.value], write: true, network: true)
        }
    }
    public func lfs(_ action: LFSTask, expected: RepositorySnapshot) async throws -> String {
        try await gate.withPermit {
            let fresh = try await checkReviewed(expected)
            let args: [String], network: Bool, write: Bool
            switch action {
            case .status: args = ["status"]; network = false; write = false
            case .track(let path): args = ["track", "--filename", "--", path.value]; network = false; write = true
            case .fetch(let remote):
                _ = try checkedRemote(remote, expected: expected, fresh: fresh)
                args = ["fetch", remote.name]; network = true; write = true
            case .pull(let remote):
                _ = try checkedRemote(remote, expected: expected, fresh: fresh)
                guard fresh.changes.isEmpty else { throw GitError.dirtyWorktree }
                args = ["pull", remote.name]; network = true; write = true
            case .lock(let path): args = ["lock", "--", path.value]; network = true; write = true
            case .unlock(let path): args = ["unlock", "--", path.value]; network = true; write = true
            }
            // Bring-your-own git-lfs; never install from an error path.
            do {
                let result = try await command(["lfs"] + args, write: write, network: network)
                return try GitParsers.string(result.stdout) + GitParsers.string(result.stderr)
            } catch GitError.commandFailed(let code, let text) {
                throw GitError.commandFailed(code, TransportPresentation.sanitize(text, using: fresh.collaboration.value?.credentials ?? []))
            }
        }
    }
    public func runTrustedTool(executable: URL, arguments: [String], input: String,
                               expected: RepositorySnapshot) async throws -> String {
        guard executable.isFileURL, executable.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable.path),
              arguments.count <= 100, arguments.allSatisfy({ !$0.utf8.contains(0) && $0.utf8.count <= 65536 }),
              input.utf8.count <= runner.outputLimit else { throw GitError.invalidInput("Review one executable, bounded JSON argv and input (≤4 MiB).") }
        return try await gate.withPermit {
            _ = try await checkReviewed(expected, allowOperation: true)
            return try await TemporaryInput.withFile(Data(input.utf8)) { file in
                let argv = arguments.map { $0.replacingOccurrences(of: "{input_file}", with: file.path) }
                let process = runner.usingExecutable(executable, timeout: 300)
                let result = try await process.run(argv, directory: root)
                guard result.status == 0 else { throw GitError.commandFailed(result.status, String(decoding: result.stderr, as: UTF8.self)) }
                return try GitParsers.string(result.stdout)
            }
        }
    }
}
