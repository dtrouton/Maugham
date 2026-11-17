# Updates — area guide

The Mac's in-place auto-updater: finding the latest Mac release on GitHub, downloading and size-checking it, staging and verifying the bundle, and the detached helper that re-verifies it and swaps it into place atomically after the app quits. Mac-only, and disabled for dev builds (`BuildVariant.updaterEnabled`). CLAUDE.md's area table names no rule of its own for this area; the one rule is this guide's: **only the helper's install-time check decides what is installed, and the install location is never absent.** The history is in `docs/history/updates.md`.

## Map

Every file in `Maugham/Updates/` appears once.

- `UpdateInstaller.swift` — stage-and-verify (`stageAndVerifySync`, `stageAndVerifyUnchecked`), the verify logic, the zip-size gate (`archiveTotals`, `parseZipinfoTotals`, `extractionDecision`), `discardRefusedArchive`, `installMode`, the swap tool (`swapToolURL`, `isRunnableTool`), `volumeSupportsSwapRenaming` and `NoSwapVolumeMemory`, the helper (`helperScript(tools:)`, `helperArguments`, `HelperTools`, `HelperFailureStep`, `launchSwapHelper`), `runningAppTeamID()`, and `PendingUpdateReveal` (the Finder reveal deferred to next launch when a quit-time helper could not be launched).
- `UpdateChecker.swift` — the background schedule (`UpdateSchedule`: due on the wall clock, 6 h since the last completed check, not within 15 min of an attempt; triggers are launch, a 30-min tick, wake and activation; times persist in `refusalDefaults`), download into place (a `.download` temp, then moved to `Maugham-<ver>.<ext>`; a complete file already there is reused), the trusted-URL check and the pre-download size refusal, stage-and-verify dispatch, `pendingQuitInstall`, `reportInstallStatus(in:)`, `installNotice`, `sweepAfterStage`, and `InstallRefusalMemory` (the two-refusal background guard).
- `UpdateDownload.swift` — the download itself: a `URLSessionDownloadTask` on its own session (delegate `UpdateDownloadSession`, progress from `didWriteData`), one retry, the cap, the redirect policy (`followsRedirect`), the extension taken from the asset's name.
- `UpdateLimits.swift` — the size ceilings, `UpdateLimits.standard`: `maxDownloadBytes` 512 MB, `maxUncompressedBytes` 1 GB, `maxFiles` 20 000.
- `UpdateState.swift` — the updater's states: idle, checking, downloading, readyToInstall, installing, error, upToDate, newerBuildNeedsNewerSystem.
- `InstallStatus.swift` — the helper's `install-status` line: `parse`, `consume`, the notice's sentence (`sentence(waitsForManualCheck:)`).
- `UpdateSweep.swift` — deletes the updater's own old downloads (`staleUpdateArtifacts(in:keeping:runningVersion:)`, `sweep`).
- `GitHubReleasesAPI.swift` — the Releases JSON decode, `fetchLatestRelease`, `latestMacRelease`, `zipAsset` preferred over `dmgAsset`, `owner`/`repo`, `isTrustedAssetURL`.
- `MinimumSystemVersion.swift` — the build's minimum macOS against this Mac's: the release-body marker's wire format, `parse`, and the stripper that keeps it out of the notes.
- `SemanticVersion.swift` — comparable version parsing; strict `>` is the downgrade guard.
- `UpdateBannerView.swift` — the in-window toast ("Maugham X.Y.Z is ready", or the last install's notice through its pure `notice(for:)`).
- `UpdateSheet.swift` — the Check for Updates… sheet; it checks on appear only when asked (`checksOnAppear`), so a restored window fetches nothing and offers **Check Now**.
- `UpdateCheckRequest.swift` — the one-shot flag the menu item sets before `openWindow`.
- `UpdateMenuCommand.swift` — the menu bar entry; its title derives from `UpdateState`.

Outside the folder: `maugham-swap/main.swift` (repo root) — the compiled swap tool, `maugham-swap <absolute-pathA> <absolute-pathB>`, one `renamex_np(RENAME_SWAP)` call. Exit 0 swapped, 64 usage, 1 failed (`strerror` on stderr), 3 the volume cannot swap (`ENOTSUP` only: `EINVAL` is also path-shaped, and 3 is remembered for good); nothing is swapped on a non-zero exit. Embedded at `Contents/Helpers/maugham-swap` in every configuration (`project.yml`); `release.yml` re-signs it inside-out and `verify-mac-signing.sh app` holds it, with `maugham-mcp`, to the team, the hardened runtime and no `get-task-allow` (`EXPECT_NESTED`).

## Rules

### The verification chain
Every update is checked **twice**: when it is staged (in-app, `stageAndVerifySync`), and again by the detached helper **at install time**, on the `.inflight` copy (the exact bytes the swap moves) after the app has exited. Only the second check decides what is installed.

| When | Step | What | Why |
|---|---|---|---|
| Staging | `codesign --verify --deep --strict` | Valid Developer ID signature throughout the bundle | Catches tampered or unsigned bundles |
| Staging | `spctl -a -t exec` | Apple notarization present | Catches sideloaded or un-notarized builds |
| Staging | Team ID == running app's Team ID | The staged bundle is from our team | A validly signed bundle from the wrong team must not replace the app |
| Staging | `CFBundleIdentifier` == running app's bundle identifier (`decideIdentity`) | The staged bundle is this app | The same certificate signs other apps: one renamed `Maugham.app` passes the team check |
| Staging | `CFBundleShortVersionString` == the version being installed (`decideIdentity`) | The staged bundle is the version offered | An older signed Maugham inside a newer tag passes every other check |
| Install (helper, on `.inflight`) | `codesign --verify --deep --strict --test-requirement="=identifier \"<bundle id>\" and anchor apple generic and certificate leaf[subject.OU] = \"<team>\""` | Validity, this app's identifier and our team in one call (exit 3 when unsatisfied) | The staged copy waited hours or days in a user-writable folder |
| Install (helper, on `.inflight`) | `spctl -a -t exec` | Notarization, again | As above |
| Install (helper, on `.inflight`) | `PlistBuddy` reads `CFBundleShortVersionString`, exactly `$VERSION` | The version offered | An older signed Maugham put in its place passes the requirement: no silent downgrade |

- **The bundle identifier is the running app's own, read at runtime** (`Bundle.main.bundleIdentifier`), never a literal: dev and stable differ. A missing plist, another identifier or another version is `InstallError.verifyFailed`, discarding the archive. The version is the tag without its `v`, exactly what `release.yml`'s "Sync version into project.yml" writes, dry runs included. Without a well-formed identifier (`isWellFormedBundleIdentifier`) `launchSwapHelper` launches nothing.
- **The Team ID is read from the running app's own signature at runtime** (`UpdateInstaller.runningAppTeamID()` via `SecCodeCopySelf`), never hardcoded: any signed release verifies a future one without a code edit, and a team change needs the installed app and the update to carry the new ID at once. With no team (ad-hoc, unsigned, the test host) or a malformed one, `launchSwapHelper` launches nothing and the caller takes the Finder fallback.
- **The helper re-checks the staged bundle at install time**: the staged copy sits in `~/Library/Application Support/<variant>/Updates/staged-<ver>/`, a plain user-owned folder, until "Restart & Update" or the next quit, and anything that could write that folder could substitute it. After the app exits the helper copies it to `<installed>.inflight` (same volume as the install location), runs the codesign requirement check and `spctl` on that copy, and only then swaps.
- **On a refusal the installed app is untouched**: the helper removes `.inflight`, writes `refused <version>` to `Updates/install-status` and exits; after "Restart & Update" (`RELAUNCH=1`) it reopens the OLD app, so the writer is never left with no Maugham running.
- **No second verifier in-process**: in `willTerminate`, `spctl` could hang the quit on the network.
- **Offline is not a refusal.** `release.yml` staples the notarization ticket (`xcrun stapler staple`, then gates on `spctl -a -t exec` before packaging), so `spctl` assesses the staged copy from its own ticket with no network. A refusal therefore means the bytes failed.
- **The residual exposure is stated, not fixed**: a same-user race of a few milliseconds between the verify and `renamex_np`. `installMode` requires the install folder to be writable by this user, and anything that can win that race can already write the install folder.
- **The helper takes its paths as arguments, never interpolated.** `helperScript(tools:)` is fixed text; the pid, both bundle paths, the team, the relaunch flag, the version, the Updates folder, the swap tool's path and the running app's bundle identifier arrive as `$1`…`$9` (`helperArguments`), every use double-quoted. The script checks there are nine and re-validates each (pid digits, team ten of `A-Z0-9`, relaunch `0`/`1`, version digits and dots, identifier `A-Za-z0-9.-`, paths absolute, installed ending `.app`, the tool a regular executable file) and exits 2 before touching anything if one is wrong, so a path containing `"`, `$(…)` or a backtick is data.
- **The only interpolated values are constants**: `HelperTools`' tool paths (`codesign`, `spctl`, `ditto`, `open`), which a precondition restricts to `^[A-Za-z0-9/._-]+$` and tests replace with stubs (`test_helperToolPaths_arePlainAbsolutePaths`), and the status words and `swapUnsupportedExitCode`. The swap tool is not a `HelperTools` entry: its path names the install folder, so it is an argument.
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
- **The totals are what the archive DECLARES**; a crafted archive can lie, and only a byte-counting extractor would close that.
- **A refused archive is not reused.** Every `InstallError` from staging (`unzipFailed`, `verifyFailed`, `archiveTooLarge`, `archiveUnreadable`) goes through `UpdateInstaller.discardRefusedArchive`, which deletes the stage folder AND the downloaded `Maugham-<ver>.zip`: the checker reuses a zip already at that path, so a bad one left there would be re-staged and re-refused on every later check.

### The atomic swap
- **The swap is `renamex_np(src, dst, RENAME_SWAP)`, never `rm` then `mv`**: a crash between `rm -rf "<installed>"` and `mv` left `/Applications/Maugham.app` missing until a manual reinstall. `RENAME_SWAP` exchanges the two directory entries atomically; both paths exist throughout (`test_helperScript_usesAtomicSwap_notRmMv`).
- **`.inflight` is always a sibling of the installed bundle**, so it is on the same volume by construction, which `renamex_np` requires. After the swap it holds the old bundle; if removing it fails, the stale `.inflight` is harmless and is cleaned on the next update.
- **The compiled tool is the one swap**: `maugham-swap` makes the single `renamex_np(RENAME_SWAP)` call; there is no Swift or script mirror. The helper runs the CURRENTLY INSTALLED app's own tool (`swapToolURL()` reads `Bundle.main`), never the incoming bundle's, so the verified old build decides how the new one goes in. Why it replaced the earlier interpreted swap: `docs/history/updates.md`.
- **Atomic or Finder, nothing in between** (ruling): there is no non-atomic `.bak` fallback. `installMode` answers Finder unless the install volume reports `volumeSupportsSwapRenaming` (unknown is no); the tool's exit 3 is the backstop, recorded as `failed <v> swap-unsupported`, after which that volume is remembered (`NoSwapVolumeMemory`, by volume UUID, never forgotten) and takes Finder. On exit 3 the helper removes `.inflight`, a mere copy, so no stray bundle is left beside the app.
- **Not `FileManager.replaceItemAt`**: it parks the destination at a backup path first.

| Crash point | State | Recovery |
|---|---|---|
| During `ditto` (staging) | `.inflight` is partial; installed is intact | The installed app runs; `.inflight` is cleaned on the next update |
| During `renamex_np` | Atomic: cannot crash mid-swap | N/A |
| After the swap, during `.inflight` cleanup | Stale `.inflight`; the new app is in place | Harmless; cleaned on the next update |

### The detached helper
The app cannot replace its own running bundle, so a detached helper does it.

1. **Swift side** (`launchSwapHelper(stagedBundle:version:updatesDirectory:relaunch:…)`) refuses (returns false → Finder fallback) unless `installMode` answers in place ("Worst case" below), the running app has a well-formed team ID and bundle identifier, and the version is `X.Y.Z`. It writes the fixed `helperScript()` to `$TMPDIR/maugham-update-<uuid>.sh` and launches it detached (`/bin/bash script.sh <pid> <staged> <installed> <team> <1|0> <version> <Updates dir> <swap tool> <bundle id>`).
2. **The app terminates** via `MaughamAppDelegate.requestQuit()`, never `NSApp.terminate` (0.46.0 hung). The child reparents to launchd, which adopts orphans.
3. **The bash helper** runs under `set -e`, and every failure path below is an explicit `if !` so it records. Every one after the argument guard ends in `reopen`: with `$RELAUNCH` `1` it runs `open "$INSTALLED"` (the untouched old app) before `exit 1`, `|| true` so it cannot trip `set -e`. In order:
   - validates its nine arguments, the swap tool included, before the wait (exit 2; nothing touched, nothing recorded; `test_helperScript_swapToolIsValidatedBeforeAnyStep`);
   - takes `install-lock-<pid>` or leaves (two helpers undo each other); polls `kill -0 "$PID"`;
   - `rm -rf .inflight && ditto staged .inflight`; on failure it removes `.inflight` and records `failed <v> ditto`;
   - the codesign requirement check, `spctl -a -t exec` and the version read back, all on `.inflight`; on failure it removes `.inflight`, records `refused <v>`, and exits before the swap;
   - the swap tool, then removes `.inflight` (the old bundle); exit 3 removes `.inflight` and records `failed <v> swap-unsupported`; any other failure records `failed <v> swap` and keeps `.inflight`;
   - `reopen`: with `$RELAUNCH` `1`, `open "$INSTALLED"`, now the new app.
- **Under Xcode/lldb the swap does not apply**: the debugger kills the process group, helper included.

### The install status and the next launch
- **`Updates/install-status` holds ONE line, overwritten** (written to `install-status.tmp`, then `mv`): `refused <version>` or `failed <version> <step>`, the step one of `UpdateInstaller.HelperFailureStep` (`ditto`, `swap`, `swap-unsupported`). Success writes nothing. A step an older installed build's helper wrote and this build no longer names (`legacyFailureSteps`) still parses, as a plain failure.
- **The next launch reports it before the poll starts**: the Welcome scene's `.task` calls `UpdateChecker.reportInstallStatus(in:)` (stable variant only, never in a test host).
- **`InstallStatus.consume` removes the file unconditionally**, a line that does not parse included: a later successful install writes nothing, and an old line would otherwise outlive it.
- **`InstallStatus.parse` accepts exactly the two forms**, an `X.Y.Z` version and a `HelperFailureStep` raw value (or a `legacyFailureSteps` one), and nothing else.
- **The parsed notice is held as `UpdateChecker.installNotice`, apart from `state`**, so no check result replaces it: the sentence must actually be seen (`test_theNoticeSurvivesEveryLaterCheckResult`). Dismiss (`dismissInstallNotice`) clears it. It is not persisted; one launch is enough.
- **`UpdateBannerView` draws the notice ahead of any "ready" row**, and the sheet draws it above whatever the check shows.
- **`refused` says** *"The update to Maugham <v> didn't pass its safety check and wasn't installed. Maugham will download it again."* (`test_theRefusedSentenceIsDenversRulingVerbatim`), **and deletes that version's `Maugham-<v>.zip` and `staged-<v>` through `discardRefusedArchive`**, or the sentence would be false.
- **`failed` says** *"The update to Maugham <v> couldn't be installed. Maugham will try again."* **and KEEPS the staged files**: every step names this Mac at that moment, not the bytes, so the next check re-stages without a download. `swap-unsupported` says instead that Maugham will show the update in Finder, which is true: the volume is remembered.
- **A line naming a version not newer than the running app is stale** (that update arrived) and says nothing.
- **The banner mounts in project windows only**, and the Welcome window has no update surface, so a writer who never opens a project sees the notice only in Check for Updates…. Stated limit.
- **A version refused twice is not re-staged by the background poll.** `reportInstallStatus` increments `InstallRefusalMemory` (key `maugham.updateInstallRefusals`: a version and a count, in `refusalDefaults`) on every `refused` line. At `backgroundLimit` (2) the poll stays idle for that version: no download, stage or banner (each retry is a full re-download refused again).
- **A manual Check for Updates still downloads and stages a twice-refused version.** The memory is forgotten when a check is offered any other version, or when the running app has reached it. A `failed` line is not counted.
- **From the second refusal on, the notice says so**: *"The update to Maugham <v> didn't pass its safety check again and wasn't installed. Choose Check for Updates… to try once more."* (`UpdateChecker.installNoticeWaitsForManualCheck` → `InstallStatus.sentence(waitsForManualCheck:)`).

### Old updates are deleted
- **`UpdateSweep` deletes only the updater's own artifacts.** The pure `staleUpdateArtifacts(in:keeping:runningVersion:)` can only ever return `Maugham-<semver>.(zip|dmg)`, the same with `.download`, and `staged-<semver>`: never `install-status`, never anything else (`test_foreignAndUnmatchedNamesAreNeverReturned`).
- **Versions compare with `SemanticVersion`** (pre-releases like 0.41.90 exist). With a `keeping` version every other matching entry goes; with none, entries at or below the running version go and a newer one is kept (the next check may reuse it).
- **The sweep runs twice.** At launch: in the Welcome `.task`, after `reportInstallStatus` off the main thread, skipped in test hosts and dev builds, `.download` files included. After a successful stage: `UpdateChecker.sweepAfterStage` (set only by the app at launch), keeping only the new version and never touching `.download` files, since one may be mid-write.

### The unwritable-`/Applications` fallback
- **Worst case is the status quo, never worse.** Before offering "Restart & Update", `installMode(installedBundlePath:…)` checks `FileManager.default.isWritableFile(atPath:)` on the installed bundle AND on its folder (the helper creates `.inflight` there), that the running app's swap tool is an executable regular file, and that the folder's volume can swap. If any is not so it returns `.finderFallback`, and the caller reveals the download in Finder. Every input is an injectable predicate.
- **A quit-time helper that cannot launch defers its reveal to next launch** (`PendingUpdateReveal.markPending`, consumed once): the app is already tearing down, unlike `installNow`'s live fallback in `MaughamApp.swift`'s `performInstall`.

### The macOS floor
- **The build floors `LSMinimumSystemVersion` at `MACOSX_DEPLOYMENT_TARGET` and does not cap it** (measured, table in `docs/history/updates.md`), and the minimum-macOS marker is read off the built plist: a stale-LOW declaration cannot publish a lie, a stale-HIGH one would withhold updates. So every macOS floor in `project.yml` is the same number (`TripwireGrepTests.test_everyMacOSFloorInProjectYmlIsTheSameNumber`, control `test_theMacOSFloorCensusFiresOnAPlantedOffender`).

### What is and is not unit-testable

| Aspect | Where |
|---|---|
| Verify and identity decisions (team, identifier, version, missing plist, dry-run version); staging refusing through `verifyFailed` and discarding the archive (a zipped fake bundle, injected verdict) | `UpdateInstallerTests.test_accepts_*`, `test_rejects_*`, `test_decideIdentity_*`, `test_staging*` |
| Minimum-macOS block (injected `systemVersion`) | `MinimumSystemVersionTests`; `UpdateCheckerTests.test_aBuild*System*` |
| Install mode (injected predicates); the real volume probe; a remembered no-swap volume | `test_installMode_*`, `test_theVolumeProbe*`, `InstallStatusTests.test_aVolumeThatCannotSwap_isRemembered*` |
| The BUILT swap tool the test host embeds: swaps, usage 64, missing path 1 (a missing tool fails, never skips) | `SwapToolTests` |
| The tool's exit 3 on a real no-swap volume: by hand only (a FAT disk image: `ENOTSUP` → 3, probe false); the helper's handling of 3 via a stub | `UpdateSwapHelperEndToEndTests.test_aVolumeThatCannotSwap*` |
| No helper without a well-formed team, identifier or version, or a swap tool | `PendingUpdateRevealTests.test_launchSwapHelper_returnsFalse_*` |
| Script shape (string inspection): argv order, fixed text, re-check before the swap, tool validated first, exit 3 its own step, no rm+mv | `test_helperArguments_*`, `test_helperScript_*`, `test_helperToolPaths_*` |
| **The helper end to end** (real `bash`, `ditto`, built `maugham-swap`; stub `codesign`/`spctl`/`open`; an exited pid): swap in; refusals leave the app byte-identical and reopen it; `ditto`, `swap`, `swap-unsupported` recorded; bad arguments stop it with exit 2; an identifier-checking stub refuses another app; hostile paths are data; a stuck run is killed, its process tree in the failure | `UpdateSwapHelperEndToEndTests` |
| A restored Check for Updates… window does not check (pure, windowless) | `UpdateCheckRequestTests` |
| The schedule: when due, which states a background check skips, wake and activation | `UpdateScheduleTests` |
| Download: retry, cap, extension, delegate path (`file://`), redirect decision (not the delegate's redirect) | `UpdateDownloadTests` |
| Cap and trusted URL refused before a download; pending version not re-staged; refusal memory | `UpdateCheckerTests`, `GitHubReleasesAPITests` |
| Zip totals and each size/space arm; refused zips deleted with their stage folder | `UpdateInstallerTests` |
| Install-status line, sentences, consume, the notice's lifetime | `InstallStatusTests` |
| The sweep | `UpdateSweepTests` |
| **Not unit-testable**: the running app's real Team ID (the test host is ad hoc), launchd adopting the helper, real codesign/spctl on a notarized build, relaunch | The real-update smoke (Recipes) |

## Recipes

### Change the helper script or the swap (the real-update smoke)
The full install cycle (codesign + notarize + download + verify + swap + relaunch) is verified only by the real-update smoke; run it after any change to `helperScript` in `UpdateInstaller.swift` or to `maugham-swap/main.swift`.
1. Make the change in `UpdateInstaller.swift`.
2. Extend `UpdateSwapHelperEndToEndTests` (stubbed `codesign`/`spctl`/`open`, real `ditto` and `maugham-swap`) and the string-inspection tests in `UpdateInstallerTests`.
3. Cut a throwaway `v0.0.x` tag (`docs/RELEASING.md`); CI builds, signs and notarizes it.
4. Install the throwaway on a real Mac in `/Applications`.
5. Trigger an update to a higher patch version.
6. "Restart & Update": the app quits, the new version appears, and there is no gap where `/Applications/Maugham.app` is missing (Activity Monitor / `ls -la`).
7. "Dismiss", then an ordinary quit: the pending-quit install fires.
8. Delete the throwaway tags after confirmation.

### Add a helper failure step
1. Add the case to `UpdateInstaller.HelperFailureStep` in `UpdateInstaller.swift` (its raw value is what the script writes), and the recording `if !` branch to `helperScript(tools:)`, ending in `reopen`.
2. `InstallStatus.parse` (`InstallStatus.swift`) reads it through `HelperFailureStep`'s raw values; `test_parse_everyStepTheHelperNamesIsReadable` (`InstallStatusTests`) covers every case. The `failed` sentence names no step (`test_theFailedSentenceNamesNoStep`); give the step its own sentence only when "will try again" would be false (`swap-unsupported`). A retired step joins `legacyFailureSteps`.
3. Pin the branch in `UpdateSwapHelperEndToEndTests`.

### Move the macOS floor
1. Change every macOS floor in `project.yml` (`deploymentTarget.macOS`, every `MACOSX_DEPLOYMENT_TARGET` and `LSMinimumSystemVersion`) to the same number; `TripwireGrepTests.test_everyMacOSFloorInProjectYmlIsTheSameNumber` refuses a mismatch.
2. Run `./gen.sh`; `release.yml` publishes the built plist's value as the marker.

## Pointers

- Spec: `docs/superpowers/specs/2026-06-01-mac-auto-update-design.md`. Its "Error handling" promise of an atomic rename is what `renamex_np(RENAME_SWAP)` now delivers; where the spec and this guide differ, this guide describes the code.
- Releases and signing: `docs/RELEASING.md`, `.github/workflows/release.yml` (the minimum-macOS marker, the stapled ticket, patch ≥ 90 pre-releases).
- The dry run is the integration test: a throwaway tag through the real pipeline (`docs/RELEASING.md`) is the only proof of signing, notarization and the swap.
- Tripwire 13 (`docs/tripwires.md`, `TripwireGrepTests.test_noHardcodedIdentityStringsInMacSources`): the variant-dependent paths come from `BuildVariant`.
- Tests: `UpdateInstallerTests`, `UpdateSwapHelperEndToEndTests`, `UpdateCheckerTests`, `UpdateScheduleTests`, `UpdateDownloadTests`, `InstallStatusTests`, `UpdateSweepTests`, `GitHubReleasesAPITests`, `MinimumSystemVersionTests`, `PendingUpdateRevealTests`, `UpdateBannerIntegrationTests`, `UpdateProgressTests`, `UpdateSheetIntegrationTests`, `UpdateStateTests`.
- History, the incidents and the rejected alternatives: `docs/history/updates.md`.
