# Your devices are you — plan 2: the phone, the saved-by hint, signing, smoke and the paired release — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn plan 1 on for real.
- The iPhone signs its own claim with the person key, and names itself *"Denver's iPhone"*.
- The Mac's admission sheet shows iCloud's *saved by* name.
- Both apps carry the keychain entitlement, and the Mac release embeds its provisioning profile.
- Real hardware proves it end to end.
- It ships as a paired release.

**Architecture:**
- The phone reuses Core's `PersonKey`/`PersonKeyStore`/`RegistryWriter.personClaim` and the one `RegistryPresence.ensureDeviceRecord` door (tripwire 19). Its only new code is a store construction point with a test-host guard, a claim intent on `PhoneDeviceRecord.ensure`, a name rule, and a Settings line.
- The saved-by hint is one Core reader over the device record file's ubiquitous metadata.
- Signing changes are two entitlements files, `project.yml`, and `release.yml`'s embed step.

**Tech Stack:** Swift 6, Security, Foundation ubiquitous resource keys, XCTest, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-27-your-devices-are-you-design.md`. Spike: `docs/superpowers/notes/2026-09-27-person-key-spike.md`. Plan 1 outcome and carries: `docs/superpowers/notes/2026-09-28-your-devices-plan1-outcome.md`. **Where this plan, the spec and a ruling differ, stop and say so.**

## How to read this plan

It gives contracts, with signatures **verified at file+line on 2026-09-28 against main `5d5dd244`**, and no bodies. If a cited line has moved, find the symbol. If a signature is wrong, stop and report it.

- **The disable experiment is required on every negative**: disable the guard, show the failing output on a line containing `EXPERIMENT`, then restore. Grep your diff for `EXPERIMENT` / `if false` / `true ||` before each commit.
- State every rule in both directions.

## Global Constraints

- Everything plan 1's Global Constraints say still binds, with these additions:
  - Every person-key fact is read from the root's chain only.
  - Recognition never writes `AdmissionMemory`.
  - Tripwire 53's censuses must be extended deliberately. The phone's sites join them by name.
- **The phone signs no person record, no event and no claim record.** It writes ONE record, its own device record, through Core, and that record now carries a claim. `TripwirePhoneGrepTest`'s writer and admission censuses stay empty.
- **No test ever reaches a real keychain.** The phone gets a test-host guard like the Mac's `TestHost.isActive` arm. The simulator may not enforce access groups, so assume it doesn't.
- **The Mac's Debug build stays unentitled.** An ad-hoc build carrying a restricted entitlement with no profile can be refused at launch, and the gate is ad-hoc. The keychain entitlement is Release-only on the Mac. On the phone it is Release-only too, unless Task 5 shows a Debug device build needs it for Denver's own testing, in which case it is decided there.
- iOS tripwires (MaughamPhone/AREA.md) bind. In particular #5 (no `NSFilePresenter`) and #7 (byte-compatible with the Mac reader, proven by a round trip).
- **Process:**
  - Branch `claude/your-devices-are-you-p2` off main. Sequential opus implementers.
  - `git commit -- <paths>`. Never amend. Run `./gen.sh` whenever a file is added or deleted.
  - Fixtures via `TestTemp.root`.
  - Gates: `./scripts/test.sh core`, `./scripts/test.sh`, `./scripts/test.sh phone`. Add `full` plus a Release build on Tasks 1, 3 and 8.
  - `pgrep -x xcodebuild`. `command grep -a`. END WITH THE HAND-BACK.
- **Models:** opus implementers. Reviewers: opus for Tasks 1, 3 and 5; sonnet for the rest. The whole-branch review is fable.

## Review Focus

1. **The phone writes its claim and the root's Mac recognises it.** Pin this with a Mac-side read of a phone-written device record in a real temp book (tripwire #7's round trip). The claim must verify and `Recognition` must answer `.ownDevice` (Task 1).
2. **A phone test host never touches a keychain**, even on a simulator that ignores access groups (Task 1).
3. **The saved-by reader on the book OWNER's Mac returns nil for the owner's own saves.** It must never claim the owner's own device was saved by someone else. On a non-owner Mac it must not invent a name (Task 3).
4. **The released Mac app carries the profile, and codesign seals it.** A Release build without the profile must fail the workflow loudly, not ship an app that silently reads the keychain as unavailable (Task 6).
5. **The name rule never overwrites a real user-assigned name.** *"<first name>'s <model>"* applies only when the system name is generic (Task 1).

## Rulings this plan makes (confirm at plan review)

- **P2-1:** the phone's claim is made on its first WRITE in a book, as its device record is today. There is no new open-time write, so the phone still writes only when the writer acts. *Cost if wrong:* a phone that only reads is never recognised, and it wasn't going to be admitted anyway.
- **P2-2:** the first name for *"Denver's iPhone"* comes from the person key item's name. The Mac seeds it from `NSFullUserName()`. The first name is the first whitespace-delimited word. With no name, the device name stays the system name. *Cost if wrong:* a multi-word first name is shortened.
- **P2-3:** the saved-by hint reads `ubiquitousSharedItemMostRecentEditorNameComponents` on the stranger's DEVICE RECORD file, and shows only when it is non-nil. When it disagrees with the claimed person name, the sheet says so plainly. *Cost if wrong:* the hint is absent where iCloud doesn't provide it.
- **P2-4:** the entitlements are Release-only on the Mac. The Mac entitlements file carries the literal group, because `release.yml` re-signs with the raw file and no `$(AppIdentifierPrefix)` expansion happens. The phone's file uses `$(AppIdentifierPrefix)`, because Xcode signs it. *Cost if wrong:* a team-signed local Debug build on the Mac makes no claim (true today).

## File structure

New:

| file | responsibility |
|---|---|
| `MaughamPhone/Storage/PhonePersonKeyAccess.swift` | the phone's ONE `PersonKeyStore` construction, with a test-host guard |
| `Packages/MaughamCore/Sources/MaughamCore/SavedByReader.swift` | the one reader of a file's iCloud "most recent editor" name |
| `MaughamPhone/MaughamPhone.entitlements` | the keychain access group, `$(AppIdentifierPrefix)com.maugham.person` |

---

### Task 1: The phone claims (phone + Core round trip)

**Files:**
- `MaughamPhone/Storage/PhoneDeviceRecord.swift`:
  - `ensure(in:identity:identities:name:declare:)` at :67–85;
  - the name at :87;
  - the memo `Declaration` at :46–53.
- Callers: `InboxCaptureWriter.swift:228` and `AnnotationWriter.swift:365`.
- Core:
  - `RegistryPresence.ensureDeviceRecord(... personClaim:)` :63;
  - `RegistryWriter.personClaim(forDevice:signedBy:)` :197;
  - `PersonKey.findOrCreate(in:seedName:)` :53;
  - `KeychainPersonKeyStore.accessGroup(teamID:)` :131.
- The Mac precedent: `Maugham/Stores/PersonKeyAccess.swift`, and `DocumentStore.claimIntent` :294 / `declareThisMac` :314.
- `MaughamTests/PersonKeyCensusTests.swift`: `storeConstruction` :58 and `personKeySigning` :167.

**Contract:**
- **`PhonePersonKeyAccess`** mirrors the Mac's `PersonKeyAccess`:
  - an injected store wins;
  - a test host gets an in-memory store that refuses to create;
  - production gets `KeychainPersonKeyStore(accessGroup: accessGroup(teamID: "FF3XH4ZJ45"))`.
  - Test-host detection uses the same XCTest environment keys `TestHost.isActive` uses. It is not shared code, because the phone target cannot import the Mac's.
- **`ensure` gains the claim intent.**
  - It finds the key off the main actor, or on it if the call is already async-safe. Say which, and measure it.
  - `.set` with a key, `.keep` without one, never `.remove` (plan 1's rule). The claim goes through `RegistryWriter.personClaim`.
  - The memo includes the claim's facts, so a key that appears mid-run is declared once.
  - A refused claim is logged, and the record is written with `.keep`. Nothing is thrown to the writer's path.
  - The seed name is `""`: iOS has no owner name, and an empty-named item is filled later by a Mac.
- **The name rule (P2-2, Review Focus 5).**
  - The system name is kept unless it is generic, meaning it equals the model (`"iPhone"`).
  - In that case, and when the key's name is non-empty, the name is *"<first name>'s <model>"*.
  - It is a pure function, pinned both ways.
- **Census.** Register the phone's store construction and `.store` read, its `findOrCreate` and its `RegistryWriter.personClaim`, in tripwire 53's arrays under `MaughamPhone/<file>`. The empty-allow-list control keeps firing for any OTHER phone file.
- **Round trip (Review Focus 1).**
  1. A phone test writes its device record with a claim into a real temp book, through the real `ensureDeviceRecord`.
  2. A Core test reads it with `RegistryReader`: `verifiedPersonClaims` holds it.
  3. `Recognition.recognise` with the root's linked key answers `.ownDevice`.

  Put the shared fixture where both targets can use it, or pin each half in its own target against the same bytes.

- [ ] Tests first, EXPERIMENT per negative (including the test-host guard). Gates: core, fast, phone, full, Release. Commit.

---

### Task 2: The phone's Settings line

**Files:**
- `MaughamPhone/Settings/SettingsView.swift`:
  - `thisDeviceSection` :75–125;
  - the Code row :88;
  - `resolveStandings()` :158–178.

**Contract:**
- One device-wide line after Code. It is not per book.
- With a key: *"Recognised as <name> on your other devices."* If the key has no name yet: *"Recognised on your other devices once a Mac has named you."*
- Unavailable: *"iCloud Keychain is off, so each book asks about this phone once."*
- It is read in the same detached task as the standings, and re-read on `scenePhase == .active` and on pull (tripwire #5).
- It is a pure model sentence, pinned for all three states.

- [ ] Tests first. Phone gate. Commit.

---

### Task 3: The saved-by hint (Core reader + Mac sheet)

**Files:**
- New `SavedByReader.swift` (Core).
- The precedent is `FileURLShareMetadataReader.swift`: it requests `.ubiquitousSharedItemMostRecentEditorNameComponentsKey` at :45 and never reads it. Reuse its shape; don't duplicate its share logic.
- `RegistryWriter.url(` :57 for the device record's path.
- `AdmissionDecision.swift`: `AdmissionRequest` :10–110, `hint` :61, `requests(...)` :189–238, `refreshedRequests` :467.
- `AdmissionSheet.swift` `hintLines(for:)` :162–168. The guard at :163 must let a saved-by line through with no claim.

**Contract:**
- **`SavedByReader.name(ofFileAt:) -> String?`** returns the formatted name components, or nil.
  - It never throws, and never blocks the main actor. Resolve it where requests are built off-main, or cache per refresh; say which.
  - It is injectable for tests (a protocol, or a closure), so the gate never needs iCloud.
- **`AdmissionRequest`** gains `savedBy: String?`.
- **The sheet line:** *"iCloud says this device's record was saved by <name>."*
  - When the claimed person name exists and doesn't match (case- and whitespace-insensitive), it adds *"That isn't the name the device gives."*
  - Plain, not an alarm.
- **Review Focus 3.** nil on the owner's own saves (the spike: nil means the current user). Pin that the line is absent for nil, and never shows the root's own name as someone else's.
- **The census.** `SavedByReader` is the one reader of that key. Add a census entry: the key is named only in `SavedByReader.swift` and `FileURLShareMetadataReader.swift`, the latter unchanged.

- [ ] Tests first, EXPERIMENT per negative. Gates: core, fast, phone, full, Release. Commit.

---

### Task 4: The guide, and the plan-1 carries that plan 2 touches

**Files:**
- `docs/guide/people-and-devices.md`: Task 7's proposed guide text is in `.superpowers/sdd/2026-09-27-your-devices-are-you-plan1-the-person-key/task-7-report.md`, plus Tasks 1–3 of this plan.
- `MaughamPhone/AREA.md`:
  - :58–62 ("no keychain item, no entitlement") goes stale;
  - the declaration section :236–262.
- `docs/release-notes/phone/SETUP.md` §1 :21–28 ("No special capabilities").
- `docs/RELEASING.md`:
  - the stale "macos-latest" (the phone workflow runs on `macos-15`);
  - the Mac signing section :64–71.
- `docs/release-notes/SETUP-mac-signing.md`: :80, which says `github.run_number` where the workflow now uses `git rev-list --count`, and a new profile section.

**Contract:** docs describe what ships in THIS release. Do not write a word about behaviour that needs the entitlements until Task 6 exists; ordering does that.

- [ ] Commit `docs: …`.

---

### Task 5: Entitlements and project.yml (P2-4)

**Files:**
- `Maugham/Maugham.entitlements` (an empty `<dict/>` today).
- New `MaughamPhone/MaughamPhone.entitlements`.
- `project.yml`:
  - the Mac Release block :92–99;
  - the phone target :193–214.

**Contract:**
- The Mac entitlements file carries `keychain-access-groups: [FF3XH4ZJ45.com.maugham.person]`. It is literal: the re-sign doesn't expand variables.
- The Mac Debug config stays unentitled.
- The phone's entitlements file uses `$(AppIdentifierPrefix)com.maugham.person`, in Release. Debug is decided with evidence: does a team-signed device Debug build need it for Denver's hands-on test, and does the ad-hoc simulator gate break with it?
- Local proof:
  - an ad-hoc Release Mac build still builds (`CODE_SIGNING_ALLOWED=NO`);
  - the phone simulator gate still runs;
  - `codesign -d --entitlements -` on a locally Developer-ID-signed build shows the group. Denver has the cert, so the controller can run this with his OK.

- [ ] Gates: fast, phone, Release. Commit.

---

### Task 6: `release.yml` embeds the Mac profile

**Files:**
- `.github/workflows/release.yml`:
  - build :184–190;
  - locate :233–242;
  - re-sign :244–267, where the outer app is signed at :265;
  - notarize :269–328.
- `phone-release.yml` :101–120 is the profile-install precedent.

**Contract:**
- A new secret `MAC_PROVISIONING_PROFILE` (base64). Decode it and copy it to `"$APP/Contents/embedded.provisionprofile"` BEFORE the re-sign at :265.
- If the Xcode build step itself demands the profile, install it where the phone workflow does and pass `PROVISIONING_PROFILE_SPECIFIER`. Decide from the dry run's evidence.
- **Review Focus 4:**
  - After signing, a verify step asserts the embedded profile exists and that `codesign -d --entitlements -` names the group. If either is missing, the job FAILS.
  - The pin is a script test run in CI's workflow-lint job if one exists; otherwise the verify step itself is the check.
- `cut-release.sh` gains no check (it runs locally unsigned). Say so in RELEASING.md.

- [ ] Commit `ci: …`.

---

### Task 7: Denver's portal steps and the two dry runs (controller + Denver)

**Denver:**
- Create a **Developer ID provisioning profile** for `com.maugham.Maugham` with the keychain group. The spike's Xcode-managed "Mac Team Direct" profile is the model, or the profile Xcode makes when the Mac target is archived with the entitlement.
- Base64 it into the `MAC_PROVISIONING_PROFILE` secret.
- Check the phone's App Store profile. If `security cms -D` on the current `PROVISIONING_PROFILE` doesn't show `keychain-access-groups: FF3XH4ZJ45.*`, regenerate it.

**Dry runs:**
- A Mac `v0.41.90` tag. Patch ≥ 90 is a prerelease (RELEASING.md :141–149). Install it and confirm:
  - the embedded profile is there;
  - it launches;
  - it makes a claim in a scratch book (`devices/<fp>.json` has `personClaim`).
- A throwaway `phone-v0.0.x` to TestFlight. Install it and confirm it writes a claim on its first capture in a scratch book.
- Delete the throwaway tags and releases afterwards.

- [ ] Record the results in the plan-2 outcome note.

---

### Task 8: Docs, the full gate, and the whole-branch review

**Contents:**
- The ADR 0032 plan-2 addendum and limits:
  - an app binary a test launches is not a test host;
  - the open-path cost (measured in the smoke);
  - the saved-by hint's owner-only scope.
- The AREA files.
- The release notes drafts: Mac `v0.42.0` and phone `v0.15.0`.
- CLAUDE.md text as text in the report.

**Gates:** full gate, core, phone, Release. Then the fable whole-branch review, given both ledgers, told to assume a Critical, with the seams:
- T1 × plan-1 recognition: a phone claim verified on the Mac;
- T3 × chain scoping;
- T5/T6 × Debug builds;
- the name rule × `sharesLabel`: *"Denver's iPhone"* is a device name, never a label.

- [ ] Fix wave → re-review.

---

### Task 9: Smoke on real hardware, then the paired release (controller + Denver)

**Smoke** on the dry-run builds or release candidates, on Denver's Mac and iPhone plus the second Apple ID:
1. His iPhone writes in his book and is filed under him silently, with the History line. The Settings line says *Recognised as Denver Trouton*.
2. **Playlist's 0ECB** becomes his *"Denver's iPhone"* under Denver Trouton after the phone's first write.
3. A second-Apple-ID device's first write: the sheet shows its claimed name and *"iCloud says … saved by"*.
4. That person's second device joins silently as them.
5. Forget, then their next device gets the sheet again, with a dated History line.
6. iCloud Keychain off on a device, then the sheet as today.
7. Measure the open-path time with recognition on a book with several devices.

**Release:**
1. Push main.
2. **Wait for CI green** (memory: CI before tag).
3. Cut `v0.42.0` and `phone-v0.15.0`, and push each tag by name.
4. Watch both runs. Record the release in memory.

---

## Order

Tasks 1, 2 and 3 in order, then 4 and 5, then 6. Task 7 (Denver) follows once 5 and 6 are merged to a branch that can be tagged; its dry-run tags come off that branch. Then Task 8, then Task 9.
