# Forky

A focused, native Git workspace for macOS. Independently implemented in SwiftUI,
AppKit and Swift 6; **macOS 14+**, no third-party package dependencies.

## Open and run

```bash
cd /Users/boom/workspace/forky
open Forky.xcodeproj
```

Select the **Forky** scheme, destination **My Mac**, then **⌘R**.
Use **⌘U** for core and native UI tests. A local development signing team may be
selected in Xcode; the provided scripts use ad-hoc signing without an Apple account.

Terminal build:

```bash
./scripts/build.sh
open .artifacts/DerivedData/Build/Products/Debug/Forky.app
```

Open a specific trusted repository:

```bash
open .artifacts/DerivedData/Build/Products/Debug/Forky.app --args --repository /absolute/path/to/repo
```

No installation into /Applications, global tool changes, or REA MCP registration is required.
The app invokes `/usr/bin/git`; Xcode / Command Line Tools must already be available.

## Current workflows

- Open an existing worktree/subdirectory and switch between recent repositories.
- Clone or initialize in a **new** folder, then open it; existing directories are never adopted.
- Add remotes, fetch tracking refs, pull **fast-forward only**, and push/publish one reviewed
  branch with optional upstream setup. Explicit remote/destination review before network access.
- Locally observed upstream / ahead / behind state; Fetch updates it, not a background network poll.
- Save / preview / apply / drop stashes. Including untracked files is opt-in; applying keeps
  the recovery entry, including on conflict. Restore staged/unstaged separation optionally.
- Cancellable long operations, uncancelled final state checks, and a bounded session activity
  list identifying the repository. Cancellation and errors are never presented as rollbacks.
- Collapsible branch/remote/tag sidebar with a live name filter.
- Connected, topological commit graph with local/remote/annotated-tag badges.
- Frozen-root history paging (200 commits per page) and literal, case-insensitive
  **commit-message** search across the selected history, not just loaded rows.
- Commit summary: full SHA, parents, author/email, date, full body and references;
  changes use root or first-parent merge diffs.
- Compact changed-file list, file filtering, unified or synchronized side-by-side
  line-numbered diff, and Finder/copy-path context actions.
- Per-file stage/unstage by button, context menu or double-click. Stage All / Unstage
  All require confirmation; with a filter, **only visible listed files** are affected.
- Commit **only explicitly staged files**, with stale-index/conflict/operation checks,
  soft summary-length guidance and in-memory drafts when switching repositories.
- Create a branch at HEAD or the **selected historical commit without switching**. Checkout is a separate,
  confirmed local-branch action, requiring a clean worktree and unchanged destination.
  Single-clicking a branch/tag only filters history; double-clicking a local branch
  requests checkout confirmation. Remote branches can create and switch to a new local
  **tracking branch** after confirmation; symbolic aliases are not checkout targets.
- ⌘O open, ⌘R refresh, ⌘1 changes, ⌘2 history, ⌘3 stashes, ⇧⌘N new branch,
  ⇧⌘S stash, ⌘↩ commit.
- Native appearance, resizable panes and original Forky artwork.

Not yet implemented: hunk/line staging, branch/tag deletion, stash pop, interactive
merge/rebase/cherry-pick/revert, conflict editor/continue/abort controls, blame/file tree,
automatic filesystem watching, credential/account management, AI, configurable Git
executable or notarization. Diverged pulls intentionally stop rather than guessing a policy.

See [the alignment notes](docs/ALIGNMENT.md) for reference sources and remaining gaps.

## Safety and limits

Only open repositories you trust. Git can invoke configured clean/smudge filters, signing
tools, commit hooks and checkout hooks. Forky disables external diff/textconv and fsmonitor commands for its
queries, but it is **not a sandbox for malicious Git configuration**.

Commands use argv arrays, literal pathspecs and NUL-framed output, not a shell.
Ambient GIT_* overrides are discarded to preserve the selected worktree.
Operations share a cancellable repository gate. Read failure is never an empty clean
repository; stale snapshots disable writes. Existing-repository writes, successful or
not, are followed by a refresh. Successful creation opens/reads the new repository;
failed creation retains its location for inspection. Failures are not rollbacks.

Before commit, Forky compares HEAD and the staged diff with the reviewed snapshot.
This catches many external index changes, but is **not an atomic lock against other Git
clients**. Do not concurrently write the same repository from another client.

Process output is limited to 4 MiB per stream. Local commands have a 30-second deadline;
transport commands use 300 seconds, creation/clone uses 900 seconds. The diff
renderer separately previews at most 500,000 characters and marks truncation.
Timeout/cancellation controls the directly owned Git process, not arbitrary descendants
started by hooks or filters. A helper that keeps output open produces an explicit
incomplete-output error. A failed or interrupted write may have already changed state;
inspect/refresh before retrying. Non-UTF-8 paths are rejected rather than rewritten.

There are no automatic remote operations, force operations, discard/reset/clean actions,
or hidden stage-all/checkout. Checkout refuses dirty worktrees, refuses overwriting ignored
files, does not recurse into submodules, and respects other worktrees' branch ownership.

Network access happens only after your explicit confirmation. Git URL rewrite rules,
SSH agent/configuration, credential helpers, remote helpers and pre-push hooks remain
effective. No new credential storage/account login is provided. Terminal credential prompts
are disabled; configure an existing helper/agent if authentication fails. Known HTTP URL
userinfo is hidden in remote presentation/errors; new URLs with embedded credentials are
rejected. Helper/hook output can contain its own data; review diagnostics before sharing.
New local source paths must be absolute; there is no shell tilde expansion.

Fetch deliberately omits pruning, automatic tags and recursive submodules. Mirror and
custom fetch mappings outside a remote's tracking namespace fail closed. Push never
forces or follows tags and sends one explicit immutable commit/refspec. Upstream setup
is a subsequent local step: it can fail **after the remote push succeeds**. Pull can update
tracking refs even when fast-forward fails. Stash drop checks the captured full list and
selector/OID; other Git clients must not concurrently mutate it. These checks are not
cross-process atomic transactions.

Commit drafts/recents/activity remain local UI state, not AI/service uploads. Your explicitly
requested Git transport can send repository data to the chosen remote. Failed/cancelled
creation is not recursively removed; inspect the destination before retrying.

## Tests

```bash
swift test                 # Core parsers, processes and real temporary Git repositories
./scripts/test.sh          # Xcode core + actual macOS UI tests (interactive desktop)
```

Tests create isolated temporary repositories and never target the REA repository,
Fork.app, your existing repositories or your global Git config. UI test screenshots
and results are retained in ignored `.artifacts/*.xcresult` bundles.

See [docs/VALIDATION.md](docs/VALIDATION.md) for checks actually executed and limitations.

## Project structure

- `Sources/ForkyCore/`: typed Git boundary, parsers, process ownership and operations.
- `Sources/Forky/`: @MainActor observable state, SwiftUI shell, AppKit history / diff.
- `Tests/ForkyCoreTests/`: real-Git and boundary regressions.
- `Tests/ForkyUITests/`: native commit/history, graph/search/split-diff, alphabetic input,
  filtered staging, local/tracking/historical branches, clone/init, remote publish/sync,
  stash management, activity and cancellation workflows.
- `scripts/generate-project.py`: regenerate stable native Xcode project (Python stdlib).
- `scripts/generate-icon.swift`: regenerate the original icon with AppKit.

The Xcode project uses synchronized groups and the local ForkyCore package.
Regeneration is not required when adding Swift files to the existing source/test folders.

Forky takes workflow inspiration from Git clients, not their proprietary code, artwork,
or licensing mechanisms. It is an independent project, not affiliated with Fork.
