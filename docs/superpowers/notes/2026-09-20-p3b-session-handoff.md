# Signed op log P3 — session handoff into P3b (2026-09-20)

**Why this note exists.** The session that specced P3 and built P3a ran out of context. This is the door for the next one: where things stand, what to read, what Denver owes, and what to do first. It points at the records; it does not repeat them.

## State of the world

- **P3a — *the permit, enforced* — is merged to LOCAL main** (`99ed06f6`, 2026-09-20). Not pushed, not tagged. Local main is ~49 commits ahead of origin.
- **Denver's ruling, 2026-09-20: P3 ships whole.** P3a/P3b/P3c are a split for ease of implementation, not a release split. Nothing of P3 is released until P3c's closing smoke. Do not cut, tag or push a release from main until then.
- Gates at merge: fast gate on merged main **8,611 / 0**; the branch's full gate **8,721 / 0, no skip classes**; Core **1,586**; phone green.
- Branch `claude/signed-op-log-p3a-2026-09-19` still exists locally (merged; safe to delete).
- Audit **PR #65** (the 2026-09-20 full audit) has two comments from this session: the triage note and the closing note with commit hashes for F1, F2, F3, F8–F10. F4 is carried to P3b. The PR itself is still open — merge its note when processing audits.
- Scratch from the build (task reports, briefs, the fix-wave brief and report) is kept in `.superpowers/sdd/2026-09-19-signed-op-log-p3a-the-permit-enforced/` (git-ignored). The reports hold each task's public names and signatures — useful when writing P3b, but **verify every name against source**.

## Read first, in this order

1. `docs/superpowers/specs/2026-09-19-signed-op-log-p3-roles-scope-collaborator-design.md` — the P3 spec (roles, **per-piece scope**, the collaborator), incl. its dated *as built in P3a* note and the amended §3.3.
2. `docs/superpowers/notes/2026-09-17-signed-op-log-p3-handoff.md` — from **"What shipped"** to the end: the P3a OUTCOME, the fix wave, *For the release notes*, *The decision still owed for the release*, **PARKED for Denver — the unsigned door**, **Carries into P3b**, *What the fix wave's re-review left for P3b*, the open question, **Carries into P3c**. This is the list P3b is planned against.
3. `docs/superpowers/notes/2026-09-20-signed-op-log-p3a-build-ledger.md` — the evidence: ~35 `Ruling:` lines with what each costs if wrong, every deferred minor, the whole-branch review. Hand it to P3b's whole-branch reviewer.
4. `docs/adr/0032-the-signed-op-log.md` — the P3a addendum and its limits section. `Maugham/OpLog/AREA.md` — the P3a section and tripwire rows. `CLAUDE.md` tripwires 38–48 and the reworded Bootstrap invariant.
5. `docs/superpowers/plans/2026-09-19-signed-op-log-p3a-the-permit-enforced.md` — for house style only (contracts, verified signatures, disable experiments — no function bodies).

## Decisions Denver owes — BEFORE the P3b plan is written

Present one at a time, pros / cons / recommendation, as the P3 rulings were.

1. **The unsigned door** (handoff: *PARKED for Denver*). A registerless book, a never-sealed file no record can name, and pre-signing legacy history are applied with no permit check — P1's design. A modified client that never seals walks past roles. **This contradicts what Denver was told under handoff decision #8** (that unsigned lines sit pending — they are applied). Sharpest edge, and it needs a surface whichever way this goes: on a Mac with no enclave, the day the root FIRST narrows anybody, every note that Mac withdrew reappears and every note edit reverts, on every signed Mac, silently. Candidate close: the first narrowing event snapshots the book's unsigned files (digests); unsigned lines outside the snapshot are pending in a narrowed book. It shapes P3b's pane and the first-reviewer flow, so it comes first.
2. **C8 item 5** — should `claimedAt` move on a later adoption? Reverted in P3a because a deliberately-named P2 test pins that it does NOT. Doing it properly wants a per-adoption date — a `ClaimRecord` format change, filed with the signed-structure roadmap item.
3. **The release census** — W3's stop: three load-time `typingBurst` emissions carry no `synthesisSource`, so any such lines v0.37–v0.40 signed under the assistant/translator key stay refused (set aside, recoverable). This Mac's census found none (23 projects, segments decoded, iCloud empty). Decide: run the Swift census on every Mac that has opened a book before the P3 release, and give those emissions a `synthesisSource` prospectively.

## What P3b is (re-derive against the BUILT code — rule 11; cap ~10 tasks — rule 12)

Spec §4.5's question surface, all of §7, plus the MUSTs the P3a build produced:

- **The first NARROWING event bumps the manifest schema gate** (as schemaVersion 5 did). A v0.40 Mac in a narrowed book applies a reviewer's refused text and then re-asserts her words under ITS book-author key. This is what makes P3 a paired Mac+phone release.
- **An escape for a sweep that would refuse for ever** — a remembered stream/segment that is legitimately gone makes `revoke`/`changePermit`/`admit` for that person refuse permanently. Build it with the truncated-stream drawer: a loss the writer has been SHOWN stops being expected, or the verb offers *proceed, judging that stream as new*.
- **The admission sheet never offers a non-author actor key nor a contested key** — a held span whose slug says `assistant-`/`translator-`/`maugham-` waits for its device record. This closes two P3a residuals at their root.
- **The pane calls `DocumentStore.changePermit(everyRecordOf:to:)`** — permits live on person RECORDS and a person is a label.
- Surfaces with no drawer yet: permit-pending lines (held silently in P3a), `IntegrityReport.truncatedStreams` / `TruncatedStream.sentence`, `RegistryAdmission.recordBehindEvents`, an event whose person record has not arrived (draws no History row), the set-aside → Send to Inbox door (ruling 1), the unsigned line on a device row (#8), the three load questions (admission · *Sam started X — hers?* · *N paragraphs written while retired*).
- A census that no file under `Maugham/MCP` emits a task op (the load-emission rule judges `taskCreate` as the author's by KIND — safe only while MCP cannot create tasks).
- Measured cost to inherit and re-measure: **one reviewer ≈ +15 ms per document open** (23.8 → 39.2 ms); an un-narrowed book pays nothing.
- Audit F4 (a cold-cache tamper of a sole root record leaves Finder as the only fix). P2 carries C1, C2, C11, C13, C15, C16 (see the P3 spec §13).

**P3c** then takes the membrane (`Posture`; ⌘S keeps its flash and writes nothing on a piece this device may not write; `flushBurstNow`), Component A's retirement, inbox attribution, the phone (it must apply `AnnotationOwnership`; posture off `DeviceStanding`), guides + the constitution amendment, C4/C5/C7/C10+C17/C12/C14, the closing two-Mac smoke (`scripts/second-mac.sh`) and a second Apple ID.

## First moves for the next session

1. Read the list above. Do not re-derive P3a.
2. Put decision 1 (the unsigned door) in front of Denver; then 2 and 3.
3. `superpowers:writing-plans` for **P3b only**, against the built code. Verify every signature at file+line before it goes in the plan.
4. Subagent-driven build on a new branch off main; opus implementers; **opus/fable for the whole-branch review, with the ledger and named seams**.

## Process notes that paid in P3a (keep doing these)

- **The controller's trust rulings were half of a two-sided rule SIX times.** Every one was caught because dispatches said *stop if a ruling looks half-stated against the code* and reviews were told to *check the ruling, not just the code*. State both directions in every ruling. Keep both instructions in every dispatch.
- **"Unreachable until the next plan" is a claim to test, not to trust.** The whole-branch Critical was a premise the whole build shared — *no events exist before P3b* — while P3a's own verbs wrote events. Ask: does THIS plan's shipped code create the state?
- **Census production before wiring enforcement.** *List what production actually writes under each actor; stop if any would be refused* found five paths signing manuscript ops under the wrong key, including the writer's crash-recovered words.
- The automated security review flags implementers' in-flight disable experiments as Criticals. The answer is a marker grep (`EXPERIMENT|where false|true \|\|`) over the COMMITTED diff before accepting a task.
- Implementers sometimes finish and never hand back. Check `git log`, the report file and `pgrep -x xcodebuild` before assuming a stall; put *END YOUR TURN WITH THE HAND-BACK* in every dispatch.
- Never pipe a gate through `tail` when you need its exit status — the status you read is `tail`'s. Redirect to a file and echo `$?`.
- Two implementers in one FILE commit each other's partial edits. Sequence fix rounds that touch the same file; read-only reviews can run beside the next task.
- Another project (`Julsi`/`Twarfsi`) builds on this Mac; `pgrep -x xcodebuild` may show its build. `test.sh` queues behind its own lock; for measurements, wait for quiet or say it was not.

## RULED 2026-09-20 (second session) — the three decisions, both directions

1. **The unsigned door — CLOSED BY SNAPSHOT (option B).** The first NARROWING event (not the first permit event — admissions change nothing about who may write what) carries a mark, in P3a's own chain-position form, over every stream with no attributable key. **At or before the snapshot:** everything is as P1 — manuscript text stays applied AND an unsigned Mac's note edits/withdrawals stay honoured (this replaces `AnnotationOwnership.unplaced`'s backward reach; narrowing must not reach back, the demotion rule). **After it:** an unsigned line in a narrowed book is PENDING — held, never set aside (nothing is wrong with it), never pardonable by admission (no key), its one way in is Send to Inbox. An un-narrowed or registerless book is untouched. Narrowing is sticky (`hasNarrowingPermits` reads timelines), so there is no un-narrowing direction. The unsigned Mac applies its own lines locally under a standing line. **Where two roots both narrow, the EARLIEST narrowing event's snapshot governs.** People & Devices' unsigned line and the first-narrowing confirmation say what narrowing does to that Mac BEFORE the first reviewer exists.
2. **C8 item 5 — `claimedAt` does NOT move (option C now, B later).** `claimedAt` stays the day the book was claimed and the P2 test stands. History stops borrowing it for an `.adopted` row: that row takes this device's own remembered date where it saw the adoption, else draws undated. A per-adoption date on `ClaimRecord` rides with the roadmap's *Signed structure* format changes.
3. **The release census — A + 3b.** A kept `scripts/` census runs on every Mac that has opened a book before the P3 release (P3c release checklist) and reports hits to Denver; a hit is a per-line manual recovery, never a rule change. The three load-time `typingBurst` emissions gain a `synthesisSource` prospectively (P3b). **Accept direction:** on an author-signed line the label is provenance only and changes no judgment. **Refuse direction:** an assistant-/translator-signed burst stays refused whatever the field says.
