# Signed op log P3 — roles, scope and the collaborator

**Status:** DESIGNED 2026-09-19 (brainstorm with Denver; every ruling below is his, dated that day). **P3a BUILT 2026-09-20** on branch `claude/signed-op-log-p3a-2026-09-19` — see *As built in P3a* below. P3b and P3c unbuilt; re-derive each against the built code (rule 11).

## As built in P3a — where the build corrected this spec (2026-09-20)

Written so P3b is planned against the truth rather than against the design. Each
of these was found by building the thing, and each is a change to what this spec
says, not an implementation detail.

- **§3.3's mark is what the root had SEEN, not what it had applied** (amended in
  place above). A mark selects which permit judges a line; it does not bless the
  line. *Last applied* would let refused text at the end of what the root had
  read fall after a promotion's mark and be applied under the new permit — the
  pardon §5 forbids — and would re-judge a segment's honestly applied lines under
  a demotion because one refused line had kept the segment out of the mark. A
  **revocation** is the one act whose mark means applied, so the store answers
  two questions: `OpLogStore.seenPositions` and `OpLogStore.appliedPositions`.
- **§3.4 does not say what governs the lines BEFORE a person's first event, and
  the answer is *it depends on that event's kind*.** `admitted` /
  `silentlyAdmitted` ⇒ that event's permit governs everything on both sides of
  its mark, because nothing precedes an admission and a stranger's HELD
  manuscript text would otherwise fall to the book-author default the instant she
  was admitted as a reviewer. `roleChanged` / `scopeChanged` / `readmitted` first
  ⇒ the person was admitted under P2, so the opening stays book author: **a
  demotion must not reach back**. An unknown kind first ⇒ unjudgeable, so the
  lines are held. `revoked` / `retired` are skipped when finding *first*.
  `PermitTimeline.opening(before:)` is the five arms. **Consequence for P3b: a
  re-admission must mint `.readmitted` and never `.admitted`.**
- **A retirement is ONE-WAY, and a retired device's later words are SET ASIDE rather than held** (found building P3b Task 7, 2026-09-20; ruled by the controller the same day). §7.3's third question — *N paragraphs were written on it while retired — bring them in?* — and §5's *re-admission asks* are **withdrawn**, because neither of the two things they assume is true of the build. A sealed span written at or after `retiredAt` is `.quarantined`, not `.pending` (`TrustVerdict.settling`, OpLogChain.swift:1158–1159): it is refused with `QuarantineCause.afterRetirement`, written into a `.lines` record reading *written after this device was retired*, and `RevocationSplit.partition` excludes a retirement by name, so none of find 5's keep-what-was-applied machinery reaches it. And there is no verb to re-admit a retired DEVICE at all: `retire` is idempotent and clears nothing (RegistryAdmission.swift:1318), `RegistryPresence.ensureDeviceRecord` refuses to un-retire on purpose, and `admit`'s readmission arm is about a revoked PERSON. Building the question would have meant an un-retirement verb in the registry's authority set plus a keep/refuse cut for `.afterRetirement` — a P2b-sized addition, reversing a rule the build states in three places. **A one-way retirement is the honest shape**: a device that stands itself down has said so with its own key, and the words it writes afterwards are somebody else's problem to bring back deliberately rather than the book's to re-absorb on a button. What is unchanged: its unsealed tail stays APPLIED as pre-retirement work (`settlingAnUnsealedSpan` answers nil for `.retired`), so nothing a retiring machine had in flight is lost. Its later words come back through §7.4's **Send to Inbox**, by the writer's own hand, like any other set-aside text. **Cost if wrong**: a writer who retires a Mac by mistake recovers its later paragraphs one at a time through the Inbox instead of with one press.
- **A contested non-author actor key belongs to NOBODY, forever.** Nothing proves
  possession of a key a device record merely LISTS; only the author slot is
  self-proving. One claimant ⇒ that device's, whatever its standing; two or more
  ⇒ nobody's, and revocation does not cure it. Standing plays no part, because
  awarding a disputed key to the only standing claimant made a revoked owner's
  later lines read as the standing liar's. `Registry.actorKeyOwners` is the one
  resolution. **Carry to P3b: the admission sheet must not offer a CONTESTED key
  as a stranger to admit — it is a disputed key, not a new device — and it must
  not offer a NON-AUTHOR actor key at all** (a held span whose slug reads
  `assistant-`/`translator-`/`maugham-` waits for its device record instead).
- **Everything the LOAD PATH or a derivation emits on its own account is the
  AUTHOR actor's, whatever actor opened the file** — the bootstrap, both
  pending-recovery folds, the task anchors and their `taskCreate`. §4.6 does not
  say this and it has to: each is a kind the table refuses to `assistant` and
  `translator`, so under MCP they were lines the partition would set aside, with
  `bootstrap` the worst (a document whose opening op leaves the book derives
  EMPTY, and the first autosave writes that empty render over the manuscript).
  `Document.authorEmissionDevice(loadedAs:)`.
- **An UNSEALED span answers to its file's verdict** (Task 11, from the
  2026-09-20 audit, PR #65 F1+F2; a defect in released v0.39.0/v0.40.0 that this
  spec did not notice). Trust was consulted at `case .seal` alone, so a signed
  foreign device's writing since its last seal was applied whatever the register
  said. The file's key is the last chain-verified seal's whatever ITS verdict,
  else the key a verified device record gives the filename's slug, else
  unchanged — and that third arm is the unsigned door.
- **§4.9's *quarantined whole* and its two-row table were already superseded
  here**; the parent spec now carries the annotation in place.

Three things this spec asked for that P3a deliberately did **not** do, each with
its reason recorded in the ADR's *limits* section: the unsigned door stays open
(parked for Denver); roles guard the words and not the binder; and the label-wide
permit verb exists but nothing presses it, because permits are per person RECORD
and P2b merges devices under one LABEL.


**Parents:** `2026-09-05-signed-op-log-design.md` (§4.9–§4.11, §5, §6, §8 — **amended here**, see §11), `2026-09-09-signed-op-log-p2-people-and-admission-design.md` (BUILT), [ADR 0032](../../adr/0032-the-signed-op-log.md). The brief and the first six rulings are in `docs/superpowers/notes/2026-09-17-signed-op-log-p3-handoff.md`.

## 1. What P3 is

P1 made every line provable to a device. P2 gave the book a register of who may write in it, labels only. P3 makes the register say **what each person may write, where, and since when** — and enforces it where the lines are read, so that a permission is a fact about storage rather than a courtesy of the UI.

Three things are new against the parent spec, all ruled 2026-09-19:

- **Scope.** Two people writing different pieces of one book and reviewing each other's is a first-class case. An author is an author *of the whole book* or *of some pieces*.
- **History.** A permit is evaluated **as of the line**, never as of today. A demotion does not reach back; a promotion is not a pardon.
- **Line by line.** A span that carries lines its signer may not write loses those lines and keeps the rest (amends parent §4.9's *quarantined whole*).

## 2. The ladder

| rung | may sign |
|---|---|
| **reviewer** | annotation creation (comment, query, suggestion, craft note); edit/withdraw of their OWN annotations; inbox rows |
| **author of some pieces** | inside their pieces — the piece's text, dispositions, pass states, the piece's own statement, its translations: everything. On the project stream: task ops. Everywhere else: the reviewer row |
| **author of the whole book** | everything, including project statements (intent, visual language, lessons, first reader, edition briefs). Two book authors editing one project statement resolve last-writer-wins, as today |

**The root** is a book author with one more power: it alone admits, revokes, and changes a role or a scope — and never its own (a book must not end up with no author). The root is whole-book at storage **always**; on a piece assigned to someone else it takes review posture *cooperatively* (§8) with an override, because restricting a root that can revoke and reassign is theatre.

**The four actor keys narrow within the person's permit** (parent §4.9's 2026-09-08 paragraph, unchanged in substance): `author` = the person's permit; `assistant` = the reviewer row, always, on every device including the root's — *MCP never mutates manuscript text* at the storage layer; `translator` = translation records only, any language, only for pieces the person's permit covers; `maugham` = the task priority rebalance only, where the person may sign tasks.

**Roles guard the words, not the binder** (handoff decision 6). `OpKind` has no structural cases; create/rename/reorder/trash go through the unsigned manifest. Structure is cooperative under P3 and the guide says so. Signing structure is its own roadmap milestone (Group 4, *Signed structure*). One consequence is stated rather than hidden: *which piece a piece-statement belongs to* is a manifest fact, so that link is cooperative too.

## 3. Records, events, marks

### 3.1 The person record — current state

`PersonRecord` stays what it is: the current state, re-signed in place through `RegistryWriter.resign` so unknown fields survive. It gains:

- `role`: `"author"` | `"reviewer"` (the field exists, written `"author"` at three sites, read by nothing).
- `scope`: `"book"` | `"pieces"`. **A missing `scope` reads as `"book"`** — what every P2-era record means. Explicit strings, never absent-vs-empty: an author of some pieces with none yet is a real state (*she may write what she starts*), and a frozen signed format must not hang two opposite meanings on a missing key.
- `pieces`: a list of document-id strings; meaningful only under `"pieces"`; may be empty.

All strings (tripwire 42: `JSONSerialization` normalizes numbers).

**An unrecognised `role` or `scope` holds that person's lines PENDING — never set aside.** An older Mac must not quarantine what a newer one would apply.

### 3.2 Event records — the history (handoff ruling 3A)

One signed file per event under `.maugham/people/events/` — one file per event because a shared append-only file is tripwire 17. Kinds: admitted, silently admitted, role changed, scope changed, revoked, revoked entirely, re-admitted, retired. Fields, all strings: the kind, the subject (person or device), the resulting `role`/`scope`/`pieces`, the **mark** (§3.3), the date, the signer.

- **Signer:** the root, except a retirement, which the device signs for itself (as `retire` already is).
- **Authority is the existing three files.** `RegistryWriter` spells the directory (tripwire 40 — a fourth path in the one function); `RegistryAdmission` is the only writer of an event (tripwire 41); `RegistryCanonical` decides what the signature covers (tripwire 42). `RegistryCache` remembers events byte-faithfully and restores them loudly, as it does records. The phone writes none.
- **Order of writes: the event, then the record.** A crash between them leaves the history whole and the current-state record one step behind; the reader notices (latest event ≠ record) and the root's pane offers the re-sign.
- **`TrustEvents`** reads event records as its source for the dated entries under History's Project heading. Its record-only derivation stays for books (or people) with no events. `silentlyAdmitted` — a `Kind` that exists and is never derived — finally has a writer, which closes C11.

### 3.3 What a mark is

P2's mark is one opId per person (`highestOpIdSeen`). **P3's marks are not that**, for two reasons found in design:

- An opId carries a timestamp **its own writer chooses** — a demoted author could stamp new text with an old id and slip under the mark.
- Fixing that with each device's own memory makes a fresh Mac (no memory) apply what the root's Mac refused: divergence.

So a mark is **chain positions, from shared data**. Verified against the code 2026-09-19, and it shapes the format: **each file is its own chain** — `classify` yields one `Verification` per file, and after a rotation the new tail's first line links to `genesis`, not to the segment's last line (`sealTailIfNeeded` copies the whole tail into a segment and deletes it). So *position in the file* cannot be keyed by filename (the marked line MOVES from the tail into a segment at the next rotation) and cannot be ordered across files by anything the writer does not control (a segment index is a filename).

A mark is therefore, per STREAM of the subject's (`<docId>.<slug>`, and the translation and inbox streams likewise), two things the root SAW: **the digest of every whole segment it had read and judged**, and **the `OpLogChain.lineHash` of the last line it had read and judged** — *seen*, not *applied* (corrected 2026-09-20 in the P3a build). A mark does not bless lines; it selects which PERMIT judges them. Were the position *the last line applied*, refused text sitting at the end of what the root had read would fall AFTER a promotion's mark and be applied under the new permit — the pardon §5 forbids — and a segment with one refused line in it, left out of the mark, would have its honestly-applied lines judged under a demotion's new permit and refused retroactively. Lines the root refused under the old permit stay under the old permit and stay refused; lines it applied stay applied. Not *seen*: a torn tail line, and anything a broken chain quarantined. **A revocation is the one act whose mark means *applied*** (*keep what this Mac had applied*), so the store answers two questions — `seenPositions` for permit events, `appliedPositions` for revocation. Judging a file: a segment whose digest the mark lists is wholly under the OLD permit; the file that CONTAINS the marked line hash (the tail then, some later segment now — a line's hash covers its `prev`, so it is unique in its chain) is old up to and including that line and new after it; every other file, and every stream the mark does not name, is under the NEW permit. Every device computes the same answer from the same bytes; backdating an opId, renumbering a segment or rewriting one buys nothing.

Honest late sync — her offline second Mac's writing from before the change — lands as *after the mark* and is refused, with the inbox door (§7.4). That is ruling 1's choice, applied uniformly to every kind of mark.

Revocation events carry the map too. `highestOpIdSeen` stays on the person record, written as today, for P2-era readers; where an event with a map exists, the map is what `RevocationSplit` reads.

### 3.4 The permit timeline

`PermitTimeline` (Core, pure): a person's events in order, each a `(permit, mark)`. A person with no events has one permit — author, book, from the start (every P2 admission). The role check reads **the timeline and never the record**. `TrustResolution.verifiedRegistry` stays the one registry read; the timeline is built there or nowhere, and `TrustVerdict.admitted` is how it reaches the walk — **no parallel table** (tripwire 39).

## 4. The check

### 4.1 Document class

`DocumentClass` (Core): a lookup from a stream's document id to *manuscript piece · piece statement (→ its piece) · project statement · project stream · translation (→ its piece) · inbox*, resolved from the manifest. An id the manifest does not know is a piece in nobody's scope.

### 4.2 The table

`Permit.allows(kind:class:actor:)` — **one exhaustive switch** over `OpKind` × `DocumentClass`, a second narrower one for the actor, beside `Deriver.appliesToManuscript` (today's only kind classifier). A new `OpKind` cannot compile without a row. `.unknown` (a newer build's kind) → **pending**, the same rule as an unknown role.

*Own annotations* is a same-person rule, not a per-file one: the partition lets edit/withdraw kinds through on the reviewer row, and `AnnotationDeriver` honours one from a signer without author rights on that document only when signer and creator resolve to the same person — through one Core helper, never restated.

### 4.3 The partition

`PermitPartition` — pure, modelled on `RevocationSplit.partition`: verified lines + the signer's `PermitTimeline` + the file's `DocumentClass` → *applied* / *refused, with a cause per line*. It runs where `RevocationSplit` runs, in **both** classify paths (`loadFileDiagnosed` and `loadSyncMerged`), and in the translation and inbox streams.

- **The translation and inbox streams run the same partition.** (Corrected 2026-09-19 against the code: `TranslationStore.loadMerged` ALREADY resolves a real `TrustTable`; only `appendBatch`'s write-side closure is keyless, which is the sanctioned must-not-widen-past-my-own-hand shape of tripwire 39, as is the phone's default `ChainPolicy` closure. So nothing "joins" the table — the read paths gain the partition, and the write paths are left alone.)
- **Line by line** (ruling, amending parent §4.9). Ops are independent; a note anchored to a set-aside paragraph falls to the staleness handling that already exists; the revocation split already applies part of a span.

### 4.4 Refusal

One new `QuarantineCause` arm carrying the person, what was refused (manuscript text · a disposition · a pass state · a statement · a task · a translation), and whether the line is after a mark. `JSONLAppendStore.setAside` already groups a `.lines` record per distinct cause. The sentences join `AdmissionDecision`'s vocabulary — one phrasebook:

- *Sam's Mac wrote 2 changes to the manuscript, which a reviewer can't. Kept in backup.*
- *Sam's Mac wrote 14 changes to "Chapter 4", which isn't one of her pieces. Kept in backup.*
- *…after it stopped being hers.*
- *The assistant on Sam's Mac…* — the AI actor is never given a product name.

A role violation is **set aside**, not pending: something is wrong with it.

### 4.5 Her new piece — pending, with a question

For the TEXT, creation is provable: every document opens with a signed `bootstrap`. An author-of-some-pieces' manuscript lines in a document are **pending** iff no book author's key has signed a manuscript op in that document (somebody's NOTES on it do not make it theirs) **and** it is in nobody's scope; if a book author has written its text, the piece is theirs and her lines are set aside (§4.4). Computable by every device from shared data. Pending→set-aside later is harmless — nothing was applied.

The question is *Sam started "X" — is it hers?* **Hers** is a scope event adding the piece. **Not now** leaves it pending — never *yours*: applying her text as the opening of a piece that becomes the root's is the pardon shape §5 forbids. Her Mac shows a standing line: *Waiting for [root's label] to add this piece to yours.*

### 4.6 The load seam

`Document.load` runs Bootstrap. On a device with no manuscript permit for a piece, opening it before its ops have synced would mint a `bootstrap` the device may not sign. The load path gains a **waiting for this piece to arrive** state that mints nothing and shows nothing as truth (tripwire 20: not the `.md`). This touches a hard invariant (`Bootstrap.run` from every load path; `BootstrapWiringTests`) — the invariant becomes *…from every load path **that may write the piece***, and the test moves with it. Opus, and its own review.

### 4.7 Remembered foreign heads (handoff ruling on #6)

`OpLogDeviceState` remembers nothing about other devices' files today. It gains one remembered head per foreign file, written when the file settles in `loadFileDiagnosed`, pruned by the rule that already prunes heads (`rootIsGone`). A foreign file whose chain no longer contains its remembered head has been **truncated**: a dated History entry and an integrity finding that names the file and points at Backup; the surviving prefix stays applied; nothing is refused over it. With §3.3's marks doing the permit work, this memory has exactly one job.

## 5. Both directions, stated once

| act | what stays | what changes |
|---|---|---|
| **demotion / a piece leaves her scope** | everything at or before the mark stays applied. History: *Sam became a reviewer. What she wrote before then stays in the book.* | her manuscript lines after the mark are set aside in her name |
| **promotion / a piece joins her scope** | manuscript lines she signed while the permit said no **stay set aside** — a promotion is not a pardon | lines after the mark are applied |
| **revocation** (P2, unchanged) | what this Mac had applied, by default; *Set Aside Everything* is the second button | everything after |
| **late-sync half of any mark** | never applied — nothing judged under a closed permit enters by the log | the inbox door (§7.4) |
| **retirement** (ruling 2C) | the retired Mac applies its own later lines — typing never fails — under a standing banner | **AMENDED 2026-09-20:** every other device SETS THEM ASIDE (`QuarantineCause.afterRetirement`) rather than holding them, and there is no re-admission to ask; they come back through §7.4's Send to Inbox. See *A retirement is one-way* under *As built*. Its unsealed tail is applied everywhere, unchanged |
| **the root on her piece** | applied, always | the app warned first (§8) |

## 6. The acts

`RegistryAdmission` stays the authority:

- `admit` gains role, scope, pieces, and writes the admitted event.
- **`changePermit(person:role:scope:pieces:…)`** — new. The root only; never on itself; computes the mark (§3.3) from what this Mac has applied, writes the event, then re-signs the record.
- `revoke`, re-admission, `retire` each write their event (`retire`'s signed by the device, carrying its own files' positions — what ruling 2C's *written while retired* is derived from; no new op field, no schema change from it).
- Refusals — *only the Mac this book was started on can change that*; *that would leave the book with no author* — are new `RegistryAdmissionError` cases with sentences in the one phrasebook.

**`AdmissionMemory` is unchanged in shape**: project-keyless, label only. A role is a fact about one book.

## 7. Surfaces — the Mac

### 7.1 The admission sheet

For somebody else's device: a role control (*Reviewer* · *Author of some pieces* · *Author of the whole book*) and, for the middle one, a piece picker over the tree. The iCloud share keys pre-fill the name and a suggested role (a read-only share suggests reviewer) — their one surviving use. A known machine arrives with its label filled and **only the role asked, once per book**. The writer's own devices never see the sheet.

### 7.2 People & Devices

Each person's row shows role and pieces; changing either goes through the pane's one `Confirmation` type, whose text states both directions (*What Sam already wrote in Chapter 4 stays. Anything she writes there from now on is set aside.*). Also here: pending new-piece questions (*Hers* / *Not now*, answerable later); an **unsigned** line on a device with no enclave (#8 — with a dated History entry once per project; under roles, unsigned decides whether a device's writing is ever applied elsewhere); a nameless device no longer shows its code as its own name (C2).

### 7.3 The questions a load can raise

**AMENDED 2026-09-20 (P3b Task 7) — the third question is withdrawn; see *A retirement is one-way* under *As built* below.** A load raises TWO questions, not three: the admission question, and the new piece (§4.5), both on the same load path and through the same held-lines union (`DocumentStore.heldLines`). The retired Mac's banner is in the editor's status-footer register, stronger than today's Settings notice.

### 7.4 The inbox door (ruling 1)

Any set-aside record whose lines are manuscript text gains **Send to Inbox** in History's set-aside disclosure: each refused paragraph becomes a capture attributed to its writer. Nothing touches the op log; the words come back through the writer's own hand as the writer's own ops. `InboxPane.setAsideNotice` becomes reason-aware (C1); a set-aside record's sentence is re-derived from the current cause rather than frozen in the sidecar (C16).

### 7.5 Whose piece is whose (ruling A+C)

The Inspector gains *Written by Sam*; the altitude table gains a **Writer** column, hidden in a one-author book. **The tree is untouched** — parent §5's *nothing in the tree, the footer or a badge* stands.

## 8. The membrane widens to the table

Today a non-author role locks exactly one thing: text mutation in the editor (`EditorEditPolicy`). Left alone, a reviewer's Mac would let her press Accept and then set her own act aside.

One Core value, **`Posture`**, derived from *this device's own permit for the document shown*, and every surface gates on it: a locked editor; no dispositions in the queue or the margin; no pass chips; statement panes read-only; no structural verbs in the tree (cooperative); no Run for a round. The root on somebody else's piece gets a warning and an override. One spelling, asked of the permit and never of a role name — a census with a planted offender, because this is the distinction most likely to be re-spelled per surface.

**Component A retires.** `CollaborationRole`, `ShareIdentityMapper`, `ReviewPosturePolicy`, `ProjectWindow.resolvedRole`/`shareReader`/`effectivePosture` and the phone's `SharingRoleBanner` are deleted. `SharingStatusPill` stays as a sharing indicator that claims no role. `FileURLShareMetadataReader` survives with one caller, the sheet's defaults. `authorCollaboratorId` is decoded and never written; attribution is the signing device through the registry. **A book with no registry** (a keyless Mac) has posture *author* — P1's behaviour exactly.

## 9. The inbox and the phone

- **Inbox attribution.** `InboxByline` resolves a row's `deviceId` to a person: *from Sam*. No new field. Her rows pass through the same partition.
- **The phone.** `DeviceStanding` gains the permit. The Annotations tab hides dispositions wherever posture forbids — per piece for an author of some pieces; capture is always offered. Settings shows role and pieces and gains a refresh watcher (C5). The phone's two `ChainPolicy` sites (`InboxCaptureWriter`, `AnnotationWriter`) are verified to take their closures from the table (C7) — a reviewer's phone is the first phone whose lines another person's Mac must judge. The phone signs no record and no event; its censuses stay empty.

## 10. Constitution, ADR, docs

- **Constitution.** *AI is never the author* gains its storage-layer sentence and falsification condition (parent §6) and the `assistant` row as its mechanism. New, stated as a limit: *roles guard the words, not the binder.*
- **ADR 0032 — P3 addendum:** line-by-line set-aside; marks as chain positions and why not opIds or local memory; events as history and the timeline as the only thing the check reads; scope; the root asymmetry; the load seam's amendment to the Bootstrap invariant.
- **Guides.** `docs/guide/people-and-devices.md` gains roles, scope, the three questions and the inbox door; `docs/guide/index.json` is explicit. The WF1 spec gains a header note: Component A retired.
- **CLAUDE.md.** Tripwires 39–42 extended (events directory; events' writer). New tripwires with census + planted offender: the permit table has one spelling; `Posture` is asked of the permit; the role check reads the timeline, never `PersonRecord.role`. The Hard-invariants Bootstrap bullet is reworded per §4.6. The OpLog per-area cell gains P3.

## 11. Amendments to the parent spec (annotate in place)

- §4.9 *quarantined whole* → line by line (§4.3). §4.9's two-row table → the ladder (§2).
- §4.9/§4.6 marks → chain positions (§3.3).
- §5 stands; the Writer column and Inspector line are how a co-written book shows itself without amending it.
- §8's single P3 plan → three.

## 12. Testing

- `PermitPartition`, `PermitTimeline`, `Permit.allows`, `DocumentClass`: pure Core, table-driven — every `OpKind` × class × rung × actor cell pinned.
- Every row of §5 is a **paired** test, one per direction. (P2's two wrong rulings were each half of a two-sided rule.)
- The mark: a backdated opId after a mark is refused; a fresh device and the root's device reach the same partition from the same bytes.
- Mac↔phone round-trip integration tests for the permit and posture (tripwire 19).
- Every suite that asserts *verified* injects the test signer (tripwire 36). New fixtures register their roots for teardown (C10's factory, from P3c on; not leaked before it).
- **Smoke**, on the two-Mac rig (`scripts/second-mac.sh`, `--name third`): a co-author; an author of some pieces; a reviewer; a demotion while she is typing; a piece she starts; *Not now* then *Hers*; retire, type, re-admit; Send to Inbox; a truncated foreign file. **Closing smoke with a second Apple ID** — WF1's participant-side iCloud review is still unverified.

## 13. Shipping

A Mac+phone **paired release** — a check that changes what a reader APPLIES. No new `OpKind` is expected (events are registry records, not ops); whether the schema version moves is confirmed at the P3a plan. The milestone ships whole: slices land on main, nothing is pushed as a release until P3c's smoke.

- **P3a — the permit, enforced.** Events + marks + `changePermit` (§3, §6); the timeline; the table and partition (§4.1–4.4), including §4.5's pending-vs-set-aside RULE (the question's surface is P3b's); the partition in the translation and inbox read paths; foreign heads (§4.7); the load seam (§4.6). Carries: C8, C9 (measure the main-thread resolves — the partition adds to them). **P3a is behaviour-neutral for every existing book**: no events ⇒ everyone is an author of the whole book ⇒ the P2 suite passes untouched.
- **P3b — scope's lifecycle and the Mac's surfaces.** §4.5, §7 entire. Carries: C1, C2, C11, C13 (reproduce the blank window — History's set-aside disclosure is being touched anyway), C15, C16.
- **P3c — the collaborator.** §8, §9, §10. Carries: C4, C5, C7, C10 + C17 (one fixture factory and its census), C12, C14 (tripwire 33's click arm). Then the smoke and the release.

**Dropped on merit:** C6 — verified 2026-09-19: the cache route is already lazy and pinned (`RegistryCacheTests.test_aProjectWithNoRegistryNeverReachesForTheEnclave`), and the mint that remains at project open is `RegistryPresence`'s, commented *MINTS, and should*. C3 (History's Project block interleaved by date) — nobody has asked for it and the event records make the block more useful as a block.

## 14. Out of scope

- Signed structure (roadmap, Group 4).
- The author lock and the baton (WF2) — `changePermit` and the events are the record it will use; nothing here forecloses it.
- A *translator* PERSON role (someone admitted only to translate) — the actor row exists; a person-level rung waits for a person who needs it.
- A signed per-span exception for late sync (handoff ruling 1's option A) — one more event kind if a smoke shows the inbox door hurts.
- A `list_people` MCP read (parent §4.12).
- Per-statement grants.
