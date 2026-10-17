# Forky

A native Git workspace for macOS, independently implemented in SwiftUI, AppKit and
Swift 6. **macOS 14+**, original branding/assets, no third-party package dependencies.

## Build and run

```bash
open Forky.xcodeproj                 # Forky scheme → My Mac → ⌘R; ⌘U tests
./scripts/build.sh                  # ad-hoc development signing, no account needed
open .artifacts/DerivedData/Build/Products/Debug/Forky.app
# Optional startup repository:
open .artifacts/DerivedData/Build/Products/Debug/Forky.app --args --repository /absolute/path
```

No installation into /Applications, global tool changes or REA registration.
Bring your own Xcode/Command Line Tools and trusted Git; default is /usr/bin/git.
Tools → Git Settings can select another executable and explicit helper PATH.

## Workflows

- Independent repository tabs, recents, reopen-closed sessions, last-session tab restore (up to
  four) and saved repository workspaces with rename, ordering, replace-with-open-tabs and bounded
  persistence; commit drafts persist across launches.
- Open linked worktrees/subdirectories; clone/init only into newly reserved directories.
- Filesystem/foreground refresh, debounced invalidation and stale-state write protection.
- Per-file, filtered batch, exact line/hunk and inline stage/unstage; explicit destructive
  line discard has a separate review. Regular modified/new/deleted text is supported.
- Staged-only commits with `commit.template` prefill and an explicit per-commit
  `Signed-off-by` toggle; ordinary amend/reword with message-only default; per-repository drafts.
- Complete branch/tag lifecycle, remote URL/name/removal and upstream management.
- Captured graph/ref badges, frozen-root paging, message/author/committer/path/changed-text
  search, SHA navigation, date/first-parent filters and selectable merge-parent diffs.
- Embedded tree/blob/blame, rename-following file history, back navigation, two-revision
  or working comparisons, reflog recovery and separately approved reset modes.
- Unified/split diff, context/whitespace/wrap/hunk controls; image side/swipe/onion comparison
  with local LFS object resolution (pointer without a local object is reported, never fetched).
- Three-stage conflict editor with per-file chunk progress, previous/next unresolved
  navigation, bulk one-side choices, explicit save/stage and configured mergetool.
  There is no synchronized three-pane scrolling.
- Reviewed merge start (FF/no-ff/squash/no-commit), cherry-pick/revert with merge mainline
  and no-commit options, linear interactive rebase with backup/update-ref review.
- Existing operation Continue/Skip/Abort with captured identities and ignored-data protection.
- Remote fetch, FF-only Pull, explicit immutable branch/tag push, selected-remotes fetch;
  merge/rebase of a separately reviewed **already fetched** upstream.
- Stash save/preview/apply/drop, selected-file save, rename and success-then-drop pop.
- Worktree management, frozen text-patch import/check/apply and non-overwriting export.
- Local/inherited Git settings and original config backups; existing identity/signing/helpers.
- Submodule status with structured gitlink rows, ahead/behind and per-row update/open;
  bring-your-own LFS status/tracking/network/locks with a structured lock list.
- Local overview/statistics, manual bisect, bring-your-own Gitflow and explicit trusted
  executable/JSON-argv tools, including optional AI draft generation.

Use the **Tools** menu for secondary workflows. History context actions use the clicked
commit, not the old selection. Every action has a real handler or explicit unavailable
reason; optional helpers are never installed or silently emulated.

[Workflow guide](docs/WORKFLOWS.md) · [G01–G22 implementation matrix](docs/IMPLEMENTATION_MATRIX.md)
· [Architecture](docs/ARCHITECTURE.md) · [Validation](docs/VALIDATION.md)

## Safety and boundaries

Only open trusted repositories. Commands use direct argv and literal/NUL-framed paths;
the fixed rebase sequence-editor callback is the documented narrow exception.
Git hooks, filters, signing, helpers and URL rewrites remain configured user code,
not a sandbox. Non-UTF-8/unsafe paths refuse instead of being normalized to other files.

Shared repository gates serialize this app's sessions, not other clients. Captured
HEAD/index/config/ref/worktree facts are rechecked; writes—including failed/cancelled
ones—finish independent reconciliation. Stale/unavailable state disables writes.
Checks are sequential, not cross-client atomic locks. Cancellation is **not rollback**.
Only directly owned children are supervised; arbitrary descendants are not contained.

No automatic networking/stashing, force/mirror push, background remote polling, hidden
stage-all or checkout. Normal Pull stays FF-only; divergence requires explicit integration.
Configured helper/Gitflow/custom/AI code may have broader side effects and must be reviewed.
Terminal credential prompts are disabled. No new credential/account store or installation.
Known HTTP URL authentication is redacted; new embedded credentials are rejected.
Helper output can contain its own data: inspect diagnostics before sharing.

Clone/worktree creation reserves a new directory and retains failed/cancelled output.
Pop drops only after successful apply and unchanged list; reset/hunk discard/Skip/Abort
are explicitly destructive and cannot recover unstaged data from a reflog or backup tag.
Transport can partially succeed; Activity retains full latest diagnostics plus bounded
session previews. Push never silently includes unselected refs or force options.

Process output: 4 MiB/stream; deadlines 30 s local, 300 s transport/history tools, 900 s
creation. Display diffs preview 500,000 characters with a truncation marker; selectable
patches must be complete (20,000 lines). Conflict editing ≤4 MiB/file, retained drafts
16 MiB/session. Rebase/bisect review ≤200 commits; blame ≤20,000 rows. File history and
reflog load 200 records per page on request; the sheet states that loaded rows are not
proof of complete history. Oversize/unknown input is not an empty successful result.

Deliberate remaining exclusions: partial rename/type/mode/binary edits, complex conflict
types, merge-preserving/arbitrary-exec rebase, syntax/word diff, built-in service accounts
or AI providers, automatic bisect-run and notarized distribution. Specialized helper and
platform coverage is explicitly limited in the validation report, not full Fork parity.

## Test

```bash
swift test
./scripts/test.sh
./scripts/test.sh -only-testing:ForkyUITests/ForkyUITests/testNormalAmendMessageOnly
```

Latest full gate: **147 passed = 116 Core + 31 native UI, 0 failed, 0 skipped**.
Fixtures are newly created and isolated; never Fork.app, business repositories, actual
remote accounts or global Git config. Results/screenshots remain ignored .artifacts files.

Sources/ForkyCore owns typed Git semantics/processes; Sources/Forky owns state/views.
Xcode owns the app/UI tests, SwiftPM owns Core/tests. Synchronized groups discover new
Swift files; scripts/generate-project.py reproduces the project, generate-icon.swift the
original artwork. No proprietary Fork code/assets or licensing behavior is copied.
