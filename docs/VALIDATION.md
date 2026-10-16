# Validation — workflow alignment iteration

Executed on **2026-10-16**, Apple Silicon, **macOS 27.0.1**, **Xcode 27.0
(27A266a)**, **Swift 6.4**, Apple Git **2.54.0**. Deployment target remains
macOS 14.0; runtime on macOS 14–26 and Intel is not established.

## Final gate

- `swift test`: **36 core tests passed**, 4 suites.
- `./scripts/build.sh`: native arm64 app built successfully during implementation.
- Final `/usr/bin/time -l ./scripts/test.sh`: **TEST SUCCEEDED**.
- Result: **42 passed, 0 failed, 0 skipped**, independently read from xcresult summary:
  **36 core + 6 actual macOS UI tests**.
- Result bundle: `.artifacts/Forky-20261016-214234.xcresult`.
- The final Xcode test action rebuilds the application and tests together.
- `codesign --verify --strict`: local ad-hoc app signature valid. This is not notarization.
- No connected Xcode MCP tools were available; the native Xcode project and actual
  macOS destination were built/tested through the repository's xcodebuild scripts.

## Real native UI journeys

1. Working diff → stage → type message → commit staged → clean worktree, with
   independent real Git subject verification.
2. Stage → unstage → All Commits → native table/root-commit diff.
3. A genuinely branched/merged/tagged temporary repository → split diff with distinct
   old/new content → graph/tag badge → full merge summary → message search → clear.
4. Uppercase CREATE → filtered root commit; uppercase NEEDLE → no matches.
   Assert no unintended New Branch sheet, including uppercase N.
5. Type UIFEATURE → create without switching → branch context menu → confirm
   checkout → independently verify current branch and clean status with Git.
6. Type KEEP file filter → confirm staging exactly two listed files → independently
   verify index paths → confirm unstage → clear filter → all files still exist.

All fixtures are newly created temporary repositories. Fixture HOME is outside the
worktree. No write test targets user repositories or Fork.app.

## Core regressions

Existing parser/process/repository coverage remains: NUL-framed special filenames,
renames, malformed/non-UTF-8 rejection, conflicts, log bodies, diff numbering/truncation,
unborn repositories, explicit staged-only commits, stale index, linked worktrees,
failed hooks, ongoing operations, disabled external diff, ambient Git redirection,
process limits/deadline/cancellation/launch failure and cancelled gate waiters.

Added coverage:

- Merge graph parent edges, disconnected roots, page-prefix layout stability.
- Annotated tag object vs commit identity; non-commit/nested target uncertainty.
- Split line pairing, unequal blocks, hunk boundaries and no-newline markers.
- Explicit batch path scope and unborn unstaging without deleting files.
- Create without switching; invalid branch names and shorthand rejection.
- Dirty/untracked worktree protection, ignored file preservation and other-worktree
  ownership; stale HEAD and moved destination rejection.
- Literal case-insensitive message/body search and annotated-tag history.
- 205 commits paged across an external ref advance without missing/duplicate commits.
- Ref advances **during** its metadata read: a test wrapper lets real Git emit old
  facts, advances the real temporary ref, then returns. This test was observed failing
  before the fix and passing after peeling the captured object OID instead of rereading
  the mutable name. Raw ref/log outputs are from real Git, not fabricated fixtures.

## Harness findings

Early native UI attempts hit Touch Bar mirrors when querying confirmation buttons;
queries now scope alerts to real windows.

With the active non-Latin input source, bulk `typeText` for alphabetic fields left
composition uncommitted and one attempt invoked a menu shortcut. The final alphabetic
journeys send each key with **explicit Shift and no Command**, finish composition,
and verify exact editor values, search results and Git outcomes. Keyboard-source and
clipboard settings were never changed. This is not proof of every IME/input method.

The successful run still contains Apple's metadata-skipped and XCTest event-synthesis /
priority-inversion warnings. No Swift compiler errors occurred. These diagnostics
do not constitute application responsiveness measurements.

## Measurements and unavailable coverage

One **warm/incremental development test run**, not a product benchmark:
131.31 s elapsed, 12.05 s user and 9.58 s system CPU. BSD time reported maximum RSS **321.4 MiB**. That number is
not simultaneous whole-process-family memory; LaunchServices/XCTest-controlled apps
and services are not fully represented. No equivalent before/after product workflow
was benchmarked, and no speedup is claimed.

Not measured: large-repository UI latency, graph scrolling, complete family CPU/peak
memory, cold builds, massive ref inventories or every cleanup phase. Not verified:
long-distance split-scroll synchronization by automation, all double-click/copy/Finder
paths, draft switching, all shortcuts/IME/multiline inputs, dark appearance screenshots,
interactive signing/filters, crash recovery, arbitrary descendants, malicious repository
configuration, every submodule/binary/merge case, older OS/Intel, or distribution.
Frozen history can fail if external GC removes retained objects.

## Retained artifacts

Ignored under `.artifacts/`:

- `alignment-core-final.log`, `alignment-build.log`, `alignment-final.log`,
  `alignment-summary.json`, earlier focused/failed runs and xcresult bundles.
- `alignment-ref-regression-before.log`: observed pre-fix failure.
- `alignment-graph.png`, `alignment-split.png`, `alignment-history.png`,
  `alignment-clean.png`: explicit **window-only** previews.
- `DerivedData/Build/Products/Debug/Forky.app`: runnable native prototype.

Default XCTest failure diagnostics can contain desktop recordings; they stay ignored
local artifacts, never project assets. Reference screenshots also stay ignored.

The existing base commit is `3537273`. No project commit was created by this iteration,
no global tool/config installation was performed, and the REA worktree stayed unchanged.
