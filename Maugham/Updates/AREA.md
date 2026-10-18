# Updates — area guide

The Mac's in-place auto-updater: finding the latest Mac release on GitHub, downloading and size-checking it, staging and verifying the bundle, and the detached helper that re-verifies it and swaps it into place atomically after the app quits. Mac-only, and disabled for dev builds (`BuildVariant.updaterEnabled`). CLAUDE.md's area table names no rule of its own for this area; the one rule is this guide's: **only the helper's install-time check decides what is installed, and the install location is never absent.** The narrative, the incidents and the rejected alternatives are in `docs/history/updates.md`.

## Map

Every file in `Maugham/Updates/` appears once.

- `UpdateInstaller.swift` — stage-and-verify (`stageAndVerifySync`, `stageAndVerifyUnchecked`), the verify logic, the zip-size gate (`archiveTotals`, `parseZipinfoTotals`, `extractionDecision`), `discardRefusedArchive`, `installMode(installedBundlePath:)`, the atomic swap (`atomicSwap(staged:installed:)`, `pyAtomicSwapSource`), the helper (`helperScript(tools:)`, `helperArguments`, `HelperTools`, `HelperFailureStep`, `launchSwapHelper`), `runningAppTeamID()`, and `PendingUpdateReveal` (the Finder reveal deferred to next launch when a quit-time helper could not be launched).
- `UpdateChecker.swift` — the background poll, download into place (a `.download` temp, then moved to `Maugham-<ver>.<ext>`; a complete file already there is reused), the trusted-URL check and the pre-download size refusal, stage-and-verify dispatch, `pendingQuitInstall`, `reportInstallStatus(in:)`, `installNotice`, `sweepAfterStage`, and `InstallRefusalMemory` (the two-refusal background guard).
- `UpdateDownload.swift` — the download itself: a `URLSessionDownloadTask` on its own session (delegate `UpdateDownloadSession`, progress from `didWriteData`), one retry, the cap, the redirect policy (`followsRedirect`), the extension taken from the asset's name.
- `UpdateLimits.swift` — the size ceilings, `UpdateLimits.standard`: `maxDownloadBytes` 512 MB, `maxUncompressedBytes` 1 GB, `maxFiles` 20 000.
- `UpdateState.swift` — the updater's states: idle, checking, downloading, readyToInstall, installing, error, upToDate, newerBuildNeedsNewerSystem.
- `InstallStatus.swift` — the helper's `install-status` line: `parse`, `consume`, the notice's sentence (`sentence(waitsForManualCheck:)`).
- `UpdateSweep.swift` — deletes the updater's own old downloads (`staleUpdateArtifacts(in:keeping:runningVersion:)`, `sweep`).
- `GitHubReleasesAPI.swift` — the Releases JSON decode, `fetchLatestRelease`, `latestMacRelease`, `zipAsset` preferred over `dmgAsset`, `owner`/`repo`, `isTrustedAssetURL`.
- `MinimumSystemVersion.swift` — the build's minimum macOS against this Mac's: the release-body marker's wire format, `parse`, and the stripper that keeps it out of the notes.
- `SemanticVersion.swift` — comparable version parsing; strict `>` is the downgrade guard.
- `UpdateBannerView.swift` — the in-window toast ("Maugham X.Y.Z is ready", or the last install's notice through its pure `notice(for:)`).
- `UpdateSheet.swift` — the Check for Updates… sheet.
- `UpdateMenuCommand.swift` — the menu bar entry; its title derives from `UpdateState`.

## Rules

### The verification chain
Every update is checked **twice**: when it is staged (in-app, `stageAndVerifySync`), and again by the detached helper **at install time**, on the `.inflight` copy (the exact bytes the swap moves) after the app has exited. Only the second check decides what is installed.

| When | Step | What | Why |
|---|---|---|---|
| Staging | `codesign --verify --deep --strict` | Valid Developer ID signature throughout the bundle | Catches tampered or unsigned bundles |
| Staging | `spctl -a -t exec` | Apple notarization present | Catches sideloaded or un-notarized builds |
| Staging | Team ID == running app's Team ID | The staged bundle is from our team | A validly signed bundle from the wrong team must not replace the app |
| Install (helper, on `.inflight`) | `codesign --verify --deep --strict --test-requirement="=anchor apple generic and certificate leaf[subject.OU] = \"<team>\""` | Validity and our team in one call (exit 3 on a wrong team) | The staged copy waited hours or days in a user-writable folder |
| Install (helper, on `.inflight`) | `spctl -a -t exec` | Notarization, again | As above |

- **The Team ID is read from the running app's own signature at runtime** (`UpdateInstaller.runningAppTeamID()` via `SecCodeCopySelf`), never hardcoded: any signed release verifies a future one without a code edit, and a team change needs the installed app and the update to carry the new ID at once. With no team (ad-hoc, unsigned, the test host) or a malformed one, `launchSwapHelper` launches nothing and the caller takes the Finder fallback.
- **The helper re-checks the staged bundle at install time**: the staged copy sits in `~/Library/Application Support/<variant>/Updates/staged-<ver>/`, a plain user-owned folder, until "Restart & Update" or the next quit, and anything that could write that folder could substitute it. After the app exits the helper copies it to `<installed>.inflight` (same volume as the install location), runs the codesign requirement check and `spctl` on that copy, and only then swaps.
- **On a refusal the installed app is untouched**: the helper removes `.inflight`, writes `refused <version>` to `Updates/install-status` and exits; after "Restart & Update" (`RELAUNCH=1`) it reopens the OLD app, so the writer is never left with no Maugham running.
- **There is no second verifier in-process.** In `willTerminate`, `spctl` could hang the quit on the network with nothing on screen; in the helper the app is already gone.
- **Offline is not a refusal.** `release.yml` staples the notarization ticket (`xcrun stapler staple`, then gates on `spctl -a -t exec` before packaging), so `spctl` assesses the staged copy from its own ticket with no network. A refusal therefore means the bytes failed.
- **The residual exposure is stated, not fixed**: a same-user race of a few milliseconds between the verify and `renamex_np`. `installMode` requires the install folder to be writable by this user, and anything that can win that race can already write the install folder.
- **The helper takes its paths as arguments, never interpolated.** `helperScript(tools:)` is fixed text; the pid, both bundle paths, the team, the relaunch flag, the version and the Updates folder arrive as `$1`…`$7` (`helperArguments`), every use double-quoted. The script re-validates each (team ten of `A-Z0-9`, version digits and dots, paths absolute, the installed path ending `.app`) and exits 2 before touching anything if one is wrong, so a path containing `"`, `$(…)` or a backtick is data.
- **The only interpolated values are `HelperTools`' constant tool paths** (`codesign`, `spctl`, `ditto`, `open`), which a precondition restricts to `^[A-Za-z0-9/._-]+$` and tests replace with stubs (`test_helperToolPaths_arePlainAbsolutePaths`).
- **The staged bundle's quarantine xattr is stripped before install**: the app is already notarized, and the xattr would re-trigger Gatekeeper on first launch.

### Which release, and whether to fetch it
- **Which release is "latest" is decided in-app, never by `/releases/latest`.** `GitHubReleasesAPI.fetchLatestRelease` reads the first 30 entries of `/releases`, and `latestMacRelease` takes the highest `SemanticVersion` that is not a draft, not a pre-release, and carries a plain `X.Y.Z` Mac tag. A `phone-v*` tag parses to nil and is skipped: `/releases/latest` returns the most recently published release across all tags, which a phone tag cut after the Mac release would win (`test_selectMacRelease_ignoresNewerPhoneTag`).
- **Dry-run builds never auto-install**: `release.yml` marks patch ≥ 90 as a pre-release (e.g. `v0.5.90`), and pre-releases are filtered out.
- **Version comparison is strict `>`** (`UpdateChecker.swift`), which prevents a downgrade.
- **A build this Mac cannot launch is not an update.** `release.yml` appends `<!-- maugham-minimum-macos: <n> -->` to every release body, read out of the built app's own `LSMinimumSystemVersion`. `MinimumSystemVersion.parse` reads it off the body the checker already fetches; a minimum above `ProcessInfo`'s OS lands in `.newerBuildNeedsNewerSystem`: up-to-date-shaped, nothing downloaded, one sentence in the sheet. It is decided **before** the asset guard and before any byte is fetched.
- **A release with no minimum marker is offered as before**: absence is never a refusal (`test_aReleaseCarryingNoMinimumIsOfferedAsBefore`). The marker is stripped from `releaseNotes`, because the sheet draws them as plain `Text`.
- **Only this repo's release URL is requested.** `GitHubReleasesAPI.isTrustedAssetURL` admits exactly `https://github.com/dtrouton/Maugham/releases/download/<tag>/<asset.name>` (the release's own `tag_name`; no port, user, query or fragment), checked in `performCheck` after the asset guard and before the size check. A failure is `.untrustedAssetURL`: an error on a manual check, idle on a background poll.
- **A redirect is followed only to https**, to any host: GitHub redirects to its asset CDN, whose host changed once already, and TLS plus the signature chain gate the bytes. A non-https redirect is refused (`UpdateDownload.followsRedirect`, applied in `UpdateDownloadSession`) and fails as `.insecureRedirect`.
- **A zip-less release's `.dmg` is not verified in-app at all**, so for it the URL check is the only in-app gate.
- **The download is capped** at `UpdateLimits.standard.maxDownloadBytes`: an asset DECLARING more is refused before a byte is fetched (an error on a manual check, idle on a background poll), and a download RECEIVING more is cancelled and leaves no file.
- **The download retries once**: on a transient `URLError` (resuming from its resume data) or an HTTP 5xx, with progress kept monotonic across it. A Swift-Task cancel that lands before the task exists cancels it instead of resuming it.
- **A pending version is not re-staged.** While `pendingQuitInstall` names version V and its `staged-<V>` bundle exists, a later check offered V (background or manual) neither downloads nor stages, and just restores `.readyToInstall` with the pending bundle: re-staging would `removeItem` the stage folder and re-`ditto` it while a quit could hand that path to the helper.

### Staging refusals
- **An archive is size-checked before it is unpacked.** `stageAndVerifyUnchecked` reads the zip's central directory with `/usr/bin/zipinfo -t` (`archiveTotals`/`parseZipinfoTotals`) and asks the pure `extractionDecision`: refuse over `UpdateLimits.maxUncompressedBytes` or `maxFiles`, or when the Updates volume's `volumeAvailableCapacityForImportantUsage` is under `uncompressedBytes * 2 + 256 MB` (twice, because the helper copies it again beside the installed app).
- **Over-limit and not-enough-space are `InstallError.archiveTooLarge(reason)`; totals or free space that cannot be read are `InstallError.archiveUnreadable`**, a refusal too ("The downloaded update couldn't be read…").
- **The totals are what the archive DECLARES**; a crafted archive can lie, and only a byte-counting extractor would close that. Stated limit.
- **A refused archive is not reused.** Every `InstallError` from staging (`unzipFailed`, `verifyFailed`, `archiveTooLarge`, `archiveUnreadable`) goes through `UpdateInstaller.discardRefusedArchive`, which deletes the stage folder AND the downloaded `Maugham-<ver>.zip`: the checker reuses a zip already at that path, so a bad one left there would be re-staged and re-refused on every later check.

### The atomic swap
- **The swap is `renamex_np(src, dst, RENAME_SWAP)`, never `rm` then `mv`**: a crash between `rm -rf "<installed>"` and `mv` left `/Applications/Maugham.app` missing until a manual reinstall. `RENAME_SWAP` exchanges the two directory entries atomically; both paths exist throughout (`test_helperScript_usesAtomicSwap_notRmMv`).
- **`.inflight` is always a sibling of the installed bundle**, so it is on the same volume by construction, which `renamex_np` requires. After the swap it holds the old bundle; if removing it fails, the stale `.inflight` is harmless and is cleaned on the next update.
- **The `RENAME_SWAP` constant (`0x00000002`) and the call live in two places that must agree**: `UpdateInstaller.pyAtomicSwapSource` (the Python embedded in the bash helper) and `UpdateInstaller.atomicSwap(staged:installed:)` (the Swift unit-testable entry point). The Python source is flush-left (`test_pyAtomicSwapSource_noLeadingSpacesOnTopLevelLines`).
- **`FileManager.replaceItemAt` is not the primitive**: it moves the destination to a backup path first, so the install location transiently holds the backup, and it is built for files, not bundles.

| Crash point | State | Recovery |
|---|---|---|
| During `ditto` (staging) | `.inflight` is partial; installed is intact | The installed app runs; `.inflight` is cleaned on the next update |
| During `renamex_np` | Atomic: cannot crash mid-swap | N/A |
| After the swap, during `.inflight` cleanup | Stale `.inflight`; the new app is in place | Harmless; cleaned on the next update |

### The detached helper
The app cannot replace its own running bundle, so a detached helper does it.

1. **Swift side** (`launchSwapHelper(stagedBundle:version:updatesDirectory:relaunch:…)`) refuses (returns false → Finder fallback) unless the bundle AND its folder are writable, the running app has a well-formed team ID, the version is `X.Y.Z` and `python3` is on PATH. It writes the fixed `helperScript()` to `$TMPDIR/maugham-update-<uuid>.sh` and launches it detached (`/bin/bash script.sh <pid> <staged> <installed> <team> <1|0> <version> <Updates dir>` via `Process`, without waiting).
2. **The app terminates.** The child reparents to launchd, which adopts orphans.
3. **The bash helper** runs under `set -e`, and every failure path below is an explicit `if !` so it records. Every one after the argument guard ends in `reopen`: with `$RELAUNCH` `1` it runs `open "$INSTALLED"` (the untouched old app) before `exit 1`, `|| true` so it cannot trip `set -e`. In order:
   - validates its seven arguments (exit 2; nothing touched, nothing recorded);
   - `command -v python3`, before the wait (`test_helperScript_python3GuardPrecedesFirstDestructiveStep`); missing, it records `failed <v> python3`, and with `$RELAUNCH` `1` waits for the app to exit and reopens it;
   - polls `kill -0 "$PID"` until the app is gone;
   - `rm -rf .inflight && ditto staged .inflight`; on failure it removes `.inflight` and records `failed <v> ditto`;
   - the codesign requirement check, then `spctl -a -t exec`, both on `.inflight`; on failure it removes `.inflight`, records `refused <v>`, and exits before the swap;
   - the Python `renamex_np(RENAME_SWAP)`, then removes `.inflight` (the old bundle); a failure (including making or writing its source file) records `failed <v> swap` and **leaves `.inflight`, which on the fallback path may hold the only copy of the new app**;
   - `reopen`: with `$RELAUNCH` `1`, `open "$INSTALLED"`, now the new app.
- **Under Xcode/lldb the swap does not apply**: the debugger kills the process group on app exit, helper included. Only a Finder/Dock launch detaches the child.

### The install status and the next launch
- **`Updates/install-status` holds ONE line, overwritten** (written to `install-status.tmp`, then `mv`): `refused <version>` or `failed <version> <step>`, the step one of `UpdateInstaller.HelperFailureStep` (`python3`, `ditto`, `swap`). Success writes nothing.
- **The next launch reports it before the poll starts**: the Welcome scene's `.task` calls `UpdateChecker.reportInstallStatus(in:)` (stable variant only, never in a test host).
- **`InstallStatus.consume` removes the file unconditionally**, a line that does not parse included: a later successful install writes nothing, and an old line would otherwise outlive it.
- **`InstallStatus.parse` accepts exactly the two forms**, an `X.Y.Z` version and a `HelperFailureStep` raw value, and nothing else.
- **The parsed notice is held as `UpdateChecker.installNotice`, apart from `state`**, so no check result replaces it: the sentence must actually be seen (`test_theNoticeSurvivesEveryLaterCheckResult`). Dismiss (`dismissInstallNotice`) clears it. It is not persisted; one launch is enough.
- **`UpdateBannerView` draws the notice ahead of any "ready" row**, and the sheet draws it above whatever the check shows.
- **`refused` says** *"The update to Maugham <v> didn't pass its safety check and wasn't installed. Maugham will download it again."* (`test_theRefusedSentenceIsDenversRulingVerbatim`), **and deletes that version's `Maugham-<v>.zip` and `staged-<v>` through `discardRefusedArchive`**, or the sentence would be false.
- **`failed` says** *"The update to Maugham <v> couldn't be installed. Maugham will try again."* **and KEEPS the staged files**: every step names this Mac at that moment, not the bytes, so the next check re-stages without a download (with no python3, the next install takes the Finder fallback).
- **A line naming a version not newer than the running app is stale** (that update arrived) and says nothing.
- **The banner mounts in project windows only**, and the Welcome window has no update surface, so a writer who never opens a project sees the notice only in Check for Updates…. Stated limit.
- **A version refused twice is not re-staged by the background poll.** `reportInstallStatus` increments `InstallRefusalMemory` (UserDefaults key `maugham.updateInstallRefusals`: one version and a count; injected as `refusalDefaults`, so tests use a private suite) on every `refused` line. At `backgroundLimit` (2) the poll stays idle for that version: no download, no stage, no banner, because each retry is a full re-download refused again at the next quit.
- **A manual Check for Updates still downloads and stages a twice-refused version.** The memory is forgotten when a check is offered any other version, or when the running app has reached it. A `failed` line is not counted.
- **From the second refusal on, the notice says so**: *"The update to Maugham <v> didn't pass its safety check again and wasn't installed. Choose Check for Updates… to try once more."* (`UpdateChecker.installNoticeWaitsForManualCheck` → `InstallStatus.sentence(waitsForManualCheck:)`).

### Old updates are deleted
- **`UpdateSweep` deletes only the updater's own artifacts.** The pure `staleUpdateArtifacts(in:keeping:runningVersion:)` can only ever return `Maugham-<semver>.(zip|dmg)`, the same with `.download`, and `staged-<semver>`: never `install-status`, never anything else (`test_foreignAndUnmatchedNamesAreNeverReturned`).
- **Versions compare with `SemanticVersion`** (pre-releases like 0.41.90 exist). With a `keeping` version every other matching entry goes; with none, entries at or below the running version go and a newer one is kept (the next check may reuse it).
- **The sweep runs twice.** At launch: in the Welcome `.task`, after `reportInstallStatus` so the refused-deletion and the sweep never race, off the main thread, skipped in test hosts and dev builds, `.download` files included. After a successful stage: `UpdateChecker.sweepAfterStage` (set only by the app at launch), keeping only the new version and never touching `.download` files, since one may be mid-write.

### The unwritable-`/Applications` fallback
- **Worst case is the status quo, never worse.** Before offering "Restart & Update", `installMode(installedBundlePath:)` checks `FileManager.default.isWritableFile(atPath:)` on the installed bundle AND on its folder (the helper creates `.inflight` there). If either is not writable it returns `.finderFallback`, and the caller reveals the `.dmg` in Finder.
- **A quit-time helper that cannot launch defers its reveal to next launch** (`PendingUpdateReveal.markPending`, consumed once): the app is already tearing down, unlike `installNow`'s live fallback in `MaughamApp.swift`'s `performInstall`.

### The macOS floor
**What the BUILD does when `LSMinimumSystemVersion` and `MACOSX_DEPLOYMENT_TARGET` disagree** (measured on Xcode 27.0, building the app with each value in turn):

| `project.yml` declares | `MACOSX_DEPLOYMENT_TARGET` | Built `Info.plist` carries | Xcode says |
|---|---|---|---|
| `LSMinimumSystemVersion: "15.0"` | `27.0` | **`27.0`** | `warning: LSMinimumSystemVersion of '15.0' is less than the value of MACOSX_DEPLOYMENT_TARGET '27.0' - setting to '27.0'.` |
| `LSMinimumSystemVersion: "28.0"` | `27.0` | **`28.0`** | nothing |

- **The build floors the value at the deployment target and does not cap it**, and the marker is read off the built plist.
- **A stale-LOW declaration can never publish a lie**: the build has already raised it, so the updater cannot offer a build to a Mac that cannot run it.
- **A stale-HIGH declaration can**: nothing raises the target to meet it and nothing warns, so the marker would publish a floor higher than the code needs and withhold updates from Macs that could run them. Every macOS floor in `project.yml` is the same number (`TripwireGrepTests.test_everyMacOSFloorInProjectYmlIsTheSameNumber`; control `test_theMacOSFloorCensusFiresOnAPlantedOffender`).

### What is and is not unit-testable

| Aspect | Testable? | Where |
|---|---|---|
| Verify decision logic (accept/reject/team mismatch) | Yes | `UpdateInstallerTests.test_accepts_*` / `test_rejects_*` |
| Minimum-macOS block (above → no update + sentence; at/below → offered; no fact → offered) | Yes (injected `systemVersion`) | `MinimumSystemVersionTests`; `UpdateCheckerTests.test_aBuild*System*` |
| Install mode (bundle and folder writable → inPlace, either not → finderFallback) | Yes (injected predicate) | `test_installMode_*` |
| No helper without a well-formed team or version | Yes | `PendingUpdateRevealTests.test_launchSwapHelper_returnsFalse_*` |
| Helper script shape: argv order, fixed text carrying no argument, re-check between the wait and the swap, python3 guard first | Yes (string inspection) | `test_helperArguments_*`, `test_helperScript_*`, `test_helperToolPaths_*` |
| No rm+mv on the installed bundle | Yes | `test_helperScript_usesAtomicSwap_notRmMv` |
| **The helper end to end**: accept swaps in (no `.inflight`, no status); a codesign or spctl refusal leaves the installed bundle byte-identical, no `.inflight`, `refused <v>`, and with relaunch reopens the old app (stub `open` receives exactly the installed path) and without it opens nothing; a failed copy records `failed <v> ditto` over an older line and reopens; a malformed team stops it before codesign; directory names carrying `"`, `$(touch PWNED)` and a backtick install, reach `open` as one argument, and run nothing; a run that outlives 10 s is terminated and fails rather than hanging | Yes (real `/bin/bash`, `ditto`, `python3`; stub `codesign`/`spctl`/`open` under `TestTemp.root`; an exited pid; skipped without python3) | `UpdateSwapHelperEndToEndTests` |
| Python swap source is flush-left | Yes | `test_pyAtomicSwapSource_noLeadingSpacesOnTopLevelLines` |
| `atomicSwap` same-volume: destination never absent, content swapped | Yes (temp dirs) | `test_atomicSwap_sameVolume_*` |
| `atomicSwap` missing staged path → `.sourceNotFound` | Yes | `test_atomicSwap_throwsSourceNotFound_*` |
| `renamex_np` across volumes is refused by the kernel (`.crossVolume`) | Yes (another mounted volume; skipped if none) | `test_atomicSwap_crossVolume_kernelRejectsRenamexNp` |
| Download retry classifier, size cap, extension from the asset name | Yes (pure) | `UpdateDownloadTests` |
| Download delegate path: completes into place / progress never decreases and ends at 1.0 / refused past the cap leaves nothing | Yes (`file://` source under `TestTemp.root`, no network) | `UpdateDownloadTests.test_a*` |
| An asset declaring more than the cap is never downloaded | Yes (injected download closure) | `UpdateCheckerTests.test_anAsset*Cap*` |
| Only this repo's release URL is trusted; an untrusted one is never downloaded | Yes (pure table; injected download closure) | `GitHubReleasesAPITests.test_onlyThisRepos*`; `UpdateCheckerTests.test_anUntrustedAssetURL*` |
| Redirect policy (https only, any host) | Pure decision only; the delegate's redirect is not exercised offline | `UpdateDownloadTests.test_aRedirectIsFollowedOnlyToHttps` |
| Zip totals parse; each size/space refusal arm; a real tiny zip is read by `zipinfo`; a zip with no room is refused before unpacking and deleted | Yes (pure + injected free space + real `ditto -c -k` under `TestTemp.root`) | `UpdateInstallerTests.test_*Zipinfo*`, `test_extractionDecision_*`, `test_archiveTotals*`, `test_aZipTooBig*` |
| A pending version is not re-downloaded or re-staged; a gone bundle is staged again | Yes (injected closures, a bundle folder under `TestTemp.root`) | `UpdateCheckerTests.test_aCheckForTheVersionAlreadyPending*`, `test_aPendingBundleThatIsGone*` |
| Refusal memory: one refusal still auto-stages; two keep the background poll idle while a manual check proceeds; a newer version or reaching it clears it | Yes (injected `refusalDefaults` suite) | `UpdateCheckerTests.test_oneRefusal*`, `test_twoRefusals*`, `test_aNewerVersionClears*`, `test_reachingTheRefusedVersion*` |
| Install-status line: both forms parse, garbage and non-`X.Y.Z` versions don't; both sentences; the file is removed even when garbage; `refused` deletes only that version's zip and stage folder, `failed` keeps them; the notice survives every later check result and is cleared only by Dismiss | Yes (pure + files under `TestTemp.root`; windowless) | `InstallStatusTests` |
| A refused zip is deleted with its stage folder | Yes (garbage / app-less zip under `TestTemp.root`, real `ditto`) | `UpdateInstallerTests.test_aZip*IsDeleted*` |
| The sweep: what it may return, the launch and post-stage runs | Yes (pure + a real directory) | `UpdateSweepTests` |
| Running-app Team ID (real signed build) | No: the ad-hoc test host returns nil; proven in the dry run | `test_runningAppTeamID_doesNotCrash` (smoke only) |
| **The detached helper surviving the app's exit (launchd adoption), real codesign/spctl on a real notarized build, relaunch** | **No** | The real-update smoke (Recipes) |

## Recipes

### Change the helper script or the swap (the real-update smoke)
The full install cycle (codesign + notarize + download + verify + swap + relaunch) is verified only by the real-update smoke; run it after any change to `helperScript` or `pyAtomicSwapSource` in `UpdateInstaller.swift`.
1. Make the change in `UpdateInstaller.swift`, and keep `atomicSwap(staged:installed:)` and `pyAtomicSwapSource` agreeing.
2. Extend `UpdateSwapHelperEndToEndTests` (stubbed `codesign`/`spctl`/`open`, real `ditto`/`python3`) and the string-inspection tests in `UpdateInstallerTests`.
3. Cut a throwaway `v0.0.x` tag (`docs/RELEASING.md`); CI builds, signs and notarizes it.
4. Install the throwaway on a real Mac in `/Applications`.
5. Trigger an update to a higher patch version.
6. "Restart & Update": the app quits, the new version appears, and there is no gap where `/Applications/Maugham.app` is missing (Activity Monitor / `ls -la`).
7. "Dismiss", then an ordinary quit: the pending-quit install fires.
8. Delete the throwaway tags after confirmation.

### Add a helper failure step
1. Add the case to `UpdateInstaller.HelperFailureStep` in `UpdateInstaller.swift` (its raw value is what the script writes), and the recording `if !` branch to `helperScript(tools:)`, ending in `reopen`.
2. `InstallStatus.parse` (`InstallStatus.swift`) reads it through `HelperFailureStep`'s raw values; `test_parse_everyStepTheHelperNamesIsReadable` (`InstallStatusTests`) covers every case. The `failed` sentence names no step (`test_theFailedSentenceNamesNoStep`).
3. Pin the branch in `UpdateSwapHelperEndToEndTests`.

### Move the macOS floor
1. Change every macOS floor in `project.yml` (`deploymentTarget.macOS`, both `MACOSX_DEPLOYMENT_TARGET`s and `LSMinimumSystemVersion`) to the same number; `TripwireGrepTests.test_everyMacOSFloorInProjectYmlIsTheSameNumber` refuses a mismatch.
2. Run `./gen.sh`; `release.yml` publishes the built plist's value as the marker.

## Pointers

- Spec: `docs/superpowers/specs/2026-06-01-mac-auto-update-design.md`. Its "Error handling" promise of an atomic rename is what `renamex_np(RENAME_SWAP)` now delivers; where the spec and this guide differ, this guide describes the code.
- Releases and signing: `docs/RELEASING.md`, `.github/workflows/release.yml` (the minimum-macOS marker, the stapled ticket, patch ≥ 90 pre-releases).
- The dry run is the integration test: a throwaway tag through the real pipeline (`docs/RELEASING.md`) is the only proof of signing, notarization and the swap.
- Tripwire 13 (`docs/tripwires.md`): the variant-dependent paths come from `BuildVariant`.
- Tests: `UpdateInstallerTests`, `UpdateSwapHelperEndToEndTests`, `UpdateCheckerTests`, `UpdateDownloadTests`, `InstallStatusTests`, `UpdateSweepTests`, `GitHubReleasesAPITests`, `MinimumSystemVersionTests`, `PendingUpdateRevealTests`.
- History, the incidents and the rejected alternatives: `docs/history/updates.md`.
