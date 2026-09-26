# Signed op log P3c plan 2 — Option A, own-note reopen, the phone, and the carries — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An author of some pieces can start a piece of her own and write in it while the root decides; a reviewer can restore her own deleted note; the phone judges annotations and offers verbs exactly as the Mac does; and the carries P3b and plan 1 left are closed.

**Architecture:** Every rule stays a pure MaughamCore value asked by both surfaces (tripwire 19). Option A is decided by a fact on the piece itself: the manifest item records which device STARTED it. In a narrowed book only that device mints the piece's opening. Its own Mac applies its own lines in the piece while nobody has claimed it, and every other Mac holds them and asks the root, as today. Own-note reopen moves onto the edit/withdraw ownership path. The phone reaches `Posture` through a Core door rather than restating the Mac's.

**Tech Stack:** Swift 6, SwiftUI/AppKit/UIKit, XCTest. MaughamCore + the Mac target + MaughamPhone.

**Spec:** `docs/superpowers/specs/2026-09-19-signed-op-log-p3-roles-scope-collaborator-design.md` §4.5, §9, §12. Rulings: `docs/superpowers/notes/2026-09-17-signed-op-log-p3-handoff.md` (**DENVER RULED 2026-09-23** I3 → option A; *P3c plan 1 OUTCOME* → *What plan 2 carries*, ruling P). The plan-1 ledger `.superpowers/sdd/2026-09-24-signed-op-log-p3c-posture-and-component-a/progress.md` holds rulings A–AL. **Where this plan, the spec and a ruling differ, stop and say so — do not pick.**

## How to read this plan

Contracts, the failure each must not have, and **signatures verified at file+line on 2026-09-24 against main `41614ab1`** — no function bodies (memory: *a plan's code is a liability*). If a cited line has moved, find the symbol. If a cited signature is WRONG, stop and report: that is a plan defect.

**The disable experiment is required on every negative assertion**: remove the REAL guard, watch the test fail, restore it, put the failing output in your report. Wrap the experiment in a line containing `EXPERIMENT`.

**Every rule is stated in both directions. Check the ruling, not just the code.** Controller rulings have been half-rules seven times in P3.

**"Unreachable" is a claim to test.** And three P3 lists of "which paths write X", written from prose, were each incomplete. Where a task says "every site", derive the list from the code (a grep census), never from this plan.

## Global Constraints

- **Behaviour-neutral for every book with no narrowing permit.** Option A's starter rule, the reopen change and the phone's judgement change nothing in an un-narrowed book, so every existing suite passes untouched except the tests each task names as flipping.
- Tripwires 19, 38–52 bind. 19: anything both surfaces do is ONE Core implementation. 44/47: no rung comparison outside the permit layer. 46: `OpLogStore.localWritePermit` is the one builder. 51: surfaces ask `Posture`. 52: every manuscript writer outside the editor asks first. The census population is derived.
- **The phone signs no PERSON record, no event and no claim.** It already signs its own DEVICE record through `RegistryPresence.ensureDeviceRecord` (`PhoneDeviceRecord.ensure`). That stays, and no other record is written.
- MaughamPhone/AREA.md's iOS tripwires bind, especially 5 (no `NSFilePresenter`) and 7 (byte-compatible with the Mac reader, proven by a round trip).
- Hide, don't disable (in-pane verbs). Menu-bar items disable (ruling X).
- The AI actor is never given a product name.
- Tripwire 33: no test presses a mounted control and waits. Pin the decision on a pure value.
- Fixtures register their roots and remove them in `tearDown`. Every test asserting *verified* injects the test signer (tripwire 36).
- **Process:** branch `claude/signed-op-log-p3c-plan2-2026-09-24` off main. Implementers work SEQUENTIALLY in the main checkout.
  - Commit with `git commit -- <paths>`. Never amend, and every commit must build alone. Run `./gen.sh` in the same step as any file you add or delete.
  - `pgrep -x xcodebuild`, never `-f`. No wait loop with `xcodebuild` in its argv.
  - Never read a gate's exit status through a pipe.
  - Check `df -h /System/Volumes/Data` before a full gate.
  - Gates for any Core change: Core `swift test`, `./scripts/test.sh` and `./scripts/test.sh phone`. Run `./scripts/test.sh full` plus a Release build on Tasks 3, 4, 6 and 10.
  - **END YOUR TURN WITH THE HAND-BACK.**
- **Models:** opus implementers throughout. Task reviewers are sonnet, except Tasks 2, 3, 4 and 5, which get opus: the table, the load seam and the phone's judgement. The whole-branch review is fable, given all three P3c/P3b/P3a ledgers.

## Review Focus

1. **Her two Macs.** She starts a piece on Mac 1 and opens it on Mac 2 before its ops sync. Mac 2 waits, then applies her lines once they arrive, still unclaimed, because both Macs' keys are hers (Task 3).
2. **The root opens her new piece before its ops arrive.** The root waits and mints nothing, so her words are never set aside behind a root-signed opening (Task 4).
3. **A legacy piece**, one with no `startedBy` that nobody has ever opened, in a narrowed book: whoever may write its text mints it, exactly as today (Task 3).
4. **The root answers *Theirs*.** Her Mac's standing line goes and her posture is ordinary. No second copy of her lines appears (Task 4).
5. **A reviewer restores her own deleted note on her phone.** It is honoured on the Mac, and a restore of somebody else's archived note is not (Tasks 2, 5).

## Rulings this plan makes on Denver's behalf (confirm at plan review)

- **OA-1 — the starter is recorded ON THE PIECE, not only on the Mac.**
  - Denver ruled "only its starter". This plan records the starter as a manifest-item field, `startedBy` (the author device id of the Mac that created it). A device-local memory would give a legacy piece no answer at all, and her own second Mac could never learn it was hers.
  - A piece with no `startedBy` (made before this build) falls back to today's rule: whoever may write its text mints it.
  - The manifest is unsigned and cooperative, so this is a courtesy about who mints. It is not enforcement; the partition still judges every line.
  - *Cost if wrong:* a modified client could claim to have started a piece. It still cannot get its lines applied anywhere but on its own Mac.
- **OA-2 — the starter rule binds the root too.** In a narrowed book the root's Mac waits for a piece it did not start, rather than bootstrapping it. *Cost if wrong:* the root sees "waiting for this piece to arrive" for a few seconds on a piece a collaborator just made.
- **OA-3 — her own Mac applies her own lines** in a piece she started and nobody has claimed. Every other Mac holds them and the root is asked (unchanged). When a book author writes the piece's text, her lines are set aside on every Mac, hers included, as §4.5 already rules for other Macs. *Cost if wrong:* her screen and the root's disagree about an unclaimed piece until the root answers. That is the ruling's intent.
- **RP-1 — ruling P's consequence for somebody else's note.**
  - Moving reopen onto the ownership path means a reviewer's reopen of somebody else's archived note is no longer set aside as a `.lines` record. It is quietly not honoured, exactly like her edit of somebody else's note today ("not honoured loses no words").
  - Her own withdrawn note's reopen is honoured.
  - Her own note that the ROOT archived, rejected or stetted stays the root's disposition, so her reopen of it is not honoured.
  - *Cost if wrong:* nothing in History records the refused reopen.
- **NC-1 — the Mac on no chain** (a collaborator's Mac before its admission) is treated as part of I1 (Denver, 2026-09-24): stated as an ADR limit, filed as a future enhancement, and nothing is built.

## File structure

New:

| file | one responsibility |
|---|---|
| `Packages/MaughamCore/Sources/MaughamCore/PostureDoor.swift` | the Core door both surfaces build a `Posture` through (Task 1) |
| `Packages/MaughamCore/Sources/MaughamCore/PermitWords.swift` | the role/pieces sentences, moved from the Mac's `PermitControl` / `PeopleAndDevicesModel` so the phone says the same words (Task 1) |
| `MaughamPhone/Annotations/PhonePosture.swift` | the phone's thin per-piece posture cache over `PostureDoor` (Task 6) |

The rest are modifications, named per task.

---

### Task 1: One posture door and one set of role words, in Core

**Files:**
- Create `PostureDoor.swift` and `PermitWords.swift`.
- Modify:
  - `Maugham/Stores/DocumentStore+Posture.swift`: `permitFromTheBuilder` at :342 builds through the Core door.
  - `Maugham/Compiler/RulingPerformer.swift`: `windowlessPosture` at :366.
  - `Maugham/MCP/Tools/TranslationWritePipeline.swift`: its posture build.
  - `Maugham/Views/PermitControl.swift`: `Permit.Rung` titles at :176–203.
  - `Maugham/Views/PeopleAndDevicesModel.swift`: `Person.permitSentence` at :382–392.
  - `MaughamTests/TripwireGrepTests.swift`: the posture census allow-list.
- Tests: `PostureDoorTests` (Core, new), `PermitWordsTests` (Core, new), and the existing Mac suites unchanged.

**Verified facts:**
- `OpLogStore.localWritePermit(as:documentClass:) -> LocalWritePermit`, OpLogStore.swift:276. It is sync and never throws.
- `OpLogStore.documentClass(forDocId:in:)`, OpLogPermitContext.swift:372.
- `Posture.init(_:yieldingTo:)`, Posture.swift.
- Tripwire 51's census (`postureAskRoots` = Mac + MaughamPhone, TripwireGrepTests ~:9138; patterns ~:9085) does NOT scan Core.

**Contract:**
- `PostureDoor.posture(forDocId:in projectURL:as actor:using store: OpLogStore) -> Posture` builds `Posture(store.localWritePermit(as: actor) { OpLogStore.documentClass(forDocId: docId, in: projectURL) })` and nothing else. Yielding stays the Mac's (it needs `PieceWriters`).
- The Mac door's live-manifest class optimisation (Ruling AD) stays: it passes its own class closure through a second entry point, `posture(permit: LocalWritePermit) -> Posture`, or equivalent. It must be ONE place that turns a `LocalWritePermit` into a `Posture`.
- `RulingPerformer.windowlessPosture` and the translation pipeline call the Core door, and their census allow-list entries shrink to match. Count the arrays.
- `PermitWords`: the rung titles and the "role + pieces" sentence move to Core byte-identical, and the Mac views call them.

**Both directions:** every existing posture test passes unchanged. The census proves that no Mac or phone file constructs `Posture(` except the door wrapper that is left.

**Must not:** add a second builder, or put yielding in Core.

- [ ] Red: `PostureDoorTests` covers {no registry → `.author`, a reviewer, a pieces-author in/out}, and `PermitWordsTests` pins every rung's words. **Disable:** make the door ignore the actor and watch a translator case go wrong.
- [ ] Implement. Run the Core, Mac and phone gates. Commit `refactor(posture): one door and one set of role words in Core, for both surfaces`.

---

### Task 2: Ruling P — a reviewer restores her own deleted note

**Files:**
- Modify:
  - `Permit.swift`: `group(of:)` at :445–477, the `.annotationReopen` arm.
  - `AnnotationDeriver.swift`: pass 1b at :64–78, the `latestLifecycle` fold at :20–27, `deriveWithdrawn` at :244 and `isWithdrawn` at :283.
  - `AnnotationOwnership.swift`: `AnnotationAmendments` at :193–271.
  - `Maugham/OpLog/Document+Annotations.swift`: `reopenAnnotation` at :1141, its door at :1147, `reopenAcceptedTextlessAnnotation` at :1211, and the withdraw-undo catch at :458–466.
  - `Maugham/Views/AnnotationsPane.swift`: Restore at :1184–1190 and `AnnotationRowVerbs` at :2097–2146.
  - `Maugham/OpLog/AREA.md`: the "Known edge" at :1272–1277.
- Tests: `PermitTableTests` (:233 flips), `AnnotationOwnershipTests`, `AnnotationDeriverTests`, and `DocumentAmendmentOwnershipTests`.

**Verified facts:**
- The partition sees only the op kind, never the target's creator. `AnnotationInverse.reopenOp` (AnnotationInverse.swift:29–61) writes no "undoing" discriminator.
- Edit/withdraw pass the reviewer row (`.ownAnnotation`), are recorded by `AmendmentPermits`, and are judged in the deriver by `AnnotationAmendments.judged` → `mayAmend`, whose same-person arm is `trust.sameWriter`.
- A reopen is also a lifecycle kind (`isLifecycleKind`, :342–349). It cancels a withdraw in pass 1b AND an archive/reject/stet in `latestLifecycle`.

**Contract (RP-1, both directions):**
- `.annotationReopen` moves to `.ownAnnotation`, so the partition passes it and records it like edit/withdraw.
- The deriver gates reopen PER PASS:
  - In the withdraw pass it is honoured under the ownership rule: same person, or author rights.
  - In the lifecycle fold it is honoured only under the DISPOSITION rule: author rights on the document, never the same-person arm. Her own note archived by the root stays archived when she reopens it.
  - `AnnotationAmendments` gains the second judgement (a pass-aware call or a second closure). There is still ONE Core policy.
- The Mac door at `reopenAnnotation` branches on what it undoes. Undoing a withdraw goes through the ownership check (her own ⇒ allowed); anything else goes through `requireDispositionPermitted(.annotationStet)`.
- Restore draws for her own deleted note, and the withdraw-undo no longer refuses her own.
- A reviewer's reopen of somebody else's archive is not honoured. The Mac never offers it. A modified client's line passes the partition and changes nothing.

**Must not:** add an `OpKind`; let the same-person arm reach the lifecycle fold; restate the ownership rule outside `AnnotationOwnership`.

- [ ] Red, all of these, each with a real-disk fixture:
  - Her own withdraw, then her reopen ⇒ open.
  - Her own note archived by the root, then her reopen ⇒ still archived.
  - Somebody else's archive, then her reopen ⇒ still archived.
  - The book author's reopen of anything ⇒ open.
  - Unnarrowed book ⇒ unchanged.
  - **Disable:** let the lifecycle fold use the ownership closure, and watch "archived by the root" reopen.
- [ ] Implement. Run the Core, Mac and phone gates. Commit `feat(annotations): a reviewer restores her own deleted note — reopen joins the ownership path, per pass (ruling P)`.

---

### Task 3: Option A in Core — the starter, the permit arm, her own lines

**Files:**
- Modify:
  - `ProjectManifest.swift`: the structure item gains optional `startedBy: String?`, whose absence decodes as nil. ADR 0015: tolerate unknown fields and add a round-trip test.
  - `LocalWritePermit.swift`: a *may start a piece* arm.
  - `OpLogStore.swift`: `localWritePermit` at :276 learns the starter.
  - `Permit.swift`: `mayStartAPieceOfTheirOwn` at :266 stays the rung half.
  - `PermitPartition.swift`: the §4.5 `.no` arm at :225–252, and `startsAPieceNobodyHasClaimed` at :832–848.
  - `OpLogPermitContext.swift`: `unownedPiece` at :438.
  - `Posture.swift`: the `.startAPiece` probe at :152–174.
- Tests: `PermitPartitionTests`, `PermitLoadTests` (the §4.5 group at :811–897), `PostureTests` (:115 flips), `LocalWritePermitTests`, and a manifest round trip.

**Contract (OA-1, OA-3, both directions):**
- **The starter.**
  - A narrowed book's piece may be MINTED (its `bootstrap`) by the device whose author id equals the item's `startedBy`.
  - A piece with no `startedBy` falls back to today's rule: `writePermit.allows(.op(.bootstrap))`.
  - Expose ONE Core predicate that the Mac load (Task 4) asks, e.g. `LocalWritePermit.mayMintOpening(of:)`. Spell it once.
- **The permit arm.** For an author of some pieces (`mayStartAPieceOfTheirOwn`), in a piece she started (`startedBy` is one of HER person's devices, via the table's `sameWriter`) that nobody's permit authors, `localWritePermit` answers manuscript kinds `.yes`. Her posture there is ordinary writing, with a `Posture.Reason` of its own (e.g. `.waitingToBeClaimed(root:)`) for the standing line.
- **Her own lines, on her own Mac.** The partition applies a `.mine` / same-person line that §4.5 would hold. On every other Mac it is held and recorded (`recordStartedAPiece`) exactly as today.
  - Once a book author has written the piece's text (`bookAuthorWroteManuscriptText`), her lines are set aside everywhere, hers included, and her posture flips to `.notYourPiece`.
  - A book author's `bootstrap` alone does not count as writing its text. After OA-2 the root no longer mints another's piece; pin this anyway.
- **`.startAPiece`**: true for the book author AND for an author of some pieces. Still false for a reviewer and for `.cannotJudge`.

**Must not:** build `LocalWritePermit(` outside OpLogStore/LocalWritePermit (tripwire 46); compare a rung outside the permit layer (47); let her lines apply on the ROOT's Mac before *Theirs*.

- [ ] Red: every direction above, and the Review Focus lines 1 and 3.
  - Her two Macs: both are her keys.
  - A legacy piece with no `startedBy`.
  - `startedBy` naming somebody else ⇒ this Mac may not mint.
  - A book author wrote the text ⇒ set aside on her Mac too.
  - **Disable:** apply her lines on every Mac, and watch the root's Mac apply them.
- [ ] Implement. Run the Core, Mac and phone gates **and the full gate**. Commit `feat(oplog): Option A — the piece records its starter; her own Mac writes the piece she started until the root says whose it is`.

---

### Task 4: Option A on the Mac — the load, the creation sites, the line, the question

**Files:**
- Modify:
  - `Maugham/OpLog/Document+Load.swift`: the bootstrap guard at :386–402.
  - `Maugham/OpLog/Document+Waiting.swift`: `waitingSentence` at :96–116.
  - Every site that creates a piece. Derive the list with a grep census over `addStructureItem`, `duplicateStructureItem`, `addLoosePiece` and the MCP `test_add_document`, and name it in the report.
  - `Maugham/Views/PostureStandingLine.swift`: a new reason's sentence.
  - `Maugham/Views/NewPieceModifier.swift`: `recompute` at :115.
  - `Maugham/Views/CollectionPiecesPane.swift`: `StartAPieceDoor.refusal` at :394 and `emptyDescription` at :282.
  - `CLAUDE.md`: the Hard-invariants Bootstrap bullet (the controller edits it after review; put the proposed text in your report).
- Tests: `DocumentWaitingTests` (:514 and :549 flip), `LoadQuestionsTests`, `AdmissionPermitTests`, `PostureSurfaceTests` (:1701 flips), and `BootstrapWiringTests`, which is unchanged and must stay green.

**Contract (OA-1, OA-2, both directions):**
- `Document.load` mints only where Task 3's predicate says so. Every other narrowed-book load of a no-log piece throws `waitingForPiece`, **the root's included (OA-2)**.
- Every creation site writes `startedBy` = this Mac's author device id, and it is written only on a creation. A rename or move never rewrites it.
- Her Mac's standing line reads *Waiting for <root> to say this piece is yours* while the piece is unclaimed. After *Theirs* it is gone, with no reopen (epoch bump).
- **The survey's suspected bug:** `NewPieceModifier` asks "Sam started X — is it hers?" on any Mac whose `myRoot` resolves, which includes her own non-root Mac, about herself. Ask it only on a Mac holding its own root record: reuse `Registry.holdsARootRecord` (Ruling AA). Pin both directions.
- The pieces-author sees New Document / Duplicate / the File menu (plan 1's rulings W and X widen with `.startAPiece`), and the refusal and empty-state words change to match.

**Must not:** mint on a Mac that did not start the piece in a narrowed book; write `startedBy` anywhere but a creation; change an un-narrowed book's load.

- [ ] Red, with real-disk fixtures on two identities:
  - She creates X ⇒ `startedBy` is hers ⇒ her load mints ⇒ she types ⇒ her Mac applies.
  - The root loads X before her ops arrive ⇒ `waitingForPiece`, nothing minted.
  - Her ops sync ⇒ the root holds them and asks.
  - *Theirs* ⇒ both Macs apply, one copy.
  - Her own Mac is never asked about herself.
  - **Disable:** drop OA-2 (let the root mint), and watch her lines set aside.
- [ ] Implement. **Run the full gate** and a Release build. Commit `feat(option-a): she starts a piece and writes it while the root decides; the root waits for a piece it did not start`.

---

### Task 5: The phone judges annotations as the Mac does

**Files:**
- Modify:
  - `MaughamPhone/Annotations/AnnotationLoading.swift`: :65–74 gain `amendments:`.
  - `AnnotationsStore.swift`: :61–78, `loadDiagnosed(amendmentPermits:)`.
  - `AnnotationDetailView.swift`: `rederive` at :555–568, and the accept re-read at :419–423.
  - `AnnotationWriter.swift`: the `isWithdrawn` guard at :156, and the `ChainPolicy` site at :355–359.
  - `MaughamPhone/Capture/InboxCaptureWriter.swift`: the `ChainPolicy` site at :229–232.
  - `MaughamPhoneTests/TripwirePhoneGrepTest.swift`: the comment at :697–700.
- Tests: `PhoneAnnotationIntegrationTests` (extended), `PhoneOneKeyTests` (extended to a book WITH a register), and a new `PhoneAnnotationOwnershipTests`.

**Verified facts:**
- The phone already runs the permit partition. `OpLogStore.load` goes to `loadDiagnosed` and on to `trust()`.
- It never passes `AmendmentPermits`, so it derives with `.honourEverything`.
- The Mac applies ownership at `Document+Load.swift:662` via `opStore.annotationAmendments(from:documentClass:)` (OpLogStore.swift:348).
- Both phone `ChainPolicy` sites take the default single-signer closure. For a pure writer that is equivalent to the keyless table (`JSONLAppendStore` asks only `== .mine`).

**Contract:**
- The phone threads `AmendmentPermits` through `loadDiagnosed`, then `annotationAmendments(from:)`, into every derive, including the `isWithdrawn` guard. It uses the same Core calls as the Mac, restating nothing (tripwire 19).
- C7: both `ChainPolicy` sites are verified to be write-only single-signer. Leave the default and pin why with a test. If you find a READ through either, it takes the table.
- Extend `PhoneOneKeyTests` to a book with a register and a narrowing: the new read path still mints no non-author key on the phone.

**Both directions:**
- A reviewer's edit of somebody else's note: judged away on the Mac, and now judged away on the phone.
- Her own edit: honoured on both.
- An unnarrowed book: identical to today.
- Ruling P, via Task 2's Core change: her own restore is honoured on the phone; somebody else's archive stays archived.

**Must not:** construct a trust table the Mac would not, or mint a key.

- [ ] Red: Mac↔phone round trips (spec §12). A Mac-written narrowed book is read on the phone with every ownership case, and the phone's writes are read back on the Mac. **Disable:** pass `.honourEverything` again and watch the reviewer's edit reappear.
- [ ] Implement. Run the phone, Mac and Core gates. Commit `feat(phone): annotations are judged by the same ownership rule the Mac applies`.

---

### Task 6: The phone's posture — verbs per piece, capture always, Settings says who you are

**Files:**
- Create `MaughamPhone/Annotations/PhonePosture.swift`.
- Modify:
  - `AnnotationDetailView.swift`: `actionButtons` at :253–286, `reopenAffordance` at :325–344, and the performs at :407–476, each gaining a door.
  - `MaughamPhone/Settings/SettingsView.swift`: `thisDeviceSection` at :78–107, and `resolveStandings` at :134–159.
  - `DeviceStanding.swift`: gains the permit.
  - `MaughamTests/TripwireGrepTests.swift`: the posture census allow-list for `PhonePosture.swift`, by file AND spelling.
  - `MaughamPhoneTests/TripwirePhoneGrepTest.swift`.
- Tests: new `PhonePostureTests`, `DeviceStandingTests`, and the Settings model.

**Contract:**
- `PhonePosture` asks Task 1's Core door per `(project, docId)`, warmed off the main actor, and cached per load.
  - Accept/Reject/Reply/"Mark answered"/Reopen & Revert follow `.acceptOrReject`.
  - Archive/Reopen follow `.dispose`, except that a reopen of her OWN withdrawn note follows the ownership answer (Task 2).
  - Each is hidden where refused. Each perform re-asks before writing, and a refusal is said.
  - Capture is always offered. The inbox row is on every rung.
- `DeviceStanding` gains `permit: Permit?` from `table.myTimeline.current`, answered through `Permit.rung(of:)` (never a literal: tripwire 47).
  - Settings shows the rung and the piece titles in `PermitWords` (Task 1), and the same words as People & Devices.
  - Resolve with `TrustResolution.resolveVerified` rather than `RegistryReader.load`, or state why not.
- **C5 — refresh.** Settings re-resolves on `scenePhase == .active` and pull-to-refresh. The phone has no `NSFilePresenter` (iOS tripwire 5) and gains none.

**Both directions:** a reviewer sees no disposition and can still capture. A pieces-author sees verbs on her pieces only. Promotion shows on the next active / pull. A book with no register shows no role line, and the phone behaves exactly as today.

**Must not:** hand-build a permit; name a rung; add a file presenter; write any record beyond its own device record.

- [ ] Red: the verb decisions as pure functions over `Posture`; the Settings model's sentences; the refresh trigger. **Disable:** show dispositions regardless, and watch the reviewer case fail.
- [ ] Implement. **Run the full gate**, the phone gate and a Release build. Commit `feat(phone): the phone offers what the permit allows and says who you are in each book`.

---

### Task 7: The P3b carries — the snapshot sweep, adopted roots, the pre-seal stranger

**Files:**
- Modify:
  - `Maugham/Stores/DocumentStore+Registry.swift`: `sweptUnsignedSnapshot` at :266.
  - `RegistryAdmission.swift`: `refuseANarrowingWithNoSnapshot` at :1016–1020, and the event writer at :996–999.
  - `Maugham/Views/PeopleAndDevicesModel.swift`: :784.
  - `Maugham/Views/PieceWriters.swift`: :115–121.
  - `DeviceStanding.swift`: :158–159.
  - `ClaimDecision.swift`: :126.
  - `TrustTable.swift`: the `myChain` doc at :183.
  - `HeldLines.swift`: :224–266 and :25–28.
  - `TrustEventSentence.swift`: :98–109.
  - `Maugham/Views/SetAsideDoor.swift`: :101–103 and :377–379.
  - `Maugham/Views/HistoryPane.swift`: :599–638.

**Contract:**
- **Carry 7.** When the resolved table already has a governing `unsignedSnapshot`, a narrowing verb skips the sweep and passes `.nothingApplied`. The event writes `unsigned: {}`, which never governs because it is not the earliest. The door accepts it. Pin that the governing snapshot is unchanged and that no sweep ran (a counter).
- **M4.** People & Devices, `PieceWriters` (and so the root's yields), `DeviceStanding` and the claim decision list the TABLE's `myChain` (my root plus the roots it adopted), never `chain(underRoot: myRoot)`. Fix the stale doc.
- **M2.**
  - The unsigned sentences stop asserting "there is no device to admit" about a stream that may belong to a signing Mac whose first seal has not synced. People & Devices' wording (:491–517) is the model.
  - The held-span door's sent-memory is keyed by the LINES (`<docId>|<opId>#<paragraphId>` per word, as the record door is), not by the holder. Words sent before the seal synced are then not offered again once the same lines are held under a fingerprint.

**Both directions:**
- First narrowing: swept. A later narrowing: not swept, and the governor is unchanged.
- An adopted root's admitted person: listed and yielded to. A stranger: not.
- Sent before the seal: not re-offered after it. Never sent: offered.

- [ ] Red: all three, each with a disable experiment. Implement. Run the Core, Mac and phone gates. Commit(s) `fix(oplog): …`.

---

### Task 8: Plan 1's behaviour carries

**Files (derive exact lines; the survey's are in the plan-1 handoff's *What plan 2 carries*):**
- `AnnotationsPane.swift`: rows for a yielded document.
- `AdmissionModifier.swift`.
- `ProjectStore+Tasks.swift`: :35–37 and :104.
- `TasksPane.swift`: :537–576.
- `Document+Tasks.swift`: `archiveTask` near :686.
- `ReviewCardActions.swift` / `EditorCoordinator` (margin nil posture).
- The Keep mine sheet.
- `DocumentStore+Posture.swift`: the `.translation` yield arm.
- `AdmissionDecision.swift`: the pre-check and the non-root skip.

**Contract, one line each, each pinned in both directions:**
- **AJ.** For the root in the project-scope queue, a yielded document's rows carry the reason ("Sam's piece") and an *Edit Anyway* in that document's group header, calling `overrideYield`.
- **F10 late capture.** An open admission sheet re-describes itself when `inboxStore.refreshes` changes (the `InboxPane` `.task(id:)` precedent). No new event.
- **Project-stream tasks.** `createProjectPaneTask` / `archiveProjectTask` (sync) refuse through the drawing posture. `.settling` refuses and says "try again in a moment". The census counts the site.
- **`archiveTask`.** It sets `didSplice` only if the splice wrote.
- **The margin card.** A nil posture draws the fail-closed set (annotate plus her own-note edit/delete), not the full set.
- **Keep mine's sheet** offers only the homes that may be written.
- **The door's `.translation` yield arm.** Delete it (unreachable; `DocumentClass.resolve` never yields `.translation`), and pin what translation surfaces DO resolve.
- **A corrupt `people/<fp>.json`.** It no longer hides a record-only stranger: an unreadable person file counts as "resolve".
- **A non-root Mac** skips the admission resolve entirely (cheap `holdsARootRecord`-by-filename first).

- [ ] Red per line, with a disable experiment each. Implement. Run the Mac gate. Commit(s).

---

### Task 9: Plan 1's census and test hygiene

**Contract (each an edit to TripwireGrepTests or a test file, plus the tiny production cleanups named):**
- `test_everyGuardedDocumentMutatorIsClassified` gains its planted-offender control.
- The manuscript-writer census counts per SPELLING per file, not per file.
- Add the missing plan-1 tests: the provisional path, `posture(forPath:)` on a closed document, a re-stamp after a class-changing adoption (m7), and disable experiments on the no-registry and second-window-override tests (m5).
- `passOrderNudge` end to end, windowless.
- `posture(forPath:)` caches an unknown path's miss (m4).
- Find asks posture once per document, not per match row. `offersRevert` asks only for documents the picker lists.
- The revert picker's sentence names titles, not ids.
- Collapse the three `offersVerbs` wrappers into one.
- `TasksPane`'s `.project` arm asks the project stream directly.
- `CollectionPieceModifier` answers start-a-piece only where the project shows the pieces pane.
- The `AnnotationInverse` doc comment is corrected.
- M6: `scripts/census-load-bursts.sh`'s header and the release checklist say *run from this Mac against each Mac's folders*.
- M7: tripwire 50's row loses its prose count (the controller edits CLAUDE.md; put the text in the report).

- [ ] Implement with a disable experiment on each new census control. Run the Mac gate. Commit(s) `test: …` / `chore: …`.

---

### Task 10: Docs and the gate

**Files:**
- ADR 0032: a P3c plan-2 addendum (Option A with OA-1..3, ruling P with RP-1, the phone, the carries) and its limits.
  - NC-1: the no-chain Mac is stated under I1.
  - `startedBy` is cooperative, not enforcement.
  - The P3b limit "the phone holds identically and has no surface" is struck.
- AREA files: `Maugham/OpLog/AREA.md`, `Maugham/Views/AREA.md`, `MaughamPhone/AREA.md`.
- Guides: `docs/guide/people-and-devices.md` (starting a piece of your own; restoring your own note; what the phone shows).
- The P3 handoff's *P3c plan 2 OUTCOME* section: what shipped; the plan-3 list (P2 carries C4, C10+C17, C12, C14; the closing smoke; the release, including the open question to Denver about an old build over an eventless book).
- The CLAUDE.md edits proposed by Tasks 4 and 9, as text in the report. The controller applies them.

- [ ] Implement. **Run the full gate**, Core, phone and a Release build. Commit `docs(oplog): P3c plan 2 — …`.

---

## Order

Sequential: Task 1, then Task 2, then Task 3, then Task 4, then Task 5, then Task 6, then Tasks 7, 8 and 9 in any order, then Task 10. Run the full gate after Tasks 3, 4 and 6.

## Whole-branch review — seams to name to the reviewer

Give the reviewer all three P3 ledgers, the plan-1 handoff, and this list. Tell it to assume there is a Critical.

- **T3×T4** — the starter predicate is spelled once, and the load, the partition and the posture read the same `startedBy`.
- **T3×T2** — her own lines in an unclaimed piece include annotation amendments. Does ownership still judge them?
- **T4 × plan-1's census (tripwire 52)** — every new creation site is a manuscript writer that asks first.
- **T5×T6×T2** — the phone's own-note restore: the verb shows, the write passes, and the Mac honours it.
- **T7×T4** — `PieceWriters` over `myChain`: an adopted root's pieces-author starting a piece.
- **T1** — the Mac door and the phone door agree for one document at one moment.

**The premise check:** grep the diff for *unreachable / never / always / cannot* and test each. Which states does this plan's own code create that a guard calls impossible? A piece with `startedBy` in an un-narrowed book, a `startedBy` naming a revoked device, and a piece started on a Mac that is later retired.
