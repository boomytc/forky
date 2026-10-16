# Alignment with Fork workflows

This is an independently implemented Git client, not a copy of Fork's code, assets,
branding or licensing. The local Fork installation and user repositories were not opened
or mutated for this iteration.

## Reference evidence

Public Fork Mac screenshots inspected on 2026-10-16:

- [Commit graph / sidebar / summary](https://git-fork.com/images/carousel/carousel_mainMac.jpg)
- [Side-by-side diff](https://git-fork.com/images/carousel/carousel_commitviewMac2.jpg)
- [Feature inventory](https://git-fork.com/)
- [Mac release notes](https://git-fork.com/releasenotes)

The screenshots show an older product presentation; they do **not** establish the exact
appearance or behavior of installed Fork 2.70.2. Prior local static evidence remains in
the separate REA investigation. Reference images are ignored research artifacts only,
not bundled product resources.

## Implemented in this iteration

| Reference workflow | Forky outcome |
| --- | --- |
| Dense commit list with connected lanes and refs | Native 25-point rows, merge lanes, branch/remote/tag badges, full identities in tooltips |
| Branch/sidebar navigation | Collapsible groups, current-branch marker, live branch/tag filter, single-click history selection |
| Commit investigation | Changes/Commit tabs, full SHA and parent IDs, author/email, complete message, selected file diff |
| Message search | Debounced, literal case-insensitive Git search over the selected history; not a filter of loaded rows |
| Stable paged history | Frozen root OIDs and refs; test advances HEAD between the 200th and 201st commits without gaps/duplicates |
| Diff layout | Unified/split toggle, preserved old/new line numbers, aligned blanks and synchronized vertical scroll |
| Stage/unstage workflow | Compact rows, double-click/context/button actions, confirmed explicit batches scoped to visible files |
| Branch creation and checkout | Separate actions, reviewed HEAD, confirmation, dirty/ignored-file/other-worktree protection |
| Draft editing | Soft 72-character summary guidance; preserve drafts in memory when changing repositories |
| Native interaction | Resizable panes, status bar, original shortcuts plus new branch, Finder and copy actions |

Forky's own green mark remains; repository content uses native system accent and semantic
colors. No disabled fake remote/AI controls were added to suggest unimplemented functions.

## Important remaining gaps

Not full parity: remote authentication/fetch/pull/push, stash, hunk/line staging, merge
conflict editor, interactive rebase, merge/cherry-pick/revert, graph collapsing, file
tree/blame, repository tabs, clone/init, image comparison, automatic filesystem watching,
and AI are still absent.

Split diff is a **line pairing preview**, not word-level alignment or syntax highlighting.
Search is by commit message, not arbitrary authors/OIDs/file contents. Filtered search
hides the graph because omitted commits would make contiguous ancestry misleading.
A nested tag's direct commit target may be unknown for badges, though Git can resolve
its history. A frozen view may become unreadable if external garbage collection removes
its objects. Checkout is deliberately more conservative than clients that offer automatic
stash or carrying changes between branches.

See [VALIDATION.md](VALIDATION.md) for executed evidence and unavailable coverage.
