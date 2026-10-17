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
transport/history-edit and creation deadlines are 30/300/900 seconds; retained output is at most
4 MiB per stream. Timeout copies retain the caller's executable and isolated environment.
Ambient GIT_* redirection is discarded, not persisted.

Known HTTP URL userinfo is redacted for presentation/transport errors. New source
URLs reject embedded HTTP credentials; new local source paths must be absolute.
Other Git settings remain effective: rewrite rules, SSH agent/config, credential and
remote helpers, templates, signing and hooks are trusted user code. Terminal prompts
are disabled. No credential/account store is added.

Arbitrary descendants, malicious configuration, crash recovery and distribution
are not containment guarantees. Failed/cancelled writes may have completed partially.

## Exact index editing

PartialPatch owns the complete original Git patch and LF/ASCII-byte-framed selectable
facts. It never consumes the truncated DiffDocument presentation. Both directions are
forward patches FROM the index (Git -R produces unstage input). Unselected deletion
becomes context; unselected addition is omitted; coordinates/counts and no-newline
markers are preserved. HEAD/index and exact source patch are rechecked before Git
checks/applies the index-only result. Regular modified/new/deleted text is supported,
with a 20,000-patch-line selection budget. Reverse working discard has a different
review/method and separate destructive authorization; it cannot be selected by an
index-only command flag. DiffOptions never changes the canonical write patch.

ConflictReview owns stage identities and working bytes. Save rechecks both, rejects
unsafe types/symlink traversal and writes one regular path before optional staging.
SafeWorktree pins parent descriptors, uses a unique sibling replacement and copies
ACL/xattrs plus permissions. Failed staging does not undo successful file replacement.
Failed save/reword inputs remain in the bounded 16 MiB session draft cache.

TemporaryInput owns its private directory through child completion and cleanup,
including cancellation. Cleanup failure reports the retained location and original
failure; it is not silently successful.

## History editing and operation interpretation

OperationState reads bounded controls once, validates required facts and fingerprints
length-framed source bytes. It owns kind, restore identity, original branch, edit-stop
facts and supported pending revisions. Unknown/corrupt state is active/unknown, never
idle. Snapshot's boolean is derived, not an independent filesystem interpretation.

OperationReview captures token, HEAD/index and changed worktree bytes. Continue/
Skip/Abort recheck them. Continue refuses conflicts/unstaged tracked changes; Skip/
Abort require explicit destructive approval. Abort is not a general rollback.

RebasePlan owns a complete linear range and captured base/HEAD. Typed commands retain
each commit once, including drop. Onto refs are rechecked by captured identity.
A fixed native sequence-editor callback copies a private todo input through a quoted
invocation-local environment operand. User code is not interpolated. Native todo
survives input cleanup and pauses. Autostash/autosquash and submodule recursion are
disabled. Update-refs is disabled by default; explicit eligible branches generate
native update-ref instructions and validated pending state. Backup tags cannot be
rewritten as eligible branch refs. Edit/reword is explicit paused amendment, then Continue.
Unsupported external todo commands do not execute silently.

HistorySafety checks complete possible write paths against ignored obstructions
before native replay/reset, covering onto, replay, pending todo and restore transitions.
Porcelain clean alone does not protect ignored local data. Conservative case-folded/
prefix lookup keys retain source paths. Inventory errors never mean no collision.

## Browsing and UI ownership

RepositoryBrowser lazily reads captured commit/tree/blob identities, without checkout,
filters or LFS hydration. Blame's LF-byte metadata/content parsing preserves CRLF and
combining Unicode. Historical filename presentation is retained, never a lookup path.

HistoryCommand is the single named action catalog for native context/detail menus.
Context payload captures the clicked commit, not current selection or catalog position.
Store checks session/root and write eligibility before routing immutable AdvancedRequest.
Views never invoke Git directly.

## Extended workflow ownership

WorkspaceHub owns independent stores, saved/closed sessions and whole-window quit
eligibility. RepositoryGates weakly shares one gate per canonical Git common directory.
DirectoryIdentity owns filesystem lookup identity separately from URL presentation.
RepositoryMonitor owns FSEventStream resources; the store owns coalescing, disk generation,
session cancellation and publish eligibility. A newer event cannot be cleared by an
older read, including after final write reconciliation.

RepositoryManagement owns normal amend/ref/merge preflights. RepositoryQueries owns
search/date/cursor identity, reflog framing, rename-following file history and comparisons.
HistoryLocation retains bounded navigation facts without rerunning inputs via view
onChange. Explicit binding setters distinguish user queries from restored frozen results.

CollaborationManagement owns selected literal stash paths, native reflog rename/pop,
worktree ownership and selected transport refs. RepositoryTools owns settings/backups,
frozen text patches, child-submodule gates, LFS and trusted helper boundaries. Bisect
owns its native state/preflight; Gitflow owns named BYO argv presets. RepositoryMedia
owns captured image bytes/decode constraints and complete UTC statistics.

Process failure preserves stderr AND stdout, which can describe accepted refs before
another ref fails. Activity retains one full latest diagnostic and bounded older previews.
Explicit helper executable changes preserve the caller-selected process environment;
ambient environment is never serialized merely because a child inherits it.

## Deliberate exclusions / verification limits

Partial rename/type/mode/binary edits, complex conflicts, merge-preserving/exec rebase,
word diff/highlighting, built-in accounts/AI providers, automatic bisect-run, broad
platform/provider/performance guarantees and notarization remain outside scope.
Split/image diff is presentation, never input to exact selectable writes.
See WORKFLOWS.md, IMPLEMENTATION_MATRIX.md and VALIDATION.md.
