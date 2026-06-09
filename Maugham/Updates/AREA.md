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
- Strict `>` version comparison (`UpdateChecker.swift`) prevents downgrade.
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
| Install mode (writable → inPlace, not writable → finderFallback) | Yes (injected predicate) | `test_installMode_*` |
| Helper script shape (pid-wait, ditto, open presence) | Yes (string inspection) | `test_helperScript_*` |
| No rm+mv on installed bundle (brick-prevention assertion) | Yes | `test_helperScript_usesAtomicSwap_notRmMv` |
| Python swap source is flush-left (no IndentationError) | Yes | `test_pyAtomicSwapSource_noLeadingSpacesOnTopLevelLines` |
| `atomicSwap` same-volume: destination never absent, content swapped | Yes (temp dirs) | `test_atomicSwap_sameVolume_*` |
| `atomicSwap` missing staged path → `.sourceNotFound` | Yes | `test_atomicSwap_throwsSourceNotFound_*` |
| `atomicSwap` cross-volume → `.crossVolume` | Yes (RAM disk via hdiutil; skipped if unavailable) | `test_atomicSwap_throwsCrossVolume_*` |
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
| `UpdateInstaller.swift` | Verify logic, atomic swap (`atomicSwap`/`pyAtomicSwapSource`), helper script generation, Team ID extraction |
| `UpdateChecker.swift` | Background poll loop, download, stage-and-verify dispatch, `pendingQuitInstall` |
| `UpdateState.swift` | Enum of updater states (idle/checking/downloading/readyToInstall/installing/error/upToDate) |
| `GitHubReleasesAPI.swift` | GitHub Releases JSON decode; `zipAsset` preferred over `dmgAsset` |
| `UpdateBannerView.swift` | In-window toast ("Maugham X.Y.Z is ready") |
| `UpdateSheet.swift` | Sheet variant of the install UI |
| `UpdateMenuCommand.swift` | Menu bar entry (title derived from `UpdateState`) |
| `SemanticVersion.swift` | Comparable version parsing; `>` used for strict downgrade prevention |

---

## Spec reconciliation

`docs/superpowers/specs/2026-06-01-mac-auto-update-design.md` §"Error handling" says:
> "Swap fails mid-ditto → ditto to a temp sibling then **atomic rename**, so a partial
> copy never replaces a working app"

The spec promised an atomic rename, and the original implementation used `rm -rf` + `mv`
instead (not atomic, brick risk on crash). This is now correct: the swap uses
`renamex_np(RENAME_SWAP)`, which is the atomic primitive the spec intended. The spec
entry is superseded by this AREA.md description of what the code actually does.
