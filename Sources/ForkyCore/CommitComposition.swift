import Foundation

/// What the commit UI should start from. The template is a prefill only: the message
/// editor content is the source of truth and nothing is appended without the user seeing it.
public struct CommitComposition: Sendable {
    /// Absolute path resolved from `commit.template`, or nil when the key is unset.
    public let templatePath: String?
    public let templateText: String?
    /// Why template text is absent or shortened. Never contains template content.
    public let note: String?
}

/// Explicit per-commit choice. `.configured` leaves Git's own configuration in effect.
public enum CommitSignOff: Sendable {
    case configured
    case include
    case omit

    var arguments: [String] {
        switch self {
        case .configured: []
        case .include: ["--signoff"]
        case .omit: ["--no-signoff"]
        }
    }
}

extension GitRepository {
    public static let commitTemplateLimit = 64 * 1024

    /// Reads `commit.template` without touching the index.
    /// `git commit -m` never applies the template, so the UI must prefill it itself.
    public func commitComposition() async throws -> CommitComposition {
        try await gate.withPermit {
            let templateSetting = try await effectiveConfiguration("commit.template")
            var seenPath: String?, text: String?, note: String?
            if let setting = templateSetting, !setting.isEmpty {
                let path = templateURL(for: setting)
                seenPath = path.path
                do {
                    let data = try Data(contentsOf: path, options: .mappedIfSafe)
                    if data.count > Self.commitTemplateLimit {
                        note = "Commit template is larger than 64 KiB. Nothing was prefilled."
                    } else if let value = String(data: data, encoding: .utf8) {
                        let comment = try await commentCharacter()
                        if let cleaned = Self.templatePrefill(value, comment: comment) { text = cleaned }
                        else { note = "Commit template has no text after removing comment lines." }
                    } else {
                        note = "Commit template is not valid UTF-8. Nothing was prefilled."
                    }
                } catch {
                    note = "Commit template could not be read at this path. Nothing was prefilled."
                }
            }
            return CommitComposition(templatePath: seenPath, templateText: text, note: note)
        }
    }

    private func effectiveConfiguration(_ key: String) async throws -> String? {
        let result = try await command(["config", "--null", "--get", key], accepted: [0, 1])
        if result.status == 1 { return nil }
        var bytes = result.stdout
        guard bytes.last == 0 else { throw GitError.malformedOutput("Incomplete configuration value.") }
        bytes.removeLast()
        return try GitParsers.string(bytes)
    }


    /// Git documents a relative `commit.template` against the top-level working tree.
    private func templateURL(for setting: String) -> URL {
        setting.hasPrefix("/") ? URL(fileURLWithPath: setting) : root.appendingPathComponent(setting)
    }

    private func commentCharacter() async throws -> Character {
        guard let value = try await effectiveConfiguration("core.commentChar") else { return "#" }
        // "auto" defers to Git's default; only a single byte can act as a comment prefix here.
        guard value.utf8.count == 1, let character = value.first else { return "#" }
        return character
    }

    /// Mirrors Git's default `cleanup=strip` closely enough for a starting point:
    /// comment lines, trailing whitespace, repeated blank lines and surrounding blanks are removed.
    static func templatePrefill(_ text: String, comment: Character) -> String? {
        // Swift treats CRLF as one grapheme, so normalize before splitting on newline.
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.hasSuffix("\r") ? String(raw.dropLast()) : String(raw)
            if line.first == comment { continue }
            while let last = line.last, last == " " || last == "\t" { line.removeLast() }
            if line.isEmpty, lines.last?.isEmpty == true { continue }
            lines.append(line)
        }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
