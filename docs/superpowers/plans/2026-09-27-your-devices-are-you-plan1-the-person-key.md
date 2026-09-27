# Your devices are you — plan 1: the person key, the claim, and the Mac's recognition — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A device signed into the same Apple ID as a book's root is recognised by the root's Mac and filed under the root without an admission sheet. A known collaborator's further devices join silently as her. Everyone else gets today's sheet, pre-filled with the names their device claims.

**Architecture:**
- A P256 **person key** lives in iCloud Keychain behind a `PersonKeyStore` protocol, which is in-memory in the gate.
- Each device's own device record gains an optional **person claim** signed by that key.
- The root's person record, and each admitted person's, gains an optional **linked person key**, written only by the root's Mac.
- One pure **recognition** function decides own / known / ask.
- Silent admissions go through the existing `RegistryAdmission.admit(… silently: true …)` door and leave the existing History event.

**Tech Stack:** Swift 6, CryptoKit, Security (keychain), XCTest. MaughamCore + the Mac target. **The phone, the iCloud saved-by hint, entitlements and signing, the smoke and the release are plan 2**, written against this plan's built code (rule 11).

**Spec:** `docs/superpowers/specs/2026-09-27-your-devices-are-you-design.md`. **Where this plan and the spec differ, stop and say so — do not pick.**

## How to read this plan

It gives contracts and the failure each must not have, with signatures **verified at file+line on 2026-09-27 against main `0c3d7cd7`**. It gives no function bodies. If a cited line has moved, find the symbol. If a cited signature is WRONG, stop and report it: that is a plan defect.

**The disable experiment is required on every negative assertion**: remove the REAL guard, watch the test fail, restore it, and put the output in your report on a line containing `EXPERIMENT`. **State every rule in both directions.** Derive "every site" lists with a grep census, never from this plan.

## Global Constraints

- **Behaviour-neutral where there is no person key.** No keychain item, a claim that fails to verify, or a book with no claims all lead to today's behaviour. Every existing suite passes untouched except tests a task names as flipping.
- **Nothing here changes what anybody may WRITE.** Permits, the partition, the timeline and the load are untouched. Recognition only decides who is *admitted*, and admits with the permit the spec's table names.
- **Tripwires bind:**
  - 19: one Core implementation for both surfaces.
  - 35/36: device keys stay the enclave's; `PersonKey` is the ONE new software-key site, by name.
  - 39: trust from `TrustTable`.
  - 40/41: registry writes only through `RegistryWriter`, by `RegistryPresence` / `RegistryAdmission` / `RegistryCache`.
  - 42: `RegistryCanonical` alone decides what a signature covers.
  - 43: permits are read from the timeline.
  - 47: no rung comparisons outside the permit layer.
- **Records stay readable by v0.41 builds.** New fields are optional, omitted when unset (the `PersonRecord.scope` pattern, `RegistryRecord.swift:157–168`), and never change an existing record's bytes.
- **Never create a real synchronizable keychain item in the gate or on the developer's account.** Tests use the in-memory store. The keychain implementation is exercised only by the plan-2 dry run.
- **Process:**
  - Branch `claude/your-devices-are-you-p1` off main. Sequential implementers in the main checkout.
  - Commit with `git commit -- <paths>`. Never amend. Run `./gen.sh` in the same step as any file add/delete.
  - Fixtures only via `TestTemp.root` / `TestTemp.workerRoot`. No press- or click-then-wait tests (tripwire 33). Tests asserting *verified* inject the test signer (tripwire 36).
  - Gates: `./scripts/test.sh core` (never a bare `swift test`), `./scripts/test.sh`, `./scripts/test.sh phone` for any Core change. Run `./scripts/test.sh full` plus a Release build on Tasks 5, 7 and 9.
  - `df -h /System/Volumes/Data` before a full gate. `pgrep -x xcodebuild`, never `-f`. grep here is ugrep `-I`, so use `command grep -a`.
  - **END YOUR TURN WITH THE HAND-BACK.**
- **Models:** opus implementers. Task reviewers are sonnet, except Tasks 3, 5 and 6, which get opus (the claim, the decision and the silent admission). The whole-branch review is fable.

## Review Focus

1. **A claim copied from Denver's phone record into a stranger's device record.** It must not verify for the stranger, because the claim names its own device (Task 3).
2. **A collaborator on a read-write share writes a device record whose claim is signed by a key she generated and names "Denver Trouton".** Her device must get the sheet, never silent admission as Denver (Task 5).
3. **A person key already linked to Sam appears in a claim on a device that says it is Denver's.** Nobody may be linked twice, and no silent admission may happen (Tasks 4 and 5).
4. **A v0.41 build rewrites a device record carrying a claim** (`ensureDeviceRecord` builds a fresh `DeviceRecord`, `RegistryPresence.swift:99–103`). The claim is dropped, and the next new-build open writes it back. Nothing refuses, and nothing is admitted twice (Tasks 3 and 6).
5. **Recognition on a Mac that is not the book's root.** It admits nothing and links nothing, exactly as `admitRemembered` requires `holdsARootRecord` (Task 6).

## Rulings this plan makes (confirm at plan review)

- **PK-1 — the claim lives inside the device record, not in a record of its own.** The device key signs the device record, which covers the claim. The person key signs the claim's canonical form, `{device, personKey, name}`. *Cost if wrong:* a v0.41 build that rewrites the device record drops the claim until the next new-build open (Review Focus 4).
- **PK-2 — "own device" admits with the ROOT's own standing, so author of the whole book.** "Known person" admits with that person's current permit read from the timeline. *Cost if wrong:* none known. The spec's table says exactly this.
- **PK-3 — linking needs an already-admitted device.** A root links a person key to a person record only when a device ALREADY admitted under that record shows a verifying claim with that key. The root's own record links to the root Mac's own key at open. *Cost if wrong:* a collaborator whose only device predates her person key needs one device to open the book on the new build before her other devices go silent.
- **PK-4 — the History entry reuses `.silentlyAdmitted`.** It gains an optional reason (`recognised`), so the sentence reads *"joined as <label> — recognised by their Apple ID"*. It is not a new event kind, because older builds must read the event. The implementer verifies whether `PermitEvent.Kind` decodes an unknown kind losslessly, and uses a new kind only if it does. *Cost if wrong:* a wording-only difference.

## File structure

New:

| file | one responsibility |
|---|---|
| `Packages/MaughamCore/Sources/MaughamCore/PersonKey.swift` | the person key: the `PersonKeyStore` protocol, the keychain store, the in-memory store, find-or-create, sign |
| `Packages/MaughamCore/Sources/MaughamCore/RegistryPersonClaim.swift` | the claim: make, canonical digest (through `RegistryCanonical`), verify. Named `Registry*` so the canonical census picks it up automatically |
| `Packages/MaughamCore/Sources/MaughamCore/TrustRecognition.swift` | the one pure recognition decision (named `Trust*` for the same census) |

Everything else is a modification, named per task.

---

### Task 1: The spike (controller + Denver, throwaway — not a subagent)

**Question:**
1. Can a Developer-ID-signed Mac app and the iOS app share ONE synchronizable keychain item (`kSecAttrSynchronizable`, a team-prefixed `keychain-access-groups` entry)?
2. What does each need: entitlement, provisioning profile, and App ID capability?
3. Does an ad-hoc-signed Debug build get the keychain at all? (We expect not. If so, Debug builds run with the in-memory store or no store, and that must be decided here.)
4. On a real shared iCloud Drive folder, does `URLResourceValues.ubiquitousSharedItemMostRecentEditorNameComponents` return the collaborator's name for a file she saved?

**Output:** a note, `docs/superpowers/notes/2026-09-27-person-key-spike.md`, with answers, the exact entitlement keys, the portal steps Denver performed, and a go/no-go for the saved-by hint. Nothing built here is kept.

- [ ] Write a throwaway two-target probe (Mac and iOS) that writes, then reads, one synchronizable generic-password item in the shared group. Denver signs and runs it with his team. Record the results.
- [ ] Check the saved-by metadata on a folder shared with the second Apple ID. Record the results.
- [ ] Commit the note. **If the keychain cannot be shared across the two apps, STOP**: the spec's approach falls, and Denver rules before Task 2.

---

### Task 2: The person key (Core)

**Files:** new `PersonKey.swift`. `MaughamTests/TripwireGrepTests.swift`: `test_noSoftwarePrivateKeyInProduction` at :7346, allow-list :7357, predicate `isSoftwarePrivateKeyLine` :7332. Core tests.

**Contract:**
- `public protocol PersonKeyStore: Sendable` with an item shape of `{privateKey raw, publicKey, name}`. It has find, create (only if absent) and set-name.
- `KeychainPersonKeyStore`: synchronizable generic password, one fixed service and account, and the access group Task 1 names, injected rather than hard-coded here. It returns "unavailable" on any keychain error. It never throws into a caller's open path.
- `InMemoryPersonKeyStore`: the gate's store.
- `public struct PersonKey`: `fingerprint` (SHA256 hex of the public key's x963 representation, the same shape as device fingerprints; verify how `DeviceIdentity.fingerprint` is computed and match it), `name`, and `sign(_ digestHex:) -> OpLogChain.Credentials`. Reuse the credentials shape at `OpLogChain.swift:280`, and add a public entry beside `OpLogChain.credentials(signing:identity:)` (:296, internal) rather than a second format.
- `PersonKey.findOrCreate(in store:, seedName:)`:
  - When there is no item, creates one with `seedName`.
  - When the item's name is empty and `seedName` is non-empty, fills the name in.
  - Never overwrites a non-empty name.
- **Tripwire 36:** the allow-list gains `PersonKey.swift` by name, with a rationale comment in the test. The self-check plants a software key in a file NOT named `PersonKey.swift` and it still fires.

- [ ] Write the tests first (in-memory: create, find, seed-only-when-empty, sign and verify with `OpLogChain.credentialsVerify` :316, and "unavailable" reports rather than throws). Watch them go red. Implement. Run the tripwire and its self-check. Core gate. Commit.

---

### Task 3: The claim (Core)

**Files:** new `RegistryPersonClaim.swift`. `RegistryRecord.swift`: `DeviceRecord` at :101, init :116. `RegistryPresence.swift`: `ensureDeviceRecord` at :63 (`nonisolated public static func ensureDeviceRecord(in projectURL: URL, identities: LocalIdentities, name: String, kind: DeviceKind, now: () -> Date = { Date() }, presenter: NSFilePresenter? = nil) throws -> URL?`), and its equality short-circuit at :92–96. `RegistryReader.swift` `verify` :666.

**Contract:**
- `DeviceRecord` gains `personClaim: PersonClaim?` (optional, omitted when nil; the `scope` pattern). `PersonClaim` is `{personKey: String (fingerprint), personPub: String, name: String, sig: Credentials}`.
- **The claim's signed content** is the canonical form of `{device: <this record's device>, personKey, personPub, name}`, computed through `RegistryCanonical` alone (tripwire 42). There is NO new `JSONEncoder` / `SHA256` in this file; the census proves it. A claim verifies for a device record only if its `device` equals that record's `device` (Review Focus 1).
- `ensureDeviceRecord` gains `personClaim: PersonClaim? = nil`:
  - it writes the claim into the record;
  - the "already matches" short-circuit also compares the claim, so a record missing its claim is rewritten;
  - a record whose claim is the same is not.
  - The Mac's existing caller passes nothing in this task (Task 6 wires it).
- **The reader verifies the claim separately from the record.** An invalid claim leaves the device record VALID and marks the claim unverified. A new field or computed accessor on the loaded registry carries "verified claim or nil" per device. It never lands in `malformed` (Review Focus 4's sibling: an old or bad claim must not un-admit a device).

- [ ] Tests first:
  - a round trip;
  - a claim copied into another device's record → unverified, record valid;
  - a claim signed by a different key than `personPub` → unverified;
  - a tampered name → unverified;
  - an old-shape record with no claim → unchanged bytes and signature;
  - `ensureDeviceRecord` rewrites only on a claim change.

  EXPERIMENT per negative. Core, fast and phone gates. Commit.

---

### Task 4: The linked person key (Core)

**Files:** `RegistryRecord.swift`: `PersonRecord` :149, init :182, the `scope` pattern :157–168. `RegistryAdmission.swift`: `rename` :1260 (the `RegistryWriter.resign` precedent), `records(sharingLabelWith:in:)` :726. `RegistryWriter.resign` :142.

**Contract:**
- `PersonRecord` gains `personKey: String?` (the fingerprint; optional, omitted when nil).
- `RegistryAdmission.linkPersonKey(person:to key:in:by root:cache:now:presenter:) -> PersonRecord`:
  - **Root only.** It uses the same "the admitting root, or a root for itself" rule `rename` uses.
  - It re-signs through `RegistryWriter.resign`, so unknown fields survive.
  - It REFUSES if the key is already linked to another person record in the verified registry (Review Focus 3).
  - Linking the same key again is a no-op.
- `RegistryAdmission.forgetPersonKey(person:in:by:…) -> PersonRecord`: the inverse. It removes the field, root only.
- Writers stay the three files (tripwire 41's census stays green without an allow-list change).

- [ ] Tests first: link; relink no-op; refuse when linked elsewhere; refuse for a non-root; forget; an unknown later field survives a link. EXPERIMENT per negative. Core gate. Commit.

---

### Task 5: The recognition decision (Core, pure)

**Files:** new `TrustRecognition.swift`. `TrustTable.swift`: `verdict(forSealKey:)` :513, `sharesLabel` :1021. `Registry.holdsARootRecord` (`RegistryReader.swift` :334).

**Contract:**
- `public enum Recognition { case ownDevice(root: PersonRecord), knownPerson(PersonRecord), ask(hint: ClaimHint?) }`. `ClaimHint` is `{personName, deviceName, linkedElsewhere: Bool}`.
- `static func recognise(device: DeviceRecord, verifiedClaim: PersonClaim?, registry: Registry, thisRoot: String) -> Recognition`, a pure function:
  - a verified claim whose `personKey` equals the root record's linked key → `.ownDevice`;
  - equal to exactly one other admitted, unrevoked person record's linked key → `.knownPerson`;
  - linked to MORE than one record, or to a revoked one → `.ask` with `linkedElsewhere` where it applies;
  - no verified claim, or an unknown key → `.ask` with the claimed names as hint (nil hint with no claim);
  - a device that already has a person record → not asked here (the caller filters).
- The decision never reads a permit rung. It returns records, and the caller admits with the timeline's permit.

- [ ] Table tests for every row, in both directions, including Review Focus 2 (a self-generated key naming "Denver Trouton" → `.ask`) and 3. EXPERIMENT per negative row. **Full gate + Release build.** Commit.

---

### Task 6: The Mac recognises (Mac + Core presence)

**Files:**
- `RegistryPresence.swift`: `admitRemembered` :589 (`nonisolated public static func admitRemembered(in projectURL: URL, identities: LocalIdentities, cache: RegistryCache, memory: AdmissionMemory, mark: (String) throws -> PermitMark = { _ in .nothingApplied }, now: () -> Date = { Date() }, presenter: NSFilePresenter? = nil) throws -> [PersonRecord]`) and its `admit(... silently: true, within: registry ...)` call at :630.
- `RegistryAdmission.admit` internal :341 and public :276.
- `DocumentStore.swift`: open at :242; `ensureDeviceRecord` call :301; `ensureRootIfEmpty` :304; `admitRemembered` :330. `DocumentStore+Registry.swift`: the mid-session `admitRemembered` :672/:681.
- `PermitEvent.swift` Kind :53. `TrustEventSentence.swift` `.silentlyAdmitted` :37.

**Contract:**
- **The Mac makes its claim at open.** `DocumentStore.open` finds or creates the person key (seed name `DocumentStore.thisWritersName`, :240) through an injected `PersonKeyStore`:
  - the production store is the keychain store;
  - Debug and gate builds use whatever Task 1 decided;
  - a store reporting "unavailable" yields no claim.
  
  It passes the claim to `ensureDeviceRecord`.
- **The root links its own key.** At open, a Mac holding its own root record links its person key to that record if it is unlinked (PK-3).
- **`RegistryPresence.admitRecognised(...)`**, beside `admitRemembered`, with the same root-only guard (Review Focus 5):
  - For every device with no person record and a verified claim, it asks `TrustRecognition.recognise`. `.ownDevice` and `.knownPerson` admit through `RegistryAdmission.admit(... silently: true ...)` with the recognised record's label and the timeline's current permit for that person (PK-2).
  - For every ADMITTED device whose person record has no linked key and whose verified claim names an unlinked key, it links it (PK-3).
- **Callers.** It runs at open right after `admitRemembered`, and mid-session wherever `admitRemembered` runs (derive the callers by grep).
- **History.**
  - The event records the recognition reason per PK-4.
  - `TrustEventSentence` renders *"<device> joined as <label> — recognised by their Apple ID"*.
  - For the root's own devices the pane's first-person wording applies (read how the existing sentences say "you").
- **Other callers.** `AdmissionDecision.refreshedRequests` (`Maugham/Views/AdmissionDecision.swift:400`) already calls `admitRemembered` when anything is remembered. It now also triggers the recognition pass, so a recognised device never reaches the sheet.

- [ ] Tests first, windowless, on real temp books with test signers:
  - Denver's phone device (a claim with the root's key) is admitted silently with no request;
  - Sam's second device joins as Sam with Sam's current permit (demote Sam first and check the new device gets the demoted permit);
  - a stranger with a self-generated claim is still requested;
  - a non-root Mac admits nothing;
  - an already-admitted device's claim links its key;
  - a v0.41-style rewrite that drops the claim, then reopen → the claim is restored, and nothing is admitted twice.
  
  EXPERIMENT per negative. Fast gate. Commit.

---

### Task 7: The sheet and People & Devices (Mac surfaces)

**Files:**
- `AdmissionDecision.swift`: `AdmissionRequest` :10, `requests` :175, `proposal(ownName:knownLabels:)` :225.
- `AdmissionSheet.swift`: `typedLabel` seed :88, `reseeded` :166.
- `PeopleAndDevicesModel.swift` / `PeopleAndDevicesSection.swift` (v0.41.1's grouping).

**Contract:**
- `AdmissionRequest` gains `hint: ClaimHint?`.
- **Pre-fill.** The proposed label is the claim's person name where one exists and does not collide with a known label under a *different* person key. Otherwise today's proposal stands.
- **The sheet's lines.**
  - It shows *"It calls itself <device name>, belonging to <person name>."*, marked as the device's own claim.
  - With `linkedElsewhere`, it says the key is already linked to someone else.
  - No iCloud saved-by line yet (plan 2).
- **People & Devices.**
  - A person whose record carries a linked key shows *"Recognised on every device signed into this person's Apple ID."* with **Forget this person key** (root only; hidden elsewhere, per the pane's hide-don't-disable rule).
  - Forget calls `RegistryAdmission.forgetPersonKey` through a `DocumentStore` verb, then `invalidateTrust`.
- **Pins.** Model pins, windowless (tripwire 33).

- [ ] Tests first. EXPERIMENT per negative. **Full gate + Release build.** Commit.

---

### Task 8: Censuses

**Contract:**
- `PersonKeyStore` / `KeychainPersonKeyStore` are constructed in ONE production file per surface. Plan 1 has the Mac's store-injection point; the phone's is plan 2 and is anticipated by name.
- `PersonClaim` is VERIFIED in `RegistryPersonClaim.swift` only.
- `TrustRecognition.recognise` has a named array of production callers.
- `linkPersonKey` / `forgetPersonKey` are called from `RegistryPresence` / `DocumentStore` only.
- Every census gets a planted-offender control (a census beats a warning).

- [ ] Censuses and controls. EXPERIMENT per control. Fast gate. Commit.

---

### Task 9: Docs and the gate

**Files:**
- ADR 0032: a "your devices are you" addendum covering PK-1..4 and the limits:
  - a v0.41 rewrite drops a claim until the next new-build open;
  - a person key is proof of an Apple ID, not of a person;
  - Forget plus per-device revoke answers a compromised Apple ID.
- `Maugham/OpLog/AREA.md`; `Maugham/Views/AREA.md`; `docs/guide/people-and-devices.md` (what ships in plan 1 only: recognition works once devices on the new build have opened the book).
- CLAUDE.md text for the tripwire 36 allow-list change and the censuses, as text in the report.

- [ ] Docs. **Full gate, Core, phone, Release.** Commit.

---

## Order

Task 1 (Denver, portal), then Tasks 2 through 9 in order. Run the full gate after Tasks 5, 7 and 9.

## Whole-branch review — seams to name

- **T3×T6:** `ensureDeviceRecord`'s short-circuit and the claim — does every open rewrite a record, and so churn signatures?
- **T4×T5:** a linked key on a REVOKED record.
- **T6 × `admitRemembered`:** both silent paths admitting the same device on one open.
- **T6 × the timeline:** "known person" admitted with the permit Sam had WHEN? It must be now, not her first record's.
- **T2 × Debug builds:** does the dev app ever create a real synchronizable item on Denver's Apple ID?

**The premise check:** grep the diff for *unreachable / never / always / cannot* and test each.
