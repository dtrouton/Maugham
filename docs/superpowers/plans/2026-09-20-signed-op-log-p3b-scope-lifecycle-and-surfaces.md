# Signed op log P3b — scope's lifecycle and the Mac's surfaces — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the permit P3a enforces a way to be GIVEN and SEEN on the Mac — the role/scope controls, the three load questions, every held or lost thing drawn somewhere — and close what the P3a build left open: the unsigned door (by snapshot), the schema gate at the first narrowing, the sweep that can refuse for ever, the sheet offering keys it must not.

**Architecture:** Every decision stays a pure MaughamCore value; every surface is a pure model + a thin SwiftUI view reading it (the P2b shape: `PeopleAndDevicesModel`, `AdmissionDecision`, `HistoryPane`'s static sentence functions). `RegistryAdmission` stays the only authority that writes a record or an event; the pane reaches it through `DocumentStore+Registry`. No second trust table, no second permission table, no surface comparing a permit rung (tripwires 39, 44, 47).

**Tech Stack:** Swift 6, SwiftUI/AppKit, CryptoKit, XCTest. MaughamCore + the Mac target. **The phone is P3c** — it links Core, so its gate runs, but no phone source changes here.

**Spec:** `docs/superpowers/specs/2026-09-19-signed-op-log-p3-roles-scope-collaborator-design.md` — §4.5's question, all of §7, and its *As built in P3a* note. Rulings: `docs/superpowers/notes/2026-09-20-p3b-session-handoff.md` (**"RULED 2026-09-20 (second session)"** — the unsigned door, `claimedAt`, the census). Carries: `docs/superpowers/notes/2026-09-17-signed-op-log-p3-handoff.md` from *Carries into P3b* to *Open question*. Evidence: `docs/superpowers/notes/2026-09-20-signed-op-log-p3a-build-ledger.md`. **Where this plan, the spec and a ruling differ, stop and say so — do not pick.**

## How to read this plan

Contracts, the failure each must not have, and **signatures verified at file+line on 2026-09-20 against main `6f36876d`** — no function bodies (memory: *a plan's code is a liability*). If a cited line has moved, find the symbol. If a cited signature is WRONG, stop and report: that is a plan defect.

**The disable experiment is required on every negative assertion** (*is held*, *is not offered*, *writes nothing*, *refuses*): remove the guard, watch the test fail, restore it, put the failing output in your report. Wrap the experiment in a line containing the literal word `EXPERIMENT` so the controller's marker grep finds one you forgot.

**Every trust rule here is stated in both directions.** If you find yourself building one half, the other half is in the task. **Stop if a ruling looks half-stated against the code.** **Census what production actually writes before wiring enforcement** — list it in your report; stop if any honest path would be held or refused.

**"Unreachable until P3c" is a claim to test.** P3b creates narrowed books. Ask of every guard: does THIS plan's shipped code create the state?

## Global Constraints

- **Behaviour-neutral for every un-narrowed book.** No narrowing permit ⇒ P2/P3a behaviour exactly ⇒ every existing suite passes UNTOUCHED. A pre-P3b test that needs an edit to pass is a stop-and-report (fixture-premise fixes need the controller's ruling).
- Tripwires 38–48 all bind. In particular: 39 (trust closures from `TrustTable`), 40/41 (registry paths in `RegistryWriter`; writers are `RegistryPresence`/`RegistryAdmission`/`RegistryCache` only — **no view, model or store file writes a record**), 42 (`RegistryCanonical` alone; every new record field is a STRING or a collection of strings), 43 (the check reads the timeline), 44/47 (**no surface compares a permit rung** — a surface asks `Permit.allows` or reads a DISPLAY value the model derived), 45 (partition call sites are a named array — a new site edits the array in the same commit), 46.
- RULING-54: a present-but-unreadable record throws with its `FileKind`; no `try?` on a trust reader.
- An unrecognised `role`/`scope`/event `kind`/`OpKind.unknown` is PENDING, never set aside.
- **Pending is never worded as admission unless the holder is a stranger** (`Registry.isStrangerDevice`, RegistryReader.swift:406). Three kinds of held line now exist — a stranger's, a permit-pending line from an ADMITTED person, an unsigned line after the snapshot — and each has its own sentence.
- **The AI actor is never given a product name**: *the assistant*.
- Tripwire 33: no test presses a mounted control and waits. Pin the decision on the pure model; assert only that the control is drawn.
- Tripwire 15 for any new empty state; tripwire 21 for any event (`MaughamEvent` only); help/docs describe what ships.
- Fixtures register their roots and remove them in `tearDown`. Reuse `RegistryAdmissionTests`', `PermitLoadTests`', `DocumentWaitingTests`' (`narrow(...)`) and `PendingLoadTests`' helpers; every test asserting *verified* injects the test signer (tripwire 36).
- **Process:** branch `claude/signed-op-log-p3b-2026-09-20` off `main`. `git commit -- <paths>`; never amend a reviewed commit; `./gen.sh` in the same step as any file add/delete; `pgrep -x xcodebuild`, never `-f`; no wait loop with `xcodebuild` in its argv; **never read a gate's exit status through a pipe — redirect to a file and `echo $?`**. Gates per task: `swift test --parallel --package-path Packages/MaughamCore`, `./scripts/test.sh`, `./scripts/test.sh phone` for any Core change; `./scripts/test.sh full` on Tasks 2, 4, 10 and before merge. **END YOUR TURN WITH THE HAND-BACK** (report file + final message), always.
- **Models:** opus for every task. Task reviewers: sonnet (opus for Tasks 1, 2, 6), told to check the RULING as well as the code. Whole-branch review: the most capable model, given the P3a ledger and the seams named at the end of this plan.

## File structure

New (Core unless a path says otherwise):

| file | one responsibility |
|---|---|
| `UnsignedSnapshot.swift` | the snapshot value: which narrowing event governs, and *is this unattributable line inside it* |
| `HeldLines.swift` | the ONE classification of a held line's holder: stranger · admitted-but-permit-pending · unsigned — and the sentence family for each |
| `Maugham/Views/PermitControl.swift` | the role control + piece picker, shared by the sheet and the pane (a DISPLAY choice → a `Permit`, built once) |
| `Maugham/Views/LoadQuestions.swift` | pure model for the three load questions |
| `Maugham/Views/SetAsideDoor.swift` | pure model: which set-aside records offer Send to Inbox, and their re-derived sentence |
| `MaughamTests/Performance/NarrowedBookCostTests.swift` | the kept, env-gated W5 measurement |
| `scripts/census-load-bursts.sh` + `Packages/MaughamCore/Sources/…/LoadBurstCensus.swift` | the kept release census (ruling 3) |

Modified: `PermitEvent.swift`, `RegistryAdmission.swift`, `TrustTable.swift`, `OpLogChain.swift`, `OpLogStore.swift`, `PermitPartition.swift`, `AnnotationOwnership.swift`, `Permit.swift`, `SynthesisSource.swift`, `ProjectManifest.swift`, `ForeignStreamWatch.swift`, `OpLogDeviceState.swift`, `TrustEvents.swift`, `TrustEventSentence.swift`, `OpLogQuarantine.swift`, `JSONLAppendStore.swift`; Mac: `DocumentStore+Registry.swift`, `DocumentStore.swift`, `InboxStore.swift`, `Document+Load.swift`, `Document.swift`, `AdmissionDecision.swift`, `AdmissionSheet.swift`, `AdmissionModifier.swift`, `PeopleAndDevicesModel.swift`, `PeopleAndDevicesConfirmation.swift`, `PeopleAndDevicesSection.swift`, `ProjectSettingsSheet.swift`, `HistoryPane.swift`, `InboxPane.swift`, `EditorHost.swift`, `InspectorView.swift`, `PieceInspector.swift`, `OutlineTable.swift`; `TripwireGrepTests.swift`; docs.

---

### Task 1: The unsigned snapshot — the record, the sweep, and who governs

**Files:** Create `UnsignedSnapshot.swift`. Modify `PermitEvent.swift`, `RegistryAdmission.swift`, `OpLogStore.swift`, `TrustTable.swift`, `DocumentStore+Registry.swift`. Tests: `UnsignedSnapshotTests` (new), `PermitEventTests`, `RegistryAdmissionTests`.

**Verified facts:**
- `PermitEvent` fields PermitEvent.swift:143–161; `mark: [String: StreamMark]` :156; init :163 (defaults for role/scope/pieces/mark). Synthesized Codable; unknown fields survive because verification is over the FILE's bytes (`RegistryCanonical.canonicalBytes(ofJSON:)` :76).
- `RegistryAdmission.writeEvent` is private, RegistryAdmission.swift:741; `carriesForward` :820. `changePermit` :503; `admit` :233 / internal :296 (readmission is decided INSIDE admit at :377–380 — there is no `readmit` verb).
- The position sweep: `OpLogStore.seenPositions(ofDeviceIds:in:trust:expecting:)` OpLogStore.swift:875; private `positions(…lastLine:)` :941; private `verificationForPositions` :1171. Sweeps hardcode `state: nil` so a mark derives only from shared bytes (ledger L176) — **keep that**.
- A file is *unattributable* exactly when `OpLogChain.judgingWhatNoSealHasClosed` (OpLogChain.swift:1024) reaches arm 3 (:1052–1053): no last seal key that answers a state, and `PermitMark.keyNaming(_:in:)` (PermitMark.swift:183) names no key. `TrustVerdict.isUnattributable` OpLogChain.swift:1177.
- `PermitTimeline.narrows` PermitTimeline.swift:214; `TrustTable.hasNarrowingPermits` TrustTable.swift:799. Narrowing is STICKY — it reads every entry of every timeline.
- Store side: `DocumentStore.changePermit(person:to:)` DocumentStore+Registry.swift:133, private mark-carrying overload :157, `sweptPermitMark(forPerson:)` :146, `seenMarkOrRefuse(forPerson:)` :610, `expectedStreams` :665.

**Contract:**
- `PermitEvent` gains `unsigned: [String: StreamMark]?` — **omitted from the encoding while nil**, so every P3a-era event's bytes and digest are unchanged (pin against a checked-in P3a event fixture). Strings only.
- A **narrowing event** = one whose installed permit is not book-author (ask `Permit(event:)` / `Permit.bookAuthor` INSIDE the permit layer — tripwire 47; add the predicate to `Permit.swift` or `PermitTimeline.swift`, not to `RegistryAdmission`). **Every narrowing event the verbs write carries `unsigned`**: a `PermitMark`-shaped map over every stream in the book that is unattributable at that moment (ops, translation and inbox streams; the legacy unsuffixed `<docId>.jsonl` included under its P3a stream key). A non-narrowing event (a book-author admission, a revocation, a retirement) carries none.
- `OpLogStore.unattributablePositions(in:trust:) throws -> PermitMark` — sibling of `seenPositions`, same listing, same `classify`, `state: nil`; it **refuses exactly as the other sweeps do** (`ReadError.unlistableStreamDirectory` :575, a present-but-unreadable file) and the verb then writes nothing. *A short snapshot is the reach-back this ruling exists to prevent*: an omitted stream would judge AFTER and its whole history would be held.
- `UnsignedSnapshot` (pure): built from `Registry.events`; **the governing snapshot is the EARLIEST narrowing event's, by event id order within one root's chain, and across adopted roots the earliest by the event's own id ordering** (ruling 1). `func side(streamKey:fileIsSegmentWithDigest:lines:) -> PermitMark.Judgement` delegates to `PermitMark.judge` (PermitMark.swift:288) — do not restate the old/new rule.
- `TrustTable` exposes `unsignedSnapshot: UnsignedSnapshot?` — nil iff `!hasNarrowingPermits`. **A narrowed book whose governing event carries NO `unsigned` field** (written by a P3a-era dev build — only on this developer's Mac, but pin it) ⇒ the snapshot is EMPTY ⇒ everything unattributable is *after*. State this in the doc comment; tripwire 11 says do not migrate.
- The verbs: `RegistryAdmission.changePermit` and `admit` take `unsigned: PermitMark?` (defaulted nil) and refuse with a new `RegistryAdmissionError` case if a NARROWING permit arrives without one — the door, not call-site discipline. `DocumentStore` computes it beside the existing swept mark, off the main actor where the existing sweep is.

**Both directions:** narrowing ⇒ snapshot present and complete or the verb refuses; not narrowing ⇒ no field, bytes unchanged, no sweep cost (pin: an admission performs zero extra directory listings).

**Must not:** put the narrowing predicate outside the permit layer; compute the snapshot from device memory; let the second narrowing event's snapshot supersede the first.

- [ ] Red: P3a fixture bytes unchanged; narrowing `changePermit`/`admit` writes `unsigned` covering a legacy file, a never-sealed file and an unsigned device's chained-unsealed stream; a book-author admission writes none; an unreadable stream ⇒ refused, NOTHING written (**disable experiment**); a narrowing call with `unsigned: nil` ⇒ refused (**disable**); earliest-governs with two events and with two adopted roots (**disable**: make latest win, watch it fail).
- [ ] Implement. Core + Mac + phone gates. Commit `feat(oplog): the first narrowing snapshots the book's unsigned streams — chain positions, earliest governs`.

**Produces:** `PermitEvent.unsigned`, `UnsignedSnapshot`, `TrustTable.unsignedSnapshot`, `OpLogStore.unattributablePositions(in:trust:)`, the verbs' `unsigned:` parameter, `RegistryAdmissionError` case for a narrowing without a snapshot.

---

### Task 2: The unsigned door closes — held after the snapshot, honoured before it

**Files:** Create `HeldLines.swift`. Modify `OpLogChain.swift` (arm 3), `OpLogStore.swift`, `JSONLAppendStore.swift`, `TranslationStore.swift`, `AnnotationOwnership.swift`, `PermitPartition.swift` (only if `judgesAnything`/`couldJudge` need the snapshot). Tests: `UnsignedDoorTests` (new, Core), `AnnotationOwnershipTests`, `PermitLoadTests`, `TripwireGrepTests`.

**Verified facts:**
- Arm 3 returns nil ⇒ lines keep their walked state (`.legacy`/`.unsealed`/`.unsignedHistory`, `Line.State` OpLogChain.swift:405–446) ⇒ applied. `keyOfAnUnsealedFile` is threaded at OpLogStore.swift:1189, :1448, :1723, TranslationStore.swift:259, JSONLAppendStore.swift:131/:210.
- Holding is `OpLogChain.repartitioned(_:refusing:holding:)` OpLogChain.swift:1376 → `.pending(device:)` :1389. `pendingByDevice(of:)` ~:654.
- `AnnotationOwnership.unplaced(_:trust:)` AnnotationOwnership.swift:146 is today `looksLikeADeviceId` ⇒ `!trust.hasNarrowingPermits` — the blanket, backward-reaching rule ruling 1 replaces. `mayAmend` :95; `AnnotationAmendments.judged(by:permits:class:)` :204. Amendments are judged AS OF THE LINE through `AmendmentPermits` (OpLogPermitContext.swift:112).
- The WRITE side of this device's own file is `chainedAppend` with the sanctioned keyless `trusted:` closure — **byte-for-byte unchanged by this task** (ledger L186).

**Contract:**
- In a book with `trust.unsignedSnapshot != nil`, an unattributable file's lines are judged by `UnsignedSnapshot.side`: **old ⇒ exactly today's state and application; new ⇒ `.pending`**, under a holder string `HeldLines` recognises as *unsigned* (never a fingerprint, never parseable as one). Held, never `refusing` — no `.lines` record, no `QuarantineCause`.
- **This device's OWN unattributable file is never held on this device** (an enclave-less Mac applies its own lines; typing never fails). Decide "own" the way the load already does for `.mine`/keyless (`TrustResolution.keyless(mine:)`), not by filename alone — stop and report if only the filename can say it.
- `AnnotationOwnership`: an amendment op from an unplaced production-shaped device id is **honoured iff its line is inside the snapshot**, not honoured after it; legacy/hostname/sentinel strings keep today's answer. The line's side must reach the rule the way `AmendmentPermits` carries a governing permit per op id — extend that carrier; do not add a second.
- `HeldLines.Holder`: `.stranger(fingerprint)` · `.permitPending(person)` · `.unsigned(stream device slug)` with ONE classifier `HeldLines.holder(of pendingDevice: String, registry:)`, and the three sentence families. `Registry.strangersAwaitingAdmission` (RegistryReader.swift:412) and every admission-worded count must exclude the other two — extend the one predicate, don't add a filter per surface.
- Every partition call site that gains a judgment edits `TripwireGrepTests.partitionCallSites` in the same commit; if arm 3's judging lands in `OpLogChain.verify` rather than the partition, say so in the report and add the census that it is spelled once.

**Both directions, each a paired test:** un-narrowed book ⇒ all unsigned applied (P1); narrowed, line inside snapshot ⇒ applied / amendment honoured; narrowed, line after ⇒ held / amendment not honoured; own file on its own device ⇒ applied either side; a forged legacy-shaped file created after the snapshot ⇒ wholly held; a snapshot-listed segment REWRITTEN (digest differs) ⇒ wholly held; a fresh Mac and the root reach the same answer from the same bytes.

**Census first:** list every production writer that can produce an unattributable line on a signed Mac in a rooted book (keyless fallback paths, a failed enclave, the legacy unsuffixed file's writers if any survive). Stop if an honest signed Mac would hold its own words.

**Must not:** reach back (the cliff this replaces); set aside; widen `chainedAppend`; hold anything in a registerless or un-narrowed book.

- [ ] Red tests above, **disable experiment on every held/not-honoured assertion**; the P3a `AnnotationOwnership.unplaced` tests move only where ruling 1 changes their premise — list each in the report.
- [ ] Implement. Full gate. Commit `feat(oplog): an unsigned line after the first narrowing is held, and nothing before it moves`.

**Produces:** `HeldLines.Holder`, `HeldLines.holder(of:registry:)`, `HeldLines.sentence(…)`; the closed door.

---

### Task 3: The schema gate, the labelled load bursts, and two censuses

**Files:** Modify `ProjectManifest.swift`, `SynthesisSource.swift`, `Permit.swift`, `Document+Load.swift`, `Document.swift`, `DocumentStore+Registry.swift`, `ProjectStore` (the manifest save door). Create `LoadBurstCensus.swift`, `scripts/census-load-bursts.sh`. Tests: `ProjectManifestTests`, `SynthesisSourceTests`, `PermitTableTests`, `TripwireGrepTests`, `LoadBurstCensusTests`.

**Verified facts:**
- `ProjectManifest.currentSchemaVersion = 8` ProjectManifest.swift:95; stamped on EVERY save via the init default :341 — there is no lazy bump. Gate: `decodeGuardingSchema` :330 throws `SchemaTooNewError` :303; the sentence is `ProjectStoreError`'s at ProjectStore.swift:24. `SynthesisSource.swift:37` carries *adding a case ⇒ bump `currentSchemaVersion`*.
- The three unlabelled emissions: Document+Load.swift:528–532 (recovery fold, non-empty), :545–550 (ordering-only fold), Document.swift:1265–1273 (the flush carrying the anchor splice, explicit `provenance: nil`). `Op.Provenance.synthesisSource` Op.swift:38.
- `Permit.isALoadEmission` Permit.swift:616 (bootstrap, taskCreate); `actorJudging(_:signedBy:)` :602 — widens `.maugham` too (handoff: narrow to assistant/translator).
- Nothing under `Maugham/MCP/` names a task-op emitter. Production emitters: `appendTaskOpInternal` Document+Tasks.swift:226, `createPaneTask` :298, `setTaskStatus` :377, `setTaskPriority` :415, `archiveTask` :536, `createProjectPaneTask` ProjectStore+Tasks.swift:36, `appendProjectTaskOp` :104. Census shape to copy: `TripwireGrepTests.test_theIsCoachCensusFiresOnAPlantedOffender` :670–691.

**Contract:**
- `SynthesisSource` gains cases for the load's own bursts (suggested raw values `pending_recovery`, `anchor_splice`; one case per distinguishable cause) ⇒ `currentSchemaVersion` becomes **9**, with the bump-ladder comment extended. All three sites write it. Site 3 writes it ONLY when the flushed changes are the anchor splice's — a writer's ordinary burst through the same function stays unlabelled; stop and report if the two cannot be told apart at that line.
- **The label changes no judgment, in either direction:** on an author-signed line it is provenance only; an assistant-/translator-signed `typingBurst` stays REFUSED whatever `synthesisSource` says (`isALoadEmission` is NOT widened). Both pinned, the second with a disable experiment.
- `Permit.actorJudging` narrows its waiver to `.assistant`/`.translator`; a `.maugham`-signed `taskCreate` is judged as `.maugham`'s (refused). Paired test.
- **The gate at the first narrowing (MUST):** because the stamp rides on a manifest SAVE, a narrowing verb in `DocumentStore+Registry` must make the ON-DISK manifest read `schemaVersion >= 9` **before** the narrowing event is written, through the store's existing manifest save door (tripwire 14's neighbours — do not hand-write JSON). Order: gate, then event, then record. A crash after the gate and before the event leaves a gated, un-narrowed book — harmless; the reverse order is the defect (a v0.40 Mac applying a reviewer's refused text and re-asserting it under its own book-author key). If the gate write fails, the verb refuses and writes no event. **A non-narrowing event forces no manifest write** (pin: admission leaves the manifest bytes untouched).
- Census A: no file under `Maugham/MCP` names any production task-op emitter above nor `kind: .task` — planted offender + comment control.
- Census B (kept, ruling 3): `LoadBurstCensus.scan(projectURL:) -> [Hit]` — read-only, decodes tails AND `.mzseg`, reports every `typingBurst` whose stream slug names a non-author actor; `scripts/census-load-bursts.sh <dir>…` walks project folders and prints hits or *none*. It changes nothing on disk and decides nothing.

- [ ] Red tests; **disable**: write the event before the gate and watch the ordering test fail; drop the refuse-direction guard.
- [ ] Implement; run the script over `~/Documents` and this Mac's recents and put the output in the report. Core + Mac + phone. Commit `feat(oplog): the first narrowing gates old builds out; the load's own bursts say what they are`.

**Produces:** `currentSchemaVersion == 9`, the new `SynthesisSource` cases, the gate-then-event order, both censuses.

---

### Task 4: The admission sheet — a role, some pieces, and the keys it never offers

**Files:** Create `Maugham/Views/PermitControl.swift`. Modify `AdmissionDecision.swift`, `AdmissionSheet.swift`, `AdmissionModifier.swift`, `DocumentStore.swift` (`admit` :1069), `DocumentStore+Registry.swift` (`heldLinesByDevice` :735). Tests: `AdmissionDecisionTests`, `AdmissionSheetTests`, `PermitControlTests`.

**Verified facts:**
- `AdmissionDecision.requests(pending:registry:memory:myRoot:)` AdmissionDecision.swift:95; its only filter is `registry.isStrangerDevice` :111. `AdmissionRequest` :10 carries `fingerprint` (*the sealing key itself where no record names it*), `code`, `waitingCount` — **no slug**. `refreshedRequests` :154; outcome :197; write path `AdmissionModifier.admit` :247.
- A non-author actor key with no device record is only recognisable by its STREAM's slug: `DeviceIdentity.actor(ofDeviceId:signingWith:)` DeviceIdentity.swift:120 (checked; hex run is 13–16 chars because `DeviceSlug.make` truncates at 24 — never assume 16), `claimedActor(ofDeviceId:)` :138. Contested keys are ABSENT from `Registry.actorKeyOwners` (RegistryReader.swift:226; precedent `InboxByline.swift:71`); `TrustTable.aDeviceRecordNames(_:)` TrustTable.swift:605.
- `RegistryAdmission.admit` takes `role:scope:pieces:` (:233) and mints `.readmitted` itself for a revoked person (:377).
- Spec §7.1: role control + piece picker; share keys pre-fill name and suggested role; a known machine arrives with its label and **only the role asked, once per book**; the writer's own devices never see the sheet.

**Contract:**
- The held-lines union carries enough to classify: extend `heldLinesByDevice` (or add a sibling) so each held holder comes with the stream slug(s) it was held under. `AdmissionDecision.requests` then offers a holder **only if** `HeldLines.holder` says `.stranger` AND the key is not a non-author actor key (by the CHECKED slug parse) AND no device record merely names it as a disputed key. Non-author ⇒ *waits for its device record* (silent in the sheet; one line in People & Devices, Task 5). Contested ⇒ never a request; its own sentence (Task 5). Unsigned and permit-pending ⇒ never a request.
- **Both directions:** an author-key stranger is still offered exactly as today (every existing `AdmissionDecisionTests` case untouched); once the device record arrives and names an author key, the person is offered by THAT key and the held actor lines ride in with them.
- `PermitControl`: three display choices (*Reviewer* · *Author of some pieces* · *Author of the whole book*) + a piece picker over the manifest's manuscript documents for the middle one; produces a `Permit` via `Permit.parse`/the wire accessors (`wireRole`/`wireScope`/`wirePieces` Permit.swift:157–174). It **builds** a permit; it never compares one (tripwire 47 — if a census fires, the spelling is wrong, not the census).
- The sheet passes role/scope/pieces through `DocumentStore.admit`; a NARROWING admission takes Task 1's snapshot and Task 3's gate through the same store verb — the sheet knows nothing of either. A narrowing admission that is the book's FIRST narrowing shows Task 5's first-narrowing sentence before Commit.
- Silent admission (`admitRemembered`) stays book-author and asks nothing — *only the role asked once per book* means: a remembered label pre-fills, and the sheet still opens for a device this BOOK has not admitted when its person is not this writer. Pin where the line falls using `AdmissionMemory`'s existing own-device knowledge; stop if own-vs-other is not decidable from what the sheet has.

- [ ] Red: the three never-offered classes (**disable each**); author-key stranger unchanged; reviewer admission writes a `.admitted` event with reviewer permit + `unsigned` + gate; re-admission of a revoked P2 author as reviewer keeps her chapters (the P3a pin `test_aP2AuthorLetBackInAsAReviewerKeepsTheChaptersSheWrote` must still pass, now driven from the store verb).
- [ ] Implement. Full gate. Commit `feat(admission): the sheet asks what somebody may write, and never offers a key that is not a person's`.

**Produces:** `PermitControl`, the slug-carrying held-lines union, the filtered `requests`.

---

### Task 5: People & Devices — roles, the both-directions confirmation, and the lines that had no row

**Files:** Modify `PeopleAndDevicesModel.swift`, `PeopleAndDevicesConfirmation.swift`, `PeopleAndDevicesSection.swift`, `ProjectSettingsSheet.swift`, `DocumentStore+Registry.swift`. Tests: `PeopleAndDevicesModelTests`, `…ConfirmationTests`, `…SectionTests`.

**Verified facts:**
- `PeopleAndDevicesModel.Person` :215 already has `role: String` :231 (display-only; the ONE sanctioned non-permit reader — tripwire 43's allow-list). `Device` :166, `Unverifiable` :327 (`canRestore` :353), `PendingRequest` :146. Confirmation verbs PeopleAndDevicesConfirmation.swift:29–33, factories :122–:209, `Alternate` carries a second button. Store calls are wired in ProjectSettingsSheet.swift:550–639.
- `DocumentStore.changePermit(everyRecordOf:to:)` DocumentStore+Registry.swift:211 (pre-flights every record's sweep, skips revoked siblings, includes retired, throws `PermitChangePartlyApplied` :764). Nothing presses it.
- `RegistryAdmission.recordBehindEvents(person:in:)` RegistryAdmission.swift:656 — zero production callers. `RegistryAdmissionError.cannotChangeARoot` :117; `historyUnreadable(name:act:)` :85.
- `DeviceStanding` DeviceStanding.swift:24 (`ownRecordUnverified` :84). Audit F4: `RegistryCache.reconcile` :612 short-circuits on a cold cache (:619) so a tampered SOLE root record has `canRestore == false` and no way back in-app.

**Contract:**
- Each person row shows role and pieces (titles from the manifest; an unknown id draws as *a piece this Mac can't find*). Changing either opens `PeopleAndDevicesConfirmation` with a new verb `.changePermit` whose message **states both directions** from spec §5 — demotion/piece leaves: *What Sam already wrote in "Chapter 4" stays. Anything she writes there from now on is set aside.*; promotion/piece joins: *…what was set aside while it wasn't hers stays set aside.* The sentence is a pure function of (old permit, new permit) and lives with the confirmation factories; test every transition pair.
- Commit calls **`changePermit(everyRecordOf:to:)`** — never the single-record verb (tripwire-style census: `changePermit(person:` has no caller under `Maugham/Views`). `PermitChangePartlyApplied` and every refusal surface as the pane's `notice`, in the error's own sentence. The root's own row offers no control (and the verb would refuse).
- **First narrowing:** when the book has no narrowing permit yet, the confirmation (and the sheet's, Task 4) adds: what it does to older versions of Maugham (*they will no longer open this book*), and — iff the book has an unsigned device/stream — what it does to that Mac (*its writing from now on waits on the other Macs until it is sent to the Inbox; nothing it has already written changes*).
- **Unsigned line (#8):** a device/stream with no attributable key gets a row line saying it is unsigned and, before any narrowing, what narrowing WILL do; after, what it does. Source: Task 1's sweep result, not a guess from the enclave of THIS Mac alone.
- New rows/lines, each from the pure model: a non-author key waiting for its device record; a **contested key** (*two devices say this key is theirs; its writing waits*); `recordBehindEvents` ⇒ *this person's record is a step behind the book's history* with **Re-sign** (the root only; through a `RegistryAdmission` verb — add one if `changePermit`'s retry arm is not callable for it; tripwire 41 stays three files); pending new-piece questions listed here as well as raised at load (Task 7 owns the model).
- **C2:** a nameless device never shows its code as its own name (`ownName == code` suppressed).
- **F4:** a record that doesn't verify, isn't restorable, and is THIS device's own record offers **Write this Mac's record again** through `RegistryPresence` (a device signing its own record is its authority); anybody else's says which Mac must open the book to repair it. **Both directions:** never offered for another device's record; never overwrites a record that verifies. Stop if `RegistryPresence` cannot do it without a fourth writer.

- [ ] Red on the pure model + confirmation; views asserted drawn only. **Disable**: single-record verb, root row control, F4 on a foreign record.
- [ ] Implement. Gates. Commit `feat(people): the pane gives and changes a permit, and says both directions before it does`.

**Produces:** `.changePermit` confirmation, the row lines, the first-narrowing sentences (one function, shared with Task 4).

---

### Task 6: A loss the writer has been shown — the drawer, and the sweep's way out

**Files:** Modify `ForeignStreamWatch.swift`, `OpLogDeviceState.swift`, `OpLogStore.swift`, `DocumentStore+Registry.swift`, `HistoryPane.swift`, `PeopleAndDevicesModel.swift`. Tests: `ForeignStreamWatchTests`, `OpLogStorePositionsTests`, `HistoryPaneTests`.

**Verified facts:**
- `ForeignStreamWatch.loss(remembered:found:)` :205 is the one verdict; `settle` :243 keeps a memory frozen while a loss stands and still re-spells `rotated`/`missing` locally (fold them into `loss` or a sibling here). `OpLogDeviceState.truncations(inRoot:)` :415, `StreamTruncation` :151, `ForeignStreamUpdate.clearsTruncation`. `OpLogStore.TruncatedStream.sentence` OpLogStore.swift:1226; `IntegrityReport.truncatedStreams` ProjectIntegrity.swift:32 — no drawer.
- Sweeps throw `ReadError.streamMissingFromSweep(streamKey:)` :581; the verbs map it to `RegistryAdmissionError.historyUnreadable(name:act:)`.

**Contract:**
- History draws each standing truncation (its `sentence`, orange, pointing at Backup) with **Acknowledge** — *I know this history is gone*. Acknowledgement is device-local state beside the truncation (`OpLogDeviceState`), pruned with its root.
- **The escape, both directions:** an ACKNOWLEDGED loss stops being expected — a sweep passes `expecting:` without that digest/head, so `revoke`/`changePermit`/`admit` for that person proceed. An UNacknowledged loss refuses exactly as today (a mid-sync file must never shorten a mark silently). If the bytes RETURN, the truncation and its acknowledgement clear and the stream is expected again. **Stated cost, to go in the confirmation's text:** history that returns AFTER a verb was pressed over an acknowledged loss is judged as written after that change.
- The refusal names the way out: `historyUnreadable`'s surface in the pane says *…History shows what is missing* rather than dead-ending.
- The acknowledgement never enters a mark and never leaves this device — marks still derive from shared bytes only (pin: two Macs, one acknowledged, same bytes ⇒ same mark for every stream both can read).

- [ ] Red: refuse-for-ever reproduced first (remember a digest, delete the segment, `changePermit` refuses); acknowledged ⇒ proceeds; unacknowledged ⇒ refuses (**disable**); bytes return ⇒ expected again; `settle` single-sourced.
- [ ] Implement. Gates. Commit `feat(oplog): a loss the writer has been shown stops being expected — the sweep can no longer refuse for ever`.

**Produces:** acknowledged truncations, the History drawer, the single `loss` spelling.

---

### Task 7: The load's questions, and the held lines that had no voice

**Files:** Create `Maugham/Views/LoadQuestions.swift`. Modify `AdmissionModifier.swift` (or a sibling modifier on the same load path), `HistoryPane.swift`, `InboxPane.swift`, `EditorHost.swift`, `DocumentStore.swift` (`announcePendingHistory` :1000), `DocumentStore+Registry.swift`. Tests: `LoadQuestionsTests`, `HistoryPaneTests`, `EditorHostWaitingTests`.

**Verified facts:**
- New-piece pending is `PermitPartition` arm :227–231 (`UnownedPiece.nobodyHasWrittenItsText` :56), holder = `trust.person(forSealKey:)`; `OpLogStore.unownedPiece(forDocId:in:trust:)` OpLogPermitContext.swift:348.
- `announcePendingHistory` narrows by `pendingStrangersByDevice` and posts `MaughamEvent.postAdmissionRequested`. History's pending sentence ~HistoryPane.swift:495–504; `InboxPane.pendingNotice(counts:names:)` :89.
- Her Mac: `DocumentLoadError.waitingForPiece(docId:from:)` Document+Waiting.swift:30, drawn as the editor placeholder EditorHost.swift:460 (no notice, by design).
- Retire's mark can OVERCOUNT (ledger L163); a retired device's ≤99-op unsealed tail is applied elsewhere and quarantined once sealed (handoff carry 12).

**Contract:**
- `LoadQuestions` (pure) derives, from the held-lines union + registry + manifest: (1) admissions — unchanged, Task 4's list; (2) **new piece**: *Sam started "X" — is it hers?* → **Hers** = `changePermit(everyRecordOf:to:)` adding the piece to her scope (a `scopeChanged` event); **Not now** = nothing written, still pending, asked again only from People & Devices (never nagged per load). *Never "yours"* — there is no verb that applies her text as the opening of the root's piece; (3) **re-admitting a retired device**: *N paragraphs were written on it while retired — bring them in?*, copy stating N may include writing from just before it was retired; **Not now** leaves them pending.
- **Ruling (controller's, both directions, surface to Denver at finish):** a retired device's unsealed tail stays as P3a built it — applied as pre-retirement work; lines it writes AFTER retirement are held pending once sealed, and the re-admission question is their one way in. Cost if wrong: text visible on other Macs can withdraw when that device next seals — the question's copy says so.
- **Permit-pending lines get a sentence of their own** in History and the Inbox (`HeldLines.sentence`): an admitted person's held lines never read *waiting to be admitted*; unsigned-after-snapshot lines read as unsigned and point at Send to Inbox (Task 8).
- Her Mac: where the wait is for a piece not yet in her scope, the placeholder reads *Waiting for [root's label] to add this piece to yours.* — one more arm on the existing outcome, no notice, nothing read from the `.md` (tripwire 20).
- An event whose person record has not arrived draws a History row (*…this Mac hasn't received their record yet*) instead of nothing.

- [ ] Red on `LoadQuestions` for every arm incl. *Not now* writing nothing (**disable**), an admitted person's lines never appearing in an admission-worded count (**disable**), the overcount copy present.
- [ ] Implement. Gates. Commit `feat(people): the three questions a load can raise, and a voice for every line that waits`.

**Produces:** `LoadQuestions`, the sentences, the placeholder arm.

---

### Task 8: The way back in — Send to Inbox, and sentences that tell the truth

**Files:** Create `Maugham/Views/SetAsideDoor.swift`. Modify `InboxStore.swift`, `HistoryPane.swift` (`SetAsideRecordsDisclosure` :1627), `InboxPane.swift` (`setAsideNotice(changeCount:)` :69), `OpLogQuarantine.swift`. Tests: `SetAsideDoorTests`, `InboxStoreTests`, `InboxPaneTests`, `HistoryPaneTests`.

**Verified facts:**
- `QuarantineRecord` OpLogQuarantine.swift:15 — `reason: String` :19 frozen at quarantine time; `Kind.lines` :36; `records(forDocId:in:)` :512; `setAsideChanges` :599. `QuarantineCause.notPermitted(person:what:afterMark:actor:)` OpLogChain.swift:624; sentence `JSONLAppendStore.notPermittedReason` :572.
- `InboxStore` has NO public create — only private `append` :393 / `appendThrowing` :404 (monotonic `writtenAt`, one seal per capture). Inbox rows pass through the partition as `.inboxRow`.
- The disclosure lists names only (`setAsideRecordNames` HistoryPane.swift:145, built :1001–1003).

**Contract:**
- `InboxStore` gains ONE public creation verb for recovered text, signed by this device's AUTHOR actor like any capture, carrying an attribution line naming the original writer (text in the entry body/metadata the existing `InboxEntry` can hold — **no new wire field without stopping to report**; tripwire 17's monotonic `writtenAt` and the per-capture seal preserved).
- `SetAsideDoor` (pure): a `.lines` record offers **Send to Inbox** iff its refused lines include manuscript text (decode with `PermitPartition.writtenOp` + `Deriver.appliesToManuscript` — tripwire 44: ask, never restate); each refused paragraph's text becomes one capture. Unsigned-held lines (Task 2) get the same door from their History sentence. **Nothing touches the op log; the record stays held** and is marked sent so the door is not offered twice (device-local, beside the set-aside acknowledgement).
- **Both directions:** the door never offers a record of dispositions/tasks/annotations only; it never applies anything — the words come back only through the writer's own hand as the writer's own ops (constitution: *AI is never the author* — the assistant's refused text comes back attributed *the assistant on Sam's Mac*, as a capture like any other).
- **C1:** `InboxPane.setAsideNotice` becomes reason-aware, sharing History's by-reason derivation (one function, two callers). **C16:** a set-aside record's displayed sentence is re-derived from the record's current cause where the bytes allow, falling back to the frozen `reason`. **C13:** reproduce the blank-window report (History → *Set-aside records* disclosure) on a project with ≥1 `.lines` record BEFORE touching the disclosure; record what you saw; fix only a cause you observed.

- [ ] Red on the pure model and the store verb; **disable**: door on a non-text record; second offer after sending.
- [ ] Implement. Gates. Commit `feat(history): set-aside words can be sent to the Inbox — the one way back is the writer's own hand`.

**Produces:** `InboxStore`'s recovered-text verb, `SetAsideDoor`.

---

### Task 9: Whose piece is whose

**Files:** Modify `InspectorView.swift`, `PieceInspector.swift`, `OutlineTable.swift`, a small pure `PieceWriters` helper beside `PeopleAndDevicesModel`. Tests: `PieceWritersTests`, `InspectorViewTests`, `ProjectAltitudePaneTests`.

**Verified facts:** `InspectorView` `Section("Document")` :22, row shape `LabeledContent("Title", value:)` :23; `OutlineTable` columns :45–:73, row data off `store` (:74); `setPass` `[weak store]` at InspectorView.swift:165 and `PieceInspector`'s copy (C15).

**Contract:**
- `PieceWriters` (pure): docId → the label(s) whose CURRENT scope names the piece, from the registry's timelines (`timeline.current` — display only; asked via a Core accessor that returns labels, so no view touches a rung). A one-author book ⇒ empty ⇒ **nothing drawn anywhere**: no Inspector row, no Writer column (both directions pinned). **The tree is untouched** (parent spec §5).
- Inspector: *Written by Sam*; altitude table: a **Writer** column only when `PieceWriters` is non-empty for the book.
- Resolution happens off the main actor and is cached per registry read — tripwire 4 (no per-row trust resolution).
- **C15:** decide and apply to both `setPass` copies — hold `store` strongly for the duration of the write; pin with a test that the write lands when the view's is the only reference.

- [ ] Red; implement; gates. Commit `feat(shell): a co-written book says whose piece is whose — and a one-author book says nothing`.

---

### Task 10: History's dated truth, the open question, the measurement, and the doc sweep

**Files:** Modify `TrustEvents.swift`, `TrustEventSentence.swift`, `HistoryPane.swift` (`symbol(for:)` :608), `DocumentStore` debug-level log for `AutomationNotPermitted`; create `NarrowedBookCostTests.swift`; tests `TrustEventsTests`, `PermitMarkTests`, `AmendmentPermitsTests`, `TripwireGrepTests`; docs: ADR 0032 (P3b addendum + limits rewritten), `Maugham/OpLog/AREA.md`, `Maugham/Views/AREA.md`, `CLAUDE.md` (tripwire rows + OpLog cell), `docs/guide/people-and-devices.md` + `docs/guide/index.json`, roadmap (*Signed structure*: per-adoption date, per-actor possession proofs), the P3 handoff's OUTCOME for P3c.

**Verified facts:** `.adopted` rows are dated `claim.claimedAt` TrustEvents.swift:292–301; device-memory dated rows exist (`.joined` :304–308 via `RegistryCache.joinedAt(for:)` :362). `TrustEvent.Kind` :25 has no unsigned case; `symbol(for:)` is `default:`-less. C11: `silentlyAdmitted` has a writer since P3a. W5's probe was deleted; template gate `MAUGHAM_PERF_FIXTURE` (`OpLogGrowthBaselineTests.swift:25`).

**Contract:**
- **Ruling 2:** an `.adopted` row is dated by this device's own remembered date where it saw the adoption (device-local, in `RegistryCache` beside `joinedAt`), else drawn UNDATED; `.claimed` keeps `claimedAt`; the P2 test `test_adoptingASecondRootKeepsTheDayTheBookWasClaimed` untouched.
- **#8's History half:** one dated *unsigned* entry per project per unsigned device (new `TrustEvent.Kind` + symbol + sentence). **C11:** a silent admission reads *without asking*.
- **S4(c) answered by test:** two roots that adopted each other, each writing a permit event with a mark computed from its own folder copy ⇒ both Macs judge every line identically from the same bytes; and Task 1's earliest-governs holds across them. If it does NOT hold, stop — that is a design finding, not a test to bend.
- Pin the two unexercised arms (handoff carry 13): a replayed MARKED line as the first line of a forged tail ⇒ following lines NEW; `AmendmentPermits`' restrictiveness tie-break, driven through a fixture P3b can now produce (two governing permits for one amendment op).
- `NarrowedBookCostTests`: kept, env-gated, medians of 7, the four W5 measures × {admissions-only, one reviewer, one reviewer + snapshot with an unsigned stream}. Report numbers beside P3a's (23.8 → 39.2 ms `Document.load`); state whether the machine was quiet (`pgrep -x xcodebuild`). AREA.md and the ADR agree on the wording (*about one 16 ms frame*).
- Censuses with planted offenders + controls: the narrowing predicate and `UnsignedSnapshot` are spelled in the permit layer only; `changePermit(person:` has no caller under `Maugham/Views`; `HeldLines.holder` is the one holder classifier; Task 3's two. Update `partitionCallSites`, `manuscriptClassifierCallers` and every allow-list this branch moved — **count the arrays, not prose**.
- Docs describe what SHIPS; sweep every now-false claim (*no surface*, *nothing presses it*, *the unsigned door is open*, *held silently*).

- [ ] Implement; **full gate**; Commit(s) `feat(history)…`, `test(oplog)…`, `docs(oplog): P3b — …`.

---

## Whole-branch review — seams to name to the reviewer

Give the reviewer the P3a ledger and this list: **T1×T2** (the snapshot's stream keys vs the keys arm 3 judges under; rotation after the snapshot) · **T1×T3** (gate → event → record order under every narrowing verb incl. the sheet's admission and `changePermit(everyRecordOf:)`'s multi-record loop — gate once, first) · **T2×T4** (an unsigned holder must never become an admission request) · **T2×T8** (unsigned-held lines reach the inbox door; nothing else applies them) · **T4×T5** (one first-narrowing sentence, two callers) · **T6×T1** (an acknowledged loss vs the snapshot sweep's refusal — does the escape cover `unattributablePositions` too?) · **T7×T5** (*Not now* state lives in one place) · **T3×everything** (schema 9: does any P3a-era test fixture pin 8?) · **the premise check**: which states does P3b's own shipped code create that a guard calls unreachable?
