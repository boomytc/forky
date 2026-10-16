import Foundation
import CryptoKit

/// Auxiliary metadata failure must not masquerade as an empty remote/stash inventory,
/// nor prevent unrelated local worktree operations.
public enum Observed<Value: Sendable>: Sendable {
    case available(Value)
    case unavailable(String)
    public var value: Value? { if case .available(let value) = self { value } else { nil } }
    public var error: String? { if case .unavailable(let error) = self { error } else { nil } }
}

public struct GitRemote: Identifiable, Equatable, Sendable {
    public let name: String
    public let fetchURLs: [String]
    public let pushURLs: [String]
    public let fetchRefspecs: [String]
    public let isMirror: Bool
    public var id: String { name }
    public func ownsTrackingReference(_ reference: GitReference) -> Bool {
        reference.kind == .remoteBranch && reference.fullName.hasPrefix("refs/remotes/" + name + "/")
    }
    public func suggestedLocalName(for reference: GitReference) -> String? {
        guard ownsTrackingReference(reference) else { return nil }
        return String(reference.fullName.dropFirst(("refs/remotes/" + name + "/").count))
    }
    public var effectivePushURLs: [String] { pushURLs.isEmpty ? fetchURLs : pushURLs }
    public var limitation: String? {
        if isMirror { return "Mirror remotes are not supported by these scoped operations." }
        if fetchURLs.isEmpty { return "This remote has no configured fetch URL." }
        if (fetchURLs + pushURLs).contains(where: { $0.contains("\n") || $0.contains("\r") }) {
            return "Multiline remote URLs cannot be reviewed safely in this interface."
        }
        guard !fetchRefspecs.isEmpty, fetchRefspecs.allSatisfy({ spec in
            if spec.hasPrefix("^") { return !spec.contains(":") }
            let mapping = (spec.hasPrefix("+") ? String(spec.dropFirst()) : spec).split(separator: ":", omittingEmptySubsequences: false)
            return mapping.count == 2 && mapping[0].hasPrefix("refs/heads/")
                && mapping[1].hasPrefix("refs/remotes/" + name + "/")
        }) else { return "Custom fetch mappings outside this remote's tracking namespace are not supported." }
        return nil
    }
}

public struct BranchTracking: Equatable, Sendable {
    public let upstream: String
    public let remote: String
    public let mergeRef: String
    public let upstreamOID: String?
    public let ahead: Int?
    public let behind: Int?
    public var label: String { upstream.hasPrefix("refs/remotes/") ? String(upstream.dropFirst(13)) : upstream }
}

public struct GitStash: Identifiable, Equatable, Sendable {
    public let oid: String
    public let selector: String
    public let date: Date
    public let subject: String
    public var id: String { selector + ":" + oid }
}

public struct CollaborationSnapshot: Sendable {
    public let remotes: [GitRemote]
    public let tracking: BranchTracking?
    public let stashes: [GitStash]
    public let configurationDigest: String
    // Only explicit HTTP transport credentials are redacted. No name-based secrecy heuristics.
    let credentials: [(String, String)]
}

/// Display/error handling only. Never use a formatted URL to invoke Git.
public enum TransportPresentation {
    public static func display(_ source: String) -> String {
        guard var url = URLComponents(string: source),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user != nil || url.password != nil else { return source }
        url.user = nil; url.password = nil
        return url.string ?? source
    }

    public static func validateNewSource(_ source: String) throws {
        guard !source.isEmpty, !source.utf8.contains(0), !source.contains("\n"), !source.contains("\r") else {
            throw GitError.invalidInput("Enter a repository URL or local path without NUL or line breaks.")
        }
        let colon = source.firstIndex(of: ":")
        let isTransport = colon.map { colon in source.firstIndex(of: "/").map { colon < $0 } ?? true } ?? false
        guard source.hasPrefix("/") || isTransport else {
            throw GitError.invalidInput("Use an absolute local source path, a URL, or an SSH host:path address. Relative paths and shell tilde expansion are not used.")
        }
        guard display(source) == source else {
            throw GitError.invalidInput("Do not embed HTTP credentials in repository URLs. Use Git's credential helper or SSH agent.")
        }
    }

    static func redactions(_ sources: [String]) -> [(String, String)] {
        sources.flatMap { source -> [(String, String)] in
            var values: [(String, String)] = []
            let displayed = display(source)
            if source != displayed { values.append((source, displayed)) }
            if let url = URLComponents(string: source), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                for password in [url.password, url.percentEncodedPassword].compactMap({ $0 }) where !password.isEmpty {
                    values.append((password, "[credential redacted]"))
                }
            }
            return values
        }.sorted { $0.0.count > $1.0.count }
    }

    static func sanitize(_ message: String, using redactions: [(String, String)]) -> String {
        redactions.reduce(message) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }
}

struct GitConfiguration {
    struct Entry { let key: String; let value: String? }
    let entries: [Entry]
    let digest: String

    init(_ data: Data) throws {
        entries = try GitParsers.terminatedFields(data).map { raw in
            let record = try GitParsers.string(raw)
            let pair = record.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = pair.first, !key.isEmpty else { throw GitError.malformedOutput("Empty configuration key.") }
            return Entry(key: String(key), value: pair.count == 2 ? String(pair[1]) : nil)
        }
        digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var credentials: [(String, String)] { TransportPresentation.redactions(entries.compactMap(\.value)) }

    func remotes() throws -> [GitRemote] {
        var names: Set<String> = []
        for entry in entries where entry.key.hasPrefix("remote.") {
            if let dot = entry.key.lastIndex(of: "."), dot > entry.key.index(entry.key.startIndex, offsetBy: 7) {
                names.insert(String(entry.key[entry.key.index(entry.key.startIndex, offsetBy: 7)..<dot]))
            }
        }
        return try names.sorted().map { name in
            func values(_ key: String) -> [String] {
                entries.filter { $0.key == "remote." + name + "." + key }.compactMap(\.value)
            }
            var mirror = false
            if let entry = entries.last(where: { $0.key == "remote." + name + ".mirror" }) {
                if let value = entry.value?.lowercased() {
                    if ["false", "no", "off", "0", ""].contains(value) { mirror = false }
                    else if ["true", "yes", "on"].contains(value) { mirror = true }
                    else if let number = Int(value) { mirror = number != 0 }
                    else { throw GitError.malformedOutput("Invalid remote mirror setting.") }
                } else { mirror = true }
            }
            return GitRemote(name: name, fetchURLs: values("url"), pushURLs: values("pushurl"),
                             fetchRefspecs: values("fetch"), isMirror: mirror)
        }
    }
}

extension GitParsers {
    public static func stashes(_ data: Data) throws -> [GitStash] {
        let fields = try terminatedFields(data)
        guard fields.count.isMultiple(of: 4) else { throw GitError.malformedOutput("Invalid stash framing.") }
        return try stride(from: 0, to: fields.count, by: 4).map { i in
            let values = try fields[i..<i + 4].map(string)
            guard isOID(values[0]), values[1].hasPrefix("stash@{"), values[1].hasSuffix("}"),
                  let index = Int(values[1].dropFirst(7).dropLast()), index >= 0,
                  let time = TimeInterval(values[2]), time.isFinite else {
                throw GitError.malformedOutput("Invalid stash identity.")
            }
            return GitStash(oid: values[0], selector: values[1], date: Date(timeIntervalSince1970: time), subject: values[3])
        }
    }

    static func trackingFields(_ data: Data, branch: String) throws -> (String, String, String)? {
        if data.isEmpty { return nil }
        let lines = try string(data).split(separator: "\n")
        guard let line = lines.first, lines.count == 1 else { throw GitError.malformedOutput("Ambiguous tracking record.") }
        let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5, fields[0] == "refs/heads/" + branch, fields[4].isEmpty else {
            throw GitError.malformedOutput("Invalid tracking framing.")
        }
        if fields[1].isEmpty { return nil }
        guard fields[1].hasPrefix("refs/"), !fields[2].isEmpty, fields[3].hasPrefix("refs/heads/") else {
            throw GitError.malformedOutput("Invalid upstream identity.")
        }
        return (fields[1], fields[2], fields[3])
    }

    static func divergence(_ data: Data) throws -> (Int, Int) {
        let parts = try string(data).split(whereSeparator: { $0 == "\t" || $0 == "\n" || $0 == " " })
        guard parts.count == 2, let ahead = Int(parts[0]), let behind = Int(parts[1]), ahead >= 0, behind >= 0 else {
            throw GitError.malformedOutput("Invalid ahead/behind counts.")
        }
        return (ahead, behind)
    }
}
