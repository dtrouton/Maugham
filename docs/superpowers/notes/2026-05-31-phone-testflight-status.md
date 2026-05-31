# MaughamPhone TestFlight — status & pickup plan (2026-05-31)

> **DONE (2026-05-31): `phone-v0.1.0` (build 854) released to TestFlight.** All five
> on-device bugs below are fixed, regression-tested, and verified on device by the
> user (screenplay renders correctly, folder picks, app installs). Throwaway tags
> `phone-v0.0.1`–`0.0.4` + their GitHub releases are deleted; only `phone-v0.1.0`
> remains. Milestone summary: `memory/project_milestone_iphone_companion_phase_g.md`.
> This note is kept as the forensic record of the session. Nothing left to pick up.

Working session on **Phase G** (iOS TestFlight pipeline) + the on-device bugs the
dry runs surfaced. Written mid-task so the next session can resume cleanly.

## TL;DR

- **The CI/TestFlight pipeline is DONE and proven end-to-end.** A real signed build
  (`phone-v0.0.2`) archived, signed, uploaded to TestFlight, and installed on the
  user's phone.
- **3 bugs found + fixed + committed + pushed** (all caught by real dry runs, not
  unit tests): capital-M bundle id, iPhone-only device family, and the
  security-scoped-bookmark ordering (the last verified on-device by the user).
- **1 bug in progress, fix written but NOT committed:** the Fountain (screenplay)
  reader didn't strip manuscript anchors → title page missing + `<!-- ¶id -->`
  "paragraph markers" showing. Root cause found, fix applied, 3 regression tests
  written and proven RED→GREEN. **Needs: full-suite run → commit → dry-run build.**

## What is COMPLETE (committed + pushed to origin/main)

Phase G deliverables (commit `78207e6` + fixes):
- `scripts/cut-phone-release.sh` — `phone-v*` pre-flight + tag (mirrors Mac cut script).
- `.github/workflows/phone-release.yml` — tag-triggered, macos-15, version-from-tag,
  build-number = `git rev-list --count HEAD` (fetch-depth: 0), archive →
  `-exportArchive` (`destination=upload` + ASC API key, **altool-free**) → GH release.
- `docs/release-notes/phone/{_template,SETUP}.md` — notes template + one-time Apple setup.
- MaughamPhone AppIcon (M+¶ family, opaque 1024px stable+dev) + editable SVG sources
  in `scripts/phone-icon/`.
- `project.yml`: per-config `ASSETCATALOG_COMPILER_APPICON_NAME`,
  `ITSAppUsesNonExemptEncryption: false`, `TARGETED_DEVICE_FAMILY: "1"`.

Bug fixes from the dry runs (all committed + pushed):
1. **`16a736d`** — bundle id `com.Maugham.MaughamPhone` (capital M, matches the
   registered Apple App ID; Apple namespaces App IDs case-insensitively so lowercase
   couldn't be re-registered). See CLAUDE.md → phone bundle-id note.
2. **iPhone-only** (`TARGETED_DEVICE_FAMILY=1`) — App Store Connect rejected the first
   upload: portrait-only on an iPad-capable bundle requires all 4 orientations.
3. **`45ec8f3`** — `ProjectsRoot.pick` now calls `startAccessing` BEFORE `makeBookmark`.
   On a signed build the sandbox reported the iCloud folder as non-existent
   ("Couldn't open folder because it doesn't exist") because `bookmarkData()` ran
   without active security scope. **User verified the folder picks on-device.** ✅

GitHub secrets (6) are set; ASC app record + internal tester set up by the user.

## Apple/account facts (so we don't re-derive them)

- **Bundle id: `com.Maugham.MaughamPhone`** (capital M) — release. Dev is `.dev`.
- **Team `FF3XH4ZJ45`**, profile "Maugham Phone App Store" (App Store distribution,
  expires 2027-05-31). All consistent + capital-M.
- Internal TestFlight testing → no Beta App Review, usable ~15 min after upload.

## IN PROGRESS — the Fountain reader bug (fix written, UNCOMMITTED)

**Symptom (user, on phone-v0.0.2):** screenplays partially formatted — title page not
shown, and paragraph markers (`<!-- ¶id -->`) visible in the body.

**Root cause (confirmed in code):** `DocumentReaderView.load()` stripped manuscript
anchors on the **markdown** path (`MarkdownDisplayFilter.stripAnchors`) but the
**fountain** path parsed RAW text. So `<!-- ¶id -->` anchors reached the Fountain
tokenizer, which (a) classified each anchor line as `.action` body text, and (b)
broke title-page detection — a manuscript `.fountain` is `Materializer` output where
the title-page block is preceded by its own `<!-- ¶id -->` anchor, so the file's
first non-empty line is the anchor, and `FountainTokenizer.parseTitlePage`'s
first-line `Key:` probe fails.

**Fix applied (uncommitted) in `MaughamPhone/Read/DocumentReaderView.swift`:**
extracted a pure static seam `parseFountain(_:)` that strips anchors before parsing:
`FountainTokenizer().parse(MarkdownDisplayFilter.stripAnchors(text))` — same shared
filter the markdown path uses (CLAUDE.md: single source of truth, don't add a
target-local stripper).

**Regression tests (uncommitted, new file)
`MaughamPhoneTests/DocumentReaderFountainTests.swift`:** 3 tests — title page detected
past the leading anchor, anchors stripped from body, scene heading classified after
strip. Proven **RED** (4 failures under no-strip) → **GREEN** (3/0 with the fix).
Fixture matches real `Materializer` output (anchor immediately above content, blank
between blocks; title-page keys contiguous under one anchor).

**Uncommitted working tree right now:**
- `M MaughamPhone/Read/DocumentReaderView.swift` (the fix)
- `?? MaughamPhoneTests/DocumentReaderFountainTests.swift` (the tests)
- (the `.xcodeproj` was regenerated with `./gen.sh` so the new test file is in the target)

## PICK UP HERE — ordered next steps

1. **Run the FULL phone suite** (not just the 3 new tests) to confirm nothing else
   broke — expect **131** (128 + 3):
   ```
   xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone \
     -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO
   ```
2. **Commit** the Fountain fix + tests (suggested message):
   `fix(phone): strip manuscript anchors before parsing Fountain (title page + ¶ markers)`
3. **Push main** (needs user OK — pushing to main is gated).
4. **Cut a new dry-run build `phone-v0.0.3`** so the user can verify the screenplay
   renders correctly on device (title page shown, no ¶ markers, scene headings/
   dialogue styled). Loop: write throwaway notes `docs/release-notes/phone/v0.0.3.md`
   → `./scripts/cut-phone-release.sh 0.0.3 --skip-tests` → push tag → `gh run watch`.
   (Delete old `phone-v0.0.2` tag+release first, like we did for 0.0.1.)
5. **User verifies on device.** If good → cut the **real `phone-v0.1.0`** with proper
   release notes. If another bug → same loop (root-cause → regression test → throwaway).

## Cleanup owed once we cut the real phone-v0.1.0

- Delete throwaway git tags + GitHub releases: `phone-v0.0.2` (and `0.0.3` if used).
  (`phone-v0.0.1` already deleted.)
- User deletes the throwaway TestFlight builds in App Store Connect (or lets them
  expire in 90 days). Build numbers are commit-count-monotonic, so the real cut always
  gets a higher build number — no collision even if throwaways linger.
- Optional: the throwaway `docs/release-notes/phone/v0.0.x.md` files are harmless
  history; remove in the 0.1.0 commit if desired.

## How to work this pipeline (reminders)

- `gh run watch <id> --exit-status` blocks until a run finishes (exit 0 = success).
- The dry run is the integration test (spec §7.3): cert/profile/API-key/upload can
  ONLY be validated by pushing a real build to ASC. Every bug so far was device/
  signing-only — invisible to `xcodebuild test`. Keep using throwaway `phone-v0.0.x`
  tags to prove fixes before the real cut.
- After adding a new test FILE, run `./gen.sh` before `xcodebuild` or it won't be in
  the target ("Executed 0 tests").
- iOS-sim "Busy/preflight" on a test run is a flake — re-run; don't `simctl shutdown all`.
- SourceKit "No such module 'MaughamCore'/'XCTest'" diagnostics are IDE noise;
  `xcodebuild` is ground truth.

## Related docs
- Original Phase G brief: `docs/superpowers/notes/2026-05-30-phase-g-handoff.md`
- Setup + secrets: `docs/release-notes/phone/SETUP.md`
- iOS gotchas: `MaughamPhone/AREA.md`; plan: `docs/superpowers/plans/2026-05-24-iphone-companion-v1.md`
