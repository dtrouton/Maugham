# Phase G handoff — MaughamPhone TestFlight release pipeline

**For the agent picking up Phase G of the iPhone-companion milestone.** Written 2026-05-30 right after Phases D0–F merged to `main` (`3fff8b5`, pushed to origin).

## What Phase G is (and is NOT)

Phase G is the **iOS CI / signing / distribution** phase — a TestFlight release pipeline for `MaughamPhone`, plus the app icon. **It is not app code.** The capture + read + annotation-review app is feature-complete and smoke-verified; do not change app behaviour. Mirror the existing **Mac** release pipeline, adapted for iOS (TestFlight not `.dmg`, signing required, monotonic build numbers, a separate tag namespace).

## Read first (authoritative scope)

1. `docs/superpowers/plans/2026-05-24-iphone-companion-v1.md` — the **Phase G** section (tag namespace, cut script, workflow, GH secrets, build numbering, TestFlight specifics) and the **§9 open questions** (altool-vs-notarytool, ASC Beta App Information minimum, coordinated-write deadline — the first two are yours).
2. `docs/superpowers/specs/2026-05-24-iphone-companion-v1-design.md` §3.11 — the `cut-phone-release.sh` and `phone-release.yml` reference shapes.
3. `CLAUDE.md` → **Releases** section — the Mac release recipe + the "version is tag-derived; don't bump `project.yml`" rule (same applies to the phone).
4. **The Mac pipeline you're mirroring:** `scripts/cut-release.sh`, `.github/workflows/release.yml`, `docs/release-notes/_template.md`, and the per-variant icon pattern in `Maugham/Assets.xcassets/{AppIcon,AppIconDev}.appiconset`.

## Deliverables

1. **MaughamPhone AppIcon** (do this first — App Store Connect rejects a missing icon at upload).
   - Add `MaughamPhone/Assets.xcassets` with `AppIcon.appiconset` + `AppIconDev.appiconset` (mirror the Mac's two), each with at least the 1024px marketing icon (iOS single-size asset catalogs are fine on modern Xcode).
   - Wire per-config in `project.yml` under the `MaughamPhone` target settings, exactly like the Mac target: `ASSETCATALOG_COMPILER_APPICON_NAME: AppIconDev` (Debug) / `AppIcon` (Release). Run `./gen.sh`.
   - You'll need an actual icon image. If the user hasn't supplied artwork, ask — it's their app's identity. A placeholder unblocks the dry run but flag it.

2. **`scripts/cut-phone-release.sh`** — mirror `scripts/cut-release.sh`:
   - Verify `docs/release-notes/phone/v${VERSION}.md` exists; tree clean; on `main`.
   - Run the phone test target on the simulator: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO` (the spec example uses "iPhone 15" — use an available sim; `xcrun simctl list devices available` to pick).
   - Tag `phone-v${VERSION}`, print the push command. `--skip-tests` flag for emergencies.

3. **`.github/workflows/phone-release.yml`** (new):
   - Trigger: `push: tags: ['phone-v[0-9]+.[0-9]+.[0-9]+']` (Mac uses `v[0-9]+...`; the two never collide; `milestone-*` triggers neither).
   - Runner: `macos-latest` (iOS archive needs it).
   - Steps: checkout → setup Xcode + xcodegen → import distribution cert + provisioning profile from secrets → **rewrite `CFBundleShortVersionString` from the tag and `CFBundleVersion` from `git rev-list --count HEAD`** (monotonic; never resets — Apple rejects a `CFBundleVersion` ≤ any prior upload) → `./gen.sh` → `xcodebuild archive` → `xcodebuild -exportArchive` → upload to TestFlight via the App Store Connect API → create a GitHub Release with `docs/release-notes/phone/v${VERSION}.md` as the body.
   - `project.yml` keeps the placeholders already in place (`CFBundleShortVersionString: "0.0.0-dev"`, `CFBundleVersion: "1"` on the MaughamPhone target) — CI rewrites both at build time. **Do not bump them in `project.yml`.**

4. **`docs/release-notes/phone/_template.md`** (copy-source) + **`docs/release-notes/phone/SETUP.md`** documenting the one-time setup (secrets + the App Store Connect record + the mandatory Beta App Information fields).

## What the USER must provide (you cannot)

You write the workflow; the user supplies the Apple credentials as **GitHub secrets** and does the first App Store Connect setup:

- `APPLE_DISTRIBUTION_CERT` (base64 `.p12`) + `APPLE_DISTRIBUTION_CERT_PASSWORD`
- `PROVISIONING_PROFILE` (base64 `.mobileprovision`) for `com.maugham.MaughamPhone` (the Release bundle id)
- `APP_STORE_CONNECT_KEY_ID` + `APP_STORE_CONNECT_ISSUER_ID` + `APP_STORE_CONNECT_API_KEY` (base64 `.p8`)
- An App Store Connect **app record** for `com.maugham.MaughamPhone` + the bundle id registered in the Apple Developer portal.

Ask the user for these (or to add the secrets) before the first real cut. The dev variant (`com.maugham.MaughamPhone.dev`) is for Xcode-run dev builds only; **release the stable bundle id** `com.maugham.MaughamPhone`.

## Gotchas / decisions to confirm

- **altool is deprecated.** Confirm the current upload mechanism in the chosen Xcode (`xcrun altool --upload-app` vs `notarytool`/direct ASC API). Plan §9 flags this — verify, don't assume.
- **Build number** = `git rev-list --count HEAD` (monotonic, no coordination with ASC). Do NOT use GH Actions `run_number` (resets if the workflow file is recreated).
- **Privacy.** The Info.plist already has the usage strings (mic/speech/camera/photo + NSFaceIDUsageDescription). ASC also requires the **privacy questionnaire** + (for external testers) Beta App Review on the first build of each version. Internal testing (≤100 on your team) skips Beta App Review.
- **No in-app updater** — TestFlight handles updates; the Mac's `BuildVariant.dev` updater-disable trick has no iOS analogue.
- **Dry run before the real cut** (plan §7.3 / §9): push a `phone-v0.0.1-dev` tag, watch the workflow run end-to-end (including the TestFlight upload), then delete the tag + the TestFlight build before cutting `phone-v0.1.0`.
- **Lint guard:** `TripwirePhoneGrepTest` already enforces tripwire-13 across `MaughamPhone/*.swift`; no CI grep step needed, but the workflow runs the phone tests which include it.

## Conventions / commands

- `./gen.sh` after any `project.yml` or asset-catalog change (the `.xcodeproj` is generated; never hand-edit `project.pbxproj` or commit anything under `Maugham.xcodeproj/`).
- Phone tests: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug test CODE_SIGNING_ALLOWED=NO`.
- Mac stays unaffected (its `v0.X.Y` pipeline keeps working). Both schemes must stay green: Mac 1467 / phone 126 at the merge.
- Transient simulator "Busy / failed preflight" on a test run → re-run the command; do NOT `simctl shutdown all`.

## State at handoff

- Phases D0–F merged to `main` (`3fff8b5`), pushed to origin. App feature-complete + smoke-verified (six bugs found+fixed on 2026-05-30 — see the plan STATUS banner). No milestone tag was created (the plan suggested `milestone-iphone-companion` — optional).
- Polish backlog (NOT Phase G, except the icon): Annotations show-resolved+undo, inbox preview in Capture — see the plan's Phase H polish backlog.
- See `memory/project_milestone_iphone_companion_ios.md` for the full milestone summary.
