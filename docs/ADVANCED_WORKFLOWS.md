# Advanced Git workflows

All actions use ForkyCore and the same cancellation/reconciliation lifecycle. Open
trusted repositories only: Git hooks, signing and helpers are user-configured code.
There is no promise of rollback or atomicity against another Git client.

## Lines and hunks

Changes → select a regular modified, new or deleted text file → **Stage Lines…** or
**Unstage Lines…**. Select individual changed lines, Select Hunk, or Select All, then
confirm. Only the index is changed; worktree bytes are not rewritten.

Unstage preview is the reverse direction, **Index → HEAD**, so its plus/minus lines
describe what will be removed from staging. A selected replacement addition without
its deletion intentionally leaves both lines in the index. Selection is literal, not
an inferred replacement pair.

A complete canonical Git patch is parsed at its LF-byte boundary, not from the
500,000-character display preview. CRLF, combining Unicode and no-final-newline
markers are retained. The original HEAD/index and exact patch are checked again;
Git checks the resulting index patch before applying it.

Current scope: regular modified/new/deleted text. Renames, symlinks, submodules,
binaries and mode changes use whole-file actions/external tools. Inline Staging Review
uses the same Core patch contract; Discard Working Lines has its own reverse preview
and explicit destructive approval, never an index-only shortcut.
The interactive selection budget is 20,000 patch lines, not a claim of complete preview
after truncation. Oversized or malformed input refuses partial application.

## Conflicts

Select an unmerged file → **Resolve…** (or its stage action). Review Base, Ours
(stage 2), Theirs (stage 3), and edit the result. During rebase, Ours is the new base;
Theirs is the replayed commit. They are not guessed branch names.

**Save Worktree Only** leaves the unmerged index intact. **Save & Stage Resolution**
explicitly writes/stages that one path. Use Ours/Theirs replaces the editor result,
not Git state until confirmation. A missing stage means a deleted/absent side;
**Resolve by deleting this file** is explicit, separate from saving text.

Marker lines block staging unless the user approves literal marker content. There
is no automatic merge correctness claim. Failed-save drafts are retained in session
(up to 16 MiB shared with failed reword drafts); reopening identifies restored drafts,
and Discard Retained Draft reloads the current working version. Cancel discards
unsubmitted editor edits.

Stage identities and working bytes are checked before replacement. Filesystem access
rejects final/intermediate symlinks and non-regular files. Replacement preserves normal
permissions, ACLs and xattrs; new missing files use standard mode. Worktree output is
UTF-8, bounded by the 4 MiB per-file editing limit. Binary, symlink, submodule and
directory/rename conflict resolution still needs another client. Empty missing parent
directories are not automatically recreated.

## Cherry-pick / revert

Right-click a commit or use its detail menu. Confirm its full OID, current repository
and branch. Cherry-pick replays it; Revert creates an inverse commit, not a reset.
A clean local branch is required. Merge commits require selecting the intended
mainline parent. No-commit and cherry-pick source annotation are explicit options.

If Git pauses on conflict, resolve/stage paths, then use the operation banner.
Continue commits explicitly staged content. Skip omits the current commit; Abort
uses Git's own saved state. Skip/Abort require separate destructive approval and
review of the complete changed scope, not just the staged list. Native Git may
refuse; inspect refreshed state rather than assuming undo succeeded.

## Interactive rebase

Select an ancestor **before** the commits to edit → **Interactive Rebase After Here…**.

- Range is strictly linear, complete and limited to 200 commits. Merged ranges refuse.
- Default onto is the same base; optionally select another captured local/remote ref.
- Reorder using Up/Down; choose pick, edit/reword, squash, fixup or drop.
- Every original commit remains exactly once as an explicit command, including drop.
  Squash/fixup needs a preceding kept commit; dropping everything is refused.
- Acknowledge rewriting commit identities, including possibly published commits.
  No force push, autostash or autosquash follows. Update References is opt-in and
  lists eligible captured refs; a separate lightweight backup tag is outside that update set.
- Edit/reword pauses. Stage intended changes, open Review Operation, edit the message,
  **Amend Paused Commit**, reopen the review, then **Continue**.
- Squash accepts combined default messages; fixup keeps the earlier message. To
  customize a completed squash message, run an edit/reword pass on that commit.

Git's sequence editor protocol uses a fixed system copy command, a quoted
invocation-local environment operand and a private todo input. User messages or
commands are not interpolated into shell code. The plan contains no exec commands.
Git copies the native todo before replay; the temporary source is cleaned after the
child exits, even if the rebase paused. Continue does not depend on that source.

Operation metadata is parsed once and fingerprinted, preserving unknown/corrupt
state as unknown. Pending native todo and original branch are visible. External
exec/reword/label/reset/merge/option-bearing todos are not silently executed;
Continue/Skip refuse unsupported commands. Use native Git or review Abort.

Ignored local files can be lost by native replay/reset even when status says clean.
Forky compares complete possible write paths (including pending replay and restore
transitions) with ignored files, conservatively accounting for case-folded/prefix
collisions. Potential obstructions refuse before the history command. This can reject
a harmless case pair on a case-sensitive filesystem. Move local data aside explicitly;
Forky does not delete it. Inventories and state reads have bounded output; failure
does not mean no collision. Filesystem races/unusual filesystem behavior remain unverified.

## File tree and blame

Commit menu → **Browse Tree / Blame…**. Open folders, select files, toggle Blame.
Both source blob and attribution remain anchored to the selected commit—not the
current worktree or newest HEAD. No checkout, filters, download or LFS hydration.

Blob preview distinguishes UTF-8 text from binary/non-UTF-8 content. Symlinks display
their tracked target text without following them; submodules show their commit only.
Blame includes SHA, line, author/date and hover provenance (mail, summary and Git's
source filename presentation). Historical filename presentation is never a lookup path.

Blame output and blobs use the process output budget; blame additionally caps 20,000
rows. Oversized results are unavailable rather than silently incomplete. There is
no syntax highlighting or word-level attribution. File History follows recorded rename
paths; blame SHA buttons navigate to commits, and Back restores the prior context.
