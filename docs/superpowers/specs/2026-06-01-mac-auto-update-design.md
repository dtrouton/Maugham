# Mac Auto-Update: Signing, Notarization & In-Place Install

**Date:** 2026-06-01
**Status:** Design — approved for planning
**Supersedes the relevant parts of:** `2026-05-22-production-release-design.md` §3.2 (Tier 1.5 updater) and §"signing stays Path B"

## Problem

The current macOS updater (`Maugham/Updates/`, 7 files) was built before an Apple
Developer account existed. It works around the absence of a signing identity with
three stacked compromises:

1. **No real install.** Clicking "Install" calls
   `NSWorkspace.shared.activateFileViewerSelecting([dmg])` — it just reveals the
   downloaded `.dmg` in Finder. The user manually mounts it, drags `Maugham.app`
   onto `/Applications`, confirms the overwrite, and ejects.
2. **No notarization.** `CODE_SIGN_IDENTITY: "-"`, `ENABLE_HARDENED_RUNTIME: NO`.
   Every downloaded build is quarantined by Gatekeeper, so first launch requires a
   right-click → Open ("unidentified developer" dance).
3. **No integrity check.** The `.dmg` is downloaded over HTTPS and trusted blindly.
   CLAUDE.md flags "SHA256 dmg verification" as an outstanding concern; in fact a
   hash fetched over the same channel as the file proves nothing against tampering.

Now that a Developer ID is available, we can remove all three. This is the
"Phase C + Phase B" work from the brainstorm: **notarize (C) and build a real
in-place installer (B), shipped together as one release.**

## Non-goals

- **Sparkle.** Considered and deferred. Maugham is non-sandboxed, single-admin-user,
  and Claude maintains the updater, so the usual "let a library own the dangerous
  install code" argument is muted. We keep the existing injected, tested architecture
  and add the one new unit (`UpdateInstaller`). Sparkle remains the named fallback
  **only if** the detached-helper install proves unreliable in dry-run.
- **Privileged/admin-auth install.** If `/Applications` isn't writable we fall back
  to today's Finder-reveal behavior. No `SMJobBless`/Authorization Services surface.
- **Delta updates.** Full-bundle replacement each time. Bundle is small.
- **Migrating the dev variant.** Dev stays ad-hoc-signed, updater disabled
  (`BuildVariant.updaterEnabled == (self == .stable)` already gates this).

## Success criteria

1. A user on a stable build downloads an update, clicks "Restart & Update," and the
   app quits, swaps itself in `/Applications`, and relaunches — **no Finder, no
   drag, no right-click → Open.**
2. A user who dismisses the toast gets the staged update applied **silently on their
   next ordinary quit** (no relaunch; new version appears next time they open the app).
3. The downloaded bundle is **verified** (Developer-ID signature, our Team ID,
   Apple notarization) before it is ever swapped in. A tampered or wrong-team
   bundle is rejected and the install aborts.
4. The shipped `.app` is **notarized + stapled**, so first launch from the `.dmg`
   (website download) is Gatekeeper-clean — no right-click → Open.
5. If `/Applications` is not writable, the app falls back to revealing the `.dmg`
   in Finder (current behavior). **Worst case == status quo, never worse.**
6. Dev builds are unaffected (updater still disabled, still ad-hoc-signed).

---

## Architecture

The change has three layers. Layer 1 (signing/notarization) is the prerequisite the
account unlocks; layers 2–3 are the in-app installer that becomes possible once
builds are signed.

### Layer 1 — Signing & notarization (the foundation)

**`project.yml` — Release config only; Debug/dev stays ad-hoc.**

| Setting | Debug (dev) | Release (stable) |
|---|---|---|
| `CODE_SIGN_IDENTITY` | `"-"` (unchanged) | `"Developer ID Application"` |
| `CODE_SIGN_STYLE` | `Automatic` | `Manual` |
| `ENABLE_HARDENED_RUNTIME` | `NO` | `YES` |
| `DEVELOPMENT_TEAM` | — | `$(DEVELOPMENT_TEAM)` (CI-injected) |
| `CODE_SIGN_ENTITLEMENTS` | — | `Maugham/Maugham.entitlements` |

`ENABLE_HARDENED_RUNTIME: NO` currently lives in `settings.base` (shared). It must
move to the **Debug config only**, with Release setting `YES`, so the dev build is
unaffected.

**New file: `Maugham/Maugham.entitlements`.** Hardened runtime requires an
entitlements file. Start minimal and add only what dry-run proves is needed:

- WhisperKit uses Metal / the ANE. Hardened runtime's default JIT/executable-memory
  restrictions *may* require `com.apple.security.cs.allow-jit` or
  `...allow-unsigned-executable-memory`. **We do NOT add these speculatively** — we
  ship the minimal entitlements, run a dry-run, and add an entitlement only if
  notarization or on-device transcription fails. (This is the #1 dry-run risk;
  see "Dry-run gauntlet.")
- `com.apple.security.cs.disable-library-validation` is **deliberately omitted**
  unless WhisperKit's dynamically-loaded frameworks force it — it weakens the very
  guarantee the verify step relies on.

**Inside-out signing.** Embedded code must be signed with `--options runtime` before
the outer app:
- the bundled `maugham-mcp` tool (`Contents/MacOS/` via the `copy` dependency, currently `codeSign: false`),
- the bundled `tectonic` binary (`Resources/bin/tectonic`),
- any WhisperKit `.framework`/`.dylib` payloads.
`codesign --deep` is unreliable for this; the CI step signs nested code explicitly
then the app last.

**CI (`.github/workflows/release.yml`) — new steps, after Build, before Package:**

1. **Import Developer ID cert** — `apple-actions/import-codesign-certs@v7` with new
   secrets `DEVELOPER_ID_CERT` (p12 base64) + `DEVELOPER_ID_CERT_PASSWORD`.
   (The phone workflow already uses this action for its iOS Distribution cert; this
   is the Mac analogue with a *different* cert — see SETUP.md.)
2. **Sign** nested code inside-out, then `Maugham.app` with hardened runtime +
   entitlements + the Developer ID identity.
3. **Notarize** — zip the app, `xcrun notarytool submit --wait` authenticating with
   the **existing** ASC API key secrets (`APP_STORE_CONNECT_API_KEY` / `_KEY_ID` /
   `_ISSUER_ID`) the phone pipeline already defines. notarytool accepts the same
   key family as the phone's `-exportArchive` upload.
4. **Staple** — `xcrun stapler staple Maugham.app`.
5. **Verify in CI** — `spctl -a -t exec -vv Maugham.app` and
   `codesign --verify --deep --strict` as a build gate (fail the release if either fails).
6. **Package both artifacts** (see Layer 2).

### Layer 2 — Release artifacts: ship a ZIP next to the DMG

The `.dmg` is a fine *first-install / website* artifact but a poor *auto-update*
payload (mount → drag → eject is exactly what we're eliminating). So CI now produces
**two** assets from the same notarized+stapled `Maugham.app`:

- `Maugham-<version>.dmg` — unchanged; manual download / first install.
- `Maugham-<version>.zip` — `ditto -c -k --keepParent Maugham.app` of the stapled
  bundle; this is what the in-app updater downloads. (`ditto` preserves the bundle
  metadata; the staple ticket travels inside the bundle so the unzipped copy is
  Gatekeeper-clean offline.)

`GitHubRelease` gains a `zipAsset` accessor (sibling to `dmgAsset`). The updater
prefers `zipAsset`; if absent it falls back to `dmgAsset` + Finder reveal (so a
hypothetical zip-less release degrades to current behavior).

### Layer 3 — In-app install + verify (the new core)

**One verified staged bundle, two triggers to apply it.**

```
background poll (60s after launch, then 24h)  ── unchanged cadence
        │  newer stable release found
        ▼
download <version>.zip → staging dir            (existing Updates/ dir)
        │
        ▼
unzip → VERIFY staged Maugham.app:
   • codesign --verify --deep --strict
   • Team ID == our Team ID            (anti-substitution)
   • spctl -a -t exec                  (notarized/staple present)
   • remove com.apple.quarantine xattr
        │  verify OK
        ▼
state = .readyToInstall(stagedBundleURL, version, notes)
        │
        ▼
subtle in-window toast: "Maugham X.Y.Z is ready"
        ├── [Restart & Update] ──► flush autosave → quit → helper swaps → RELAUNCH
        └── [Dismiss] ───────────► stays staged; on next ordinary quit,
                                    helper swaps (NO relaunch)
```

**Why a detached shell-script helper.** An app cannot overwrite its own running
bundle. The proven shape (the thing Sparkle's helper does, minus the privilege
machinery we don't need) is:

1. App writes a small shell script to a temp path.
2. App launches it **detached** — `Process` in its own session, so it survives the
   parent's exit (`posix_spawn` with `setsid`, or `nohup`-style detachment).
3. App terminates.
4. Script: poll until our PID is gone → `ditto "<staged>" "/Applications/Maugham.app"`
   (overwrite in place) → if relaunch requested, `open "/Applications/Maugham.app"`.

We use a plain script rather than an embedded XPC/privileged helper because Maugham
is **non-sandboxed and runs as the installing admin user**, so `ditto` over
`/Applications` needs no elevation. This keeps the notarization surface to one app
(no embedded helper tool to sign/notarize separately).

**Writability pre-check + fallback.** Before offering "Restart & Update," the
installer checks `/Applications/Maugham.app` is writable by the current user. If not
(non-admin, unusual perms), it **falls back to the current behavior**: reveal the
`.dmg` in Finder. Worst case is exactly status quo.

**Install-on-quit.** The app already posts `.maughamAppWillTerminate` from
`NSApplication.willTerminateNotification` (see `MaughamApp.init`). The installer
subscribes: if a verified update is staged and the user hasn't explicitly chosen
"Restart & Update," fire the swap helper here (no relaunch). At `willTerminate` the
editor is already idle and autosaved, which sidesteps the "replace bundle mid-teardown"
race entirely.

**Restart & Update flush.** When the user clicks "Restart & Update" with changes
still in the 750ms autosave debounce, we must `flushPendingSave()` on the open
`DocumentStore`(s) **before** quitting — same close-before-FS-surgery discipline as
CLAUDE.md tripwire #14. (Quit-time install already gets this via the existing
terminate flush.)

---

## Components

| Unit | Responsibility | Depends on | Testable seam |
|---|---|---|---|
| **`UpdateInstaller.swift`** (new) | unzip; 3-way verify; writability check; helper-script generation; detached launch; Finder fallback decision | `BuildVariant`, FileManager, `Process` | inject `verify` + `launchHelper` closures so tests exercise logic without quitting/swapping |
| `UpdateState.swift` | add `.readyToInstall(bundleURL:version:notes:)` (replaces `.ready` carrying a dmgURL); optionally `.installing` | — | enum, pure |
| `UpdateChecker.swift` | download `.zip` (was `.dmg`); on download complete, call `UpdateInstaller.stageAndVerify`; publish `.readyToInstall` | `UpdateInstaller`, `GitHubReleasesAPI` | already injected (`fetchLatest`, `downloadDMG` → rename `downloadAsset`) |
| `GitHubReleasesAPI.swift` | add `zipAsset` accessor | — | pure |
| `UpdateBannerView.swift` → toast | subtler "ready" toast; buttons "Restart & Update" / "Dismiss"; per-version dismiss persists (existing `@AppStorage`) | `UpdateInstaller` | `shouldShow` stays pure |
| `UpdateSheet.swift` | "Install" button calls `installer.install(relaunch: true)` instead of `activateFileViewerSelecting` | `UpdateInstaller` | static `title`/state fns stay |
| `MaughamApp.swift` | wire installer's quit-time hook to existing `.maughamAppWillTerminate` | `UpdateInstaller` | — |

**Verification helper (`Team ID` source of truth).** Our Team ID is read from the
running app's own code signature at runtime (`SecCodeCopySigningInformation` on
`SecCodeCopySelf`), not hardcoded — so the staged bundle must be signed by the same
team that signed the currently-running app. This is self-anchoring and survives a
team-id change without a code edit.

---

## Data flow / state changes

`UpdateState` today: `.idle / .checking / .downloading / .ready(version,dmgURL,notes) / .error / .upToDate`.

After:
- `.ready(...)` → **`.readyToInstall(bundleURL:version:notes:)`** — carries the
  *verified staged app bundle*, not a dmg.
- add **`.installing`** — brief, while the helper is launching / app is quitting.
- `.downloading` / `.checking` / `.idle` / `.error` / `.upToDate` unchanged.

Menu titles (`UpdateMenuCommand.menuTitle`) map: `.readyToInstall` → "Install Update…",
`.installing` → "Installing…".

---

## Error handling

| Failure | Behavior |
|---|---|
| Download fails | `.error` (manual) / `.idle` (background) — unchanged |
| Unzip fails | `.error` on manual; abort silently on background; keep current version |
| **Verify fails** (bad sig / wrong team / not notarized) | **abort install, do NOT swap**, surface `.error("Update failed verification")`; leave current app intact. Log the specific check that failed. |
| `/Applications` not writable | fall back to Finder-reveal of the `.dmg` |
| Helper launch fails | `.error`; current app intact (swap never started) |
| Swap fails mid-`ditto` | `ditto` to a temp sibling then atomic rename, so a partial copy never replaces a working app; on failure the original is untouched |

Verification failures are **loud** (consistent with the publishing namespace
footgun lesson: silent no-ops cost debugging chases).

---

## Testing

**Unit (in `MaughamTests/Updates/`):**
- `UpdateInstaller` verify logic with injected verify results (pass / wrong-team /
  unsigned / not-notarized → correct accept/abort).
- Writability-check → Finder-fallback decision (injected FS predicate).
- Helper-script generation: correct PID-wait + `ditto` + conditional `open`.
- `zipAsset` selection; `.zip` preferred over `.dmg`; zip-less release degrades.
- `UpdateState` / menu-title mapping for new cases.
- Version comparison (existing `SemanticVersion` tests still pass).

**Cannot be unit-tested — the dry-run gauntlet** (per `feedback_dry_run_is_integration_test`):
the only way to validate these is a throwaway `v0.x.y` tag built by CI, installed on
a real Mac:
1. Does the Developer ID cert import + sign in CI?
2. Does notarytool **accept a hardened-runtime build that embeds WhisperKit + tectonic
   + maugham-mcp**? (entitlement gaps surface here)
3. Does on-device **transcription still work** under hardened runtime? (the WhisperKit
   Metal/ANE risk)
4. Does the stapled `.dmg`/`.zip` launch **without right-click → Open**?
5. Does the detached helper actually **replace `/Applications/Maugham.app` and relaunch**?
6. Does **install-on-quit** apply on the next ordinary quit?

Cut throwaway `v0.0.x` tags to prove each on device; delete them after. Then cut the
real tag. **One manual smoke after B**, then ship as a single release.

---

## Release / ops

- **`SETUP.md`** (new, e.g. `docs/release-notes/SETUP-mac-signing.md`, mirroring the
  phone's `docs/release-notes/phone/SETUP.md`): create a **Developer ID Application**
  certificate in the Apple Developer portal (NOT the iOS "Apple Distribution" cert —
  different type, can't be reused for Mac notarization), export as `.p12`, base64-encode,
  and add the two new GitHub secrets. Document that the ASC API key for notarytool is
  the **same** one the phone pipeline already uses.
- **New secrets:** `DEVELOPER_ID_CERT`, `DEVELOPER_ID_CERT_PASSWORD`.
  **Reused secrets:** `APP_STORE_CONNECT_API_KEY`, `_KEY_ID`, `_ISSUER_ID`,
  `DEVELOPMENT_TEAM` (or read team from the cert).
- `cut-release.sh` logic unchanged; the dry-run discipline (throwaway tags first)
  is the operating procedure, not a script change.
- **Update CLAUDE.md** Releases section: builds are now signed + notarized; the
  "right-click → Open" note and "signing stays Path B" note are retired; record the
  new secrets and the SETUP.md pointer.

---

## Open risk register (resolve during dry-run, not before)

1. **WhisperKit under hardened runtime** — may need a specific entitlement; add only
   if dry-run proves it. Highest-probability surprise.
2. **Inside-out signing of tectonic (~49MB) + maugham-mcp** — verify both notarize;
   `maugham-mcp` currently ships `codeSign: false`.
3. **Relaunch race** — the helper must wait for true process death, not just window
   close; verify with a slow-teardown case.
4. **Atomic swap** — `ditto` to temp sibling + rename so a working app is never left
   half-overwritten.
