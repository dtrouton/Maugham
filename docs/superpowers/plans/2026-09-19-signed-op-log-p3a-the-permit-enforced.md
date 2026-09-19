# Signed op log P3a — the permit, enforced — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the registry say what each person may write, where and since when — and enforce it where lines are read: event records and marks, the permit timeline, the permission table, the line-by-line partition in every read path, the authority verbs, the load seam, and remembered foreign heads. No surfaces (P3b), no membrane or phone (P3c).

**Architecture:** Everything that decides is a pure MaughamCore value tested without a project on disk: `PermitEvent` (a fourth registry record), `PermitMark` (chain positions), `PermitTimeline`, `DocumentClass`, `Permit.allows`, `PermitPartition`. The trust table stays the ONE answer — a permit reaches the walk on `TrustVerdict.admitted`, never through a second table. `PermitPartition` runs exactly where `RevocationSplit.partition` runs. `RegistryAdmission` stays the only authority that writes.

**Tech Stack:** Swift 6, CryptoKit, Foundation, XCTest. MaughamCore (Apple frameworks only) + the Mac target's stores.

**Spec:** `docs/superpowers/specs/2026-09-19-signed-op-log-p3-roles-scope-collaborator-design.md` (§2–§6, §12, §13). Parent `2026-09-05-signed-op-log-design.md`; ADR 0032; handoff `docs/superpowers/notes/2026-09-17-signed-op-log-p3-handoff.md` (every ruling). **Where this plan and the spec differ, stop and say so — do not pick.**

## How to read this plan

This plan gives **contracts, requirements, the failure each must not have, and signatures verified against the file and line on 2026-09-19** — not function bodies (memory: *a plan's code is a liability*). Write the body against the real file. If a cited line has moved, find the symbol; if a cited signature is WRONG, stop and report — that is a plan defect, not yours to route around.

**The disable experiment is required on every negative assertion** (*is refused*, *is not applied*, *mints nothing*, *writes no record*): remove the guard, watch the test fail, restore it, and put the failing output in your report. A test that stays green with its subject removed is a finding.

**Rulings on trust are two-sided.** Every task below that names a direction names both. If you find yourself implementing one half, the other half is in spec §5 — implement and test them as a pair.

## Global Constraints

- **Behaviour-neutral for every existing book.** No events ⇒ every admitted person is *author, book, from the start* ⇒ the whole P2 suite passes UNTOUCHED. A P2 test that needs editing to pass is a stop-and-report.
- **Tripwire 39:** no parallel trust table. The permit travels on the verdict; every trust closure is still built from `TrustTable`. The three sanctioned keyless write-side spellings are not to be "fixed".
- **Tripwires 40/41/42:** the events directory is spelled in `RegistryWriter.directoryURL` and nowhere else; events are written by `RegistryAdmission.swift` only (and restored by `RegistryCache.swift`); nothing but `RegistryCanonical` names `JSONEncoder(`/`JSONSerialization`/`SHA256` in a registry source. **Every new record field is a STRING or a list/map of strings** — `JSONSerialization` normalizes numbers.
- **RULING-54:** a present-but-unreadable record throws with its `FileKind`; no `try?` on a trust reader.
- **An unrecognised `role`, `scope`, event `kind` or `OpKind.unknown` is PENDING, never set aside** (spec §3.1, §4.2).
- **The AI actor is never given a product name** in any string: *the assistant*.
- Tripwires 17, 19 (shared ⇒ Core), 24, 35, 36 (software keys only via `DeviceIdentity+Testing.swift`; every test asserting *verified* injects that signer), 37, 38.
- Test fixtures register their roots and remove them in `tearDown` — do not add to the `$TMPDIR` leak. Reuse `PendingLoadTests`' and `RegistryAdmissionTests`' helpers (Task notes name them) rather than writing a third fixture set.
- **Process:** branch `claude/signed-op-log-p3a-2026-09-19` off `main`. `git commit -- <paths>` (never a bare commit in a shared tree); never amend a reviewed commit; `./gen.sh` in the same step as any file add/delete; `pgrep -x xcodebuild`, never `-f`; no wait loop with `xcodebuild` in its own argv; absolute paths; quote globs for zsh. Gates per task: `swift test --parallel --package-path Packages/MaughamCore`, `./scripts/test.sh`; `./scripts/test.sh phone` for any Core change the phone links; `./scripts/test.sh full` before merge.
- **Models:** opus for every task here (the digest, the trust table, the role check, the load invariant). Reviewers: sonnet, and the reviewer checks the RULING as well as the code.

## File structure

New, all under `Packages/MaughamCore/Sources/MaughamCore/` unless noted:

| file | one responsibility |
|---|---|
| `PermitEvent.swift` | the event record (Codable, `RegistryRecordProtocol`), its `Kind` |
| `Permit.swift` | `Permit` (role + scope + pieces, parsed from strings; `.unjudgeable`), `Permit.allows` — THE table |
| `PermitMark.swift` | the mark value, its string wire form, `judge(file:)` |
| `PermitTimeline.swift` | events → ordered `(permit, mark)`; `permit(forLine:inFile:)` |
| `DocumentClass.swift` | docId → class, from the manifest |
| `PermitPartition.swift` | the pure partition; sibling of `RevocationSplit` in `OpLogQuarantine.swift` |
| `AnnotationOwnership.swift` | the one same-person helper (§4.2) |
| `Maugham/OpLog/Document+Waiting.swift` | the load seam's waiting state |

Modified: `RegistryRecord.swift`, `RegistryWriter.swift`, `RegistryReader.swift`, `RegistryCache.swift`, `RegistryAdmission.swift`, `TrustTable.swift`, `TrustResolution.swift`, `TrustEvents.swift`, `OpLogChain.swift` (one `QuarantineCause` arm, one `Line.State` reuse — no wire change), `OpLogStore.swift`, `JSONLAppendStore.swift` (`quarantineReason`), `OpLogDeviceState.swift`, `TranslationStore.swift`, `AnnotationDeriver.swift`, `Maugham/Stores/InboxStore.swift`, `Maugham/Stores/DocumentStore+Registry.swift`, `Maugham/OpLog/Document+Load.swift`, `Maugham/Views/AdmissionDecision.swift` (sentences only), the census files, docs.

---

### Task 1: The event record, the two new person fields, and the fourth directory

**Files:** Create `PermitEvent.swift`. Modify `RegistryRecord.swift` (`RegistryDirectory` L22; `PersonRecord` L141), `RegistryWriter.swift` (`directoryURL` L36), `RegistryReader.swift` (`load` L261; `Registry` L150; `MalformedRecord.Reason` L11), `RegistryCache.swift` (`Entry` L150, `reconcile` L612, `restore` L537). Tests: `PermitEventTests` (new), `RegistryReaderWriterTests`, `RegistryCacheTests`, `RegistryCanonicalCensusTests`, `TripwireGrepTests` (`registryPathPatterns` L7457).

**Verified facts:**
- `RegistryDirectory` cases carry no path; `RegistryWriter.directoryURL(_:in:)` L36 is the only mapping. A record's file is `<fingerprint>.json`, and `RegistryRecordProtocol` (L33) requires `fingerprint`, `sig`, `static directory`, `expectedSigner`.
- `PersonRecord` has no `CodingKeys` — property names ARE wire names. `role` defaults `"author"` (L160), written at RegistryAdmission.swift:271, :626 and RegistryPresence.swift:172, read by nothing.
- Records are verified over the FILE's bytes with `sig` removed (`RegistryCanonical.digestHex(ofJSON:)` L87), so unknown fields survive.

**Contract:**
- `RegistryDirectory` gains `.events` → `.maugham/people/events`, spelled in `directoryURL` only.
- `PermitEvent: RegistryRecordProtocol` — fields, ALL strings or string collections: `event` (its id — the record's `fingerprint`, so the filename is `<event>.json`; mint it as `<subject>.<ULID-shaped id>` so one subject's events sort and never collide), `kind`, `subject`, `role`, `scope`, `pieces: [String]`, `mark` (Task 2's wire form; a `[String: …]` of strings), `at` (ISO string via the date encoding records already use), `by`, `sig`. `expectedSigner == by`.
- `PermitEvent.Kind`: admitted, silentlyAdmitted, roleChanged, scopeChanged, revoked, revokedEntirely, readmitted, retired — ADR 0015 round-trip: an unrecognised raw value is PRESERVED (`.unknown(String)`), never degraded.
- `PersonRecord` gains `scope: String?` and `pieces: [String]?`, omitted from the encoding while nil so **a P2-era record's bytes and digest are unchanged** (pin this: encode a record with both nil and compare to a checked-in P2 fixture's canonical bytes).
- `RegistryReader.load` reads events into `Registry.events: [PermitEvent]`, verifying: filename == `event`; signature; signer == `by`; and **`by` is a root of the chain the subject is on, EXCEPT `kind == retired`, where `by` must be the subject device itself.** A failing event is LISTED in `malformed` with a new `Reason` (and its `sentence`), never dropped silently, never thrown over unless unreadable (RULING-54).
- `RegistryCache` remembers and restores events byte-faithfully exactly as it does records (`Entry.directory == "events"`); `reconcile`'s same-authority rule (P2b's P4) applies.

**Must not:** let an event signed by a non-root count (the whole ladder rests on it); change any existing record's canonical bytes; spell the path twice.

- [ ] Red tests: round-trip + unknown-kind round-trip; P2 fixture bytes unchanged; each verification refusal (wrong filename, bad signature, non-root signer, a retire signed by somebody else) lists as malformed — **disable experiment on each**; cache restores a deleted event.
- [ ] Implement; extend `registryPathPatterns`/`registryWriterAllowed` and the 42 census's derived walk so the new files are covered; run the planted-offender controls.
- [ ] Core + Mac + phone gates green. Commit `feat(registry): event records — the book's history of who could write what, one signed file per event`.

**Produces:** `PermitEvent`, `PermitEvent.Kind`, `Registry.events`, `RegistryDirectory.events`, `PersonRecord.scope/pieces`.

---

### Task 2: The mark — chain positions, rotation-safe

**Files:** Create `PermitMark.swift`. Modify `OpLogStore.swift` (beside `highestAppliedOpId` L542). Tests: `PermitMarkTests` (new), `OpLogStoreSegmentTests`.

**Verified facts (spec §3.3 stands on these — PIN THEM FIRST):**
- One `Verification` per file: `classify(url:bytes:state:trust:)` L610 → `classifyTail` L626 / `classifySegment` L717.
- `sealTailIfNeeded` (L1117) copies the whole tail into a segment and deletes the tail (L1188–1198); the next append starts from `verification.head ?? OpLogChain.genesis` (`JSONLAppendStore` L428). **So a new tail's first `prev` is `genesis`.**
- `OpLogChain.lineHash(_:)` L65 is public; `Line` has `bytes` and no digest field; there is no public find-by-digest — map `lineHash($0.bytes)` yourself.
- `OpLogDeviceState.markVerified(segmentDigest:)` L184 — find what that digest is computed over in `classifySegment` (L746–761) and **use the same digest**; do not invent a second one.
- `opLogFileURLs` (L1256) is UNSORTED; stream identity is `<docId>.<slug>`; `segmentIndex(fromFilename:docId:deviceSlug:)` L1311.

**Contract:**
- `PermitMark`: per stream key (`"<docId>.<slug>"`; translation streams `"<docId>.<language>.<slug>"` under a distinct prefix; the inbox stream likewise) → `{ segments: [segmentDigest], line: lineHash? }`. Wire form is strings only. An EMPTY mark is legal and means *nothing was applied* (P2's `nothingAppliedMark` in the new shape).
- `PermitMark.judge(streamKey:fileIsSegmentWithDigest:lines:) -> Judgement` where `Judgement` says, per line index, **old** or **new**: a listed segment ⇒ all old; the file containing `line` ⇒ old through that line inclusive, new after; any other file, any unnamed stream ⇒ all new.
- `OpLogStore.appliedPositions(ofDeviceIds:in:trust:) throws -> PermitMark` — sibling of `highestAppliedOpId` (same listing, same `classify` with `state: nil`), recording for each stream the digests of segments settled whole and the hash of the last APPLIED line (not held-back, not quarantined).

**Must not:** key anything by filename alone (the marked line moves into a segment at the next rotation); order files by segment index for the purpose of judging (a filename is the writer's to choose); read an opId.

- [ ] Red first: **the rotation pin** — append, mark, force a rotation, append more: the marked line is now inside a segment, and `judge` still splits at it. Then: a forged low-index segment not in the mark is all-new; a rewritten listed segment (different digest) is all-new; a backdated opId after the line is new; empty mark ⇒ all new; two devices judging the same bytes agree. Disable experiments on the three forgery cases.
- [ ] Implement. Gates. Commit `feat(oplog): a mark is chain positions — segment digests and a line hash per stream, rotation-safe`.

**Produces:** `PermitMark`, `PermitMark.Judgement`, `OpLogStore.appliedPositions(ofDeviceIds:in:trust:)`.

---

### Task 3: `Permit`, the timeline, and the verdict that carries it

**Files:** Create `Permit.swift` (the value only; the table is Task 4), `PermitTimeline.swift`. Modify `TrustTable.swift` (`TrustVerdict` L19; `resolve` L150; `verdict(forSealKey:)` L261), `TrustResolution.swift`. Tests: `PermitTimelineTests` (new), `TrustTableTests`.

**Verified facts:** `TrustVerdict` has seven arms incl. `.admitted(person:)`; the person↔device join is `verdict` L265–266 (`deviceByActorKey[fingerprint] ?? fingerprint`); `TrustTable.resolve(registry:mine:joinedRoot:)` is pure; `verifiedRegistry` (`TrustResolution.swift:147`) is the only legal registry source.

**Contract:**
- `Permit`: `.reviewer` · `.author(.book)` · `.author(.pieces(Set<String>))` · `.unjudgeable(raw:)`. Parsed from `(role, scope, pieces)` strings: missing scope ⇒ book; `"pieces"` with no list ⇒ empty set; anything unrecognised ⇒ `.unjudgeable`.
- `PermitTimeline`: built from one person's verified events ordered by event id; each entry `(permit, mark)`. **No events ⇒ one entry: author, book, no mark** (every P2 admission, and every root). `permit(for judgement…)`: a line is under the LAST entry whose mark judges it *new*, else the entry before — walk from newest to oldest. Revocation is NOT the timeline's job (the verdict's `.revoked` arm already exists); the timeline covers roleChanged/scopeChanged/admitted/readmitted.
- `TrustVerdict.admitted` carries what the walk needs to reach the timeline AND the actor: `admitted(person:, actor: DeviceActor?, timeline: PermitTimeline)` — or an equivalent that keeps `OpLogChain` ignorant of permits; choose the shape that leaves `OpLogChain.verify`'s signature alone and say which in the report. `.mine` needs the actor too (the `assistant` row binds on the root's own Mac). Count the arms; do not add one.
- A root's own timeline: a root is author-of-the-book unconditionally; an event naming a root as subject with any other permit is malformed (Task 1's reader gains this check here).

**Must not:** read `PersonRecord.role` to decide anything — the timeline only (Task 10 adds the census; write the code so it passes it). Must not change what any existing arm means.

- [ ] Red: P2-era person ⇒ author/book; unknown role ⇒ unjudgeable; two scope events ⇒ each line lands under the right entry (paired: a demotion's pre-mark lines stay author; a promotion's pre-mark lines stay reviewer); which actor key signed is recoverable on `.mine` and `.admitted`.
- [ ] Implement; the P2 `TrustTableTests` pass untouched. Commit `feat(trust): the permit timeline rides the verdict — a permit is evaluated as of the line`.

**Produces:** `Permit`, `PermitTimeline`, the widened `TrustVerdict.admitted`/`.mine`.

---

### Task 4: `DocumentClass` and THE table

**Files:** Create `DocumentClass.swift`; extend `Permit.swift`. Tests: `PermitTableTests` (new).

**Verified facts:** the only kind classifier today is `Deriver.appliesToManuscript(_:)` (`Deriver.swift:191`), an exhaustive switch — true for `.typingBurst, .bootstrap, .externalEdit, .checkpointRestore, .claudeAccept, .claudeAcceptRevert, .claudeReject`. Statements are ordinary `Document`s with their own op logs, registered in `ProjectManifest.statements` with a kind and a scope. The project stream's docId is `__project__`. Translations are NOT `OpKind`s (`TranslationRecord`, a separate stream). Read `OpKind.swift` whole before writing the switch.

**Contract:**
- `DocumentClass`: `.piece(id)`, `.pieceStatement(piece: id)`, `.projectStatement`, `.projectStream`, `.translation(piece: id)`, `.inbox`. `DocumentClass.resolve(docId:manifest:)`; an id the manifest does not know ⇒ `.piece(id)`.
- `Permit.allows(_ what: Written, in: DocumentClass, actor: DeviceActor) -> Allowed` where `Written` is `.op(OpKind)` | `.translationRecord` | `.inboxRow`, and `Allowed` is `.yes` | `.no(RefusedWhat)` | `.cannotJudge`. **Two exhaustive switches, no `default:`** — a new `OpKind` must not compile without a row. `RefusedWhat`: manuscriptText, disposition, passState, statement, task, translation, other.
- The rows are spec §2, verbatim. Group every `OpKind` into: manuscript text (= `appliesToManuscript` — CALL it, do not restate it), annotation creation, own-annotation edit/withdraw, disposition (accept/reject/stet/triage/reopen/archive and the revert), pass state, checkpoint, task, unknown. `.unknown` ⇒ `.cannotJudge`. If a kind fits no group, stop and ask — do not guess a row.
- Actor narrowing: `author` = the person's row; `assistant` = the reviewer row regardless of person; `translator` = `.translationRecord` only, and only where the person's permit covers the piece; `maugham` = `taskPriorityChange` only, where the person may sign tasks.

**Must not:** let `assistant` sign a manuscript-text kind under ANY person permit, including the root's — this is the constitution's sentence; disable-experiment it.

- [ ] Red: a table-driven test enumerating `OpKind.allCases` × every class × the four permits × the four actors against a literal expected grid checked into the test (the grid IS the spec; a reviewer reads it against §2). Plus the named negatives with disable experiments: assistant/manuscript; reviewer/disposition; scoped author outside her pieces; scoped author on a project statement; scoped author's task op allowed.
- [ ] Implement. Commit `feat(trust): the permission table — one exhaustive switch over what was written, where, by which key`.

**Produces:** `DocumentClass`, `Permit.allows`, `Written`, `Allowed`, `RefusedWhat`.

---

### Task 5: `PermitPartition`, the refusal cause, and both classify paths

**Files:** Create `PermitPartition.swift`. Modify `OpLogChain.swift` (`QuarantineCause` L545; `readmitting` L1028), `OpLogStore.swift` (`classifyTail` L626, `classifySegment` L717, `loadFileDiagnosed` L462, `loadSyncMerged` L1334), `JSONLAppendStore.swift` (`quarantineReason` L490, `setAside` L224), `AdmissionDecision.swift` (sentences). Tests: `PermitPartitionTests` (new), `PermitLoadTests` (new, modelled on `PendingLoadTests`), `OpLogChainTests`.

**Verified facts:** `RevocationSplit.partition(of:highestOpIdSeen:)` (`OpLogQuarantine.swift:187`) is the precedent — pure, runs in `readmittingWhatWasAlreadyApplied` (OpLogStore L669/L698) BEFORE `JSONLAppendStore<Op>.parse` (L671). `Line.refusal: QuarantineCause?` is per line (L490); `setAside` writes one `.lines` record per distinct cause (L242–251). `Line.settle` is `fileprivate` — re-settling goes through a function in `OpLogChain.swift`, as `readmitting` does. Fixtures: `PendingLoadTests` L45–133 (`writeRootRecord`, `admit`, `writeStrangerFile`, per-device `OpLogDeviceState`, suite-local `RegistryCache`).

**Contract:**
- `QuarantineCause.notPermitted(person: String, what: RefusedWhat, afterMark: Bool, actor: String?)`. Its sentences (spec §4.4) live beside the existing five in `quarantineReason` and are reachable from `AdmissionDecision`'s vocabulary — one phrasebook. *The assistant*, never a product name.
- `PermitPartition.partition(of: Verification, class: DocumentClass, streamKey:, fileSegmentDigest:, unowned: UnownedPiece) -> Verification`: for each APPLIED line (verified/unsealed under an `.admitted` or `.mine` verdict), decode just enough to know what was written, find the permit as of that line (Task 3 + Task 2's judgement), ask the table. `.no` ⇒ the line becomes quarantined with the cause; `.cannotJudge` ⇒ **pending**; `.yes` ⇒ untouched. **Line by line** — a refused line takes its neighbours nowhere. A seal line travels with the op before it, as in `RevocationSplit` (L226–230).
- **§4.5's rule, here, pure:** manuscript-text lines by an `.author(.pieces)` signer in a `.piece(id)` not in her set are **pending** iff `unowned == .nobodyHasWrittenItsText`, else refused. The caller computes `unowned` at the DOCUMENT level: after classifying every file of the docId, *has any key holding a book-author permit applied a manuscript-text line in it?* — so this is a two-pass in `loadSyncMerged` and in the load path around `loadFileDiagnosed`. Pending→refused later is harmless; refused→pending must not happen (pin it).
- Order in both paths: verify → revocation split → permit partition → parse. `highestAppliedOpId`/`appliedPositions` see the partitioned result (a refused line is not *applied*).
- `.mine` lines are partitioned too (the actor rows bind on this device): an `assistant`-signed manuscript line in this device's own file is refused.

**Must not:** refuse anything in a book with no events and no non-author actors' violations (the neutrality gate); set aside an unjudgeable line; hold a line pending that a permit plainly allows.

- [ ] Red, paired per spec §5: demotion (before stays / after refused); promotion (before stays refused / after applied); scope leaves / scope joins; the root writing in her piece is applied; her notes in the same span as her refused text ARE applied (line-by-line — disable experiment by making the partition whole-span); unknown kind pending; new-piece pending vs a book author's text exists ⇒ refused; assistant/manuscript refused on `.mine`. Each through BOTH `loadFileDiagnosed` and `loadSyncMerged`.
- [ ] A `.lines` record is written per cause with the right sentence; the full P2 suite passes untouched.
- [ ] Commit `feat(oplog): the permit partition — line by line, as of the line, in both read paths`.

**Produces:** `PermitPartition`, `QuarantineCause.notPermitted`, `UnownedPiece`.

---

### Task 6: The other streams, and whose annotation it is

**Files:** Modify `TranslationStore.swift` (`loadMerged` L213), `Maugham/Stores/InboxStore.swift` (`refresh` L244; `chainPolicy(trust:)` L200), `AnnotationDeriver.swift`. Create `AnnotationOwnership.swift`. Tests: `TranslationStoreTests`, `InboxStoreTests`, `AnnotationDeriverTests`.

**Verified facts:** `loadMerged` ALREADY resolves a real table (L221 `try trust ?? TrustResolution.resolve(...)`, used L243) and files held-back lines through `JSONLAppendStore.setAside` under the MANUSCRIPT's docId (L254). `appendBatch`'s keyless closure (L149) is the sanctioned write-side shape — **leave it**. `InboxStore.verifiedTrust()` L177–191 resolves verified trust off-main. `AnnotationDeriver.swift:123` reads `authorCollaboratorId`; ops carry `device` = `DeviceIdentity.deviceId(actor:fingerprint:)`.

**Contract:**
- `loadMerged` and the inbox read run `PermitPartition` with `.translation(piece:)` / `.inbox` and `Written.translationRecord` / `.inboxRow`. A reviewer's inbox rows are allowed; a reviewer's translation records are refused; a scoped author's translations of her own piece are allowed.
- `AnnotationOwnership.mayAmend(signerDevice:creatorDevice:signerPermit:class:registry…) -> Bool`: an edit/withdraw is honoured iff the signer holds author rights on that document OR signer and creator resolve to the SAME PERSON (device ids → person through the table's join, not string equality of device ids — her phone may withdraw what her Mac wrote). `AnnotationDeriver` calls it and drops an edit/withdraw that fails; the partition has already let the kind through.

**Must not:** touch the write-side closures; restate the person join (call the table's).

- [ ] Red: the three translation cases; reviewer inbox row applied; reviewer withdrawing ANOTHER reviewer's note is ignored (disable experiment); her phone withdrawing her Mac's note is honoured.
- [ ] Gates incl. phone. Commit `feat(trust): translations, the inbox and annotation amendments answer to the permit`.

---

### Task 7: The authority — `admit` with a permit, `changePermit`, and an event from every verb

**Files:** Modify `RegistryAdmission.swift` (`admit` L157, `revoke` L310, `retire` L504, `claim` L594, errors), `RegistryPresence.swift` (silent admission's event), `TrustEvents.swift` (`derive` L134), `TrustEventSentence.swift`, `Maugham/Stores/DocumentStore+Registry.swift` (`revoke` L48; `highestOpIdApplied` L285), `OpLogQuarantine.swift` (`RevocationSplit`), `AdmissionDecision.swift` (L281 — exhaustive). Tests: `RegistryAdmissionTests`, `TrustEventsTests`, `RevocationSplitTests`, `TripwireGrepTests` (`registryWriterCallers` L7529).

**Verified facts:** `revoke` writes through `RegistryWriter.resign` (L344–354) and is idempotent (L341). The person→device-ids join is `DeviceIdentity.deviceId(actor:fingerprint:)` over `record.actors` (DocumentStore+Registry L306–309, with the no-device-record fallback L314–315). `TrustEvent.Kind.silentlyAdmitted` exists and is never derived. `AdmissionDecision.sentence(for:)` is exhaustive over `RegistryAdmissionError`.

**Contract:**
- `admit(… role:scope:pieces: …)` with defaults preserving today's call sites (author, book). Writes the `admitted` event, THEN the record.
- `changePermit(person:role:scope:pieces:mark:in:by:cache:now:presenter:) throws -> PersonRecord`: refuses unless `by` is the root that admitted the person (`.notARoot`/existing arms), refuses a root as subject (new `.cannotChangeARoot` — *that would leave the book with no author*), is idempotent on an unchanged permit (no event), writes event THEN record via `resign`. `DocumentStore.changePermit(person:to:)` computes the mark with Task 2's `appliedPositions` + the open documents' snapshots, exactly as `highestOpIdApplied` folds them in today (L336–340).
- `revoke`, re-admission (an `admit` of a revoked person), `retire` and `RegistryPresence`'s silent admission each write their event. `retire`'s is signed by the device and carries ITS OWN files' positions. `revoke` keeps writing `highestOpIdSeen`; **where an event with a mark exists for that revocation, `RevocationSplit` reads the mark** (Task 2's judgement) — same keep/refuse semantics, tamper-proof positions; with no event (a P2 revocation) the opId path is unchanged.
- **Crash between the two writes:** latest event ≠ record is DETECTABLE — expose `RegistryAdmission.recordBehindEvents(person:in:) -> Bool`; P3b gives it a surface. The timeline already reads events, so enforcement is correct meanwhile.
- `TrustEvents.derive` takes events as its source where they exist (incl. `silentlyAdmitted`, roleChanged, scopeChanged) and keeps record-derivation for subjects with none. New sentences for the new kinds, both directions stated (*Sam became a reviewer. What she wrote before then stays in the book.*).
- **C8, here because these are the files:** the root-write guard keys on `myRoot`, not the registry; an unverifiable claim file is LISTED, not overwritten; adopted roots are checked to exist; `ClaimDecision.title` deleted; `claimedAt` moves on a later adoption. One commit of their own.

**Must not:** let any non-root change a permit; write a record before its event; produce an event on a no-op.

- [ ] Red: each refusal (disable experiments); event-then-record ordering (kill between the writes in a test seam; the timeline still enforces); P2 revocation path unchanged with no event; a marked revocation resists a backdated opId; `registryWriterCallers` still three files.
- [ ] Commits: `feat(registry): changePermit, and an event from every verb` · `fix(registry): the claim's five minors (C8)`.

---

### Task 8: The load seam — a device that may not write a piece mints nothing in it

**Files:** Create `Maugham/OpLog/Document+Waiting.swift`. Modify `Maugham/OpLog/Document+Load.swift` (internal `load` L268; `needsBootstrap` L317; `Bootstrap.run` L327–330), `Maugham/Views/EditorHost.swift` (`loadDocumentIfNeeded` L1014 and its catch). Tests: `BootstrapWiringTests` (`MaughamTests/OpLog/`), `DocumentWaitingTests` (new). Docs: CLAUDE.md's Hard-invariants Bootstrap bullet.

**Verified facts:** `needsBootstrap = !logExists && !parsed.isEmpty` (L317) and Bootstrap runs BEFORE the op-log read. `BootstrapWiringTests` has four tests (L80, L98, L129, L156) and enforces *every load path bootstraps*. A thrown load sets `EditorHost.loadError` and posts a notice — the writer sees a refusal pane.

**Contract:**
- Before `Bootstrap.run`: resolve this device's permit for the document (`actor`'s key, Task 3) and its class (Task 4). If `Permit.allows(.op(.bootstrap), …)` is not `.yes`, **do not bootstrap**: throw a typed `DocumentLoadError.waitingForPiece(docId:)` (or return a typed waiting value — choose what `EditorHost` can render without a second observable, tripwire 6, and say which). `EditorHost` renders it as its own calm state — *Waiting for this piece to arrive from [root's label]* — not as an error, and re-attempts the load when the ops directory changes (the presenter callback already routes sidecar changes through `MaughamSidecarPath`).
- A keyless book, a P2-era book, the root, a book author: unchanged — all four existing `BootstrapWiringTests` pass untouched. The MCP transient load (`AnnotationToolHelpers.withAnnotationDocument`) is `.assistant`, which may never bootstrap: **measure what it does today on an unanchored file** (test L156 says it bootstraps) and STOP AND REPORT before changing it — that test encodes a shipped behaviour the reviewer row contradicts, and the resolution is a ruling, not an implementation choice.
- The waiting state reads NOTHING from the `.md` as truth (tripwire 20).

**Must not:** refuse a load for the root or in a registry-less book (constitution must #1); mint a bootstrap a device may not sign (disable experiment: remove the guard, watch a reviewer's device write a `.bootstrap` line).

- [ ] Red → implement → `BootstrapWiringTests` green untouched (except by ruling, above). Reword the CLAUDE.md invariant: *…from any new manuscript load path **that may write the piece***. Commit `feat(oplog): a device that may not write a piece waits for it — the load mints nothing`.

---

### Task 9: Remembered foreign heads — a shortened file is noticed

**Files:** Modify `OpLogDeviceState.swift` (`Stored` L39; `remember` L158; `prune` L290), `OpLogStore.swift` (`loadFileDiagnosed` L462–499), `OpLogChain.swift` (`BreakReason` L512 only if a case is needed), `Maugham/OpLog/` integrity surface (find `ProjectIntegrity.check`). Tests: `OpLogDeviceStateTests`, `ForeignHeadTests` (new).

**Verified facts:** `heads` is written at exactly two sites, both for THIS device's files (`JSONLAppendStore.swift:461`, `OpLogStore.swift:485`). `fileKey(_:)` L200 = `<sha256(root)>/<filename>`. `prune` drops entries whose root `rootIsGone`; `verifiedSegments` is never pruned. `loadSyncMerged` writes nothing, by design.

**Contract:**
- `Stored.foreignHeads: [String: String]` keyed by STREAM under the root hash (not filename — rotation moves the line), value = the last settled line hash; optional in the decoder so an old state file loads. Written in `loadFileDiagnosed` when a foreign file settles; pruned by the same `rootIsGone` rule in the same pass (a pruning story from day one — the P1 state file needed one retrofitted in v0.38.0).
- On a later read: if the remembered hash is found in NO file of that stream, the stream has been **truncated**. Nothing is refused and the surviving lines stay applied (the words that remain are good); the finding is reported through the existing integrity channel with the stream's device resolved to a label, and recorded once (not per load) for P3b's History entry — expose `OpLogStore.truncatedStreams(in:)` or the equivalent the integrity check already aggregates.
- Rotation is NOT truncation: the pin is *mark, rotate, read ⇒ no finding*.

**Must not:** refuse a load or set anything aside over a truncation; grow without bound.

- [ ] Red: truncate a foreign tail ⇒ finding; rotate ⇒ none (disable experiment: key by filename and watch rotation raise a false finding); prune drops a gone project's entries; old state file decodes.
- [ ] Commit `feat(oplog): this device remembers where other devices' files stood, and says when one is shorter`.

---

### Task 10: Censuses, the measurement, the docs, the branch gate

**Files:** `MaughamTests/TripwireGrepTests.swift`, `Packages/MaughamCore/Tests/MaughamCoreTests/RegistryCanonicalCensusTests.swift`, `MaughamPhoneTests/TripwirePhoneGrepTest.swift`; `docs/adr/0032-the-signed-op-log.md`, `Maugham/OpLog/AREA.md`, `CLAUDE.md`, the parent spec (annotate §4.9, §8 per this spec's §11), `docs/roadmap.md` only if an entry's status changes.

**Contract — three new censuses, each with a planted offender and a control** (memory: *a census beats a warning*):
1. **The role check reads the timeline.** No production source outside `Permit.swift`/`PermitTimeline.swift`/the record's own file reads `.role`, `.scope` or `.pieces` off a `PersonRecord`. (P3b's pane will DISPLAY them — allow-list by file when it exists, not now.)
2. **One table.** `Permit.allows` is the only production switch over `OpKind` that answers a permission; `appliesToManuscript` has the callers it has today plus `Permit.swift`. Census the spelling `case .typingBurst` (or the group helper) outside the two files.
3. **The partition has exactly the call sites it has** — name them in an array and census the count against the array (memory: *count the array, not the prose*).
Extend 40/41/42 and the phone twins for the events directory and `PermitEvent` if Task 1 did not finish them; the phone's allow-lists stay EMPTY.

**C9 — measure, do not move:** time `rebuildAnnotationsCache` (`ProjectStore+Annotations.swift:167`, resolve at L211) and `rebuildAggregationCache` (`ProjectStore+Tasks.swift:196`, L257) on a 30-document fixture before and after this branch. Both carry a comment saying main-actor is a DECISION (P2b Task 10). Report the numbers; move nothing unless the after-number exceeds a frame budget you state, and then stop and report rather than moving it.

**Docs:** ADR 0032 **P3a addendum** (marks as chain positions and the two rejected alternatives; events as history; the timeline is the only thing the check reads; line-by-line; the Bootstrap invariant's amendment; foreign heads). `Maugham/OpLog/AREA.md` gains the sections and tripwire rows. CLAUDE.md: new tripwire rows for the three censuses, rows 40–42 amended for events, the OpLog per-area cell gains P3a — **name members, never counts**. Docs describe what SHIPS: P3a has no surface, so no guide page changes.

- [ ] Censuses red on planted offenders, green on the tree.
- [ ] `./scripts/test.sh full` green, skip list read and reported. `swift test` green. `./scripts/test.sh phone` green.
- [ ] **Whole-branch review** (opus) with the ruling ledger — the handoff's rulings plus the spec's §5 table — and the seams NAMED: Task 2×7 (a mark computed by one, judged by the other — do they agree on the stream key and the segment digest?); Task 3×5 (does `.mine` carry the actor everywhere the partition needs it?); Task 5×8 (can the waiting state and the pending-new-piece rule disagree about the same document?); Task 5×9 (is a partition-refused line ever counted as a remembered head?); Task 1×7 (event-then-record under `RegistryCache.reconcile`). One fix wave.
- [ ] Merge to LOCAL main. Do not push a release; the milestone ships whole. Write the P3a outcome into the handoff note and the memory index, then re-derive P3b against the built code.

---

## Self-review (done 2026-09-19)

- **Spec coverage:** §3.1/§3.2 → T1; §3.3 → T2; §3.4 → T3; §4.1/§4.2 → T4; §4.3/§4.4/§4.5's rule → T5; §4.3's other streams + §4.2's own-annotation rule → T6; §6 → T7; §4.6 → T8; §4.7 → T9; §10's P3a share + §12 → T10. §4.5's QUESTION, all of §7, §8, §9 are P3b/P3c by design.
- **Open by design, flagged where they bite:** the shape of the widened verdict (T3 — implementer chooses, reports); throw-vs-value for the waiting state (T8); the MCP transient load's bootstrap (T8 — stop and report; likely a ruling).
- **Known release consequence, not this plan's to solve:** a v0.40.0 Mac ignores roles and would apply what a P3 Mac refuses. The paired release must make every Mac on a book update; whether an older build should be made to REFUSE a book that has events is a decision for P3c's release task — raise it with Denver when P3b is planned.
