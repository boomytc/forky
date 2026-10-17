import Foundation

public struct DiffOptions: Equatable, Sendable {
    public var context = 3
    public var wholeFile = false
    public var ignoreWhitespace = false
    public var wrap = false
    public var showWhitespace = false
    public init() {}
    var arguments: [String] {
        ["--unified=" + String(wholeFile ? 1_000_000 : min(100, max(0, context)))] + (ignoreWhitespace ? ["--ignore-all-space"] : [])
    }
}
