> Historical 79-Core / 20-UI phase, not the current capability boundary. See [VALIDATION.md](VALIDATION.md) for the later G01–G22 gate.

# Validation — advanced Git workflows

Executed **2026-10-16–17**, Apple Silicon / **macOS 27.0.1**, Xcode **27.0 (27A266a)**,
Swift **6.4**, Apple Git **2.54.0**. macOS 14 deployment target is not broader runtime evidence.

## Executed gate

- Source `swift test`: **79 passed**, 7 suites, including parameterized edge-byte cases.
- `./scripts/build.sh`: native app built successfully.
- Full `/usr/bin/time -l ./scripts/test.sh`: **TEST SUCCEEDED**.
- Independent xcresult summary: **99 passed, 0 failed, 0 skipped** = **79 core + 20 actual
  macOS UI tests**. Reporter totals are used, not manual parameter-invocation additions.
- Bundle: `.artifacts/Forky-20261017-001515.xcresult`.
- After the full gate, an additional contradictory-marker fail-closed guard was checked
  by another successful 79-test source run plus real conflict/merge and interactive-rebase
  UI reruns (`advanced-core-final.log`, `advanced-operation-final.log`). The full 99-test
  bundle predates that error-path refinement and a test-only bounded readiness wait;
  normal-flow UI coverage was rerun. The final source test run passes all 79 tests.
- Strict ad-hoc signature verification passed; not notarization.
- No connected Xcode MCP was found; repository scripts ran the actual Mac. Existing
  human-approved automation authorization remained usable.

Based on human-created `b9b8949`; no agent commit. All writes target newly created
isolated fixtures, never business repositories or actual remote accounts. Fork.app and
REA source were not modified. No input-source, clipboard, global Git-config or OS
security-setting changes were used for automation.

## Native UI coverage

All prior 13 journeys pass again: commit/history/unstage, graph/search/split, alphabetic
input, filtered batch, local/tracking/historical branches, remote publish/sync/activity,
clone/init, stash and cancellation. Seven new real journeys:

1. Stage one line → inspect actual index → unstage a hunk → verify unchanged worktree.
2. Real merge conflict → review stages → use Theirs → save/stage → verify no unmerged
   entries → Continue → verify actual two-parent merge commit.
3. Context-menu cherry-pick → verify file/commit → Revert → verify inverse commit/file removal.
4. Interactive plan → edit/reword stop → type replacement message → amend → Continue →
   verify actual message and restored branch.
5. Captured tree/blob → advance fixture HEAD externally → Blame still shows original
   content/SHA, not current working bytes.
6. Abort remains disabled until explicit discard approval → native abort → verify bytes/clean state.
7. Context-click a different commit from selection → tree footer identifies clicked OID.

Select-All is an intentional editor command; alphabetic typing uses Shift without
accidental Command shortcuts. Explicit screenshots are app-window-only.

## Core coverage

24 added test declarations (some parameterized) cover:

- Individual partial additions, reverse unstage, whole/separate hunks, unchanged worktree.
- Literal Unicode/newline names, no-final-newline, empty-file insertion/deletion, CRLF,
  combining characters in paths/content/author/summary.
- Stale worktree/index/HEAD, binary/symlink and malformed patch rejection.
- Base/ours/theirs, save-only retains unmerged state, explicit stage and merge Continue.
- Conflict replacement retains POSIX permissions and a real extended attribute.
- Stale edits/symlink destinations refuse without changing outside bytes.
- Explicit modify/delete resolution.
- Clean cherry-pick/revert, dirty refusal, conflict/Abort, stale Abort, empty cherry-pick Skip.
- Rebase reorder/fixup/drop, captured onto, invalid plans, configured updateRefs protection.
- Edit/reword/amend/Continue works after temporary editor input cleanup.
- Real rebase conflict stage semantics, resolution/Continue and Skip.
- Corrupt/symlink operation markers stay unknown, not idle.
- Ignored obstructions block initial onto, cherry-pick/revert, pending Continue and restore
  Abort, preserving local bytes and HEAD.
- Private temporary input cleanup survives owner cancellation.
- Frozen tree/blob/blame, nested newline names, binary/symlink and malformed blame distinctions.

Prior process, parser, history/ref races, collaboration, snapshot and four finalization/
cancellation lifecycle regressions remain. ACL copying is production code; no bespoke
ACL matrix ran. Metadata assertions directly cover mode and xattr, not every file flag.

## Failures found and structural fixes

- **Ignored overwrite:** pre-fix production-boundary test allowed rebase to overwrite
  local ignored data and move HEAD. `advanced-ignored-before.log` retains three failed
  expectations. HistorySafety now checks complete possible write paths BEFORE native
  mutation, not a downstream reset/cleanup or guessed rollback. Related pending/restore/
  commit replay regressions pass.
- **Bytes vs graphemes:** CRLF parameter failed under Character-based suffix/split;
  combining Unicode can also join protocol prefixes. Patch/blame now parse LF/ASCII
  byte boundaries once, preserving payload—not stripping CR or normalizing text.
- **Reverse patch:** -R swaps a/b prefixes; parser accepts both Git-produced directions.
- **UI harness:** initial tree selector hit a disabled background README label. Native
  hierarchy showed no selected tree row. Sheet-scoped selector passes focused and full runs.
- **Command ownership:** HistoryCommand replaces divergent context/detail dispatch;
  immutable clicked-vs-selected commit payload is covered by a distinct real UI test.
- Operation controls are read once and fingerprinted; raw marker presence is no longer
  independently reinterpreted as a boolean idle/active state.

## Measurements

One warm/incremental full gate: **428.75 s elapsed**, **37.76 s user + 28.37 s system CPU**,
BSD time maximum RSS **491.8 MiB**. These are runner-reported, NOT complete process-family
CPU/peak memory; XCTest/LaunchServices apps/services are not all captured.

Source core run was about 13 s; Xcode core phase reported 35.507 s. These environments
and the prior 68-test task are not equivalent benchmarks. No cold-run, before/after
product latency, agent-token accounting, large-repo throughput or speedup claim.
Apple metadata-skipped and XCTest responsiveness/QoS warnings remain; they are not
measurements of application responsiveness.

## Boundaries / unverified

- Partial staging: regular tracked text modifications only, not added/deleted/renamed/
  binary/mode-change files or submodules.
- Conflict editor: regular UTF-8 and explicit deletion, not binary/symlink/directory/
  rename conflicts or missing-parent recreation.
- Rebase: complete linear range ≤200; no merge-preserving/arbitrary exec/mainline UI.
  Reword is edit + explicit amend; squash accepts combined default messages. Unsupported
  external todos refuse Continue/Skip. A new merge-start UI is still absent.
- Checks are sequential, not cross-process atomic. Concurrent writers, malicious config/
  symlink races, unusual filesystem normalization, crash recovery and huge inventories
  are not verified or containment guarantees.
- Live HTTPS/SSH/authentication, every hook/filter/signing/helper, arbitrary descendants,
  cleanup retry after restart, all cancellation stages/ACLs/flags/permissions are unverified.
- No syntax highlighting, blame-to-history navigation or all binary/LFS/submodule cases.
  Oversized output refuses rather than silently truncating selectable data. GC may
  remove retained objects. Broad IME/accessibility/dark-mode, older OS/Intel,
  distribution signing/notarization and product-scale performance remain unverified.

See [ADVANCED_WORKFLOWS.md](ADVANCED_WORKFLOWS.md) for actual user-facing steps/limits.

## Local evidence

Ignored `.artifacts/`: `advanced-core.log`, `advanced-build.log`, initial
`advanced-ui.log`, fixed focused `advanced-blame.log`, `advanced-final.log`,
`advanced-summary.json`, pre-fix ignored-obstruction log and result bundles.
Window-only previews: `advanced-partial.png`, `advanced-conflict.png`,
`advanced-rebase.png`, `advanced-blame.png`.

Default failed-test diagnostics can include desktop recordings; these remain local
ignored evidence, never bundled assets. App:
`.artifacts/DerivedData/Build/Products/Debug/Forky.app`.

Previous workflow gate: 68 passed in `.artifacts/Forky-20261016-224731.xcresult`.
