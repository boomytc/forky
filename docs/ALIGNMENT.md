# Fork workflow alignment

Forky is independently implemented with original branding/assets, not recovered Fork
code or a claim of full parity. The goal is a calm native client with explicit, complete
workflows—not a collection of similar-looking inactive buttons.

## Reference scope

Prior public [Mac overview](https://git-fork.com/images/carousel/carousel_mainMac.jpg),
[diff screenshot](https://git-fork.com/images/carousel/carousel_commitviewMac2.jpg),
[feature page](https://git-fork.com/) and [release notes](https://git-fork.com/releasenotes)
informed the workflow inventory. Those older screenshots do not establish the exact
current appearance/behavior of Fork 2.70.2. A fresh page fetch in this iteration was
blocked by the network tool's fake-IP address guard; no guard was disabled.

Prior local static evidence remains in the separate REA investigation. Fork.app and
business repositories were not opened/mutated for this iteration. Research images
remain ignored artifacts, not bundled application assets.

## Current outcomes

| Analyst/user task | Forky workflow |
| --- | --- |
| Start working | Open worktree/subdirectory; clone or initialize a new folder; recent repositories |
| Understand history | Real connected graph, frozen paging, literal message/body search, branch/tag badges |
| Review a commit | Full SHA/parents/author/message, root/first-parent changes, unified or split diff |
| Prepare a commit | File filters; explicit per-file/batch staging; staged-only commits; retained drafts |
| Work on an older commit | Select commit → Create Branch Here; source is that OID, not current HEAD; no implicit checkout |
| Use a remote branch | Fetch → select concrete remote ref → create local tracking branch and checkout after confirmation |
| First publication | Add remote → review destination → publish one branch → optional upstream setup |
| Synchronize | Review remote → Fetch / fast-forward-only Pull / non-force Push; show locally known ahead/behind |
| Set work aside | Save stash, opt into untracked files, preview, apply with optional index restoration |
| Retain recovery | Applying never drops the stash; explicit destructive drop is a separate confirmation |
| Interrupt/recover context | Cancel the operation, finish cleanup/reconciliation, report actual state; repository-labelled activity |

Primary synchronization actions have visible text; secondary actions remain compact.
Sidebar covers changes/history/stashes/refs; confirmations identify repository, branch
and effects. Disabled actions reflect missing prerequisites, not unimplemented features.
No hidden network polling, auto-stash, force push or automatic history rewrite.

## Deliberate conservative differences

- Pull stops on divergence. Merge/rebase policy is never guessed.
- Branch checkout requires a completely clean worktree; no automatic stash/carryover.
- No mirror remotes or fetch mappings outside the selected remote's tracking namespace.
- No recursive submodule operations, automatic fetch pruning/tags or implicit multi-ref push.
- Stash application keeps recovery entries; pop remains absent.
- Existing directories cannot be cloned/initialized into through this UI.
- Credentials come from existing Git/SSH configuration, not a new account UI.
- Split diff is line-pairing preview, not syntax/word diff or a hunk-staging model.

## Remaining gaps toward a full Git manager

These are **not shipped claims**:

1. Hunk/line staging and clearer binary/submodule inspection.
2. Conflict editor plus explicit merge/rebase/cherry-pick/revert and continue/abort flows.
3. File tree/blame, branch/tag rename/delete, stash pop, comparison tools and repository tabs.
4. Filesystem watching, larger-repository responsiveness/accessibility, credentials/account UI.
5. Authenticated HTTPS/SSH, older macOS/Intel, release signing/notarization and optional AI.

The public Git transport boundary is verified with isolated real bare remotes, not live
GitHub/GitLab accounts. See [VALIDATION.md](VALIDATION.md) for precise test coverage.
