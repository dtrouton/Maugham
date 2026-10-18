# Updates area — invariants and architecture

Mac-only (updater is disabled for dev builds via `BuildVariant.updaterEnabled`). Read
this before editing any file in this directory.

---

## Verification chain

Every staged bundle goes through three checks **on the same staged bytes**, in this order,
before anything is swapped in:

| Step | What | Why |
|---|---|---|
| `codesign --verify --deep --strict` | Valid Developer ID signature throughout the bundle | Catches tampered or unsigned bundles |
| `spctl -a -t exec` | Apple notarization present (Gatekeeper would accept it) | Catches sideloaded or un-notarized builds |
| Team ID == running app's Team ID | The staged bundle is from **our** team | Prevents a validly-signed-but-wrong-team bundle from replacing the app |

The Team ID is read from the **running app's own code signature** at runtime
(`UpdateInstaller.runningAppTeamID()` via `SecCodeCopySelf`), never hardcoded. This is
self-anchoring: any signed release of Maugham can verify a future update without a code
edit, and a developer-team change requires both the installed app and the update to carry
the new ID simultaneously.

**No TOCTOU.** The verified path (returned by `stageAndVerifySync`) is exactly the path
passed to the helper script. Verification runs on the staged bytes; the same bytes are
swapped in. There is no window between verify and install where a different bundle could
be substituted.

Other protections:
- **Only this repo's release URL is requested.** `GitHubReleasesAPI.isTrustedAssetURL` admits exactly `https://github.com/dtrouton/Maugham/releases/download/<tag>/<asset.name>` (the release's own `tag_name`; no port, user, query or fragment), checked in `performCheck` after the asset guard and before the size check — a failure is `.untrustedAssetURL`, an error on a manual check and idle on a background poll. GitHub answers with a redirect to its asset CDN; that host is **not** allow-listed (it changed in 2025, and TLS plus the signature chain gate the bytes), but a redirect to a non-https URL is refused (`UpdateDownload.followsRedirect`, applied in `UpdateDownloadSession`) and fails as `.insecureRedirect`. For a zip-less release the `.dmg` is not verified in-app at all, so for it this URL check is the only in-app gate.
- **A refused archive is not reused.** Every `InstallError` from staging (`unzipFailed`, `verifyFailed`, `archiveTooLarge`, `archiveUnreadable`) goes through `UpdateInstaller.discardRefusedArchive`, which deletes the stage folder AND the downloaded `Maugham-<ver>.zip` — the checker reuses a zip already at that path, so a bad one left there would be re-staged and re-refused on every later check. A transient refusal (spctl offline) costs one re-download; that is accepted.
- **An archive is size-checked before it is unpacked.** `stageAndVerifyUnchecked` reads the zip's central directory with `/usr/bin/zipinfo -t` (`archiveTotals`/`parseZipinfoTotals`) and asks the pure `extractionDecision`: refuse over `UpdateLimits.maxUncompressedBytes` (1 GB) or `maxFiles` (20 000), or when the Updates volume's `volumeAvailableCapacityForImportantUsage` is under `uncompressedBytes * 2 + 256 MB` (twice, because the helper copies it again beside the installed app). Over-limit and not-enough-space are `InstallError.archiveTooLarge(reason)`; totals or free space that can't be read are `InstallError.archiveUnreadable` ("The downloaded update couldn't be read…"), a refusal too. Both take the same `discardRefusedArchive` cleanup. **Stated limit:** the totals are what the archive DECLARES; a crafted one can lie, and only a byte-counting extractor would close that.
- **The download is capped** at `UpdateLimits.standard.maxDownloadBytes` (512 MB, ~17× a release today): an asset DECLARING more is refused before a byte is fetched (an error on a manual check, idle on a background poll), and a download RECEIVING more is cancelled and leaves no file.
- Strict `>` version comparison (`UpdateChecker.swift`) prevents downgrade.
- **A build this Mac cannot launch is not an update.** `release.yml` appends
  `<!-- maugham-minimum-macos: <n> -->` to every release body, read out of the built app's own
  `LSMinimumSystemVersion`; `MinimumSystemVersion.parse` reads it back off the body the checker
  already fetches, and a minimum above `ProcessInfo`'s OS lands in
  `.newerBuildNeedsNewerSystem` — up-to-date-shaped, nothing downloaded, one sentence in the
  sheet. Decided **before** the asset guard and before any byte is fetched. A release with no
  such line (everything before 0.40.0) is offered exactly as before: absence is never a refusal.
  The marker is stripped from `releaseNotes` because the sheet draws them as plain `Text`.

**What the BUILD does when `LSMinimumSystemVersion` and `MACOSX_DEPLOYMENT_TARGET` disagree**
(measured 2026-09-19 on Xcode 27.0, by building the app with each value in turn):

| `project.yml` declares | `MACOSX_DEPLOYMENT_TARGET` | Built `Info.plist` carries | Xcode says |
|---|---|---|---|
| `LSMinimumSystemVersion: "15.0"` | `27.0` | **`27.0`** | `warning: LSMinimumSystemVersion of '15.0' is less than the value of MACOSX_DEPLOYMENT_TARGET '27.0' - setting to '27.0'.` |
| `LSMinimumSystemVersion: "28.0"` | `27.0` | **`28.0`** | nothing |

So the build **floors** the value at the deployment target and does not cap it. Two consequences
for the marker, which is read off the built plist:

- **A stale-LOW declaration can never publish a lie.** `project.yml` carried `14.0` against a
  target of 26 for six weeks; had `release.yml` existed then, it would still have published `26.0`,
  because the build had already raised it. The updater's refusal cannot under-report and offer a
  build to a Mac that cannot run it.
- **A stale-HIGH declaration can.** Nothing raises the target to meet it and nothing warns, so the
  app would declare — and the marker would publish — a floor higher than the code requires, and the
  updater would withhold an update from Macs that could have run it. That is the direction the
  census guards: `TripwireGrepTests.test_everyMacOSFloorInProjectYmlIsTheSameNumber`, with
  `test_theMacOSFloorCensusFiresOnAPlantedOffender` as its control.
- CI marks patch ≥ 90 as a pre-release; `/releases/latest` excludes pre-releases, so
  throwaway dry-run builds (e.g. `v0.0.91`) never auto-install into production.
- The staged bundle's quarantine xattr is stripped before install (the app was already
  notarized; the xattr would re-trigger Gatekeeper on first launch).

---

## Atomic same-volume swap — WHY this is the only correct approach

The old code (`rm -rf "<installed>"; mv ".inflight" "<installed>"`) had a **brick risk**:
a crash or power-loss in the narrow gap between `rm` and `mv` left
`/Applications/Maugham.app` **missing** — unlaunchable until manual reinstall.

The fix is `renamex_np(src, dst, RENAME_SWAP)` (Darwin syscall, macOS 10.12+):

- **RENAME_SWAP atomically exchanges the two filesystem directory entries.** Both paths
  exist throughout; there is no instant where the install location is absent.
- The `.inflight` sibling is always in the same directory as the installed bundle
  (same volume by construction), which is required by `renamex_np`.
- After the swap, `.inflight` holds the old bundle (safe to remove). If removal fails,
  the stale `.inflight` is harmless garbage — the new app is already in place.

Crash analysis after the fix:

| Crash point | State | Recovery |
|---|---|---|
| During `ditto` (staging) | `.inflight` is partial; installed is intact | Next launch: stale `.inflight` present, installed runs fine; `.inflight` cleaned on next update |
| During `renamex_np` | Atomic — cannot crash mid-swap | N/A |
| After swap, during `.inflight` cleanup | Stale `.inflight` present; new app is in place | Harmless; cleaned on next update |

The `RENAME_SWAP` constant (`0x00000002`) and the `renamex_np` call are in
`UpdateInstaller.pyAtomicSwapSource` (the Python script embedded in the bash helper) and
in `UpdateInstaller.atomicSwap(staged:installed:)` (the Swift unit-testable entry point).

**`FileManager.replaceItemAt` was considered** but rejected for this use: it moves
the destination to a backup path before replacing, which means there IS a transient
window where the install location holds the backup (not the running app), and the API
is designed for file-level replacement, not directory/bundle swaps. `renamex_np` with
`RENAME_SWAP` is the right primitive.

---

## Detached helper relaunch model

The app cannot replace its own running bundle. The proven pattern:

1. **Swift side**: writes a small bash script to `$TMPDIR/maugham-update-<uuid>.sh`,
   launches it detached (`/bin/bash script.sh` via `Process` without waiting).
2. **App terminates.** The child process reparents to launchd (it survives the parent's
   exit because it has no controlling TTY and launchd adopts orphans).
3. **Bash helper**: polls `kill -0 <pid>` until the app is fully gone, then:
   - `rm -rf .inflight && ditto staged .inflight` — copies new bundle to same-volume sibling
   - Python `renamex_np(RENAME_SWAP)` — atomic exchange
   - `rm -rf .inflight` — cleanup old bundle
   - (if relaunch) `open "/Applications/Maugham.app"`

**Debug caveat.** When launched from Xcode/lldb, the debugger kills the process group on
app exit, so the helper is killed with it. The in-place swap will not apply in debug
sessions — only in production (Finder/Dock) launches where the child is truly detached.

---

## Unwritable `/Applications` fallback

Before offering "Restart & Update," the installer checks
`FileManager.default.isWritableFile(atPath: installedBundlePath)`. If the path is not
writable (non-admin user, unusual permissions), `installMode(installedBundlePath:)` returns
`.finderFallback` and the caller reveals the `.dmg` in Finder — identical to the
pre-auto-update behavior. **Worst case == status quo, never worse.**

---

## What is and is not unit-testable

| Aspect | Testable? | Where |
|---|---|---|
| Verify decision logic (accept/reject/team-mismatch/...) | Yes | `UpdateInstallerTests.test_accepts_*` / `test_rejects_*` |
| Minimum-macOS block (above → no update + sentence; at/below → offered; no fact → offered) | Yes (injected `systemVersion`) | `MinimumSystemVersionTests`; `UpdateCheckerTests.test_aBuild*System*` |
| Install mode (writable → inPlace, not writable → finderFallback) | Yes (injected predicate) | `test_installMode_*` |
| Helper script shape (pid-wait, ditto, open presence) | Yes (string inspection) | `test_helperScript_*` |
| No rm+mv on installed bundle (brick-prevention assertion) | Yes | `test_helperScript_usesAtomicSwap_notRmMv` |
| Python swap source is flush-left (no IndentationError) | Yes | `test_pyAtomicSwapSource_noLeadingSpacesOnTopLevelLines` |
| `atomicSwap` same-volume: destination never absent, content swapped | Yes (temp dirs) | `test_atomicSwap_sameVolume_*` |
| `atomicSwap` missing staged path → `.sourceNotFound` | Yes | `test_atomicSwap_throwsSourceNotFound_*` |
| `atomicSwap` cross-volume → `.crossVolume` | Yes (RAM disk via hdiutil; skipped if unavailable) | `test_atomicSwap_throwsCrossVolume_*` |
| Download retry classifier, size cap, extension from the asset name | Yes (pure) | `UpdateDownloadTests` |
| Download delegate path: completes into place / refused past the cap leaves nothing | Yes (`file://` source under `TestTemp.root`, no network) | `UpdateDownloadTests.test_a*` |
| An asset declaring more than the cap is never downloaded | Yes (injected download closure) | `UpdateCheckerTests.test_anAsset*Cap*` |
| Only this repo's release URL is trusted; an untrusted one is never downloaded | Yes (pure table; injected download closure) | `GitHubReleasesAPITests.test_onlyThisRepos*`; `UpdateCheckerTests.test_anUntrustedAssetURL*` |
| Redirect policy (https only, any host) | Pure decision only — the delegate's redirect is not exercised offline | `UpdateDownloadTests.test_aRedirectIsFollowedOnlyToHttps` |
| Zip totals parse; each size/space refusal arm; a real tiny zip is read by `zipinfo`; a zip with no room is refused before unpacking and deleted | Yes (pure + injected free space + real `ditto -c -k` under `TestTemp.root`) | `UpdateInstallerTests.test_*Zipinfo*`, `test_extractionDecision_*`, `test_archiveTotals*`, `test_aZipTooBig*` |
| A refused zip is deleted with its stage folder | Yes (garbage / app-less zip under `TestTemp.root`, real `ditto`) | `UpdateInstallerTests.test_aZip*IsDeleted*` |
| Running-app Team ID (real signed build) | No — ad-hoc test host returns nil; proven in dry-run | `test_runningAppTeamID_doesNotCrash` (smoke only) |
| **Detached helper actually replaces the running app and relaunches** | **NO — cannot be unit-tested** | See below |

**The running-app self-replace path requires a real update smoke test.** The only way to
verify the full install cycle (codesign + notarize + download + verify + swap + relaunch)
is to cut a throwaway tag, let CI build + sign + notarize it, install it on a real Mac,
and observe the swap. See `docs/superpowers/notes/feedback_dry_run_is_integration_test.md`.

**Smoke test checklist (run after any change to `helperScript` or `pyAtomicSwapSource`):**
1. Cut a throwaway `v0.0.x` tag (CI builds and notarizes).
2. Install the throwaway on a real Mac in `/Applications`.
3. Trigger an update to a higher patch version.
4. "Restart & Update" — verify the app quits, the new version appears, and there is no
   gap where `/Applications/Maugham.app` is missing (check Activity Monitor / ls -la).
5. "Dismiss" followed by ordinary quit — verify the pending-quit install fires.
6. Delete the throwaway tags after confirmation.

---

## Key files

| File | Purpose |
|---|---|
| `UpdateInstaller.swift` | Stage-and-verify (every refusal deletes the zip too, `discardRefusedArchive`), verify logic, atomic swap (`atomicSwap`/`pyAtomicSwapSource`), helper script generation, Team ID extraction |
| `UpdateChecker.swift` | Background poll loop, download into place (`.download` temp, then moved to `Maugham-<ver>.<ext>`; an existing complete file is reused), the trusted-URL check and the pre-download size refusal, stage-and-verify dispatch, `pendingQuitInstall` |
| `UpdateDownload.swift` | The download itself: a `URLSessionDownloadTask` on its own session (delegate `UpdateDownloadSession`, progress from `didWriteData`), one retry on a transient `URLError` (resuming from its resume data) or an HTTP 5xx, progress kept monotonic across it, cancelled past the cap (a Swift-Task cancel that lands before the task exists cancels it instead of resuming it), a non-https redirect refused; the extension comes from the asset's name |
| `UpdateLimits.swift` | The updater's size ceilings (`UpdateLimits.standard`; `maxDownloadBytes` 512 MB, `maxUncompressedBytes` 1 GB, `maxFiles` 20 000) |
| `UpdateState.swift` | Enum of updater states (idle/checking/downloading/readyToInstall/installing/error/upToDate) |
| `GitHubReleasesAPI.swift` | GitHub Releases JSON decode; `zipAsset` preferred over `dmgAsset`; `owner`/`repo` and `isTrustedAssetURL` |
| `UpdateBannerView.swift` | In-window toast ("Maugham X.Y.Z is ready") |
| `UpdateSheet.swift` | Sheet variant of the install UI |
| `UpdateMenuCommand.swift` | Menu bar entry (title derived from `UpdateState`) |
| `SemanticVersion.swift` | Comparable version parsing; `>` used for strict downgrade prevention |
| `MinimumSystemVersion.swift` | The build's minimum macOS vs this Mac's: the marker's wire format, its parser, the display stripper |

---

## Spec reconciliation

`docs/superpowers/specs/2026-06-01-mac-auto-update-design.md` §"Error handling" says:
> "Swap fails mid-ditto → ditto to a temp sibling then **atomic rename**, so a partial
> copy never replaces a working app"

The spec promised an atomic rename, and the original implementation used `rm -rf` + `mv`
instead (not atomic, brick risk on crash). This is now correct: the swap uses
`renamex_np(RENAME_SWAP)`, which is the atomic primitive the spec intended. The spec
entry is superseded by this AREA.md description of what the code actually does.
