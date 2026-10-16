import Foundation

public struct GraphSegment: Equatable, Sendable {
    public enum Level: Double, Sendable { case top = 0, node = 0.5, bottom = 1 }
    public let fromLane: Int
    public let toLane: Int
    public let fromLevel: Level
    public let toLevel: Level
    public let color: Int
}

public struct CommitGraphRow: Equatable, Sendable {
    public let oid: String
    public let lane: Int
    public let color: Int
    public let isMerge: Bool
    public let segments: [GraphSegment]
}

/// Expects child-before-parent order from Git --topo-order, not timestamp sorting.
/// Lines at the final row continue to unloaded parents rather than inventing roots.
public struct CommitGraph: Equatable, Sendable {
    public let rows: [CommitGraphRow]
    public let laneCount: Int
    public static let empty = CommitGraph(commits: [])

    public init(commits: [GitCommit]) {
        struct Lane { let oid: String; let color: Int }
        var lanes: [Lane] = []
        var rows: [CommitGraphRow] = []
        var nextColor = 0, width = 1
        for commit in commits {
            let existing = lanes.firstIndex { $0.oid == commit.oid }
            let lane: Int
            if let existing { lane = existing }
            else {
                lane = lanes.count
                lanes.append(Lane(oid: commit.oid, color: nextColor))
                nextColor += 1
            }
            let before = lanes
            let color = lanes[lane].color
            lanes.remove(at: lane)
            var insertion = min(lane, lanes.count)
            for (index, parent) in commit.parents.enumerated() {
                guard !lanes.contains(where: { $0.oid == parent }) else { continue }
                let parentColor = index == 0 ? color : nextColor
                if index != 0 { nextColor += 1 }
                lanes.insert(Lane(oid: parent, color: parentColor), at: insertion)
                insertion += 1
            }
            var segments: [GraphSegment] = []
            for (index, entry) in before.enumerated() where entry.oid != commit.oid {
                if let target = lanes.firstIndex(where: { $0.oid == entry.oid }) {
                    segments.append(.init(fromLane: index, toLane: target, fromLevel: .top,
                                          toLevel: .bottom, color: entry.color))
                }
            }
            if existing != nil {
                segments.append(.init(fromLane: lane, toLane: lane, fromLevel: .top,
                                      toLevel: .node, color: color))
            }
            for parent in commit.parents {
                if let target = lanes.firstIndex(where: { $0.oid == parent }) {
                    segments.append(.init(fromLane: lane, toLane: target, fromLevel: .node,
                                          toLevel: .bottom, color: lanes[target].color))
                }
            }
            width = max(width, before.count, lanes.count)
            rows.append(.init(oid: commit.oid, lane: lane, color: color,
                              isMerge: commit.parents.count > 1, segments: segments))
        }
        self.rows = rows
        self.laneCount = width
    }
}
