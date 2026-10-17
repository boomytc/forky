import Foundation

public struct PatchLine: Identifiable, Sendable {
    public enum Kind: Sendable { case context, addition, deletion }
    public let id: Int
    public let kind: Kind
    public let text: String
    public internal(set) var noNewline: Bool
    public var isChange: Bool { kind != .context }
}
public struct PatchHunk: Identifiable, Sendable {
    public let id: Int
    public let header: String
    let oldStart: Int
    public let lines: [PatchLine]
    public var changeIDs: Set<Int> { Set(lines.filter(\.isChange).map(\.id)) }
}

/// Complete Git patch plus selectable facts, never a truncated display preview.
public struct PartialPatch: Sendable {
    let raw: String
    let header: String
    private let deletesFile: Bool
    public let hunks: [PatchHunk]
    public var changeIDs: Set<Int> { Set(hunks.flatMap { $0.changeIDs }) }

    init(_ raw: String) throws {
        guard !raw.utf8.contains(0), raw.utf8.last == 10 else { throw GitError.invalidInput("Partial staging needs a complete text patch.") }
        let rows = try Data(raw.utf8).split(separator: 10, omittingEmptySubsequences: false).dropLast().map { try GitParsers.string(Data($0)) }
        guard rows.count <= 20_000 else { throw GitError.invalidInput("This patch exceeds the 20,000-line selection budget. Stage the complete file instead.") }
        guard rows.first?.hasPatchPrefix("diff --git ") == true,
              rows.filter({ $0.hasPatchPrefix("diff --git ") }).count == 1,
              !rows.contains(where: { row in ["old mode ", "new mode ", "rename from ", "Binary files ", "GIT binary patch"].contains(where: row.hasPatchPrefix) }),
              let first = rows.firstIndex(where: { $0.hasPatchPrefix("@@ ") }) else {
            throw GitError.invalidInput("Line selection requires a complete regular text patch; mode changes, renames and binaries need whole-file actions.")
        }
        let headers = rows[..<first]
        let validPaths = [("a/", "b/"), ("b/", "a/")].contains { old, new in
            (headers.contains(where: { $0.hasPatchPrefix("--- " + old) }) && headers.contains(where: { $0.hasPatchPrefix("+++ " + new) }))
                || (headers.contains(where: { $0.hasPatchPrefix("--- \"" + old) }) && headers.contains(where: { $0.hasPatchPrefix("+++ \"" + new) }))
        }
        let creates = rows.contains(where: { $0.hasPatchPrefix("new file mode ") })
        let deletes = rows.contains(where: { $0.hasPatchPrefix("deleted file mode ") })
        let nullPaths = (creates && headers.contains("--- /dev/null") && headers.contains(where: { $0.hasPatchPrefix("+++ ") }))
            || (deletes && headers.contains("+++ /dev/null") && headers.contains(where: { $0.hasPatchPrefix("--- ") }))
        guard validPaths || nullPaths else {
            throw GitError.malformedOutput("Unexpected patch paths.")
        }
        self.raw = raw
        deletesFile = deletes
        header = headers.joined(separator: "\n") + "\n"
        var result: [PatchHunk] = [], index = first, nextID = 0
        while index < rows.count {
            let title = rows[index]
            let fields = title.utf8.split(separator: 32, maxSplits: 4).map { String(decoding: $0, as: UTF8.self) }
            guard fields.count >= 4, fields[0] == "@@", fields[3] == "@@" else { throw GitError.malformedOutput("Invalid patch hunk.") }
            func range(_ value: String, prefix: Character) throws -> (Int, Int) {
                guard value.first == prefix else { throw GitError.malformedOutput("Invalid patch range.") }
                let parts = value.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
                guard (1...2).contains(parts.count), let start = Int(parts[0]), start >= 0,
                      let count = parts.count == 2 ? Int(parts[1]) : 1, count >= 0,
                      start <= Int.max - 20_001, count <= 20_000 else { throw GitError.malformedOutput("Invalid patch coordinates.") }
                return (start, count)
            }
            let old = try range(fields[1], prefix: "-"), new = try range(fields[2], prefix: "+")
            index += 1
            var lines: [PatchLine] = []
            while index < rows.count && !rows[index].hasPatchPrefix("@@ ") {
                let row = rows[index]
                if row == "\\ No newline at end of file" {
                    guard !lines.isEmpty, !lines[lines.count - 1].noNewline else { throw GitError.malformedOutput("Invalid newline marker.") }
                    lines[lines.count - 1].noNewline = true
                } else {
                    let kind: PatchLine.Kind
                    switch row.utf8.first {
                    case 32: kind = .context
                    case 43: kind = .addition
                    case 45: kind = .deletion
                    default: throw GitError.malformedOutput("Invalid patch line.")
                    }
                    lines.append(PatchLine(id: nextID, kind: kind, text: String(decoding: row.utf8.dropFirst(), as: UTF8.self), noNewline: false))
                    nextID += 1
                }
                index += 1
            }
            guard lines.filter({ $0.kind != .addition }).count == old.1,
                  lines.filter({ $0.kind != .deletion }).count == new.1 else { throw GitError.malformedOutput("Incomplete patch hunk.") }
            result.append(PatchHunk(id: result.count, header: title, oldStart: old.0, lines: lines))
        }
        hunks = result
    }

    /// Unselected deletions become context; unselected additions are omitted.
    /// Unstaging is also a forward patch FROM the index, produced by Git diff -R.
    public func selecting(_ selection: Set<Int>) throws -> String {
        guard !selection.isEmpty, selection.isSubset(of: changeIDs) else { throw GitError.invalidInput("Select changed lines or a complete hunk.") }
        var selectedHeader = header
        if deletesFile && selection != changeIDs {
            // A subset of a deletion leaves a normal file in the index.
            let rows = header.components(separatedBy: "\n")
            guard let old = rows.first(where: { $0.hasPatchPrefix("--- ") }) else { throw GitError.malformedOutput("Missing source path.") }
            selectedHeader = rows.filter { !$0.hasPatchPrefix("deleted file mode ") && !$0.hasPatchPrefix("index ") }
                .map { $0 == "+++ /dev/null" ? "+++ " + old.dropFirst(4) : $0 }.joined(separator: "\n")
        }
        var output = selectedHeader, delta = 0
        for hunk in hunks where !selection.isDisjoint(with: hunk.changeIDs) {
            var body = "", oldCount = 0, newCount = 0
            for line in hunk.lines {
                let prefix: String
                switch line.kind {
                case .context: prefix = " "
                case .addition:
                    if !selection.contains(line.id) { continue }
                    prefix = "+"
                case .deletion: prefix = selection.contains(line.id) ? "-" : " "
                }
                if prefix != "+" { oldCount += 1 }
                if prefix != "-" { newCount += 1 }
                body += prefix + line.text + "\n"
                if line.noNewline { body += "\\ No newline at end of file\n" }
            }
            let newStart = hunk.oldStart + delta + (oldCount == 0 ? 1 : (newCount == 0 ? -1 : 0))
            output += "@@ -\(hunk.oldStart),\(oldCount) +\(newStart),\(newCount) @@\n" + body
            delta += newCount - oldCount
        }
        return output
    }
}

private extension String {
    func hasPatchPrefix(_ prefix: String) -> Bool { utf8.starts(with: prefix.utf8) }
}

public struct PartialReview: Sendable {
    let root: URL
    let expected: RepositorySnapshot
    let change: FileChange
    public let side: DiffSide
    public let writesWorktree: Bool
    public let patch: PartialPatch
}
