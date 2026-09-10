# Signed op log P2b — admission and the surfaces — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish P2 on P2a's substrate: the lossless digest (release blocker), the admission sheet and its memory, silent admission, People & Devices, History's two shapes, revocation and retirement, the claim and the two-roots exit, the phone's Settings row and Inbox byline, the hygiene P2a's reviews named, and the docs. Ends with the paired Mac + phone release binding.

**Architecture:** Every write into the registry beyond P2a's two (`ensureDeviceRecord`, `ensureRootIfEmpty`) goes through ONE new MaughamCore type, `RegistryAdmission` (admit, revoke, retire, claim/adopt), which signs with the caller's identity through `RegistryWriter.write` and invalidates the store's trust. Every decision a sheet or pane makes is a pure value tested without a window; the SwiftUI is thin. The digest becomes lossless FIRST, because every record written after it must verify on every later build. The phone reads records through MaughamCore and writes none.

**Tech Stack:** Swift 6, CryptoKit, Foundation, SwiftUI/AppKit (Mac), SwiftUI (phone), XCTest.

**Spec:** `docs/superpowers/specs/2026-09-09-signed-op-log-p2-people-and-admission-design.md` (§3 as amended 2026-09-10; §4 admission; §5 revocation/claim; §6 surfaces as amended by ruling C — banners for facts, dated entries for events; §8 P2b's list). Parent `2026-09-05-signed-op-log-design.md` §4.5–4.7, §4.11, §5. ADR 0032 (P2 section as P2a left it). P2a's plan for the built names: `docs/superpowers/plans/2026-09-09-signed-op-log-p2a-records-trust-pending.md`.

## Decisions made for this plan (controller, 2026-09-10; Denver can undo)

- **D-C (Denver):** History carries trust in two shapes — banners for facts that hold now, dated entries for events.
- **P1 — `.otherRoot` stays `.quarantined`** (spec §3) because this plan ships the claim and the two-roots exit in the same release; the mutual-quarantine of two pre-sync-rooted Macs (P2a review I3) gets an exit by **mutual adoption** (Task 8), never by overwriting a root's record.
- **P2 — adoption is the claim's primitive, and it is symmetric.** A `ClaimRecord{newRoot: me, adopted: [R]}` written by MY root means: R's chain is admitted under mine. On a keyless restore it is the whole claim (spec §5). Between two live roots it is "this is also me", written on each Mac from People & Devices; each Mac then verifies the other's chain. A root I adopted is drawn as *merged*, never as a claimant. A root that adopted ME without my adopting it stays a claimant (B1: nothing switches my root).
- **P3 — the lossless digest invalidates every record P2a's dev builds wrote.** Unreleased, so delete-and-recreate (tripwire 11): the smoke begins by removing `.maugham/people` and `.maugham/devices` from the dev projects and `registry-cache.json` from the dev variant's Application Support.
- **P4 — the same-authority reconcile rule** (P2a ledger): a cached record for fingerprint X is displaced only by a folder record signed by the same key that signed the cached one; otherwise the folder's is listed as `malformed(.signerChanged)` and the cache's stands. A root re-homes only through a claim record.
- **P5 — the revocation opId split lives in `OpLogStore.classifyTail` after `parse`**, where ops and line states are both in hand; the walk stays generic.

## Global Constraints

- **Every registry write goes through `RegistryAdmission`** (new) or P2a's `RegistryPresence`; both call `RegistryWriter.write`, which refuses a wrong signer. Census (Task 10): no other production caller of `RegistryWriter.write`/`writeUnchecked`/`restore`.
- **B1 holds everywhere:** nothing in this plan changes `joinedRoot` except `RegistryCache.join` from arm 3, and nothing ever switches it; `RegistryPresence.ensureRootIfEmpty`'s rules are untouched.
- **RULING-54:** a present-but-unreadable record/file throws with its `FileKind`; no `try?` on a trust reader (display readers may degrade to codes with the error named in Integrity).
- Tripwires 21 (no raw `maugham.*` notifications — every post through `MaughamEvent`), 33 (no press-then-wait; sheet decisions are values), 35, 36 (software keys only in `DeviceIdentity+Testing.swift`), 37, 38, 39 (trust closures from the table only), 40 (records through the writer only).
- Tripwire 19: anything the phone and Mac both do lives in MaughamCore (`shortCode`, the trust events derivation, the Settings row's facts).
- Every new pane/sheet follows tripwire 15 (`ContentUnavailableView` full-frame) and CLAUDE.md's Views guidance (extract `ViewModifier`s; `.frame(maxWidth: .infinity, maxHeight: .infinity)`).
- Gates per task: `swift test --parallel --package-path Packages/MaughamCore`, `./scripts/test.sh`, `./scripts/test.sh phone`; `./gen.sh` after adding files; `./scripts/test.sh full` before merge. Stage by explicit path; never `git add` a directory; never amend a reviewed commit; one implementer per shared file at a time.
- Branch `claude/signed-op-log-p2b-2026-09-10` off local `main` (`dd7b3019`). Merge to local `main`; Denver pushes and cuts the **paired** release (Mac + phone) — the first tag carrying P2a.

---

### Task 1: The lossless digest and the same-authority rule (release blocker)

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/RegistryCanonical.swift` (`bytes(of:)`, `digestHex(ofRecord:)`), `RegistryWriter.swift` (`write` signs the canonical bytes of the record's OBJECT form), `RegistryReader.swift` (`verify` digests the FILE bytes' object form; new `MalformedRecord.Reason.signerChanged(expected:found:)`), `RegistryCache.swift` (`reconcile` applies P4)
- Test: `RegistryRecordTests`, `RegistryReaderWriterTests`, `RegistryCacheTests`

**Contract:** canonical bytes = `JSONSerialization` of the record's JSON object with `sig` removed, `.sortedKeys` (and `.withoutEscapingSlashes` — pick one and pin it), produced identically from (a) an encoded record on write and (b) the parsed FILE bytes on read, so a field this build does not know survives into the digest. Dates stay the ISO strings `JSONLAppendStore.dateEncoding` writes (already strings in the JSON). Pin: a record with an injected unknown field (write the file, edit the JSON to add `"future": 1`, re-sign with the software key over the new canonical bytes) verifies; the decoded record drops the field but `RegistryCache` stores the FILE bytes (`rawBytes`) so a restore is byte-faithful. P4: `reconcile` compares the folder record's `sig.key` with the cached record's; a different signer → folder record listed `malformed(.signerChanged)`, cache stands (and is NOT restored over the folder — the folder file is present); same signer → folder wins (a legitimate re-sign). Pin both, plus: a root's self-signed record cannot be displaced by a root-signed admission of that fingerprint.

- [ ] Tests red → implement → green; the P2a `RegistryReaderWriterTests` all still pass (the digest change is internal to write+read).
- [ ] Commit `feat(registry): the digest is lossless — a record from a later build still verifies; a record changes hands only under the same key`.

---

### Task 2: Adoption, the join stamp, `shortCode` in Core

**Files:**
- Modify: `TrustTable.swift` (`resolve`: a root R with a `ClaimRecord{newRoot: myRoot, adopted: [R]}` written by my root is in my chain — `chain(under:)` unions R's chain; a `ClaimRecord{newRoot: R, adopted: [myRoot]}` that I did not reciprocate leaves R a claimant), `RegistryReader.swift` (claims verified: signed by `newRoot`'s key, `newRoot` must be a root), `RegistryCache.swift` (`join(root:for:)` stamps `joinedAt: Date`; `joinedAt(for:)`), `Registry` (`adopted(by root:) -> Set<String>`)
- Create: `Packages/MaughamCore/Sources/MaughamCore/DeviceCode.swift` (`DeviceCode.short(_ fingerprint:) -> String` — the one spelling; `HistoryPane.shortCode` becomes a call to it)
- Test: `TrustTableTests` (adopted root's chain admitted; unreciprocated adoption → claimant; adoption by a non-root → malformed), `RegistryCacheTests` (join stamp survives reload; write-once still), `DeviceCodeTests`

- [ ] Tests → implement → gates. Commit `feat(registry): a root I adopted is mine; the join remembers when; one device code`.

---

### Task 3: `RegistryAdmission` — admit, and the admission memory

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/RegistryAdmission.swift` (`admit(device: DeviceRecord|fingerprint, label: String, ownName: String, in: URL, by root: DeviceIdentity, cache:) throws -> PersonRecord` — writes the person record signed by MY root with `admittedBy = myRoot`, `role: "author"`; refuses if I am not a root (`RegistryAdmissionError.notARoot`) or if a person record for that fingerprint already exists under another root (→ that is adoption's job, Task 8); records `{fingerprint: {label, ownName, labelledAt}}` in `AdmissionMemory`), `AdmissionMemory.swift` (device-local `admission-memory.json` beside `registry-cache.json`, identity-scoped like the cache; `label(for fingerprint:)`, `remember`, `forget`)
- Modify: `OpLogStore.invalidateTrust()` is called by the caller after admit (Mac side, Task 4); `RegistryPresence` gains `admitRemembered(in:identities:cache:memory:)` — silent admission at open for every stranger whose fingerprint is in memory (spec B2), returning what it admitted
- Test: `RegistryAdmissionTests`, `AdmissionMemoryTests`, `RegistryPresenceTests` (silent admission at open; nothing admitted when memory is empty; a label typed that matches an existing label merges under it — same `label`, new person record)

- [ ] Tests → implement → gates. Commit `feat(registry): admission — the author's key names a device; the Mac remembers the label it gave`.

---

### Task 4: The admission sheet, and Admit… wired

**Files:**
- Create: `Maugham/Views/AdmissionSheet.swift` (SwiftUI sheet), `Maugham/Views/AdmissionDecision.swift` (the pure model: `AdmissionDecision(pending: [device fingerprint: count], registry, memory) -> [Request]` with `Request{fingerprint, ownName, code, waitingCount, proposedLabel, knownLabels}`; `outcome(for request, typedLabel) -> .admit(label) | .mergeUnder(label) | .notNow`)
- Modify: `Maugham/Views/ProjectWindow.swift` (present the sheet on open when `AdmissionDecision` is non-empty — one sheet per stranger, sequential — and when the presenter reports a new stranger's file; a `MaughamEvent` `.admissionRequested` scoped `.project`), `Maugham/Views/HistoryPane.swift` (`admitIsAvailable = true`; Admit… posts the event), `Maugham/Stores/DocumentStore.swift` (after admit: `RegistryAdmission.admit`, `opStore.invalidateTrust()` for every open document's store, `InboxStore` re-resolve, a History entry — Task 5's event)
- Test: `AdmissionDecisionTests` (windowless: proposed label = ownName; known labels listed; typed label matching an existing one → `.mergeUnder`; `.notNow` leaves pending), `AdmissionSheetTests` (drawn: fields, code, both buttons; never pressed-and-awaited), `DocumentStoreAdmissionTests` (admit → the held ops apply on the next read of the SAME store)

**Copy (spec §4.1):** title *<ownName> wants to write in <project>* — *N notes waiting*; label field; picker of known labels (*this is also…*); *Code XXXX is shown on the device's Settings too*; **Not now** / **Admit**.

- [ ] Tests → implement → gates. Commit `feat(admission): the sheet — one per stranger, the label is the author's, the held notes apply at once`.

---

### Task 5: History's two shapes — trust events, project scope

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/TrustEvents.swift` (`TrustEvent{date, kind, subject fingerprint, label?, by?}` with kinds admitted / silentlyAdmitted / revoked / retired / claimed / adopted / anotherClaimant / recordRestored; `TrustEvents.derive(registry:, cache:, for projectURL:) -> [TrustEvent]` — dates from `admittedAt`/`revokedAt`/`retiredAt`/`claimedAt`, the join from `joinedAt`, claimants from the cache; restored records from `reconcile`'s report persisted as a small dated list in the cache), `TrustEventSentence.swift` (one sentence per kind, `<label> (<ownName>)` only where they differ — shared with the phone)
- Modify: `Maugham/Views/HistoryPane.swift` (a **Project** section at the top of the timeline listing `TrustEvent`s dated, beside the document's own entries; the banners stay: pending count + Admit, *this Mac is on <label>'s chain*; the P2a `joinedChainNotice` becomes the banner AND a dated `adopted`/`joined` entry), `Maugham/Views/AREA.md`
- Test: `TrustEventsTests` (derivation over fixture registries; ordering; a re-admitted person shows both events), `TrustEventSentenceTests`, `HistoryPaneProvenanceNoticeTests` (the section drawn; banners unchanged)

- [ ] Tests → implement → gates. Commit `feat(history): trust is a project-scope log of dated events beside the standing banners`.

---

### Task 6: People & Devices

**Files:**
- Create: `Maugham/Views/PeopleAndDevicesSection.swift` (a section of `ProjectSettingsSheet`, after `firstReaderSection()`), `Maugham/Views/PeopleAndDevicesModel.swift` (pure: rows from `Registry` + `TrustTable` + `AdmissionMemory` + pending counts — pending requests first with Admit; one row per label with `(ownName)` when different, role read-only, admitted date, Revoke; devices nested: name, kind, actors held, added, Retire; the root marked *this Mac*; adopted roots as *merged*; claimants listed with *Merge: this is also me* (Task 8 wires it); records restored from cache flagged; the share sentence; **Forget this device** for a remembered-but-absent fingerprint)
- Modify: `Maugham/Views/ProjectSettingsSheet.swift` (+ the section), `Maugham/Views/AREA.md`
- Test: `PeopleAndDevicesModelTests` (every row kind from fixtures; an unreadable registry → the section shows the FileKind sentence, not empty rows), `PeopleAndDevicesSectionTests` (drawn; controls present; never pressed-and-awaited)

- [ ] Tests → implement → gates. Commit `feat(settings): People & Devices — who may write in this book, on which devices, and what is waiting`.

---

### Task 7: Revocation and retirement

**Files:**
- Modify: `RegistryAdmission.swift` (`revoke(person:, in:, by root:, highestOpIdSeen:)` re-signs the person record with `revokedAt/revokedBy/highestOpIdSeen`; `retire(device:, in:, by that device's author identity)` re-signs the device record with `retiredAt` — a device signs its own retirement), `OpLogStore.swift` (`classifyTail` after `parse`: for a `.revoked(person, highestOpIdSeen)` span, ops with opId > `highestOpIdSeen` → quarantined *after revocation*; ops with opId ≤ → quarantined *may be late sync or may be backdated*; the `.lines` record reason carries which; `applied` unchanged), `OpLogQuarantine.swift` (the two reasons' sentences), `TrustTable.swift` (a retired device's actor keys → `.revoked`-like quarantine *after retirement* for seals after `retiredAt`; before it, verified)
- Modify: `PeopleAndDevicesModel` (Revoke/Retire wired to the verbs; History entries via Task 5's events; the one sentence beside Revoke: *This stops Maugham applying what this device writes. To stop it writing at all, remove it from the iCloud share.*), History's *may be late sync* line offers **Apply** (the one other History control; applies that `.lines` record through the existing return path — check `ReturnOutcome.setAsideByProvenance` and route a revocation-late record differently, or state in the plan why it stays refused)
- Test: `RegistryAdmissionTests` (revoke/retire shapes; only a root revokes; only the device retires itself), `PendingLoadTests` (the opId split, both reasons), `TrustTableTests` (retired)

- [ ] Tests → implement → gates. Commit `feat(registry): revocation is the root's, retirement is the device's own; what arrives after is set aside with a reason that says which`.

---

### Task 8: The claim, and the two-roots exit

**Files:**
- Modify: `RegistryAdmission.swift` (`claim(adopting roots: [String], in:, by me: DeviceIdentity, cache:)`: writes my self-signed root record if I have none, then a `ClaimRecord{newRoot: me, adopted: roots}`; refuses if any adopted root has already adopted me (then it is a merge and the reciprocal write is the same call — document that symmetry))
- Create: `Maugham/Views/ClaimSheet.swift` + `ClaimDecision.swift` (pure: offered when `TrustTable.myRoot == nil` AND a registry exists AND I can write the folder — *This book's history was written by devices this Mac doesn't know (<names>). Is it yours?* **Claim** / **Not mine**; Not mine → B3 as today)
- Modify: `PeopleAndDevicesModel` (*Merge: this is also me* on a claimant row → `claim(adopting: [thatRoot])`; after it, the row reads *merged*), `ProjectWindow.swift` (present the claim sheet at open when `ClaimDecision` says so — once per project per launch), History (events `claimed`, `adopted`, `anotherClaimant` already derived in Task 5)
- Test: `ClaimDecisionTests`, `RegistryAdmissionTests` (claim writes root + claim record; a second Mac adopting back → both tables verify both chains — the I3 exit, end to end with two software roots), `ClaimSheetTests` (drawn)

- [ ] Tests → implement → gates. Commit `feat(registry): the claim — a keyless Mac adopts the history it holds; two roots merge by adopting each other`.

---

### Task 9: The phone — Settings row, Inbox byline, per-write memo

**Files:**
- Modify: `MaughamPhone/Settings/SettingsView.swift` (a **This device** section: code (`DeviceCode.short`), per current project — *Denver on Denver's MacBook's chain since 9 Sep* / *Not yet admitted — the Mac will ask*; no control), `MaughamPhone/Storage/PhoneDeviceRecord.swift` (an in-process memo per (project, actors) so a capture costs no registry read when nothing changed), `MaughamPhone/AREA.md`
- Modify: `Maugham/Views/InboxPane.swift` + `InboxStore` (row byline: *from <label>* for an admitted device, *from <ownName> (not yet admitted)* for a stranger — the row's `deviceId` resolved through the registry once per refresh)
- Test: `MaughamPhoneTests` (the row's facts from a fixture registry + cache — pure), `InboxPaneTests` (byline composition, windowless), `PhoneDeviceRecordTests` (memo: second write reads nothing)

- [ ] Tests → implement → gates (phone gate is the one that matters here). Commit `feat(phone): this device's code and chain in Settings; the inbox says who a capture is from`.

---

### Task 10: Hygiene the reviews named, and the censuses

**Files:**
- Modify: `RegistryCache.swift` (`shared` lazy: construct the identity fingerprint on first USE, not first access — or make `TrustResolution` consult `cached(for:)` only when a registry or a cache entry might exist; measure a no-registry open before/after), `OpLogStore.classifySegment` (the unsettled segment's inner seals walked through the TABLE, not keylessly — pin that this device's own inner seals settle `verified` and a stranger's `pending`; ADR 0032 §6 amended), `TrustTable.rootSource` (People & Devices reads it for the *this Mac* / *joined* / *adopted* marker — or delete it), the P2a `ProjectStore+Annotations`/`+Tasks` hoisted resolves moved off-main where the method allows (else documented)
- Modify: `MaughamTests/TripwireGrepTests.swift` + `MaughamPhoneTests/TripwirePhoneGrepTest.swift`: census — every production caller of `RegistryWriter.write`/`writeUnchecked`/`restore` is in `RegistryPresence`, `RegistryAdmission` or `RegistryCache` (planted offender + control); `admitIsAvailable`-style flags: none left `false` in production
- Test: as named; `PendingLoadTests` for the segment change

- [ ] Commit `fix(registry): the shared cache is lazy; a stranger's rotated history is held like its tail; the registry's three writers are a census`.

---

### Task 11: Docs, guides, release notes

**Files:**
- Modify: `docs/adr/0032-the-signed-op-log.md` (P2 section complete: admission, memory, two shapes, revocation, claim/adoption, the lossless digest, the same-authority rule; the release coupling sentence updated to "P2 released whole"), `Maugham/OpLog/AREA.md` (P2b section; the two writers), `Maugham/Views/AREA.md`, `Maugham/Stores/AREA.md`, `MaughamPhone/AREA.md`, `docs/guide/` (a new `people-and-devices.md` topic + History's guide gains the trust section + Settings guide; `HelpTopicIndex` picks it up — check `docs/guide/` naming and `get_help`), `docs/roadmap.md` (P2 complete, paired release pending), `docs/product.md`/`docs/problem-map.md` where they describe collaboration, the P2 spec status line, `CLAUDE.md` (tripwire 41 for the writers census; the OpLog row), `docs/release-notes/` drafts for the Mac and phone versions (Denver names the numbers), the P1 handoff's smoke script extended with: wipe the dev registries first (P3), open a project → root written → phone files pending → sheet → Admit → notes apply; second Mac scenario if available; revoke; claim on a copied project.
- [ ] `./scripts/test.sh full`. Commit `docs(oplog): P2 — people and admission, recorded; the smoke; release notes drafted`.

---

## Whole-branch review

Seams: the digest change against every P2a reader/writer test (nothing else may have depended on the old bytes); B1 under adoption (adopting never switches `joinedRoot`; an unreciprocated adoption is a claimant); the two-roots exit end to end on two software roots; revocation's opId split against real ULIDs; every registry write through the two writers (census); the phone reads and never writes; RULING-54 at every new reader; tripwire 33 across every sheet test; the release coupling sentences now say P2 ships whole. Then `./scripts/test.sh full`, merge to local `main`, unpushed. Denver smokes with the P3 wipe first, then pushes and cuts the paired release.
