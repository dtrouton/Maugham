# Releasing Maugham

Stable releases are tag-triggered via GitHub Actions. The recipe:

1. Write release notes: `docs/release-notes/v0.X.Y.md` (template at `docs/release-notes/_template.md`).
2. Commit them on `main`.
3. `./scripts/cut-release.sh 0.X.Y` — verifies notes exist, tree is clean,
   **verifies every GitHub Action pin resolves to the tag in its `# vX` comment**
   (needs network + `gh` auth), runs tests, then creates the `v0.X.Y` tag and
   prints the push command. Pass `--skip-tests` only if you know why; pass
   `--skip-pin-check` only for a genuinely offline cut.
4. `git push --tags`. Workflow at `.github/workflows/release.yml` builds Release config,
   runs tests, packages the `.dmg`, and creates the GitHub Release with the notes file as body.
5. ~10 minutes later, the stable app's next check picks it up. Menu title goes to
   "Install Update…"; clicking reveals the `.dmg` in Finder.

**Version is tag-derived.** `project.yml`'s `CFBundleShortVersionString` stays at the placeholder
`"0.0.0-dev"` for local builds; CI rewrites it from the tag at build time. Don't bump it in
`project.yml` — bump it via the tag. `CFBundleVersion` (the build number) is
`git rev-list --count HEAD` — deterministic, tied to git history, and strictly monotonic across
releases (same mechanism as the phone pipeline; replaced `github.run_number`). This needs the full
history, so the release checkout uses `fetch-depth: 0`. The Mac and phone targets share
byte-identical placeholders in `project.yml`, so the release workflow's rewrite is **scoped to the
`Maugham:` target block** — it must not touch the `MaughamPhone:` placeholders.

**Workflow fails before publish if `docs/release-notes/v0.X.Y.md` is missing.** Tag pattern
`v[0-9]+.[0-9]+.[0-9]+` triggers the release workflow; milestone tags (`milestone-*`) don't.

**Dev builds don't auto-update.** `BuildVariant.dev` (set by `-DMAUGHAM_DEV_BUILD` in Debug config)
disables the updater. Stable lives at bundle id `com.maugham.Maugham` in `/Applications`; dev at
`com.maugham.Maugham.dev` from Xcode. They have separate MCP socket paths and separate Claude
Desktop config entries (`maugham` vs `maugham-dev`) — see `Maugham/BuildVariant.swift`.

**Builds are signed + notarized.** Release config uses a Developer ID Application
cert + hardened runtime; CI notarizes and staples, so downloaded `.dmg`/`.zip`
launch Gatekeeper-clean (no right-click → Open). Dev builds stay ad-hoc
(`com.maugham.Maugham.dev`, updater disabled). One-time secret setup:
`docs/release-notes/SETUP-mac-signing.md`. New secrets: `DEVELOPER_ID_CERT`,
`DEVELOPER_ID_CERT_PASSWORD`; notarytool reuses the phone's ASC API key. The Mac
entitlements file is `Maugham/Maugham.entitlements` (minimal — add WhisperKit keys
only if a notarization dry-run proves them needed).

**Auto-update is in-place — for the `.zip` path only.** The updater downloads the
notarized `.zip`, verifies it in-app (codesign + our Team ID via
`UpdateInstaller.runningAppTeamID` + notarization), and swaps the running app via a
detached helper — "Restart & Update" relaunches; dismissing applies the staged
update on next ordinary quit (`UpdateChecker.pendingQuitInstall`). If
`/Applications` (the running app's location) is unwritable, it falls back to
revealing the `.dmg` in Finder instead — that fallback path is **not** in-app
verified; the `.dmg` is Gatekeeper-verified on launch, the same as any downloaded
app, not by `UpdateInstaller`. The verify/stage Process work runs off the main
actor. See `docs/superpowers/specs/2026-06-01-mac-auto-update-design.md`.

**Release configuration — After any change to `ProjectWindow.body` (or any large SwiftUI `body`),
run a local Release build before tagging:**

```
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO
```

The Release config's stricter type-check budget can reject a `body` that the Debug config accepts —
this is how a green local test run shipped a broken Release build to CI on the v0.8.0 tag.

## Pinned toolchain + action-pin preflight

**The toolchain is pinned, not floating.** All three workflows (`ci.yml`,
`release.yml`, `phone-release.yml`) now pin the same toolchain so CI and the two
release pipelines build identically and can't drift between releases:

- **Xcode `26.3`** via `maxim-lobanov/setup-xcode` (was `latest-stable` in the
  release workflows). 26.3 is the newest Xcode the `macos-15` runner has
  installed — 26.5/26.6 exist only on the developer machine and pinning them
  would fail the runner (commit `a20e0da`). If GitHub updates the runner image
  and 26.3 disappears, the setup step fails loudly; bump all three files together.
- **xcodegen pinned to a frozen homebrew-core formula revision** (xcodegen
  2.45.4) instead of `brew install xcodegen`: `brew install --formula
  https://raw.githubusercontent.com/Homebrew/homebrew-core/<commit>/Formula/x/xcodegen.rb`.
  Homebrew still fetches the arch-correct, checksum-verified bottle — only the
  *version* is frozen. **To bump xcodegen:** pick a newer homebrew-core commit
  for `Formula/x/xcodegen.rb` and update the URL in all three workflows.

**Action pins are verified at cut time.** Every `uses: owner/repo@<sha> # vX`
across `.github/workflows/*.yml` is SHA-pinned (supply-chain hygiene), but a SHA
is opaque — nothing structurally guarantees it's the commit its `# vX` comment
claims. `cut-release.sh` (and `cut-phone-release.sh`) now dereference each tag via
the GitHub API and abort the cut on any mismatch or any unpinned action. This is
the fabricated-SHA guard (PR #1 history). Logic lives in
`scripts/lib/verify-action-pins.sh`; unit-tested offline with a stubbed `gh` in
`scripts/tests/verify-action-pins.test.sh` (`bash scripts/tests/verify-action-pins.test.sh`).
Use `--skip-pin-check` only for an offline cut where you already trust the pins.

> **The dry run IS the integration test for all of the above.** The pinned Xcode
> version, the pinned xcodegen formula, the `git rev-list` build number + its
> `fetch-depth: 0` requirement, and the target-scoped `sed` only fully exercise
> on a real GitHub runner — they cannot be validated on the developer machine
> (whose Xcode/xcodegen differ from the runner's). Before the next real Mac
> release, cut a throwaway **dry-run tag in the reserved patch ≥ 90 band** (e.g.
> `v0.X.90`, published as a prerelease so installed users never see it) and
> confirm the run is green end-to-end. Only then cut the real tag. A step that
> passes locally here can still fail on the runner.

## Phone releases

Phone releases use `scripts/cut-phone-release.sh` (mirrors the Mac cut script, `phone-v*` tags).
Pipeline: `.github/workflows/phone-release.yml` (`macos-latest`, version-from-tag,
build-number = `git rev-list --count HEAD`, archive → `-exportArchive` with `destination=upload`
+ ASC API key — **altool-free on purpose**: it's deprecated and silently broken on Xcode 26).

**The dry run IS the integration test.** Cert/profile/API-key/upload + Apple's bundle validation
can ONLY be checked by pushing a real signed build to App Store Connect. Cut throwaway
`phone-v0.0.x` tags to prove a fix on device, then cut the real tag; delete throwaways after.

**The phone's release bundle id is `com.Maugham.MaughamPhone` — capital "M", deliberately.**
The Apple App ID was registered with a capital M, and Apple namespaces App IDs
case-insensitively, so the lowercase form can't be re-registered without deleting the existing
App ID + App Store Connect record (an ASC record's bundle id is immutable). Codesign matches the
bundle id case-sensitively, so `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`
(Debug `com.Maugham.MaughamPhone.dev` / Release `com.Maugham.MaughamPhone`) and the
`provisioningProfiles` key in the workflow's generated `ExportOptions.plist` MUST stay capital-M
and in sync, or the export/sign step fails. If you ever regenerate the App ID you can switch to
lowercase — but then change both project.yml ids + the ExportOptions key together.

One-time Apple setup (6 GitHub secrets, ASC record): `docs/release-notes/phone/SETUP.md`.
M+¶ app icon: editable SVG sources + `render.sh` in `scripts/phone-icon/`.

**Four release-phase bugs (TestFlight dry runs found these; unit tests / debug builds can't):**

1. Bundle-id casing — see capital-M note above.
2. `TARGETED_DEVICE_FAMILY` must be `"1"` (iPhone-only) or ASC rejects portrait-only as needing all 4 iPad orientations.
3. `ProjectsRoot.pick` must `startAccessing` BEFORE `makeBookmark` (else the iOS sandbox reports the iCloud folder "doesn't exist" — a debug build worked by luck).
4. Screenplay rendering — the Fountain reader must strip `<!-- ¶id -->`/`<!--t-->` anchors via the shared `MarkdownDisplayFilter` like the markdown path (a target-local skip leaked anchors as body text AND broke title-page detection), and `.titlePage` lines must be `hidden` in `FountainStyler` since `FountainSemanticRenderer.titlePageBlock` already renders `script.titlePage` (else the title page double-renders).

Reference: `docs/superpowers/notes/2026-05-30-phase-g-handoff.md`, `docs/superpowers/notes/2026-05-31-phone-testflight-status.md`, `memory/project_milestone_iphone_companion_phase_g.md`.
