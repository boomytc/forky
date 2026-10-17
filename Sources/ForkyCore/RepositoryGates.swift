import Foundation

/// All sessions/worktrees in the same Git common directory share one serialization owner.
actor RepositoryGates {
    static let shared = RepositoryGates()
    private final class WeakGate {
        weak var value: AsyncGate?
        init(_ value: AsyncGate) { self.value = value }
    }
    private var gates: [String: WeakGate] = [:]
    func gate(for path: String) -> AsyncGate {
        gates = gates.filter { $0.value.value != nil }
        if let gate = gates[path]?.value { return gate }
        let gate = AsyncGate()
        gates[path] = WeakGate(gate)
        return gate
    }
}
