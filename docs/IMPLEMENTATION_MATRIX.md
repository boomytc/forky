# G01–G22 delivery matrix

Independent implementation against the REA Fork 2.70.2 inventory; baseline
`ef7656dbed07f6af98cdcb70472ffdda2074b33b`. This is a workflow/capability mapping,
not a parity percentage or proof of Fork runtime behavior. Core APIs are real and native
UI entries route to them. Optional integrations are explicitly bring-your-own (BYO).

**Executed gate:** 116 Core / 13 suites + 31 actual Mac UI = **147 passed**,
0 failures/skips, `.artifacts/Forky-20261017-102649.xcresult`.
A later image caption/accessibility/fixture refinement passed its stronger native rerun
(1 test, .artifacts/Forky-20261017-105427.xcresult); it is not included in the older full
bundle. [Detailed evidence and limits](VALIDATION.md), [usage](WORKFLOWS.md).

| ID | Implementation / entry | Evidence and remaining boundary |
| --- | --- | --- |
| G01 | RepositoryMonitor + RepositoryStore: recursive FSEvents, foreground/debounce, shared gate, disk/session generations | monitor/shared-gate Core tests + native external-file refresh. Failure exposes manual fallback; no background network. |
| G02 | RepositoryManagement; Tools → Amend / Reword HEAD; CommitComposer | staged-only commits; `commit.template` prefill with comment/CRLF cleanup; explicit per-commit sign-off remembered per repository; message-only amend preserves index/bytes; staged opt-in/stale tests + native typing/amend. Publication risk reviewed; no force push. |
| G03 | RepositoryManagement; Branches, Tags & Remotes | rename/delete branch/tag, lightweight/annotated tag, fetch/push URL, remote rename/remove, upstream set/clear. Real lifecycle/config/stale tests + native tag. No force branch delete or server deletion. |
| G04 | RepositoryManagement; Merge into Current Branch / Integrate Fetched Upstream | all 4 merge modes + ignored obstruction + native no-ff. FF-only Pull remains default; integration does not fetch silently. |
| G05 | RepositoryQueries + RepositoryReset; Reflog / Reset Current Branch | repeated reflog entries; show commit→recovery branch; soft/mixed/hard tests + native independent discard approval. Reflog pages 200 rows; a moved HEAD invalidates the cursor instead of repeating rows; no generic undo. |
| G06 | RepositoryQueries / Browser; File History / Tree / blame SHA / Back | real rename-following historical paths; native query→commit→Back; captured blame UI. File history pages 200 rows over one immutable anchor; no word attribution/syntax highlighting; back cache bounded. |
| G07 | History filters / QuerySheet / merge-parent picker | two immutable commits or live worktree, direction swap, first-parent/date, reflog navigation. Core comparison/frozen cursor tests + existing graph native journey. |
| G08 | HistoryOptions + literal search/parser ownership | message/author/committer/path/changed-text/SHA; Core special path/query/cursor tests + native alphabetic search. No inferred Fork popup semantics or index of arbitrary untracked text. |
| G09 | PartialPatch / IndexEditing / InlinePatchView | added/deleted/modified regular text; Core exact bytes/index/stale/CRLF tests; native inline + line/hunk roundtrip. Separate reviewed discard keeps index; rename/type/mode/binary partial edits refuse. |
| G10 | DiffOptions + RepositoryMedia / ImageComparisonSheet | context/whitespace/invisibles/wrap/hunk controls, split/unified and bounded side/swipe/onion images. Frozen media Core tests + real generated-PNG UI. No word diff, syntax engine, animation or LFS hydration. |
| G11 | ConflictDocument / ConflictSheet + configured mergetool | per-chunk ours/theirs/both/base, resolved/unresolved progress, previous/next unresolved navigation and bulk one-side choices in a scrollable list; explicit replacement, save/stage/drafts and trusted tool handoff. Byte/chunk/navigation tests + actual conflict Continue UI. Complex conflict types, synchronized three-pane scrolling and file-level unresolved totals across files remain excluded. |
| G12 | HistoryEditOptions / HistoryEditing / OperationState | mainline/no-commit/source annotation; original rebase graph/details; backup tag and explicit eligible update-ref instructions/state. Real rewrite/pause/restore tests + native reword/Continue. Linear ≤200 only, no merge-preserving/exec plan. |
| G13 | CollaborationManagement; Selected Stash Files / existing stash views | selected literal NUL paths, rename, successful apply→checked drop/pop, untracked/index options. Real tests + native selected save. Conflicts/stale state retain entries; Fork snapshot backend unknown, no invented equivalent. |
| G14 | CollaborationManagement; Worktrees | list/create/open/remove, directory identity and occupied/locked/dirty/ignored checks. Real linked-worktree create/remove test. No forced deletion/prune/automatic unlock. |
| G15 | WorkspaceHub / WorkspaceTabs | independent stores, tasks, drafts/history, tabs/recents/reopen/saved groups. Native independent-tabs journey and shared common-dir gate regression. 16 open / 8 closed sessions; workspace names currently auto-numbered. |
| G16 | RepositoryTools / Git Settings | local/inherited allowlisted settings + protected config backup, chosen Git/helper PATH; existing identity/template/signing/helpers. Backup/inheritance tests; no account/token/GPG-key creation UI, every auth/signing combination unverified. |
| G17 | CollaborationManagement + IntegrationSheet | selected-remotes fetch, explicit immutable branch/tag push, separately reviewed upstream merge/rebase. Real local-bare remote transport + accepted-tag/rejected-branch partial-result test. All push destinations shown; no force/mirror; live authentication unverified. |
| G18 | RepositoryTools; Patch Import / Export | frozen complete text bytes, check/index+worktree apply, safe paths and exclusive export. Real frozen-review/overwrite tests. Binary expansion/import and mail-series management excluded. |
| G19 | RepositoryTools; Submodules | status/add/open/verified update, literal safe paths, exact gitlink, parent+child gates, dirty/ignored refusal. Real local clone/open/update test. No recursive/remote/force update by default. |
| G20 | RepositoryTools; LFS & Locks | existing helper status/track/fetch/pull/locks/lock/unlock with explicit network/mutation. Actual installed LFS 3.8.0 local pointer/filter/status test passes. No remote lock/auth or provider traffic verification. |
| G21 | RepositoryMedia; Overview & Statistics | real complete bounded local counts, UTC charts, author identities; Core/date/count + native statistics test. Synthetic 10k-commit/20k-path Core task before/after sampled; no broad platform/accessibility/GUI-scale performance claim. |
| G22 | Bisect / Gitflow / explicit JSON-argv external tools + AI draft | actual bisect state/recovery and literal executable/input-file tests. Gitflow named BYO presets; Lean/custom tools use trusted executable boundary. AI draft is an explicit proposal, not a provider or auto-commit. Real Gitflow/Lean/AI providers unavailable/unverified. |

## Scope decisions and honest exclusions

- All groups have an implemented workflow or explicit BYO integration. This is **not**
  every possible recommendation in the static report or every commercial Fork feature.
  In particular account services, protection/licensing code, unknown snapshot semantics,
  complex partial/conflict formats, merge-preserving rebase and full provider emulation
  were not invented to fill a checklist.
- Native UI acceptance covers representative journeys, not every form variant. No
  placeholder tests, simulated-provider claims, installed plugins or real remote accounts.
- Broader OS/Intel, accessibility/dark/IME matrices, concurrent-client atomicity,
  malicious repositories, every helper/cleanup/crash path and notarization remain unverified.
- Hooks and selected tools are trusted code. Errors/cancellation can leave partial effects;
  immutable preflights and reconciliation do not turn sequential Git commands into rollback.
