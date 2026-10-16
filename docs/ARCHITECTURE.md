# Forky architecture

Independent macOS 14+ Git client. SwiftUI owns the workspace, AppKit owns native
commit tables and selectable diffs; Git invocation never lives in a view.

```text
SwiftUI / AppKit views
  → @MainActor @Observable RepositoryStore / WorkspaceSheet
  → single-use WriteLifecycle → operation → uncancelled reconciliation
  → ForkyCore.GitRepository → AsyncGate → GitProcessRunner → Git CLI
```

## Ownership and observations

Each store owns repository selection, draft, history/detail generations, tasks and one
sheet route. Older responses cannot update a newer selection/session. Writes disable
repository switching and normal quit until operation **and final state read** finish.

RepositorySnapshot owns worktree facts and an Observed<CollaborationSnapshot>.
Auxiliary metadata failure remains unavailable-with-reason: it is not an empty
remote/stash list and does not block unrelated local staging/commit. Collaboration
owns configuration digest, remote definitions, Git-resolved tracking identity, locally
observed ahead/behind counts and NUL-framed stash records. No live-server freshness
is inferred from local tracking refs.

Porcelain v1 -z, log fields, name-status -z, explicit ref atoms and config -z each
have one owning parser. GitReference preserves tag object vs commit identity and
symbolic target. Aliases are not independent graph badges or checkout destinations.
GitRemote owns tracking-namespace/name relationships; views do not guess them from
the last slash. GitPath keeps source whitespace/newlines and rejects unsafe/non-UTF-8
paths; display values are never lookup identities.

Read snapshots are sequential, not cross-process atomic. HistoryCursor freezes root
OIDs, refs and query. A selected ref is peeled by captured object OID, never reread
by mutable name. Search omits graph edges because intermediate ancestors may be
filtered out. Object GC may make retained roots unreadable. Refresh starts a new view.

## Explicit mutation contracts

- Stage/unstage uses exactly the approved file paths. Filtered batch scope is visible.
- Commit rechecks HEAD/index fingerprint, conflicts and operation state; no implicit add.
- Local checkout rechecks HEAD/destination and clean worktree, protects ignored files,
  avoids submodule recursion, and respects other worktrees.
- New branch creation uses the reviewed HEAD **or selected historical OID**, without
  checkout. Remote checkout separately confirms a new local name/tracking relationship.
- Remote actions capture root, branch/HEAD, config digest and remote definitions.
  Preflight fails if the reviewed configuration changed.
- Fetch accepts only scoped tracking mappings; no prune/automatic tags/submodule recursion.
- Pull fetches, rechecks, then merges only by fast-forward; no autostash or merge commit.
  Fetch side effects can remain even when integration is rejected.
- Push sends one immutable OID to an explicit branch ref; no force/mirror/follow-tags.
  Optional upstream setup is a separate local step and may fail after push succeeds.
- Stash save requires eligible changes; untracked inclusion is explicit. Apply uses OID,
  requires a clean worktree and retains the recovery entry on success or conflict.
  Drop checks the captured full list and selector/OID immediately before deletion.
- Clone/init atomically reserves a new directory via mkdir. It never adopts an existing
  directory or recursively removes an interrupted destination.

These are preflight checks, not transactions against external clients. Concurrent
external writers remain unsupported; an error never implies rollback.

## Cancellation and completion

WriteLifecycle is single-use, with pending/running/reconciling/finished phases. It
owns the operation child and cancellation request; queued cancellation prevents the
write. Caller cancellation propagates to the child only. Reconciliation is a fresh,
uncancelled task and remains owned through completion, including mixed write/read
failures. Late cancellation cannot cancel or skip it. Store consumes both results
and does not enable writes on a failed refresh.

Activity is bounded to 30 session-local records, with repository identity and marked
12,000-character detail previews. It is not a durable recovery/rollback journal.
One item-driven WorkspaceSheet owns modal routing.

## Process and transport boundary

Direct argv, never product shell interpolation. File operands opt into literal pathspec
mode only at their owning command. Global literal mode breaks stash's internal :/
cleanup pathspec; controlled real-Git traces and the stash/index/untracked regression
verify this boundary. Forky does not issue an extra downstream clean to repair it.

The process runner owns one direct child, both nonblocking streams, output limits,
deadline and post-exit drain. It holds the repository gate through cleanup. Local,
transport and creation deadlines are 30/300/900 seconds; retained output is at most
4 MiB per stream. Timeout copies retain the caller's executable and isolated environment.
Ambient GIT_* redirection is discarded, not persisted.

Known HTTP URL userinfo is redacted for presentation/transport errors. New source
URLs reject embedded HTTP credentials; new local source paths must be absolute.
Other Git settings remain effective: rewrite rules, SSH agent/config, credential and
remote helpers, templates, signing and hooks are trusted user code. Terminal prompts
are disabled. No credential/account store is added.

Arbitrary descendants, malicious configuration, crash recovery and distribution
are not containment guarantees. Failed/cancelled writes may have completed partially.

## Remaining product work

Hunk/line staging, merge conflict editing/continue/abort, merge/rebase/cherry-pick/revert,
file tree/blame, tag/branch lifecycle, filesystem watching, account UX and broad platform/
performance verification remain. Split diff pairs lines for display, not patch editing.
See ALIGNMENT.md for scope and VALIDATION.md for executed evidence.
