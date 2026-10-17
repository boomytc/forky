import Foundation

public enum ConflictChoice: String, CaseIterable, Sendable { case unresolved, ours, theirs, both, base }
public struct ConflictChunk: Identifiable, Sendable {
    public let id: Int
    public let raw: String
    public let ours: String
    public let theirs: String
    public let base: String?
}
public struct ConflictProgress: Equatable, Sendable {
    public let resolved: Int
    public let total: Int
    public var unresolved: Int { total - resolved }
}
public struct ConflictDocument: Sendable {
    private enum Part: Sendable { case text(String), chunk(ConflictChunk) }
    private let parts: [Part]
    public let chunks: [ConflictChunk]
    public init(_ text: String) throws {
        guard text.utf8.count <= 4 * 1024 * 1024 else { throw GitError.invalidInput("Conflict chunk input exceeds 4 MiB.") }
        var lineCount = 0
        for byte in text.utf8 where byte == 10 { lineCount += 1; if lineCount > 20_000 { throw GitError.invalidInput("Chunk navigation exceeds 20,000 lines; use the manual editor.") } }
        let bytes = Array(text.utf8), split = bytes.split(separator: 10, omittingEmptySubsequences: false)
        let lines = split.enumerated().map { index, row in String(decoding: row, as: UTF8.self) + (index + 1 < split.count ? "\n" : "") }
        func starts(_ line: String, _ prefix: String) -> Bool {
            let bytes = Array(line.utf8), marker = Array(prefix.utf8)
            guard bytes.starts(with: marker) else { return false }
            if bytes.count == marker.count { return true }
            return [9, 10, 13, 32].contains(bytes[marker.count])
        }
        var parts: [Part] = [], chunks: [ConflictChunk] = [], i = 0, plain = ""
        while i < lines.count {
            guard starts(lines[i], "<<<<<<<") else { plain += lines[i]; i += 1; continue }
            if !plain.isEmpty { parts.append(.text(plain)); plain = "" }
            let start = i; i += 1
            var ours = "", theirs = "", base: String?, section = 0, separator = false, ended = false
            while i < lines.count {
                let line = lines[i]
                if starts(line, "<<<<<<<") { throw GitError.invalidInput("Nested conflict markers require manual review.") }
                if starts(line, "|||||||") {
                    guard section == 0 else { throw GitError.invalidInput("Malformed conflict base marker.") }
                    section = 1; base = ""
                } else if starts(line, "=======") {
                    guard !separator else { throw GitError.invalidInput("Repeated conflict separator.") }
                    separator = true; section = 2
                } else if starts(line, ">>>>>>>") {
                    guard separator else { throw GitError.invalidInput("Conflict end without separator.") }
                    ended = true; i += 1; break
                } else {
                    if section == 0 { ours += line }
                    else if section == 1 { base = (base ?? "") + line }
                    else { theirs += line }
                }
                i += 1
            }
            guard ended else { throw GitError.invalidInput("Incomplete conflict markers; use the manual editor.") }
            let chunk = ConflictChunk(id: chunks.count, raw: lines[start..<i].joined(), ours: ours, theirs: theirs, base: base)
            chunks.append(chunk); parts.append(.chunk(chunk))
        }
        if !plain.isEmpty { parts.append(.text(plain)) }
        self.parts = parts; self.chunks = chunks
    }
    public func render(_ choices: [Int: ConflictChoice]) -> String {
        parts.map { part in
            switch part {
            case .text(let text): text
            case .chunk(let chunk):
                switch choices[chunk.id] ?? .unresolved {
                case .unresolved: chunk.raw
                case .ours: chunk.ours
                case .theirs: chunk.theirs
                case .both: chunk.ours + chunk.theirs
                case .base: chunk.base ?? chunk.raw
                }
            }
        }.joined()
    }

    /// Counts only chunks that belong to this document; unrelated keys are ignored.
    public func progress(_ choices: [Int: ConflictChoice]) -> ConflictProgress {
        let resolved = chunks.reduce(0) { total, chunk in
            (choices[chunk.id] ?? .unresolved) == .unresolved ? total : total + 1
        }
        return ConflictProgress(resolved: resolved, total: chunks.count)
    }

    /// The next unresolved chunk strictly after `id`, or the first one when `id` is nil.
    public func nextUnresolvedID(after id: Int?, choices: [Int: ConflictChoice]) -> Int? {
        chunks.first { chunk in
            (id.map { chunk.id > $0 } ?? true) && (choices[chunk.id] ?? .unresolved) == .unresolved
        }?.id
    }

    /// The previous unresolved chunk strictly before `id`, or the last one when `id` is nil.
    public func previousUnresolvedID(before id: Int?, choices: [Int: ConflictChoice]) -> Int? {
        chunks.last { chunk in
            (id.map { chunk.id < $0 } ?? true) && (choices[chunk.id] ?? .unresolved) == .unresolved
        }?.id
    }

    /// Bulk selection for one side; the caller still reviews the rendered result before saving.
    public func choices(_ choice: ConflictChoice) -> [Int: ConflictChoice] {
        Dictionary(uniqueKeysWithValues: chunks.map { ($0.id, choice) })
    }
}
