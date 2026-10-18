# Validation — G01–G22 follow-up

## 2026-10-18 audit rerun

- Source `swift test`: **142 passed / 18 suites**, 0 failures/skips.
- Xcode `ForkyCoreTests` target: **142 passed / 18 suites**, 0 failures/skips,
  bundle `.artifacts/Forky-audit-core-xcode-final-20261018-192708.xcresult`.
- Native `swift build` and `xcodebuild ... build`: succeeded.
- Full native UI suite: **34 passed, 0 failed, 0 skipped**, **550 s**.
  Bundle: `.artifacts/Forky-audit-ui-full-20261018-191133.xcresult`.
- Two later app-only refinements (transactional custom-command persistence and
  auth-diagnostics helper PATH) were rebuilt and followed by a
  `testOpenDiffStageAndCommit` smoke run: **1 passed**, 0 failed,
  `.artifacts/Forky-audit-ui-smoke-20261018-192624.xcresult`.
- Audit changes removed a string `submoduleStatus()` API that only a test called, an
  unreachable `LFSTask.locks` arm, an unreferenced theme color, an always-nil remote-name
  parameter, and an unreachable statistics load branch. A duplicate unborn-repository test
  was merged into the stronger multi-file test; its unique assertions were retained.
- Genuine fixes: empty submodule directories no longer report the parent HEAD; a conflict
  Base choice without a base section stays unresolved; draft archives budget JSON-encoded
  bytes; command archives reject over-budget upserts; tab persistence merges into the
  stored archive; query-string credentials are redacted; CRLF LFS pointers parse; image
  previews use the same 64 MiB budget as local LFS objects.
- Limits: the multi-tab persistence merge is code-reviewed but not covered by an automated
  UI test because `--ui-testing` deliberately disables persistence. Ambient
  `GIT_SSH_COMMAND` reporting is not exercised by a fixture. No notarization or older-OS
  run was claimed.

The historical 2026-10-17 gate below remains the record for that commit.

Executed **2026-10-17**, Apple Silicon / macOS **27.0.1**, Xcode **27.0 (27A266a)**,
Swift **6.4**, Apple Git **2.54.0**. Deployment target macOS 14 is not older-runtime proof.
Base: human commit `ef7656dbed07f6af98cdcb70472ffdda2074b33b`. No agent commit.

## Final executed gate (2026-10-17)

- Source `swift test`: **116 passed / 13 suites**, final source run **21.577 s**.
- Native `./scripts/build.sh`: succeeded; full test gate also rebuilt final app/test source.
- Full `/usr/bin/time -l ./scripts/test.sh`: **TEST SUCCEEDED**.
- Independent `xcresulttool get test-results summary`: **147 passed, 0 failed, 0 skipped**,
  **116 Core + 31 native Mac UI**. Top-level reporter total, not a sum of device rows or
  dynamic parameter invocations (the device detail includes 158 invocations).
- Bundle: `.artifacts/Forky-20261017-102649.xcresult`.
- Strict deep ad-hoc signature check and `git diff --check` passed. Not notarized.
- No connected Xcode MCP: actual tests/builds ran through repository scripts and the
  previously human-authorized XCTest desktop. No password, input-source, clipboard,
  global Git config or OS security changes were automated.

The full gate predates only an image caption/accessibility refinement and strengthened
PNG fixture assertions. A final real image UI rerun passed (1 test, 0 failures/skips,
.artifacts/Forky-20261017-105427.xcresult), including decoded-image presence, dimensions
and side/swipe/onion layouts. Core/Git behavior did not change after the full gate.
Documentation, ignored measurement artifacts and delivery cleanup followed; the older
bundle is not claimed to include the later image refinement. Prior 99-test evidence is preserved separately in
[VALIDATION_ADVANCED.md](VALIDATION_ADVANCED.md).

## Added real workflow coverage

Core additions include normal amend/index preservation; refs/config/tag lifecycle and
CAS; all merge modes and ignored obstructions; shared gates and filesystem monitor;
reflog identity; query/date/cursor choices; literal file history through rename; immutable
vs working comparisons; added/deleted partial patches; selected-file stash rename/pop;
worktree create/remove; local settings backup/inheritance; frozen text-patch apply/export;
bisect recovery; trusted literal argv/input-file; reviewed hard/soft/mixed reset and hunk
discard; conflict chunk bytes; cherry-pick merge mainline/no-commit; rebase backup/native
update-refs, no-eligible-ref state, moved-original-branch abort refusal and captured
integration base; actual submodule clone/open/update; actual local LFS filter/status;
and mixed accepted/rejected ref push with retained partial-success stdout.

All previous 20 native journeys ran again. Eleven new journeys:
1. External working-file write refreshes without manual refresh.
2. Ordinary message-only amend actually changes the commit and retains working changes.
3. Independent repository tabs restore each session.
4. Real managed tag creation.
5. Reviewed no-ff merge yields two parents.
6. Selected-file stash.
7. Captured file history → commit → Back.
8. Real local statistics.
9. Inline exact staging changes index only.
10. Hard reset stays disabled until independent discard approval.
11. Generated original PNG is decoded by the actual image comparison sheet.

Initial focused UI failures remain in ignored logs, not omitted from the account:
IME composition/old form binding, branch accessibility value vs label, native popup
snapshot timing and an incorrect clean-state selector were diagnosed and rerun.
The complete run has no failures/skips. Screenshot review additionally found the
initial PNG fixture used a dynamic catalog color unsupported by NSBitmapImageRep:
its transparent pixels did not prove visible content. The fixture now uses device-RGB,
asserts green/alpha, and the UI asserts an actual decoded image/dimensions in all 3 layouts.
The first strengthened run exposed macOS static-text value vs label again; that selector
was corrected and the final focused image run passed. Image captions now derive present
vs absent and dimensions from the captured CGImage rather than a generic “/ absent” label.

## Producer-boundary fixes, not downstream repairs

- Replacement rebase todo now carries explicit native update-ref directives; bounded
  operation-state parsing validates both final target refs and native pending state.
- Backup is a tag, not an eligible branch that update-refs could move.
- Same-OID stash store cannot rename an entry; native reflog write appends it before
  independently checked removal of the shifted original. Requires Git 2.51+.
- Directory device/inode identity replaces /var vs /private/var URL spelling comparison.
- IME marked text ends editing and requires renewed review instead of applying an old message.
- Shared gate and disk/session generations prevent newer events being cleared by older reads.
- Stash/submodule/replay/reset guard complete possible ignored-file write scope.
- Submodule child identity, dirty state and safety run under child gate while retaining parent.
- Failed multi-ref push preserves stdout as well as stderr; accepted tags remain visible
  even when another branch rejects. Latest complete diagnostic is inspectable in Activity.
- Caller absolute-path text is validated before URL construction; malformed saved workspace
  data is retained and write-blocked, not silently overwritten as an empty list.

## Provider verification is specific

**Real:** local temporary bare Git remotes; local submodule clone/open/update; installed
`/opt/homebrew/bin/git-lfs` **3.8.0**, track/filter/status and committed pointer inspection.
The conditional LFS test actually ran here (0 skips); no helper was installed/upgraded.

**Not real-provider proof:** literal /bin/cat argv/input-file acceptance only establishes
the trusted executable boundary. Gitflow plugin is not installed. No real AI/Lean service,
LFS server locks/authentication, SSH/HTTPS accounts, remote traffic/error matrix,
every hook/filter/signing or helper cancellation stage was exercised. UI forms for
specialized variants have code/API coverage, not universal end-to-end acceptance.

## Measurements, not speedup claims

Warm incremental **147-test gate**: **636.89 s elapsed**, **78.25 s user + 51.68 s system CPU**;
BSD maximum RSS **377.9 MiB**. Runner-reported, NOT complete process-family accounting.

Synthetic isolated repository: **10,000 linear commits / 20,001 tracked paths**, tiny blobs.
Debug Core task: snapshot → first 200 → next 200 → literal NEEDLE search; same immutable
data for archived baseline and current SDK. Five serial completed tasks per process.
Each returns 400 history records, 104 matches and zero changes.

| Metric | Baseline ef7656d | Current |
| --- | ---: | ---: |
| Median inner task | 263.42 ms | 249.08 ms |
| Five-task process wall time | 1.636 s | 1.364 s |
| Waited process-tree CPU, monitor subtracted | 2.188 s | 2.239 s |
| Sampled family peak RSS (estimate) | 21.19 MiB | 22.45 MiB |
| RSS samples (20 ms interval plus ps overhead) | 41 | 34 |

No improvement claim: warm filesystem, fixed before/after order, 5 samples, host noise;
an earlier exploratory pair had ~482 ms medians on both variants. Sampled RSS can miss
short child peaks and excludes services; CPU is waited-child accounting. Process/open
startup is excluded from inner task but included in process wall/CPU. No cold-cache,
native GUI render/huge-graph/production workload or agent-token accounting measurement.
Raw source, fixture provenance and results are ignored `.artifacts/benchmarks/` outputs.

XCTest retains **11 QoS priority-inversion + 13 main-thread runtime warnings** (event
synthesis contexts in runner logs). They are not zero-warning or product-responsiveness
proof; their full attribution is unverified. Metadata-skipped tool notes remain too.

## Evidence and remaining limits

Ignored logs: complete-core-final.log, complete-build.log, complete-final.log,
complete-summary.json, complete-benchmark.log, complete-export.log, complete-captures/,
complete-image-final.log (stronger-selector failure), complete-image-final-fixed.log,
complete-image-summary.json, complete-image-captures/ and complete-build-final.log.
Window-only previews: complete-refs.png, complete-inline.png, complete-reset.png,
complete-images.png, complete-statistics.png. Earlier focused complete-*.log/xcresult
files retain failures and successful reruns. XCTest default diagnostics may capture a
desktop on failure; local/ignored only, never bundled application assets.

All mutations target newly created fixtures, not business repositories, Fork.app or
actual remote services. REA source remains unchanged. No commit, global installation or
automatic tool/MCP registration. Tests do not establish cross-client atomicity/rollback,
malicious repository containment, every ACL/race/cleanup/crash state, broad IME/
accessibility/dark-mode, older macOS/Intel or distribution signing/notarization.
See [implementation boundaries](IMPLEMENTATION_MATRIX.md) and [workflow guide](WORKFLOWS.md).
