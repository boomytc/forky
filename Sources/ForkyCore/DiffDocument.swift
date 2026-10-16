import Foundation

public struct DiffLine: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case context, addition, deletion, hunk, header }
    public let id: Int
    public let text: String
    public let oldNumber: Int?
    public let newNumber: Int?
    public let kind: Kind
}

public struct DiffDocument: Equatable, Sendable {
    public let text: String
    public let lines: [DiffLine]
    public let additions: Int
    public let deletions: Int
    public let truncated: Bool
    public static let empty = DiffDocument(text: "")

    public init(text: String) {
        // Keep AppKit text layout bounded separately from the process output cap.
        let preview = String(text.prefix(500_000))
        self.text = preview
        self.truncated = preview.count < text.count
        var old = 0, new = 0, inHunk = false, plus = 0, minus = 0
        var result: [DiffLine] = []
        for (offset, line) in preview.components(separatedBy: "\n").enumerated() {
            let kind: DiffLine.Kind
            var oldNumber: Int?, newNumber: Int?
            if line.hasPrefix("@@ ") {
                let parts = line.split(separator: " ")
                if parts.count >= 3, parts[1].first == "-", parts[2].first == "+",
                   let oldStart = parts[1].dropFirst().split(separator: ",").first,
                   let newStart = parts[2].dropFirst().split(separator: ",").first,
                   let a = Int(oldStart), let b = Int(newStart) {
                    old = a; new = b; inHunk = true
                } else { inHunk = false }
                kind = .hunk
            } else if inHunk && line.hasPrefix("+") {
                kind = .addition; newNumber = new; new += 1; plus += 1
            } else if inHunk && line.hasPrefix("-") {
                kind = .deletion; oldNumber = old; old += 1; minus += 1
            } else if inHunk && line.hasPrefix(" ") {
                kind = .context; oldNumber = old; newNumber = new; old += 1; new += 1
            } else {
                kind = .header
                if line.hasPrefix("diff --git ") { inHunk = false }
            }
            result.append(DiffLine(id: offset, text: line, oldNumber: oldNumber, newNumber: newNumber, kind: kind))
        }
        self.lines = result
        self.additions = plus
        self.deletions = minus
    }
}
