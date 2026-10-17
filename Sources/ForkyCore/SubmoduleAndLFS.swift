import Foundation

public enum SubmoduleState: String, Sendable {
    case upToDate = "Up to date"
    case different = "Different commit"
    case uninitialized = "Not initialized"
    case conflict = "Conflict"
    case notInspected = "Not inspected"
}
public struct SubmoduleStatus: Identifiable, Sendable {
    public let path: GitPath
    public let recordedOID: String
    public let checkedOutOID: String?
    public let state: SubmoduleState
    /// Commits in the submodule HEAD that the parent does not record.
    public let ahead: Int?
    /// Commits recorded by the parent that the submodule HEAD does not contain.
    public let behind: Int?
    public var id: String { path.value }
}
public struct SubmoduleReport: Sendable {
    public let entries: [SubmoduleStatus]
    /// Gitlinks beyond the inspection budget are listed without recursive reads.
    public let omitted: Int
}

public struct LFSLock: Identifiable, Sendable, Equatable {
    public let id: String
    public let path: String
    public let owner: String?
    public let lockedAt: String?
}

public struct LFSPointer: Sendable, Equatable {
    public let oid: String
    public let size: Int
}

public struct LFSImageResolution: Sendable {
    public let bytes: Data?
    public let isPointer: Bool
    public let note: String?
}

extension GitRepository {
    public static let submoduleInspectionLimit = 16
    public static let lfsLockLimit = 500
    public static let lfsObjectReadLimit = 64 * 1024 * 1024

    /// Reads gitlinks from the index and each initialized submodule's own HEAD.
    /// Working-tree dirtiness inside a submodule is deliberately not inspected.
    public func submoduleStatuses() async throws -> SubmoduleReport {
        try await gate.withPermit {
            let stage = try GitParsers.terminatedFields(try await command(["ls-files", "--stage", "-z"]).stdout)
            var gitlinks: [String: String] = [:], conflicted = Set<String>()
            for record in stage {
                guard let tab = record.firstIndex(of: 9) else { throw GitError.malformedOutput("Missing index path separator.") }
                let metadata = try GitParsers.string(Data(record[..<tab])).split(separator: " ")
                guard metadata.count == 3, GitParsers.isOID(String(metadata[1])),
                      (0...3).contains(Int(metadata[2]) ?? -1) else {
                    throw GitError.malformedOutput("Invalid index entry.")
                }
                guard metadata[0] == "160000" else { continue }
                let path = try GitPath(GitParsers.string(Data(record[(tab + 1)...])))
                let stageNumber = Int(metadata[2]) ?? -1
                if stageNumber == 0 { gitlinks[path.value] = String(metadata[1]) }
                else if stageNumber == 2 { gitlinks[path.value] = String(metadata[1]); conflicted.insert(path.value) }
                else { conflicted.insert(path.value); gitlinks[path.value] = gitlinks[path.value] ?? String(metadata[1]) }
            }
            let ordered = gitlinks.keys.sorted()
            var entries: [SubmoduleStatus] = []
            for (index, key) in ordered.enumerated() {
                let path = try GitPath(key), recorded = gitlinks[key] ?? ""
                if index >= Self.submoduleInspectionLimit {
                    entries.append(SubmoduleStatus(path: path, recordedOID: recorded, checkedOutOID: nil,
                                                   state: .notInspected, ahead: nil, behind: nil))
                    continue
                }
                let directory = root.appendingPathComponent(path.value).path
                let head = try await childValue(directory, ["rev-parse", "--verify", "HEAD"])
                if conflicted.contains(key) {
                    entries.append(SubmoduleStatus(path: path, recordedOID: recorded, checkedOutOID: head,
                                                   state: .conflict, ahead: nil, behind: nil))
                    continue
                }
                guard let head else {
                    entries.append(SubmoduleStatus(path: path, recordedOID: recorded, checkedOutOID: nil,
                                                   state: .uninitialized, ahead: nil, behind: nil))
                    continue
                }
                let countsText = try await childValue(directory, ["rev-list", "--left-right", "--count", recorded + "..." + head])
                // left counts commits under the recorded OID (behind); right counts submodule HEAD only (ahead).
                let counts = try countsText.flatMap { try GitParsers.divergence(Data($0.utf8)) }
                entries.append(SubmoduleStatus(path: path, recordedOID: recorded, checkedOutOID: head,
                                               state: head == recorded ? .upToDate : .different,
                                               ahead: counts?.1, behind: counts?.0))
            }
            return SubmoduleReport(entries: entries, omitted: max(0, ordered.count - Self.submoduleInspectionLimit))
        }
    }

    /// Runs one read-only Git command inside a submodule path; missing or uninitialized
    /// directories return nil rather than failing the whole status read.
    private func childValue(_ directory: String, _ arguments: [String]) async throws -> String? {
        guard FileManager.default.fileExists(atPath: directory) else { return nil }
        let result = try await command(["-C", directory] + arguments, accepted: [0, 128])
        guard result.status == 0 else { return nil }
        return try GitParsers.string(result.stdout).trimmingCharacters(in: .newlines)
    }

    /// Queries the configured LFS server. The caller must treat this as a network action.
    public func lfsLocks(expected: RepositorySnapshot) async throws -> [LFSLock] {
        try await gate.withPermit {
            let fresh = try await checkReviewed(expected)
            do {
                let result = try await command(["lfs", "locks", "--json"], network: true)
                return try GitParsers.lfsLocks(result.stdout)
            } catch GitError.commandFailed(let code, let text) {
                throw GitError.commandFailed(code, TransportPresentation.sanitize(text, using: fresh.collaboration.value?.credentials ?? []))
            }
        }
    }
}

extension GitParsers {
    /// Accepts `[{...}]` and `{"locks":[{...}]}` because git-lfs versions differ.
    public static func lfsLocks(_ data: Data) throws -> [LFSLock] {
        guard data.count <= 4 * 1024 * 1024 else { throw GitError.invalidInput("LFS lock output exceeds 4 MiB.") }
        let root = try JSONSerialization.jsonObject(with: data)
        let rows: [Any]
        if let array = root as? [Any] { rows = array }
        else if let object = root as? [String: Any], let array = object["locks"] as? [Any] { rows = array }
        else { throw GitError.malformedOutput("LFS locks were not a JSON array.") }
        guard rows.count <= GitRepository.lfsLockLimit else { throw GitError.invalidInput("LFS lock list exceeds \(GitRepository.lfsLockLimit) entries.") }
        return try rows.map { row in
            guard let object = row as? [String: Any],
                  let path = object["path"] as? String, !path.isEmpty, !path.utf8.contains(0),
                  let id = object["id"].map({ $0 as? String ?? String(describing: $0) }) else {
                throw GitError.malformedOutput("Invalid LFS lock record.")
            }
            _ = try GitPath(path)
            let owner: String?
            if let name = object["owner"] as? String { owner = name }
            else if let ownerObject = object["owner"] as? [String: Any] { owner = ownerObject["name"] as? String }
            else { owner = nil }
            return LFSLock(id: id, path: path, owner: owner, lockedAt: object["locked_at"] as? String)
        }
    }

    /// A pointer is small, versioned text; anything else is treated as raw content by callers.
    public static func lfsPointer(_ data: Data) -> LFSPointer? {
        guard data.count <= 1024, let text = String(data: data, encoding: .utf8),
              text.hasPrefix("version https://git-lfs.github.com/spec/v1\n") else { return nil }
        var oid: String?, size: Int?
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[0] == "oid" {
                guard parts[1].hasPrefix("sha256:") else { return nil }
                oid = String(parts[1].dropFirst("sha256:".count))
            } else if parts[0] == "size" { size = Int(parts[1]) }
        }
        guard let oid, oid.count == 64, oid.allSatisfy({ $0.isHexDigit }),
              let size, size >= 0 else { return nil }
        return LFSPointer(oid: oid, size: size)
    }
}

extension GitRepository {
    /// Resolves an LFS pointer only from objects already present locally. Never fetches.
    public func localLFSObject(_ pointer: LFSPointer) -> URL? {
        let prefix = String(pointer.oid.prefix(2)), suffix = String(pointer.oid.dropFirst(2).prefix(2))
        let url = commonDirectory.appendingPathComponent("lfs/objects/\(prefix)/\(suffix)/\(pointer.oid)")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.intValue == pointer.size else { return nil }
        return url
    }

    /// Replaces pointer bytes with the local LFS object when one is present.
    public func resolveLFSImage(_ data: Data?) -> LFSImageResolution {
        guard let data else { return LFSImageResolution(bytes: nil, isPointer: false, note: nil) }
        guard let pointer = GitParsers.lfsPointer(data) else {
            return LFSImageResolution(bytes: data, isPointer: false, note: nil)
        }
        guard let url = localLFSObject(pointer) else {
            return LFSImageResolution(bytes: nil, isPointer: true,
                                      note: "This side is an LFS pointer and its object is not stored locally. Forky does not fetch here; run git lfs fetch/pull outside this sheet.")
        }
        guard let object = try? Data(contentsOf: url, options: .mappedIfSafe), object.count == pointer.size,
              object.count <= Self.lfsObjectReadLimit else {
            return LFSImageResolution(bytes: nil, isPointer: true,
                                      note: "The local LFS object could not be read within the 64 MiB preview budget.")
        }
        return LFSImageResolution(bytes: object, isPointer: true, note: nil)
    }
}
