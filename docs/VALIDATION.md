# Validation — repository workflows

Executed **2026-10-16**, Apple Silicon / **macOS 27.0.1**, Xcode **27.0 (27A266a)**,
Swift **6.4**, Apple Git **2.54.0**. Deployment target 14.0 is not runtime verification
on macOS 14–26 or Intel.

## Executed gate

- Source `swift test`: **55 passed**, 6 suites.
- `./scripts/build.sh`: native app built during implementation.
- Full `/usr/bin/time -l ./scripts/test.sh`: **TEST SUCCEEDED**.
- xcresult independently reports **68 passed, 0 failed, 0 skipped**:
  **55 core + 13 actual macOS UI tests**.
- Result bundle: `.artifacts/Forky-20261016-224731.xcresult`.
- The Xcode test action rebuilds the app and test targets together. After that gate,
  comment/documentation and error-only wording/tag refinements were followed by another
  successful 55-test source run and final app build (including NUL stash-message rejection).
- Ad-hoc signature verified with `codesign --verify --strict`; not notarization.
- Connected Xcode MCP was unavailable; repository xcodebuild scripts used the actual
  macOS destination. Initial automation authorization timed out before tests began;
  after the human approved the system prompt, real UI tests ran successfully.
- REA's Git worktree remained clean. No agent-created commit.

## Native UI coverage

Existing six journeys remain: actual stage/commit/Git subject verification; unstage/root
history; real merge graph/tag/summary/split diff/search; alphabetic input/shortcut isolation;
local create/checkout; filtered explicit batch scope.

Seven added journeys:

1. Add remote → first publish → verify server OID and local upstream configuration.
2. Peer pushes to isolated bare server → Fetch (no worktree change) → Pull (file arrives)
   → local outgoing commit → Push → verify server OID → activity → close activity.
3. Clone a real temporary bare server → open → compare actual clone/server commit IDs.
4. Initialize new directory → open → verify unborn main and clean worktree.
5. Save stash → inspect actual diff → apply, keep recovery entry → drop separately,
   independently verify stash list and preserved working-file bytes.
6. Cancel a real delayed local fetch → cancellation notice → repository refreshed →
   writes re-enabled → activity retains cancellation outcome.
7. Fetch peer feature branch → create/checkout local tracking branch → verify upstream →
   select historical root commit → create branch there, not at HEAD and without switching.

All writes target new temporary fixtures. UI creation tests prefill source and parent
from test-only environment values, then confirm through real native controls; the
folder picker and arbitrary URL text entry are not thereby established. No user
keyboard-source, clipboard, global Git config or OS security setting was changed.
The human alone approved automation authorization.

## Core coverage

The previous parser/process/repository/graph/paging regressions remain, including
special NUL-framed paths, literal pathspec safety, rename direction, malformed/UTF-8
failures, conflicts, root/merge diffs, stale index, linked worktrees, hooks, operation
guards, process limits/deadlines/cancellation and frozen history under moving refs.

Added real-Git workflow tests cover:

- Publish, clone, Fetch, fast-forward Pull and Push against an isolated real bare server.
- Divergence rejects Pull and non-fast-forward Push; server/local heads are preserved.
- Push excludes implicit tags/extra configured refspecs.
- Stale configuration/HEAD, unsafe fetch mappings, mirrors and dirty Pull fail closed.
- Upstream/ahead/behind facts and concrete vs symbolic remote identities.
- Remote tracking checkout; dirty/stale/alias/existing-local-branch rejection.
- Historical branch creation uses selected OID, without switching.
- Stash preserves staged/unstaged split and opted-in untracked data.
- Untracked exclusion, dirty apply refusal, stale/renumbered selector refusal.
- Failed conflicted apply retains the recovery entry and exposes conflict status.
- Exclusive creation refuses existing folders; failed clone retains reserved location.
- Credential URL refusal before directory creation; absolute-path requirement.
- Known HTTP authentication redaction without hiding unrelated source values.
- Auxiliary metadata failure remains unknown and does not block local staging.

Four lifecycle regressions verify active/queued cancellation, cancellation during final
reconciliation, both write/read failures, and single-use ownership. These are distinct
from merely cancelling an active Git process.

## Observed brittleness and fixes

- Global literal pathspec mode interfered with stash cleanup. The pre-fix regression
  left new.txt in the worktree after saving it; apply then correctly refused dirty state.
  Controlled real-Git traces show stash invokes `git clean ... :/`: literal mode treats
  that top-level magic as a filename. Literal mode is now scoped to caller file operands,
  not exported to stash internals. No additional downstream clean/discard was added.
- A root accessibility identifier hid the activity Done button from native automation.
  Removed the unnecessary root override; native Done interaction now passes.
- Sandboxed UI fixtures could not execute a generated shebang helper directly.
  The owned test script is read by /bin/sh instead; no quarantine/security settings changed.
- Earlier alphabetic bulk typeText/IME issues remain addressed by explicit Shift/no
  Command key events and exact field/result checks—not proof of all input methods.

Successful logs retain Apple metadata-skipped and XCTest responsiveness/priority
warnings. No Swift compiler error remains; warnings are not latency measurements.

## Measurements and limits

One warm/incremental full test run: **297.51 s elapsed**, **29.20 s user + 20.73 s
system CPU**, BSD time maximum RSS **348.7 MiB**. This is not complete process-family
CPU/peak memory: XCTest/LaunchServices apps/services are not all represented. No
equivalent before/after product benchmark or speedup is claimed.

Unverified: live authenticated HTTPS/SSH/credential prompts, arbitrary remote/SSH helpers,
push-upstream failure recovery on all custom mappings, external concurrent writers,
all hooks/signing/filters, malicious config/symlink races, huge repos/ref/stash inventories,
all descendant cleanup/crash scenarios, large split scrolling, all IME/multiline/shortcuts,
folder picker entry, dark appearance/accessibility breadth, older OS/Intel or distribution.

Pull remains FF-only. Conflict editing/continue/abort, hunk staging, advanced history
operations, branch/tag lifecycle and account management are not implemented. Frozen
history can become unreadable if external GC removes retained objects. Stash drop's
preflight is not atomic against other Git clients.

## Local artifacts

Ignored `.artifacts/` retains `workflows-core.log`, `workflows-build.log`,
`workflows-final.log`, `workflows-summary.json`, focused/failed runs and bundles,
`workflows-literal-boundary.log`, and window-only `workflows-remote.png`,
`workflows-stash.png`, `workflows-activity.png`.

Default XCTest failure diagnostics can contain desktop recordings; those remain local
ignored artifacts, never bundled assets. Runnable app:
`DerivedData/Build/Products/Debug/Forky.app` under `.artifacts/`.

Previous alignment gate (42 tests): `.artifacts/Forky-20261016-214234.xcresult`.
Current work builds on human-created base `a13008d`; no commit was created in this turn.
