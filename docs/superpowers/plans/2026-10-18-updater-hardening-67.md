# Batch D: updater and CI hardening (#67) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the updater download quickly and reliably. Check the update again at the moment it is installed. Pass paths to the swap helper safely. Accept downloads only from this repo's GitHub release URL. Refuse oversized archives before unzipping. Clean up old updates. Verify pinned actions on every CI run.

**Architecture:** Each fix sits where its decision already lives: the download in `UpdateChecker`, the archive gate in `UpdateInstaller.stageAndVerifySync`, and the install-time re-check in the detached bash helper, run on the `.inflight` copy after the app has exited. **Read `docs/superpowers/notes/2026-10-18-batch-d-research.md` first.** Its sections (F12–F16, New) are the spec for each task's details: file:line evidence, fix shapes, seams, tests and gotchas. This plan carries only the decisions.

**Tech Stack:** Swift, XCTest, bash, GitHub Actions YAML.

**Spec:** issue #67 (F12–F15, plus F16 from #78), as verified on main 8a8d62ee in the research note above, plus Denver's rulings below.

## Rulings

- **Download speed (Denver reported "slow, often fails"; measured 2026-10-18 by the controller):** for the 30 MB 0.42.0 zip, `URLSession.shared.bytes(from:)` iterated byte by byte took **192 s**, while `URLSession.shared.download(from:)` took **13 s** on the same connection. The per-byte async loop is the cause of the slowness, and the long exposure plus no retry is why downloads fail. Replace it with a download task.
- **Failed install-time check (Denver):** tell the writer at next launch, e.g. *"The update to Maugham 0.43.0 didn't pass its safety check and wasn't installed. Maugham will download it again."* The old version keeps running untouched.
- **Old updates (Denver):** delete them automatically, keeping only the version waiting to install.
- **CI pin check (Denver):** a job that runs alongside the others (no `needs:`) and turns the PR red. Whether to mark it "required" in branch protection is a settings click, left to Denver; the PR body says so.
- **Redirects (controller, per research F14):** validate the URL we REQUEST strictly (`https://github.com/dtrouton/Maugham/releases/download/<tag>/<asset.name>`). Refuse a non-https redirect target, but do not allow-list redirect hosts (GitHub changed CDN host in 2025).
- **No second verifier in-process (controller):** the install-time check is the helper's only, on `.inflight`.

## Global Constraints

- Tests never touch the network and never need a signed app. Use the injected closures/seams named in the research.
- Tests build temp files under `TestTemp.root` only (`TripwireGrepTests.test_noTestNamesTheTempDirectoryButTestTemp`).
- Tripwire 33: no synthesised clicks, and no press-then-wait tests.
- `./gen.sh` after adding a file. Iterate with `./scripts/test.sh`, and run `./scripts/test.sh full` before the PR. Never `pgrep -f xcodebuild`. If Core fails with only a `started.` line, another session's build killed it, so re-run.
- Every task sweeps `Maugham/Updates/AREA.md` for sentences its change makes false. In particular, the "No TOCTOU" paragraph goes in Task 4 (workflow rule 10). `docs/RELEASING.md` (~100-109, ~158-166) gets the same treatment.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Stage by path.

## Review Focus

1. **A download that drops mid-way** is retried once (resuming where possible). It never leaves a half file at the final `Maugham-<ver>.zip` path, which would be reused later as if complete.
2. **Progress still moves:** the sheet's bar advances during the new download, and does not jump from 0 to 1.
3. **An app path containing `"`, `$(…)` or a backtick** installs correctly and executes nothing (the end-to-end helper test).
4. **A refused install-time check** leaves the installed app byte-for-byte untouched and no `.inflight` behind, and the next launch says so once.
5. **The cleanup sweep** deletes only `Maugham-<semver>.(zip|dmg)` and `staged-<semver>` entries, never the pending version and never anything else in the folder.

---

### Task 1: Fast, retrying, size-capped download (Denver's report, F16 download half)
Research: `## F16` (download cap) and the speed ruling above. Rewrite `UpdateChecker.defaultDownload`:
- Use a `URLSessionDownloadTask` (its own `URLSession` with a `URLSessionDownloadDelegate`, bridged with a continuation), reporting progress from `didWriteData`. The implementer must confirm the progress callbacks fire. If the async `download(from:delegate:)` API is used instead, prove it delivers `didWriteData`.
- Retry once on a transient `URLError` (`.networkConnectionLost`, `.timedOut`, `.cannotConnectToHost`, `.notConnectedToInternet`), using `resumeData` when the error carries it.
- Abort when the received bytes exceed the cap (`UpdateLimits.maxDownloadBytes`, 512 MB; `UpdateLimits` is a new small struct that Task 3 also uses). `performCheck` also refuses an asset whose `asset.size` exceeds the cap, before calling `downloadAsset` (error on manual, idle on background, like `noInstallableAsset`).
- Write to `.download` then move into place exactly as today, so a failure never leaves the final file.
- Take the extension from `asset.name`, not the URL path (research New-3). Widen the closure signature if needed and keep every test's injected closure compiling.
- Tests: pure tests for the retry classifier and the cap decision; `UpdateCheckerTests` checks that an asset over the cap never calls the download closure. Before committing, run a one-off manual measurement against the real 0.42.0 asset (a throwaway script, not a test) and report the time in the report.
- Commit: `fix(updates): download with a download task, retry once, cap the size (Denver's slow updates; #67 F16)`

### Task 2: Only this repo's release URL; a bad cached zip is not reused (F14, New-2)
Research: `## F14`, `## New` items 2–3. Add `GitHubReleasesAPI.isTrustedAssetURL(_:for:tag:)`, with `owner`/`repo` hoisted to `static let`, called in `performCheck` after the asset guard. Failure throws new `GitHubReleasesAPI.Error.untrustedAssetURL`. In the download session, a redirect to a non-https URL is refused. On `unzipFailed`/`verifyFailed`, delete the cached zip as well as the stage dir.
- Tests: the research's table for `isTrustedAssetURL`; an untrusted asset never calls the download closure; a refused stage deletes the zip. Update the `https://example/…` fixtures in `UpdateCheckerTests.swift:40` and `UpdateProgressTests.swift:25` to the real github.com shape.
- Commit: `fix(updates): accept only this repo's release URL; a refused zip is not reused (#67 F14)`

### Task 3: Size gate before unzipping (F16)
Research: `## F16`. Add pure `parseZipinfoTotals`, `archiveTotals(zip:)` (runs `/usr/bin/zipinfo -t`) and pure `extractionDecision(files:uncompressedBytes:availableBytes:limits:)`. `UpdateLimits` adds `maxUncompressedBytes` 1 GB and `maxFiles` 20 000, with free space required `>= uncompressedBytes * 2 + 256 MB`. Call these in `stageAndVerifySync` before `ditto`. New `InstallError.archiveTooLarge(String)`; a rejection deletes the zip and the stage dir. Unreadable totals mean refusal.
- Tests: as listed in the research (a real `zipinfo -t` line, singular "1 file", garbage ⇒ nil; each refusal arm; one real tiny zip made with `ditto -c -k` under `TestTemp.root`).
- Commit: `fix(updates): refuse an oversized archive before unzipping it (#67 F16)`

### Task 4: The helper re-checks the update on `.inflight`, and takes its paths as argv (F12, F13, New-4)
Research: `## F12`, `## F13`, `## New` item 4. `helperScript(tools:)` becomes fixed text reading `$1`–`$5`, with a `HelperTools` seam. Add `helperArguments(...)`. `launchSwapHelper` gains `expectedTeamID`, and refuses (Finder fallback) when it is nil or malformed. The verify step (`codesign --test-requirement` with the team, then `spctl`) runs after the `kill -0` wait and `ditto` to `.inflight`, and before python. On failure: `rm -rf` the `.inflight`, write the status file, `exit 1`. `installMode` also requires the parent directory to be writable. **Status file:** the helper writes `Updates/install-status` as one line, `refused <version>` or `failed <version> <step>`, on any failure after the app exits. The version is passed as `$6`. Rewrite the "No TOCTOU" paragraph and the helper model in `AREA.md`.
- Tests: pure argv and script-shape tests (the script is byte-identical across argument sets, and the verify step sits between `kill -0` and `python3 "`); the end-to-end helper test described in the research, using stub `codesign`/`spctl`, run for accept, refuse, and hostile directory names (`"`, `$(touch PWNED)`, backtick), checking that `PWNED` does not exist. Skip with `XCTSkip` if `python3` is absent. Rewrite the three existing helper tests the research names.
- Commit: `fix(updates): re-check the update at install time; the helper takes its paths as arguments (#67 F12, F13)`

### Task 5: Next launch says what the helper couldn't do (Denver's ruling)
At launch, read and delete `Updates/install-status`. `refused <v>` shows the ruling's sentence once. `failed <v> <step>` shows *"The update to Maugham <v> couldn't be installed. Maugham will try again."* Put this through the existing `PendingUpdateReveal`/update-banner surface (find which one draws a launch-time update message, and use it rather than adding a second surface). The pure parser `InstallStatus.parse(_:) -> InstallStatus?` and the sentence are unit-tested; the banner is checked windowlessly per tripwire 33.
- Commit: `feat(updates): the next launch says when an update was refused or failed to install`

### Task 6: Old updates are deleted (Denver's ruling, New-1)
Research: `## New` item 1. Pure `staleUpdateArtifacts(in:keeping:) -> [String]` matches only `Maugham-<semver>.(zip|dmg)`, `Maugham-<semver>.<ext>.download` and `staged-<semver>`. It keeps the pending version; with no pending version it keeps nothing at or below the running version. Run the sweep at launch, off the main thread, and after a successful stage, keeping only the new version.
- Tests: a table over names (including foreign files and `install-status`, which are kept); one run against a directory under `TestTemp.root`.
- Commit: `feat(updates): delete old downloaded updates, keeping the one waiting to install`

### Task 7: CI verifies action pins on every run (F15)
Research: `## F15`. Add one job `action-pins` to `.github/workflows/ci.yml`, as shown in the research, with no `needs:` anywhere. It runs the offline unit test and then `scan_and_verify_pins` with `GH_TOKEN: ${{ github.token }}`. Use only actions already pinned in this file, and give the job `permissions: contents: read`. Update `docs/RELEASING.md` ~158-166.
- Verify locally: `bash scripts/tests/verify-action-pins.test.sh` passes, and `source scripts/lib/verify-action-pins.sh && scan_and_verify_pins` passes with the new file (it scans itself).
- Commit: `ci: verify action pins on every run (#67 F15)`

### Finish
- [ ] `./scripts/test.sh full`, green.
- [ ] Whole-branch review (opus), told not to build.
- [ ] PR closing #67. The body includes Denver's smoke (a real update, which needs a release cut, so the smoke happens at the next release), the "mark required" settings note, and the F15 honesty gotcha from the research.
