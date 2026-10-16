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

## First version

- Open an existing worktree or a subdirectory; recent repositories.
- Local / remote branch inventory; branch selection filters history, **not checkout**.
- Paged history (200 commits per page), commit files, root and first-parent merge diffs.
- Unstaged / staged changes and unified, line-numbered text diffs.
- Explicit per-file staging and unstaging, including new repositories and renames.
- Commit **only explicitly staged files**, with stale-index / conflict / ongoing-operation checks.
- ⌘O open, ⌘R refresh, ⌘1 changes, ⌘2 history, ⌘↩ commit.
- Native light/dark appearance and original generated icon.

Not yet implemented: connected commit graph lanes, line/hunk staging, branch checkout,
fetch/pull/push, conflict editor, clone/init UI, stash UI, automatic filesystem watching,
AI integration, configurable Git executable or distribution/notarization.

## Safety and limits

Only open repositories you trust. Git can invoke configured clean filters, signing tools,
and commit hooks. Forky disables external diff/textconv and fsmonitor commands for its
queries, but it is **not a sandbox for malicious Git configuration**.

Commands use argv arrays, literal pathspecs and NUL-framed output, not a shell.
Ambient GIT_* overrides are discarded to preserve the selected worktree.
Operations share a cancellable repository gate. Read failure is never an empty clean
repository; stale snapshots disable writes. Every write, successful or not, is followed
by a refresh; failures are not represented as rollbacks.

Before commit, Forky compares HEAD and the staged diff with the reviewed snapshot.
This catches many external index changes, but is **not an atomic lock against other Git
clients**. Do not concurrently write the same repository from another client.

Process output is limited to 4 MiB per stream and execution to 30 seconds. The diff
renderer separately previews at most 500,000 characters and marks truncation.
Timeout/cancellation controls the directly owned Git process, not arbitrary descendants
started by hooks or filters. A helper that keeps output open produces an explicit
incomplete-output error. A failed or interrupted write may have already changed state;
inspect/refresh before retrying. Non-UTF-8 paths are rejected rather than rewritten.

There are no automatic remote operations, force operations, discard/reset/clean actions,
or hidden stage-all. Commit messages and recent repository paths are local UI state;
the application does not send them to a service.

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
- `Tests/ForkyUITests/`: native stage/unstage/commit and history workflows.
- `scripts/generate-project.py`: regenerate stable native Xcode project (Python stdlib).
- `scripts/generate-icon.swift`: regenerate the original icon with AppKit.

The Xcode project uses synchronized groups and the local ForkyCore package.
Regeneration is not required when adding Swift files to the existing source/test folders.

Forky takes workflow inspiration from Git clients, not their proprietary code, artwork,
or licensing mechanisms. It is an independent project, not affiliated with Fork.
