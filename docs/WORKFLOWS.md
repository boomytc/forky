# Complete daily workflows

Independent implementation guided by the REA static inventory, not recovered Fork code.
All tool menus have real handlers. Unavailable tools and unsupported cases report errors;
no package installation, hidden force push, automatic stash or background network polling.

## Daily work

- Filesystem monitoring covers the worktree, per-worktree Git directory and shared refs.
  Events are debounced, invalidate readiness and cannot let an older refresh mark a newer
  disk generation current. Writes and cancelled writes finish reconciliation first.
  Foreground refresh remains available; monitoring failure explicitly falls back to manual.
- **Tools → Amend / Reword HEAD**: existing message is prefilled. By default amend changes
  the message only and leaves the index/working bytes alone; opt in to consuming explicitly
  staged files. Review rewriting an existing, possibly published commit. Hooks/signing apply.
- **Branches, Tags & Remotes**: rename/delete local branches or tags, create lightweight or
  annotated tags, edit fetch/push URL, rename/remove remote, set/clear upstream. Unmerged or
  checked-out branches are not force-deleted. Annotated tag rename moves its ref without
  changing the tag object's internal name/signature; intermediate errors may retain both.
- **Merge into Current Branch**: review a captured ref/OID and FF / no-ff / squash / no-commit.
  A clean worktree is required and ignored obstructions refuse. Squash leaves staged changes
  for an explicit normal commit; ordinary no-commit merge uses Continue/Abort.
- **Integrate Fetched Upstream**: Fetch first, then review the locally observed upstream
  OID and destination. Choose merge mode or inspect a complete linear rebase plan from the
  merge base. This deliberately does not fetch and rewrite history in one unseen step.

## Investigate and review

- History search modes: message, author, committer, literal path, changed text and SHA lookup.
  SHA lookup is independent of the selected ref. Date/time and first-parent filters are in
  History Filters. Query/cursor identity includes all filter choices.
- **Tree** is a history detail tab as well as a separate browser. File History anchors a
  literal path to a commit and follows rename records; Show Commit opens its recorded path.
  Blame SHA buttons navigate to the source commit. Back restores the prior query/loaded graph
  and selection (up to 8 locations / 10,000 retained commits / 16 MiB message-body budget).
- Select another parent for merge-commit diffs. **Compare Revisions** accepts two fixed OIDs,
  direction swap, or a clearly live working comparison.
- Reflog lists captured entries including repeated OIDs. Show Commit → Create Branch Here
  recovers a reachable object without reset. Retention/GC can still remove objects.
- **Reset Current Branch** reviews full changed path scope and a patch. Soft keeps index/files;
  mixed changes index only; hard needs separate discard approval and refuses untracked or
  ignored obstructions. A reflog/backup tag does not preserve unstaged file data.
- Diff controls: context, whole-file context (subject to output budget), whitespace display
  filtering, spaces/tabs, wrap and hunk navigation. These display settings never change the
  exact selectable patch.
- Inline staging or the line/hunk sheet uses a complete canonical patch for regular modified,
  added, untracked and deleted text files. It supports reverse unstaging. Rename/type/mode,
  symlink/submodule/binary cases use whole-file actions; partial selection errors are explicit.
- Discard Working Lines is a separate reverse-preview and separate destructive approval;
  it changes the working file, not the index. Index-only APIs cannot silently discard.
- **Image Comparison** captures bytes from commits/live worktree with side-by-side, swipe
  and onion-skin thumbnails. First frame only, ≤4 MiB bytes/side, ≤64 million source pixels,
  ≤2048 px decoded thumbnail. No automatic LFS hydration.

## Conflicts and history

- Conflict chunks support ours/theirs/both/base choices, with unresolved chunks retaining
  original markers. Replacing the editor with those choices is explicit; manual edits are
  not silently overwritten. Existing stage-identity checks, safe replacement, drafts and
  save-only vs save-and-stage remain. Complex/binary/rename conflicts still require another tool.
- Configured Mergetool is separately confirmed, uses trusted Git configuration, and can change/
  stage the selected file. Save/discard manual editor edits first. No tool is installed.
- Cherry-pick/revert can select a merge mainline, opt out of immediate commit and (cherry-pick)
  append the original SHA. The target is a captured immutable commit.
- Rebase shows its original graph/details, ordered typed commands and optional lightweight
  backup tag. Opt-in update-refs exposes eligible branches and preserves Native Git's
  update-ref directives/state through pauses. Checked-out worktree branches are excluded.
  The backup is a tag specifically so update-refs cannot move it.
- Empty replay stops for review rather than silently dropping changes. Linear ≤200 commits;
  merge-preserving/exec/arbitrary external todo is not supported. Unsupported metadata is
  unknown, not idle. Continue/Skip/Abort and final ref application recheck captured state.
- IME marked text is ended at reviewed form boundaries, then requires reapproval rather
  than applying an older bound message. No input-source or clipboard changes are needed.

## Collaboration and multiple repositories

- New Repository Tab / Reopen Closed Tab and recent quick-open retain independent stores,
  drafts, history and tasks. Saved workspaces restore repository groups in new tabs.
  All sessions/worktrees sharing a Git common directory use one weakly retained shared gate.
  Open tabs are bounded to 16; closed session recovery to 8. Quit checks inactive writes too.
- Worktree manager lists/creates/removes via Git. Creation reserves a new directory, failure
  retains it; removal refuses active/current/locked/dirty/ignored-data worktrees. Directory
  device/inode lookup identity is separate from /var vs /private/var URL presentation.
- Selected-file stash uses NUL pathspec files with per-path literal magic, not a global
  literal mode that would break stash cleanup. Rename stores recovery first then drops the
  shifted original; same-OID rename needs Native reflog write (Git 2.51+).
- Pop applies first; only success and an unchanged captured list allow dropping. Conflicts,
  cancellation or a stale post-apply list preserve recovery / report partial results.
- Multi-remote fetch and explicit branch/tag push retain scoped defaults. All configured
  push destinations are displayed; no force/mirror/follow-tags. Mixed accepted/rejected refs
  retain stdout plus stderr, with full latest diagnostics available under Activity.
- Repository settings distinguish local vs inherited values and keep a mode-0600 original
  config backup before local changes. Identity, signing key, gpgSign, template, sign-off for
  format-patch and merge.ff are explicit keys, not a generic config shell.
- Git executable / explicit helper PATH are caller selected, saved as owned preferences,
  and take effect when this tab reopens. Blank PATH inherits without persisting ambient
  environment. Other tabs keep their runner. Helpers/SSH/signing remain existing Git config;
  no new account/token/keychain store or automatic credential prompts.

## Specialized tools

- Text patch import freezes complete bytes, checks/apply index+worktree, rejects binary
  expansion and unsafe paths. Export writes a new file only. Existing destinations refuse.
- Submodules: status/add/verified open/update. Add explicitly stages .gitmodules/gitlink.
  Initialized child repositories get their own gate while parent ownership is retained;
  dirty/unknown/ignored obstructions refuse. No force/recursive/remote update by default.
- Existing Git LFS: track filename, status, fetch/pull and locks/lock/unlock. Network and
  mutation require Apply; nothing is installed. Actual server behavior is provider-dependent.
- Bisect start/good/bad/skip/reset uses known OIDs, ≤200 candidate write-path review, explicit
  native state and original restore identity. No automatic bisect-run command.
- Statistics use complete bounded local commit scope, UTC monthly/weekday buckets and
  source name/email, never inferred accounts. Output-limit failure is unavailable, not 0.
- Existing Gitflow: named version/init/start/finish commands only after scope review;
  its plugin can modify several refs/configs, checkout or invoke configured services.
  It is bring-your-own and not sandboxed. Lean branching/custom tools use explicit JSON argv.
- Optional AI: inspect the explicitly staged context, choose a trusted executable + JSON
  argv with {input_file}, review possible transmission, then run. Output is a proposal;
  Replace Current Draft is explicit and never commits. No provider, account or prompt is
  copied from Fork. Real AI providers are not verified by the /bin/cat argv boundary test.

## Known boundaries

Sequential checks are not cross-client atomic locks or rollback. Trust Git configuration
and explicitly selected executables. Direct child cleanup does not contain arbitrary
descendants. Large output refuses/truncates only marked display previews. Live authenticated
services, every hook/filter/signing flow, older OS/Intel, broad accessibility/IME/dark mode,
huge inventories, malicious races and distribution signing remain outside verified coverage.
See IMPLEMENTATION_MATRIX.md and VALIDATION.md for executed evidence, not inferred parity.
