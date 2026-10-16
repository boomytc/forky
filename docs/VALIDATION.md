# Validation — first Forky prototype

Executed on **2026-10-16**, Apple Silicon, **macOS 27.0.1**,
**Xcode 27.0 (27A266a)**, **Swift 6.4**, Apple Git **2.54.0**.
Deployment target is macOS 14.0; this does not establish runtime compatibility on 14–26
or execution on Intel.

## Passed

- `swift test`: 25 core tests passed in the first successful run.
- `./scripts/build.sh`: native arm64 Forky.app built with local ad-hoc signing.
- `./scripts/test.sh`: latest full Xcode run **TEST SUCCEEDED**:
  - 25 Swift Testing core tests in 3 suites.
  - 2 actual macOS XCTest UI tests, both passed.
  - Latest result bundle: `.artifacts/Forky-20261016-205235.xcresult`.
- Native UI journey 1: open an isolated repository, inspect diff, stage a file,
  unstage it, click All Commits, inspect native table and root-commit diff.
- Native UI journey 2: inspect diff, stage README.md, type a commit message,
  click Commit Staged, wait for a clean worktree and independently verify the new
  subject with real Git.
- Stable project generation: project.pbxproj and shared scheme hashes unchanged after
  regeneration; pbxproj, XML scheme, Python generator and shell scripts validated.
- AppIcon pixels verified as 16×16 through 1024×1024; original generated artwork.

## Core coverage

NUL-delimited whitespace/newline/Unicode and literal magic-pathspec filenames; rename
direction; malformed and non-UTF-8 rejection; conflicts; log bodies and framing;
diff line numbering, malformed hunk headers and marked preview truncation.

Actual temporary Git repositories cover unborn HEAD, per-file stage/unstage, committing
only the index, stale-index rejection, staged renames, linked worktrees/subdirectories,
hook rejection, ongoing-operation refusal, disabled external diff, ignored ambient
GIT_* redirection, and invalid-directory rejection without initializing it.

Process tests exercise simultaneous large stdout/stderr, bounded-output failure, deadline,
cancellation, launch failure and a cancelled queued repository operation.

## Automation repairs and remaining limits

Earlier runs failed while creating the project/test harness. The project generator now
rejects duplicate object identities; the Swift package is library-only to prevent an
ambiguous app-under-test; debug builds select the host architecture. Icon rendering uses
explicit bitmap pixels rather than Retina-dependent NSImage dimensions.

The macOS UI test runner is sandboxed: its fixture setup uses the real Git resolved by
the Xcode scheme, not /usr/bin/git's xcrun shim. The app itself is unsandboxed.
Swift 6 UI tests keep setup on the main actor rather than overriding nonisolated
synchronous XCTest setup methods.

The active non-Latin input source converted automated spaces / left marked text during
early UI attempts. The passing commit journey uses an exact ASCII token and explicitly
finishes composition, asserting both editor value and Git's resulting subject.
No keyboard-source or clipboard settings were changed. Arbitrary IME composition,
multiline editing and all keyboard shortcuts are **not** established by that journey.

Current successful logs retain Apple's AppIntents metadata-skipped warning and an
XCTest event-synthesis main-thread warning. There are no Swift compiler errors in the
successful run. These warnings are not evidence of complete responsiveness testing.

Not measured: representative large-repository latency, CPU/peak memory, cold/warm
performance, huge ref inventories, or complete descendant cleanup. Not verified:
long-running/interactive signing and filters, cancellation during every cleanup phase,
crash recovery, adversarial symlinks/malicious repository configurations, every merge/
submodule/binary case, Intel runtime, older supported OS versions, accessibility beyond
the tested controls, notarization/distribution, and concurrent external Git writers.

History paging currently uses Git offsets. External ref changes between pages can
produce gaps despite duplicate suppression; Refresh restarts the view. Do not treat
the loaded pages as an immutable repository snapshot.

## Retained local artifacts

Ignored under `.artifacts/`:

- `swift-test.log`, `xcode-build.log`, `xcode-test.log`.
- `Forky-*.xcresult`: successful and earlier failed runs.
- `preview-history.png`, `preview-clean.png`: final **window-only** screenshots.
- `DerivedData/Build/Products/Debug/Forky.app`: runnable prototype.

Early default XCTest diagnostics may include desktop recordings; they remain ignored
local artifacts and are not project assets. Successful explicit preview attachments
were corrected to capture only the Forky window.

All write fixtures were newly created temporary repositories with isolated Git identity/
configuration. No writes were tested against user repositories or Fork.app.
The new project is initialized on branch main but **no project commit was created**.
