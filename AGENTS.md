# Forky

Native macOS Git client. Swift 6, macOS 14+, SwiftUI and narrow AppKit bridges.
ForkyCore owns Git invocation, parsing and repository semantics. Views never run Git directly.

- Never modify Fork.app, copy its code/assets, or bypass licensing. Implement independently.
- Never run write tests against user repositories. Use newly created temporary fixtures.
- Git arguments are arrays, never interpolated shell commands. Preserve NUL-delimited paths.
- Serialize repository operations; cancel stale reads without abandoning child cleanup.
- No implicit stage-all, reset, clean, push, checkout or automatic network operations.
- Commit only explicitly staged changes; hooks/signing are user-configured side effects.
- Do not claim atomicity against external Git clients or rollback after a failed write.
- Keep UI responsive; stable IDs, paged history, bounded process output.
- Run swift test and build Forky.xcodeproj. Use connected Xcode MCP when available.
- Cmd+U includes core and UI tests. Report unavailable UI coverage, never substitute mock success.
- Do not create Git commits unless requested.
