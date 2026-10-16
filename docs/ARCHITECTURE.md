# Forky architecture

## First deliverable

An independent macOS 14+ Git client with an actual local worktree → diff → index →
commit loop. Not a binary/source copy of Fork. UI shell is SwiftUI; high-volume commit
rows and selectable monospaced diff text use narrow AppKit bridges.

```text
SwiftUI views / AppKit adapters
    → @MainActor @Observable RepositoryStore
    → ForkyCore.GitRepository
    → cancellable AsyncGate
    → GitProcessRunner (direct argv, bounded streams, deadline)
    → /usr/bin/git
```

Each store owns its selection, open/refresh/detail/history generations and tasks.
A new navigation or selection invalidates earlier responses before they can reach UI.
Repository operations remain inside the gate through process exit and stream cleanup;
queued cancellation releases the waiter without consuming the next permit.

Mutations are explicit commands, not view side effects. While a mutation runs, opening
another repository and write controls are disabled; normal application quit is refused.
The index is re-read before committing. A write error and reconciliation error must not
be interpreted as an automatic rollback. Keep the message after failed commits.

## Source representations

Porcelain v1 -z, log NUL field framing, name-status -z and explicit ref fields each have
one parser at the core boundary. GitReference is the sole ref representation for sidebar,
history roots, checkout and graph badges; tag object OIDs remain separate from known
commit targets. Non-commit/nested tag targets are not invented as commit decorations. Rename source/destination order differs between status
and name-status and is modeled explicitly. Only validated full OIDs reach revision
arguments. GitPath preserves whitespace/newlines and rejects non-UTF-8 / unsafe paths;
display formatting never becomes a lookup identity.

Read snapshots are sequential observations, not atomic snapshots against external
clients. HistoryCursor freezes root OIDs, ref metadata and normalized query for the
whole paged view. External ref advances do not reorder subsequent pages; Refresh
starts a new view. Selected refs are peeled by their captured object OID rather than
rereading a mutable name; the ref-move-during-read regression exercises this boundary
with real Git. Object deletion/GC can still make a retained root unreadable.
The graph consumes Git's child-before-parent order and extends consistently across
pages. Search can omit intermediate parents, so filtered results intentionally hide
the connected graph rather than drawing false ancestry.

## Safety model

No shell interpolation, automatic add-all/checkout, force reset/clean/checkout, or network UI.
Batch staging captures the explicit visible path list; the file filter owns both selection
and batch scope. Branch requests capture repository root, HEAD and destination ref.
The core rechecks operation state, clean worktree, HEAD and destination inside the gate.
Git switch uses --no-overwrite-ignore, --no-guess and --no-recurse-submodules. Creation
and checkout are separate operations; creation never implicitly switches.
Filesystem identity belongs to the worktree resolved by Git, including linked worktrees.
Global GIT_DIR/GIT_INDEX_FILE/GIT_CONFIG_* cannot silently select another target.
Other normal Git settings remain effective; configured filters and hooks are trusted
user code, not safely contained targets. Signed commit / hook prompts have no interactive
terminal in this version; failures and timeouts remain visible.

The process runner owns one child and both nonblocking read sources on a serial queue.
A task cancellation, timeout or output overflow stops that child and waits for exit.
Inherited pipes have a post-exit drain deadline and produce incomplete-output failure.
Descendant containment, hooks surviving the parent, and recovery after application
crash are explicitly outside the first version's guarantee.

## Next steps, not shipped claims

1. Commit graph collapsing/expansion and file tree/blame.
2. Hunk/line staging, binary and submodule detail. SplitDiff currently pairs adjacent
   deletion/addition blocks for display only, preserving line numbers and hunk boundaries;
   it is not a patch-editing model. AppKit owns paired scroll views and synchronizes only
   vertical offsets, with observer cleanup.
3. Dedicated repository activity/operation state, filesystem watching with coalescing.
4. Deliberate remote authentication, fetch/pull/push UX and cancellation/reconciliation.
5. Conflict resolution and rebase state handling.
6. Opt-in AI with visible context, explicit local CLI configuration and no hidden uploads.

Use temporary repositories for every new mutation regression. Add a real native UI
journey for each user-visible write workflow before claiming it works.
