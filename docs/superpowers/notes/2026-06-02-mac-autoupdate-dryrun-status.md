# Mac auto-update dry-run — live status (2026-06-02)

Branch: `feat/mac-auto-update-in-place` (pushed, not merged). Plan Task 14.

## UPDATE 2026-06-03 00:10Z — CI HALF PROVEN ✅
- v0.5.90 submission eventually went **Accepted** (Apple queue backlog ~3hr, not a
  build problem). **Empty entitlements were sufficient — WhisperKit hardened-runtime
  risk did NOT materialize.** No entitlement keys needed.
- **v0.5.91 ran fully green** (run 26855224321): signed build → nested signing →
  **Notarize + staple ✅** (the hardened submit-then-poll survived; Apple turnaround
  fast this time) → packaged `.dmg` + `.zip` → published as **prerelease** (patch≥90
  safety confirmed: `gh release list` shows v0.5.1 still "Latest", v0.5.91 "Pre-release";
  `/releases/latest` = v0.5.1). Assets: Maugham-0.5.91.{dmg,zip}, both notarized+stapled.
- **Remaining = on-device only** (needs the user's Mac): Steps below.

## Where we are
- Tasks 1–13 done + reviewed; full Mac suite 1487 green.
- **v0.5.90 dry-run**: signing + inside-out nested signing (tectonic/mcp) ✅, notarytool
  **upload** ✅ (Apple got submission `4bc55fbe-bde8-44df-8aef-e3e1e6a33652`). CI step
  then **failed on a transient runner network drop** (`NSURLErrorNotConnectedToInternet
  -1009`) mid-`--wait` — NOT an Apple rejection. No release published; `/releases/latest`
  still v0.5.1 (prerelease safety + late-publish both held).
- **Workflow hardened** (commit `ccab0c0`): submit-then-poll, tolerates transient
  network errors, 30-min budget, auto-dumps `notarytool log` on Invalid/Rejected.
- **v0.5.91 notes staged** (commit `113359c`), branch pushed. Ready to re-cut.

## Verdict poll (the gating signal)
```
xcrun notarytool info 4bc55fbe-bde8-44df-8aef-e3e1e6a33652 \
  --key ~/Downloads/AuthKey_6W8L644953.p8 --key-id 6W8L644953 \
  --issuer 52fa03df-b969-4243-8cff-cac936ce0c78
```
- **Accepted** → build+signing proven. Re-cut v0.5.91 (below).
- **Invalid** → `notarytool log 4bc55fbe-… <same auth args>` → names the file/entitlement
  (WhisperKit hardened-runtime suspects: `com.apple.security.device.audio-input`,
  `com.apple.security.network.client`, possibly `cs.allow-jit`). Add to
  `Maugham/Maugham.entitlements`, then re-cut.

## Re-cut v0.5.91 (one push; notes already committed)
```
git tag -a v0.5.91 -m "Dry-run throwaway 0.5.91 (hardened notarize)"
git push origin v0.5.91
gh run watch $(gh run list --workflow=release.yml --limit 1 --json databaseId --jq '.[0].databaseId')
```
Publishes as **prerelease** (patch ≥ 90), invisible to stable auto-update.

## On-device gauntlet (after v0.5.91 publishes) — Task 14 Steps 4–7
1. **First launch**: download the `.dmg` from the v0.5.91 prerelease, install to
   /Applications, launch. ✅ = opens with NO right-click → Open.
2. **Transcription under hardened runtime**: record a voice capture (WhisperKit/Metal/ANE
   path). ✅ = transcribes, no entitlement crash. (If it crashes → add the entitlement,
   re-cut — debug build can't catch this.)
3. **In-place update round trip**: with v0.5.91 installed + running, cut v0.5.92
   (`git tag -a v0.5.92 …; git push origin v0.5.92`). In-app: Check for Updates →
   "Restart & Update". ✅ = app quits, swaps, relaunches as 0.5.92.
4. **Install-on-quit**: trigger again but click **Dismiss**, then ⌘Q normally; reopen.
   ✅ = now 0.5.92 (silent swap on quit via pendingQuitInstall).
5. **Relaunch-race watch**: if the helper swaps before the app fully exits, switch the
   detach in `UpdateInstaller.launchSwapHelper` (Process `/bin/bash`) toward a `nohup`/
   `setsid` form — Task 8 flagged this as the one mechanism fork. (Note: in-place swap
   does NOT apply under an Xcode/lldb launch — debugger kills the child; test the
   installed copy, not a debug run.)

## Cleanup after gauntlet passes
```
for v in 0.5.90 0.5.91 0.5.92; do
  gh release delete "v$v" --yes 2>/dev/null
  git push --delete origin "v$v" 2>/dev/null
  git tag -d "v$v" 2>/dev/null
done
git rm docs/release-notes/v0.5.9*.md
git commit -m "chore: remove dry-run release notes"
```
Then: manual smoke (CLAUDE.md), merge branch to main, cut the REAL tag (next stable,
e.g. v0.6.0) with proper release notes.
```
