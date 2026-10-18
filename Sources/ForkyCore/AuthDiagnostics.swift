import Foundation

public struct RemoteAuthSummary: Sendable, Identifiable, Equatable {
    public let name: String
    /// Credentials removed; scheme, host, port and path are retained for diagnosis.
    public let displayURL: String
    public let scheme: String
    public let embedsCredentials: Bool
    public var id: String { name }
}

public struct AuthenticationDiagnostics: Sendable {
    public let sshAgentAvailable: Bool
    public let sshCommandConfigured: Bool
    public let publicKeyFiles: [String]
    public let gpgExecutable: String?
    public let signingKey: String?
    public let commitSigningEnabled: Bool
    public let remotes: [RemoteAuthSummary]
    public let notes: [String]

    /// Plain lines for the read-only settings sheet. No secret values are included.
    public var lines: [String] {
        var result = [
            "SSH agent: " + (sshAgentAvailable ? "socket present" : "no SSH_AUTH_SOCK"),
            "SSH command override: " + (sshCommandConfigured ? "configured (value not shown)" : "not configured"),
            "Public keys in ~/.ssh: " + (publicKeyFiles.isEmpty ? "none found" : publicKeyFiles.joined(separator: ", ")),
            "GPG executable: " + (gpgExecutable ?? "not found on PATH"),
            "Signing key: " + (signingKey ?? "(user.signingkey unset)"),
            "Commit signing (commit.gpgsign): " + (commitSigningEnabled ? "enabled" : "disabled")
        ]
        for remote in remotes {
            result.append("Remote \(remote.name): \(remote.displayURL)"
                          + (remote.embedsCredentials ? " · URL embeds credentials (redacted)" : ""))
        }
        result += notes
        return result
    }
}

extension GitRepository {
    /// Read-only authentication facts. Never reads private key material, never runs gpg or ssh.
    public func authenticationDiagnostics(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        pathDirectories: [String]? = nil
    ) async throws -> AuthenticationDiagnostics {
        try await gate.withPermit {
            let snapshot = try await readSnapshot()
            let remotes = (snapshot.collaboration.value?.remotes ?? []).compactMap { remote -> RemoteAuthSummary? in
                guard let url = remote.fetchURLs.first else { return nil }
                let redacted = Self.redactedRemoteURL(url)
                return RemoteAuthSummary(name: remote.name, displayURL: redacted.display,
                                         scheme: redacted.scheme, embedsCredentials: redacted.embedded)
            }.sorted { $0.name < $1.name }
            let key = try await effectiveConfiguration("user.signingkey")
            let signingKey = key.flatMap { $0.isEmpty ? nil : Self.shortKey($0) }
            let signing = try await effectiveConfiguration("commit.gpgsign").map(Self.boolean) ?? false
            let sshCommand = try await effectiveConfiguration("core.sshCommand")
            let environment = ProcessInfo.processInfo.environment
            let ambientSSHCommand = environment["GIT_SSH_COMMAND"] ?? ""
            let agent = environment["SSH_AUTH_SOCK"].flatMap { path -> String? in
                guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { return nil }
                return path
            }
            let directories = pathDirectories ?? (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            let gpg = Self.findExecutable("gpg", in: directories)
            let publicKeys = Self.publicKeyFiles(home: home)
            var notes: [String] = []
            if gpg == nil {
                notes.append("Commit signing needs gnupg and pinentry on PATH; Forky does not install them.")
            }
            if signingKey != nil && gpg == nil {
                notes.append("A signing key is configured but no gpg executable was found; commits may fail.")
            }
            if sshCommand != nil {
                notes.append("An SSH command override is active; inspect it yourself before fetching or pushing.")
            }
            if !ambientSSHCommand.isEmpty {
                // GitProcessRunner strips ambient GIT_* variables, so this cannot affect Forky's Git.
                notes.append("Ambient GIT_SSH_COMMAND is ignored by Forky's isolated Git environment; configure core.sshCommand instead.")
            }
            if remotes.contains(where: \.embedsCredentials) {
                notes.append("At least one remote URL embeds credentials. They stay in local Git config and are not shown here.")
            }
            notes.append("Forky does not store accounts, keys or passphrases; credential helpers and the SSH agent remain in charge.")
            return AuthenticationDiagnostics(sshAgentAvailable: agent != nil,
                                             sshCommandConfigured: sshCommand != nil,
                                             publicKeyFiles: publicKeys, gpgExecutable: gpg,
                                             signingKey: signingKey, commitSigningEnabled: signing,
                                             remotes: remotes, notes: notes)
        }
    }

    static func redactedRemoteURL(_ raw: String) -> (display: String, scheme: String, embedded: Bool) {
        guard !raw.contains("://"), !raw.hasPrefix("/") else {
            if raw.hasPrefix("/") { return ("local path", "file", false) }
            guard var components = URLComponents(string: raw) else { return ("(unparseable URL)", "unknown", false) }
            var embedded = components.user != nil || components.password != nil
            components.user = nil
            components.password = nil
            components.fragment = nil
            if let items = components.queryItems {
                var redacted = items
                for index in redacted.indices where Self.sensitiveQueryNames.contains(redacted[index].name.lowercased()) {
                    if redacted[index].value != nil { embedded = true }
                    redacted[index].value = "redacted"
                }
                components.queryItems = redacted
            }
            let display = components.string ?? "(unparseable URL)"
            return (display, components.scheme ?? "unknown", embedded)
        }
        // scp-like user@host:path carries no password; keep the user because it selects the SSH identity.
        guard let colon = raw.firstIndex(of: ":") else { return (raw, "local", false) }
        let host = String(raw[..<colon])
        return (host + ":" + String(raw[raw.index(after: colon)...]), "ssh", false)
    }

    private static let sensitiveQueryNames: Set<String> = [
        "token", "access_token", "private_token", "oauth_token", "id_token", "refresh_token",
        "password", "passwd", "pwd", "secret", "client_secret", "auth", "authorization",
        "key", "apikey", "api_key", "signature", "sig"
    ]

    static func shortKey(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 16 else { return trimmed }
        return String(trimmed.prefix(8)) + "…" + String(trimmed.suffix(4))
    }

    static func boolean(_ value: String) -> Bool {
        value.isEmpty || ["true", "yes", "on", "1"].contains(value.lowercased())
    }

    static func findExecutable(_ name: String, in directories: [String]) -> String? {
        for directory in directories.prefix(32) {
            guard directory.hasPrefix("/") else { continue }
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.path }
        }
        return nil
    }

    static func publicKeyFiles(home: URL) -> [String] {
        let directory = home.appendingPathComponent(".ssh", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return Array(entries.filter { $0.hasSuffix(".pub") && !$0.hasPrefix(".") }.sorted().prefix(16))
    }
}
