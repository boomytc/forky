import Foundation

public struct SplitDiffRow: Equatable, Sendable {
    public let old: DiffLine?
    public let new: DiffLine?
}

/// Visual pairing only: this never claims deleted and added lines are semantic matches.
public struct SplitDiff: Equatable, Sendable {
    public let rows: [SplitDiffRow]

    public init(document: DiffDocument) {
        var rows: [SplitDiffRow] = []
        var deleted: [DiffLine] = [], added: [DiffLine] = []
        func flush() {
            for index in 0..<max(deleted.count, added.count) {
                rows.append(.init(old: index < deleted.count ? deleted[index] : nil,
                                  new: index < added.count ? added[index] : nil))
            }
            deleted.removeAll(keepingCapacity: true)
            added.removeAll(keepingCapacity: true)
        }
        for line in document.lines {
            switch line.kind {
            case .deletion:
                // A new deletion block after additions must not cross-match blocks.
                if !added.isEmpty { flush() }
                deleted.append(line)
            case .addition: added.append(line)
            case .context, .hunk, .header:
                if line.text.hasPrefix("\\ No newline at end of file") {
                    // Keep the source marker beside the side to which it belongs.
                    if !added.isEmpty {
                        flush(); rows.append(.init(old: nil, new: line))
                    } else if !deleted.isEmpty {
                        flush(); rows.append(.init(old: line, new: nil))
                    } else { rows.append(.init(old: line, new: line)) }
                } else {
                    flush(); rows.append(.init(old: line, new: line))
                }
            }
        }
        flush()
        self.rows = rows
    }
}
