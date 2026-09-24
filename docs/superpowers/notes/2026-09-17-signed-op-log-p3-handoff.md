# Signed op log P3 — roles and the collaborator (handoff, 2026-09-17)

**Why this note exists.** P2 (people and admission, labels only) is complete on LOCAL main — P2a `c610a7c2`, P2b `08b7dedd` — unpushed by Denver's ruling (*"we aren't pushing half a milestone just because we split this into sub plans"*). P3 is the milestone's last plan. This is its brief: what P3 is, what P2 actually built that P3 stands on, what P2 left owed, and the decisions that are Denver's before a plan can be written. P3 is unspecced and unplanned; rule 11 held — nothing was written against an API that did not exist.

**Read first, in this order:**

1. `docs/superpowers/specs/2026-09-05-signed-op-log-design.md` §4.9 (roles, and the 2026-09-08 paragraph mapping the four actors onto the role table), §4.10 (the inbox), §4.11 (the phone), §5 (surfaces), §6 (constitution accounting), §8 (the P3 bullet).
2. `docs/superpowers/specs/2026-09-09-signed-op-log-p2-people-and-admission-design.md` — status BUILT; §3's root order is the amended, as-built one.
3. `docs/adr/0032-the-signed-op-log.md` §6/§8 and the P2b addendum; `Maugham/OpLog/AREA.md` tripwires 10–11 and its P2 sections.
4. `CLAUDE.md` tripwires 38–42 — every one is a census P3 will touch or extend.
5. `docs/superpowers/specs/2026-06-17-wf1-human-reviewers-design.md` — Component A is the thing P3 retires; its 2026-09-05 header note says how.
6. The P2b plan's header (`docs/superpowers/plans/2026-09-10-signed-op-log-p2b-admission-and-surfaces.md`) for decisions P1–P5 and D-C, and the P1 handoff's Decisions owed for the form a ruling takes here.

## State of the world (2026-09-19, end of day)

**P2 is RELEASED** — v0.39.0 + phone-v0.13.0 (2026-09-19), after a smoke wave of nine finds and a re-smoke of three more (`docs/superpowers/notes/2026-09-17-signed-op-log-p2-smoke-finds.md`; rulings there include: revoke keeps what was applied by default with *Revoke and Set Aside Everything* as the second button; People & Devices speaks in "the Mac this book was started on"). **The macOS 27 shell slice is RELEASED** — v0.40.0 (2026-09-19): deployment target macOS 27, CI on the `xcode-27` runner, the detail column frames its content, nine AX-tree tests re-derived (find by identifier, press nothing), leading chevrons, the updater refuses a build the Mac cannot run (`docs/superpowers/plans/2026-09-19-macos-27-shell-slice.md`). Main and origin agree. The section below is therefore DONE except the last item.

## Before P3 starts — what Denver owes P2

1. **Wipe the dev registries, then smoke.** P2a-era records do not verify under P2b's lossless digest (changed deliberately while nothing had shipped). In each dev project remove `.maugham/people` and `.maugham/devices`; remove the dev variant's `registry-cache.json` and `admission-memory.json` from Application Support. The script is the P1 handoff's Smoke section, step 0 and steps 11–20.
2. **Push** local main (40+ commits ahead of origin).
3. **Paired release** `v0.39.0` / `phone-v0.13.0` — drafts at `docs/release-notes/v0.39.0.md` and `docs/release-notes/phone/v0.13.0.md`; numbers and dates are placeholders. One tag by name, never `--tags`.

A smoke find changes P3's ground. Plan P3 after the smoke, not before. **(Done — see above.)** The untracked Codex files (`AGENTS.md`, `.codex/`, `.agents/`) are DELETED (2026-09-19, Denver's word; the stash holding only them was dropped).

**Two-Mac smoking on one machine:** `scripts/second-mac.sh` (and `--name third`) launches the dev build under a substituted home — fresh enclave keys, its own registry cache, admission memory and MCP socket. Drive it over its socket with `MAUGHAM_MCP_SOCKET=<home>/Library/Application Support/Maugham Dev/mcp.sock` on `maugham-mcp`. Homes: `~/.maugham-second-mac`, `~/.maugham-third-mac` (Mac C is admitted in P2-Menu/P2-Mid; the P2-* books live in the dev TestWorkspace).

**SPECCED 2026-09-19:** `docs/superpowers/specs/2026-09-19-signed-op-log-p3-roles-scope-collaborator-design.md` — it carries every ruling below plus four made in the brainstorm (what an author of some pieces holds at project level; *Not now* on her new piece; whose-piece shows in the Inspector and the altitude table, never the tree; set-aside is line by line) and two design corrections (a mark is chain positions, not an opId; the translation stream joins the trust table). Where this note and the spec differ, the spec wins.

## What P3 is (parent spec §8)

- **`author` / `reviewer` on the person record.** The field already exists: `PersonRecord.role` is written `"author"` for everyone and read by nothing (`RegistryRecord.swift`). P3 gives it a second value, a writer (the admission sheet and the People & Devices pane), and a reader (the trust table).
- **The per-op-kind role check**, inside a batch: a reviewer's batch carrying a manuscript op is set aside whole, and History says so in a person's name. The permission table is spec §4.9; the check reads the SIGNING KEY, never a claim in the op.
- **The actor rows** (§4.9's 2026-09-08 paragraph): `assistant` gets exactly the reviewer row — which is *MCP never mutates manuscript text* enforced at the storage layer; `translator` gets a row of its own (translation records, any language, nothing else); `maugham` signs only the rebalance; `author` keeps everything. A person's role gates their devices; the actor gates each of a device's four keys within that.
- **The reviewer's inbox capture with attribution** (§4.10): rows signed by the reviewer's device land in the author's inbox and read *from Sam*. No new field — `deviceId` is on every row and the registry resolves it. `InboxByline` (P2b) is the start of this.
- **The phone reads its role and takes its posture** (§4.11): a reviewer's phone offers capture and annotation creation, no dispositions. `DeviceStanding` (Core, P2b) is where the phone already reads where it stands; role is one more fact on it.
- **WF1's Component A retired in favour of the registry.** Live consumers today: `CollaborationRole`/`ShareIdentityMapper` (Core), `FileURLShareMetadataReader`, `ProjectWindow.resolvedRole` + `shareReader`, `SharingStatusPill`, the phone's `SharingRoleBanner`, and `authorCollaboratorId` on annotation ops. The iCloud share keys survive as the admission sheet's DEFAULT (name and suggested role) and nothing else. Component B's membrane stays as the cooperative half.
- **The guides and the constitution's amendment** (§6): *AI is never the author* gains its storage-layer sentence and falsification condition; `docs/guide/people-and-devices.md` gains roles; `docs/guide/index.json` is explicit, not conventional.

**Already done, do not plan it:** §4.10's palette-aim removal (`PaletteAimPicker` and the `aim:` parameters are gone; `paletteSubject` is decoded and never written).

**Expect schema and release consequences.** A role check that changes what a reader APPLIES is a Mac+phone paired release at minimum. Whether a new `OpKind` is needed is a planning question; the ADR 0015 contract (new case ⇒ schema bump) applies if so.

## What P2 built that P3 stands on

| seam | what it is | P3's use |
|---|---|---|
| `TrustTable` / `TrustVerdict` | the ONE answer to *who is this key to this device*; count the enum's arms, not a number here | the role check is a second question asked of the same resolution — do NOT build a parallel table (tripwire 39) |
| `TrustResolution.verifiedRegistry` | the ONE reconciled registry read | role is read here or nowhere |
| `RegistryAdmission` | admit / revoke / retire / claim — the authority (tripwire 41) | a role change is a fifth verb or an argument to admit; it lives in this file |
| `RegistryWriter.resign` + `RegistryCanonical.resigned` | edits the FILE's object so unknown fields survive | how a role changes on an existing person record |
| `RegistryCanonical` | what a signature covers; frozen once shipped (tripwire 42) | **`JSONSerialization` normalizes numbers** — the first numeric record field needs a pinned round-trip test before it ships. Role is a string; keep it one |
| `Line.State.pending(device:)` | held, not applied, no `.lines` record | a role violation is NOT pending — something is wrong with it; it is set aside with a reason |
| `OpLogStore.classifyTail` | where the revoked-span opId split is made | the natural home of the per-op-kind check |
| `AdmissionDecision.sentence(for:)` | the ONE refusal vocabulary | role refusals join it; no second phrasebook |
| `DocumentStore.heldLinesByDevice()` | the ONE pending union (open docs ∪ inbox) | unchanged; see carry C4 |
| `TrustEvents` / `TrustEventSentence` | dated entries under History's Project heading (ruling C) | role changes are events; *is a reviewer* is a fact (banner/pane) |
| `DeviceStanding` | the phone's "This device" section and the retirement notice | gains role; drives posture |
| `PeopleAndDevicesModel` / `Confirmation` | every pane verb confirms through one type | the role control goes through it |

## Decisions owed (Denver) — settle before the plan is written

Present one at a time, pros / cons / recommendation, as the P1 three were.

1. **Apply on the late-sync half of a revoked span.** A revoked device's span is refused whole and filed in two halves against the root's recorded mark (*after revocation* / *may be late sync*). There is no Apply on the late-sync half, deliberately: the verdict refuses the whole span, so a real Apply needs a durable per-span exception THROUGH the trust table (an implementer correctly stopped my ruling that it was returnable). Today's only way in is re-admitting the device, which lets everything in. Options: build the exception record (signed by the root, keyed by seal); leave re-admit as the door; an export-to-inbox escape that never touches the log.
   **RULED 2026-09-19: C** — export the late-sync half to the inbox as captures; nothing signed by a revoked key is ever applied, the refusal stays absolute, and the words come back through the writer's own hand as the writer's own ops. The signed per-span exception (A) is NOT built; it is cheap to add later as one more event kind under ruling 3A if a smoke shows a long lost-device span makes pasting hurt.
2. **Should a retired device keep applying its own later writes?** Today a retired Mac keeps applying what it writes and is told so (`DeviceStanding`); every OTHER device holds those lines. That is the words-are-safe direction locally and a divergence across devices. Options: keep (told, safe, divergent); refuse further manuscript appends on a retired device (consistent, but a writer can be locked out of their own typing by their own act); allow but mark every such line so re-admission has something to show.
   **RULED 2026-09-19: C** — allow, and mark. BOTH directions: the retired Mac keeps applying its own post-retirement lines (typing never fails) under a standing banner stronger than today's notice; every OTHER device holds them as pending; re-admission surfaces them by count (*N paragraphs written while retired*) and asks before applying. The marking is DERIVED — chain position against the retirement record's mark, the same mechanism as ruling 3A — so no new op field and no schema bump from this ruling.
3. **A durable trust-event log.** Events are DERIVED from the records, and a re-admission clears the revocation, so revoke-then-re-admit reads as one admission. Options: an append-only signed event file under `.maugham/people/` (a new record kind, a fourth thing `RegistryWriter` spells); keep superseded records instead of re-signing in place; accept the loss and say so in the guide. Roles make this sharper — *was Sam an author when she wrote this?* is unanswerable from current state alone, and the role check must be evaluated against the role AT THE TIME of the span or it rewrites history on every demotion. **This one is load-bearing for P3's design, not a side question.**
   **RULED 2026-09-19: A** — signed event records under `.maugham/people/`, ONE FILE PER EVENT (a shared append-only file is tripwire 17), each role-change event carrying a mark as a revocation does (the heads of that person's device files as the root saw them), so *at the time* is a chain position and a demotion never reaches back past its mark. Closes C11's question too.
4. **Carried from the P1 handoff, still open:** #6, the truncation rule's honest close (*an adopted head must be at or descended from the last trusted seal*) — ADR 0032 still names it as P2's and P2 did not build it; and #8, whether History should say once per project that a Mac with no Secure Enclave is unsigned. Confirm each is P3's, later, or dropped on merit.
   **RULED 2026-09-19: both are P3's.** #6 is BUILT in P3a, straight after the event records — it needs a remembered head per FOREIGN file, and rulings 1–3 stand on that same memory (a mark is only checkable against a remembered head; the late-sync/backdated split needs it too), so one piece of device-local state pays for all of them; give it a pruning story from day one (the P1 state file needed one retrofitted in v0.38.0). #8 is YES, in two places: a line on that device's row in People & Devices (a fact that holds now) and one dated entry under History's Project heading (something that happened) — with roles, being unsigned decides whether a device's writing is ever applied elsewhere, so it stops being harmless.
5. **New with roles:** who may change a role (the root only, as with revoke?); whether a reviewer's DEVICES are admitted silently under `AdmissionMemory` the way an author's are; what a demoted author's already-applied manuscript ops read as (they stay applied — confirm the sentence).
   **RULED 2026-09-19 — 5a/5b/5c, all confirmed.** (a) The ROOT ONLY changes a role or a scope, and never on itself (a book must not end up with no author) — `RegistryAdmission`'s, per tripwire 41. (b) A known machine's LABEL is remembered silently and its ROLE is asked once per book (the iCloud share keys pre-fill the suggestion); the writer's OWN devices stay fully silent. `AdmissionMemory` stays project-keyless and carries no role — a role is a fact about one book. (c) BOTH directions: a DEMOTION never reaches back past its mark — what she wrote as an author stays applied, History says *Sam became a reviewer. What she wrote before then stays in the book.*, and her manuscript ops after the mark are set aside in her name; a PROMOTION is not a pardon — manuscript ops she signed while a reviewer stay set aside.
   **RULED 2026-09-19 — SCOPE (Denver's question: two people authoring different pieces and reviewing each other's): B, the role carries a scope, enforced at storage.** The person record says `author` plus an optional list of document ids (strings — tripwire 42); no list = the whole book; outside it the person is a reviewer. Op logs are per-document, so the check is one question per FILE in `classifyTail`. Scope changes are events with marks (ruling 3A). BOTH directions, with the asymmetry named: a scoped author's manuscript ops in a piece assigned to someone else are SET ASIDE in her name; the ROOT is always whole-book at storage and takes review posture on others' pieces COOPERATIVELY (membrane + override), because restricting a root that can revoke and reassign is theatre. A scoped author's NEW piece is PENDING with a question (*Sam started X — hers?*), never set aside — nothing is wrong with it. Split/merge/move need rules in the spec. This makes P3 THREE plans: P3a role + events + remembered heads; P3b scope and its lifecycle; P3c the collaborator, the phone, Component A.

6. **Structure under roles (found 2026-09-19 while ruling scope).** `OpKind` has no structural cases — create/rename/reorder/trash go through the unsigned manifest, and `__project__` carries tasks only — so storage cannot prove who shaped the binder.
   **RULED 2026-09-19: A — structure stays cooperative in P3.** The membrane refuses structural verbs for a reviewer, and outside their own pieces for a scoped author; storage enforces nothing. The new-piece ask needs only the op log (a document file whose ops a scoped key signed and which is in nobody's scope is pending). The guide and the constitution amendment name the limit: *roles guard the words, not the binder*. Signing structure is FILED as its own roadmap milestone (Group 4, *Signed structure*), not bundled here.

## Carries from P2 — do or drop on merit, no defer bucket

**Surfaces and wording**
- C1. `InboxPane.setAsideNotice(lineCount:)` is still reason-blind; History's twin is reason-aware. P3 adds a third reason (role), so this stops being cosmetic.
- C2. A nameless device shows its code as `ownName`; suppress the `ownName == code` display.
- C3. History's Project section is a block, not interleaved with document entries by date. Only if Denver wants it.
- C4. Pending counts from CLOSED documents are invisible to the admission sheet — the question is put on the load path, so nothing opens without it, but the count understates. Needs a closed-document provenance read (or a project-open sweep; the release notes name this a known issue).
- C5. The phone's Settings "This device" section has no refresh watcher; it reads at appear.

**Trust and registry internals**
- C6. `RegistryCache.shared` still mints a fingerprint on the no-registry path in some routes — laziness residue. `LocalIdentities` enumeration mints nothing; this should match.
- C7. The phone JOINING a chain: its two `ChainPolicy` sites (`InboxCaptureWriter`, `AnnotationWriter`) and what trust closure each passes. P3's reviewer phone is the first phone whose lines another person's Mac must judge — verify the phone's closures come from the table (tripwire 39's phone twin).
- C8. Task 8 minors: the root-write guard keys on the registry, not `myRoot`; an unverifiable claim file is overwritten rather than listed; adopted roots are not checked to exist; `ClaimDecision.title` is dead; `claimedAt` does not move on a later adoption.
- C9. The hoisted trust resolves in `ProjectStore` still run on the main thread. Measure before moving.
- Done, note only: the unsettled-segment inner-seal fallback walk (`trusted: { _ in false }`, allow-listed by file+spelling in tripwire 39).

**Carries added 2026-09-19 (P2 re-smoke and the shell slice)**
- C11. History's silent-admission entry reads *admitted by <root>* like an asked one; *without asking* is derivable on this Mac (the admission memory's label predates the book's admission). Belongs with decision 3 (the durable event log).
- C12. The derived `.md` lags after a trust change (an admission or revocation rebuilds the live document but re-renders nothing until the next edit). A re-render trigger after trust changes, or say plainly that the `.md` lags.
- C13. The 17 Sep blank window (all three columns empty after opening History's *Set-aside records* disclosure) is STILL UNEXPLAINED — the shell spike proved a large ideal width does not move a column, so the 559pt theory is dead. Reproduce before theorising again.
- C14. Tripwire 33 wants a CLICK arm: click-then-wait-then-click is the same defect shape as press-then-wait (the chevron misses exactly once after another click's relayout). Widening the census sweeps in `TreeTravelTests`, `ProjectAltitudeCentreTests`, `PaletteWallDoorHitAreaTests` — its own piece of work.
- C15. `PieceInspector.setPass` copies `InspectorView.setPass`'s `[weak store]`, so a write whose only strong reference was the view drops silently. Pre-existing; decide whether the capture should be strong for the duration of the write.
- C16. Set-aside records are content-addressed, so a second harsh revoke of identical bytes files no new record and History keeps the OLDER record's sentence. Fine as evidence; decide whether the sentence should be re-derived from the current record's scope rather than frozen in the sidecar.
- C17. The test host leaks `xctest-worker-<pid>` folders into the dev variant's real `TestWorkspace/` (~4,500 in a week) — same family as C10.
- Process rules now in CLAUDE.md that P3's agents must follow: `git commit -- <paths>` in a shared tree (a bare `git commit` sweeps a sibling's staged files); `pgrep -x xcodebuild`, never `-f`; no wait loop with `xcodebuild` in its own argv; `./gen.sh` in the same step as any file add/delete; compile between edits; a worktree gate must run `./gen.sh` first or new test files run as zero tests.

**Test and tooling hygiene**
- C10. **A census for leaking fixtures.** Seven suites were fixed; the shared `makeTestProject` fixtures and others still leak into `$TMPDIR`. The sweep is bounded and off-main now, so a gate no longer hangs on it, but the directory still grows (230k entries / 12–13 GB remained after three prefix passes, part of it other apps'). Shape: one fixture factory that registers its roots for teardown, plus a tripwire on `temporaryDirectory`/`NSTemporaryDirectory()` in tests outside it (census + planted offender, per `feedback_census_over_warning`).

## Process notes that paid in P2

- Opus implementers; sonnet/haiku reviewers; **opus for anything touching the digest, the trust table or the role check.** A ledger of every ruling, handed to the whole-branch reviewer with the seams named.
- **Three implementers in one tree is the ceiling.** A red test file or a type-check timeout in one blocks the siblings — each agent fixes its own first.
- Stage by explicit path; never amend a reviewed commit; one fix wave per whole-branch review.
- My rulings were wrong twice in P2 in the same way — a ruling that stated half of a two-sided rule (P2a T7 "join only from arm 3"; P2b T7 "Apply is returnable"). Both were caught by an implementer or a re-review reading the verdict's actual arms. **When ruling on trust, restate BOTH directions and have the reviewer check the ruling, not just the code.**
- Absolute paths in every shell command; zsh aborts on unquoted `=====` and `--include=*.swift`.
- If 3–6 of 7 workers hang before connecting with zero assertion failures: it is `$TMPDIR` (CLAUDE.md build flow). Do not re-derive.

## Suggested shape

Two plans under the ~10-task cap, the second re-derived against the first once built:

- **P3a — the role, enforced.** Decision 3's outcome first (it fixes what a role check is evaluated against); role on the record + its verb in `RegistryAdmission`; the per-op-kind and per-actor check in `classifyTail` with a set-aside reason; the refusal sentences; History/Inbox reason-awareness (C1); People & Devices role control; censuses extended. Carries C6–C8 ride here.
- **P3b — the collaborator.** Reviewer inbox attribution; the phone's posture off `DeviceStanding` (+C5, C7); Component A retired, share keys as the sheet's default; guides, constitution amendment, ADR 0032 P3 addendum, roadmap flip and sibling-doc sweep; C4 and C10.

Then the milestone's closing smoke (a second Apple ID is the honest test — WF1's participant-side iCloud review is still UNVERIFIED) and the release.

---

# P3a OUTCOME — the permit, enforced (2026-09-20)

**Where it is.** Branch `claude/signed-op-log-p3a-2026-09-19`, eleven tasks,
**unmerged** at the time of writing: the whole-branch review and the merge to
LOCAL main both follow this note. Nothing pushed, nothing tagged — the milestone
ships whole (P3a + P3b + P3c), and the release is a Mac+phone paired one because
this changes what a reader APPLIES.

## What shipped

The mechanism, with **no surface**. Nothing in Maugham can yet give anybody a
permit; that is P3b. Behaviour-neutral for every book that exists — no permit
events means every admitted person is an author of the whole book from the
start, which is exactly what P2 meant — and the whole P2 suite passes untouched.

- **A fourth registry record**, `.maugham/people/events`, one signed file per
  event, written by `RegistryAdmission` alone; two new authority checks in
  `RegistryReader` (`eventSignerHasNoAuthority`, `eventDemotesARoot`);
  `PersonRecord` gained `scope` and `pieces` beside the `role` P2 already wrote.
- **A mark is chain positions** — per stream, the digest of every whole segment
  the root had read and the hash of the last line it had — computed from shared
  bytes, so every device reaches the same answer. **Seen**, not applied, except
  a revocation's, which alone means applied.
- **`PermitTimeline`** — the events in order as `(permit, mark)` entries; what
  the check reads, never `PersonRecord.role`. Its opening entry depends on the
  first event's KIND.
- **`Permit.allows`** — the one table, `default:`-less over `OpKind`, with
  manuscript text asked of `Deriver.appliesToManuscript` and a third answer
  (`cannotJudge`) for everything a later build might mean.
- **`PermitPartition`** — line by line, before the parse, immediately after
  `RevocationSplit`, in every read path that applies somebody else's lines:
  the op log's three, the mark sweep, the translation sidecars, and the inbox
  manifest plus the annotation log through `JSONLAppendStore`.
- **`AnnotationOwnership`** — an amendment is judged under the permit in force
  **at that line**, so a demotion cannot revert an author's honest edit of a
  reviewer's note and a promotion cannot pardon an ignored withdrawal.
- **The authority verbs** — `changePermit` and its label-wide sibling; all four
  mark-computing verbs refuse (and write nothing) rather than record a short
  sweep; `historyUnreadable` now names which ACT was refused.
- **The load seam** — `OpLogStore.localWritePermit` is the one write-side
  question; where this device may not write the piece the load mints nothing
  and answers `DocumentLoadError.waitingForPiece`; everything the load path
  emits on its own account is the AUTHOR actor's whoever opened the file.
- **Remembered foreign streams** — `ForeignStreamWatch`, so *absent* is
  distinguishable from *never existed*, with truncation as a report that clears
  when the bytes come back.
- **An unsealed span answers to its file's verdict** (Task 11, from the audit):
  a stranger's tail is held, a revoked one refused.

Measured, on a quiet machine, ordinary book, medians of 7: the two main-actor
project walks over 30 documents moved 59.5 → 59.6 ms and 63.3 → 63.4 ms against
`main`; one `Document.load` of a 1,001-op document 24.9 → 26.0 ms. C9 is
answered and nothing was moved off the main actor.

## The final fix wave (2026-09-20) — what the whole-branch review changed

Four items, four commits, each with both directions tested and a disable
experiment recorded in `.superpowers/sdd/…/final-fix-wave-report.md`.

- **W1 (Critical): a book judges itself when somebody is NARROWED, not when an
  event exists.** *No events before P3b* was false — P3a's own `admit` writes
  one for every device the writer lets in, and `DocumentStore.open`'s silent
  admission writes another. `TrustTable.hasNarrowingPermits` replaces
  `hasPermitEvents` at all four neutrality gates (the amendment record,
  `couldJudge`, `answersWholeFile`, `AnnotationOwnership.unplaced`), asking the
  permits rather than the events, over every entry of every timeline, with an
  unreadable role word counting as narrowing. The sharpest consequence it
  closes: an UNSIGNED Mac's annotation edits and withdrawals stopped being
  honoured on every signed Mac from the day the writer admitted their phone —
  P3 refusing what P1 applied, for a state the constitution calls first-class.
- **W2: a sweep asks what a stream CONTAINS.** `expectedStreams` checked names,
  which leaves the rotation-mid-sync case the shipped Revoke button walks into.
  The MEMORY travels now (`expecting:`), and the guard asks
  `ForeignStreamWatch.loss` — the load's own predicate, extracted rather than
  restated. `writeEvent`'s carry-forward unions segment digests per key.
- **W3(a): what RELEASED builds wrote is judged as the author's, permanently.**
  `Permit.isALoadEmission` + `Permit.actorJudging`. **With a stated stop** —
  see the ADR's limits: the three `typingBurst` load emissions write no
  `synthesisSource`, so they are not covered and an assistant-signed ordinary
  burst stays refused. W3(b)'s disk census over every project this Mac can
  reach (23 projects, 194 tails, 5 `.mzseg`, 11,064 lines) found no line the
  rule does not cover.
- **W4: the two automations.** `sweepOrphanedAnnotations` and
  `repairRejectedButSplicedAnnotations` now sign with `authorEmissionDevice`
  and are not made where `localWritePermit` disallows the kind.
- **W5: the narrowed book is measured** — see the ADR's *cost of a narrowed
  book* table and `Maugham/OpLog/AREA.md`. An admissions-only book pays
  nothing; one reviewer costs **+15 ms (+65 %) on a document open**.

## For the release notes

> On books shared between Macs, a device this book does not know had its
> **unsealed** writing — everything since its last seal — applied. It now waits
> for admission like the rest of its history. Nothing is lost: admitting the
> device applies all of it on the next read.

## The decision still owed for the release

**Should an OLD build refuse a book that has permit events?** A v0.40.0 Mac
knows nothing about roles, so it applies exactly what a P3 Mac refuses — and
the two Macs then hold different manuscripts with nothing red on either. The
paired release makes every Mac on a book update, but that is a request rather
than a mechanism. Options, for Denver when P3c's release task is planned: leave
it (the paired release is the answer, and a mixed fleet is a transient);
make a book with events REFUSE to open on a build that cannot read them (loud,
costs a writer their book until they update); or a one-way notice on the old
build (*this book uses permissions this version cannot read*) that stops it
writing but lets it read. Raise it with Denver when P3b is planned.

## PARKED for Denver — the unsigned door

**The state of it.** A file with ZERO attributable seals is applied unjudged.
That is P1/P2 by design (unsigned is a first-class state: a VM, CI's runner;
pre-signing legacy history is applied). Under permits it means a hostile client
that never seals — or forges a *legacy*-shaped file — bypasses the permit check
entirely. There is a further asymmetry inside it: the WRITE side narrows by
actor even with no register (`LocalWritePermit` falls back to keyless, P1
exactly), while the READ side does not.

**Why it needs a ruling.** It contradicts what this handoff told Denver under
decision #8 — *"an unsigned device's lines can never pass a role check, so they
sit pending"*. They are in fact applied. Honest Maugham always seals and ADR
0032 has always claimed provenance rather than a lock, so this is the stated
threat model's edge; but it is the edge a reader will look for, so it is now
written down in the ADR's *limits* section too.

**Candidate close, for P3b's planning:** the first permit event snapshots the
book's unsigned files by digest, and unsigned lines outside that snapshot are
PENDING in a book that has events. Cheap, needs no new record kind, and leaves
every genuinely unsigned device working until somebody starts handing out
permits.

## Carries into P3b — a list to plan against

1. **The admission sheet must not offer a CONTESTED key** as a stranger to
   admit: it is a disputed key, not a new device, and it needs its own sentence.
2. **The admission sheet must not offer a NON-AUTHOR actor key at all.** A held
   span whose slug reads `assistant-`/`translator-`/`maugham-` waits for its
   device record; then the person is admitted by their author key. This closes
   both the I5 seeding window and Task 6's residual (a stranger admitted via a
   non-author key gets a spurious `author-<hex>` seeding while her real author
   id stays unplaced, so her own amendment is not honoured until her device
   record syncs).
3. **Permits are per person RECORD, and P2b merges devices under one LABEL.**
   The pane calls `DocumentStore.changePermit(everyRecordOf:to:)`, which is
   built, pre-flights every record's sweep, skips revoked siblings and includes
   retired ones. Nothing presses it today.
4. **An event whose person record has not arrived draws no History row.**
   `RegistryAdmission.recordBehindEvents` detects it; it needs a surface.
5. **`IntegrityReport.truncatedStreams` / `TruncatedStream.sentence` have no
   drawer.** P3b's dated History entry reads them.
6. **`retire`'s mark can overcount *written while retired*** — it expects no
   streams, so an own stream evicted at retire time is counted post-retirement
   in P3b's prompt. The prompt ASKS before applying, so an overcount is
   harmless; say so in the prompt's copy.
7. **Permit-pending lines are invisible.** They reuse `.pending(device:)` and
   are filtered out of every admission-worded count by one Core predicate (*is
   this pending device a stranger?*), so they are held SILENTLY in P3a. P3b owes
   them a surface of their own.
8. **C8 item 5 is not done** — `claimedAt` does not move on a later adoption.
   Closing it without contradicting the P2 test that pins it wants a date per
   ADOPTED root, i.e. a `ClaimRecord` format change. Filed under *Signed
   structure* on the roadmap.
9. **Audit PR #65's F4** — a cold-cache tamper of a SOLE root record — is
   P3b's, by Denver's 2026-09-20 triage.
10. **Two format changes are filed on the roadmap's *Signed structure* item**,
    both found here: per-actor possession proofs in the device record (the cure
    for a contested key), and a per-adoption date on the claim record (item 8).
11. **MUST — the first NARROWING event bumps the manifest schema gate** (the
    whole-branch review's F5, and the answer to *the decision still owed*
    above for the narrowed case). A v0.40.0 author Mac in a narrowed book
    applies a reviewer's refused text, and its next burst re-asserts those
    words under ITS OWN book-author key through `sequence`/`changes` — which
    every new Mac then applies. That is somebody else's words under the
    writer's name, with nothing red anywhere, and a paired release is a request
    rather than a mechanism. The bump must happen the moment a NARROWING event
    is written (not an admission: those carry the book-author permit and change
    nothing an old build would get wrong), the same way `schemaVersion` 5 did.
    **P3a does not need it now that W1 has landed** — only book-author events
    can exist, and v0.40.0 ignores `people/events` benignly: its reader filters
    `.json` files and skips directories, and `reconcile` deletes nothing.
12. **`.retired`'s rolling ≤99-op unsealed tail is applied elsewhere and then
    quarantined once sealed.** Task 11 ruled that a retired device KEEPS its
    unsealed tail, because `retire` seals no op log and that tail is
    pre-retirement work. The consequence is a shape P3b's re-admission prompt
    is where the writer meets it: text appears on other Macs and then vanishes
    when the device next seals. Spec §5 says such lines are HELD; today they
    are applied then quarantined. Decide which, in the prompt's copy or in the
    rule.
13. **Two things nothing exercises.** Task 2's minor — a replayed MARKED line
    as the first line of a forged tail, whose following lines must judge NEW —
    has no test; the controller's analysis says it is harmless (a replayed line
    can only sit where its `prev` allows) but the analysis is unpinned.
    `AmendmentPermits`' restrictiveness tie-break has no production exerciser
    at all: nothing in P3a can produce two governing permits for one amendment
    op, so the arm that picks between them is written and never run.

## What the fix wave's re-review left for P3b (2026-09-20 — merge verdict: safe for LOCAL main, unreleased)

Recorded by the controller from the scoped re-review of `1c82d17f..0c600276`. Nothing here blocked the merge; every item is P3b's or the release's.

- **IMPORTANT — a position sweep can refuse FOR EVER.** `ForeignStreamWatch.settle` keeps a stream's memory frozen while a loss stands, so a remembered segment digest (or a whole stream) that is *legitimately gone for good* — a collaborator's project folder deleted, history that will never sync back — makes `loss` answer on every later sweep, and `revoke`, `changePermit` and `admit` for that person refuse permanently, naming history that no longer exists: the root can never demote or revoke her. Nothing in the app deletes segments, so it needs an outside cause; it is Task 9's Important with one more arm, not new. **The escape belongs with P3b's loss surface, where it is decidable:** a standing loss the writer has been SHOWN stops being expected (the sweep skips a digest `state.truncations(inRoot:)` carries as acknowledged) — or the verb offers *proceed, judging that stream as new*. Build one of them with the truncated-stream drawer; do not ship P3 without it.
- **The unsigned Mac's cliff — say it on a surface.** On a Mac with no enclave (a VM, an old Intel machine), the day the root FIRST narrows anybody, every note that Mac withdrew reappears and every edit it made to a note reverts, on every signed Mac, silently (`AnnotationOwnership.unplaced`: a production-shaped id that resolves to no key is not honoured in a narrowed book). It is the ruled behaviour and the sharpest edge of the parked unsigned door: a cliff, not a slope, with nothing that tells the writer. It goes in front of Denver WITH the unsigned-door decision, and whichever way that is ruled, People & Devices' unsigned line (#8) must say what narrowing will do to that Mac's notes BEFORE the first reviewer is created.
- **The load-emission rule is by KIND, and one of its kinds rests on an unenforced invariant.** `Permit.isALoadEmission` is exactly `bootstrap` and `taskCreate`, judged as the author's whoever signed. That is safe because **no MCP tool writes a task op** (verified 2026-09-20: nothing under `Maugham/MCP` names `appendTaskOp`/`createPaneTask`/`taskCreate`). The day a `create_task` tool lands, the assistant's *no tasks* row is silently bypassed at read time on every Mac. P3b: add the census (no file under `Maugham/MCP` emits a task op) with a planted offender, or give the load's `taskCreate` a discriminator.
- `Permit.actorJudging` widens the `maugham` actor too (`taskCreate` signed by the rebalance key would be judged as the author's). No build ever had the rebalance sign one and it is a local key on the same device — threat-model-neutral, wider than the ruling needed. Narrow the guard to `assistant`/`translator` when the file is next open.
- `ForeignStreamWatch.settle` still computes `rotated`/`missing` locally beside the one shared `loss` predicate — the VERDICT is single-sourced, two partial re-spellings of the tolerance are not. Fold them into `loss` (or a sibling) before they drift.
- AREA.md says a reviewer "will feel two frames" of the measured +15.5 ms per document open; the ADR and the fix-wave report say about one 16 ms frame. Make them agree — and P3b measures again once its surfaces exist.
- A reviewer's Mac logs one `documentLog.error` per orphan on every sweep for the EXPECTED `AutomationNotPermitted` refusal — make it a debug-level line.
- **W3's typingBurst STOP — Denver's call before ANY release.** The load's three `typingBurst` emissions (both pending-recovery folds, the task-anchor splice) carry no `synthesisSource`, so lines of that shape which v0.37–v0.40 signed under the assistant or translator key stay REFUSED (set aside into recoverable `.lines` records). The Swift census of this Mac (23 projects, 194 tails, the five `.mzseg` decoded, iCloud empty) found none. **Release checklist: run that census on EVERY Mac that has opened a book**, and give those three emissions a `synthesisSource` prospectively so the next such question has an answer.

## Open question the whole-branch review did NOT verify

**S4(c): are two roots' marks for one stream comparable after an adoption?** A
mark is a set of chain positions in a stream, and after two roots adopt each
other each holds marks it computed from its own copy of the folder. Whether
those two marks can be compared — or merged, or ordered — for the same stream
is not established anywhere, and the review states plainly that it did not
verify it. It cannot bite in P3a (nothing creates a non-book permit), but P3b
gives the writer a verb that writes marks, and two adopted roots both using it
is the first moment the question has an answer worth having.

## Carries into P3c

- **⌘S on a piece this device may not write.** The table refuses a
  `checkpoint` op there, correctly. The cure is Posture: keep the flash (muscle
  memory, a constitution position) and write NO op. If P3c forgets, a reviewer's
  ⌘S produces a set-aside record in her name.
- **The PHONE reads annotations without the ownership rule**
  (`AnnotationLoading.swift` ~68/74, `AnnotationDetailView` ~561), so it honours
  what the Mac judges away.
- **`Posture` itself** — the membrane widened to the table — plus the phone's
  posture off `DeviceStanding`, Component A's retirement, the guides and the
  constitution's amendment.
- **On a not-permitted device, `close()`'s failed-flush arm declines to
  re-persist**, so un-bursted keystrokes of a failed burst are lost from memory
  (logged). Unreachable once Posture makes such a piece read-only.

---

# P3b OUTCOME — scope's lifecycle and the Mac's surfaces (2026-09-23)

Branch `claude/signed-op-log-p3b-2026-09-20`, off main `8c6c8b26`. Merged to
local main when the whole-branch review clears; **not pushed, not tagged — P3
ships whole** (Denver's ruling of 2026-09-20 stands).

## What shipped

Ten tasks and eight fix rounds. The evidence is
`.superpowers/sdd/2026-09-20-signed-op-log-p3b/ledger.md` (every `Ruling:` line
with what it costs if wrong) and the ten task reports beside it; hand both to
P3c's planner and to any reviewer. The shape is in ADR 0032's **P3b
addendum**, whose *limits* section is the honest list.

- **The unsigned door closes by SNAPSHOT** (`UnsignedSnapshot`), in both
  directions, with the earliest narrowing governing across two roots. **S4(c)
  is answered by test** — two roots that adopted each other judge every line
  identically from the same bytes.
- **The schema gate** at the first narrowing (gate → event → record), a
  raise-only write door, and a heal for a narrowed book stamped lower.
- **An escape for a sweep that would refuse for ever** — a loss the writer has
  been shown stops being expected, through one function every sweep asks.
- **The surfaces**: the admission sheet's rung and piece picker (offering no
  non-author actor key and no contested one), People & Devices' Change… /
  Re-admit / Re-sign / write-my-record-again, the load's two questions, the
  loss drawer, History's held-line rows, both §7.4 doors, and *Written by* on
  the Inspector and the outline.
- **Retirement is one-way** — §7.3's third load question was WITHDRAWN and the
  spec amended (`cb513541`). A retired device's later sealed lines come back
  through the Inbox door, not with one press.
- Censuses: CLAUDE.md tripwires **49** and **50**, `Maugham/OpLog/AREA.md`'s
  rows 21–22, each with a planted offender and a control.
- The narrowed book is **re-measured on a KEPT fixture**
  (`MaughamTests/Performance/NarrowedBookCostTests.swift`, env-gated,
  attaching its table to the xcresult): about one 16 ms frame per document
  open, and the unsigned stream the photograph is about is the bigger half.

## For the release notes (with P3a's)

- A book MADE on this build starts at **schema 9**, and the first narrowing
  raises an existing book to it. Older Maughams cannot open a narrowed book —
  which is the point.
- The kept release census (`scripts/census-load-bursts.sh` over
  `LoadBurstCensus`) runs on **every Mac that has opened a book** before the P3
  release, per handoff ruling 3. It walks project folders and prints hits or
  *none*; **it does not walk hidden directories**, which the checklist's
  wording has to say. A hit is a per-line manual recovery, never a rule change.
  This developer's Mac: 29 projects, 203 files, 5 segments, **zero hits**.

## Carries into P3c — added by P3b

- **Spec §7.1's share pre-fill is still not built.** A read-only iCloud share
  does not suggest *reviewer*; the sheet defaults to the whole book. Build it
  with Component A's retirement, where `FileURLShareMetadataReader`'s one
  surviving caller is decided.
- **A Mac on no chain hears no narrowing at all** and applies every
  unattributable line. Permissive only, pinned
  (`UnsignedDoorTests.test_aMacOnNoChainHearsNoNarrowingAtAll`); closing it
  means deciding what such a Mac should be SHOWN, which is P3c's question.
- **The phone holds identically and has no surface for any of it** (Task 2's
  review): it applies `AnnotationOwnership`, its censuses stay empty, and it
  says nothing about a held line, a permit or a narrowing.
- **`announcePendingHistory` is narrowed to strangers**, so a §4.5 piece
  question first appears at the next project open rather than mid-session.
  Widening it puts a verified-registry read back on a path the writer's
  keystrokes reach; a separate cheap post is the shape if it is wanted.
- **Two doors on one pane, with different leads** (*Set aside…* / *Waiting…*),
  and a `chainBroke` record still OFFERS the record door — decided by content
  and not by cause, which is right and is also where *the words come back*
  meets *this was not written by Maugham*.
- **Everything else is in ADR 0032's P3b limits**, which is the list to read
  rather than this one: the accepted planted-author-filename risk, the
  acknowledgement's scope growth and device-local nature, the legacy unsuffixed
  file outside `expecting:`, the too-new-manifest mid-session window (also
  filed on the roadmap's *Signed structure*), and the unreachable
  `.alreadyAdmittedElsewhere` arm.

## P3b whole-branch review (2026-09-23) — READY for LOCAL main; four decisions Denver owes before P3c is planned

The reviewer (Fable, given the ledger, the ten task reports and the plan's seam list) found **no Critical**: no path loses a signed Mac's words, applies an assistant/translator key's manuscript text, or moves a line ruling 1 says must not move. Every seam SOUND. All three of Denver's rulings delivered at the storage layer, both directions, each pinned. Hygiene clean (no pbxproj, no experiment markers, only the four declared assertion moves, the two known non-standalone commits). What it found is that ruling 1 has clauses the code does not deliver, and the docs either defer them to P3c or still promise them:

1. **I1 — the unsigned Mac's standing line is NOT built and cannot be on the shipped design.** An enclave-less Mac can write no device record, so it is on no chain, hears no narrowing event (the signer filter), and nothing on it says the book was narrowed while every word it writes waits elsewhere. It is the ordinary state of every enclave-less Mac, not an edge case; it needs an unfiltered *did anybody narrow this book* read that no type exposes. **P3c MUST**; reword the ADR limit.
2. **I2 — "everything after is held and reaches the Inbox" is true of paragraphs only.** Held annotation/disposition/checkpoint lines from an unsigned Mac have no door and no admission to pardon them, while `HeldLines.sentence(.unsigned)` counts every held line as "N notes … can be brought back through the Inbox". Decide: the door captures held annotation text as Inbox rows too, or the sentence counts paragraphs and says notes are held with no way back.
3. **I3 — §4.5's surface is reachable on honest Maugham only through the sync window.** The write side refuses an author of some pieces opening a piece outside her scope (`waitingForPiece`), so "Sam started X" happens only when her Mac has not yet received the narrowing event; once it syncs, her OWN lines in X are held on her own Mac (bootstrap included) and X derives EMPTY on her screen with no standing line. No word lost (*Theirs* on the root brings it back). Decide: let an author of some pieces OPEN a new piece (the spec's premise, the load minting it), or document the sync window and give her own Mac the standing line for a piece held under her own key.
4. **I4 — the schema gate's in-session window.** A v0.40 Mac that already has the book open when it is narrowed continues its session: its saves write 8 back (the heal re-raises — a ping-pong until it closes) and its bursts apply a reviewer's refused text and re-assert it under a book-author key. The mirror of the stated too-new-manifest limit; ADR limit to add.

Minors, all carries: M1 an acknowledged loss feeding the UNSIGNED photograph is irreversible (the governing event never moves) — say so on the control; M2 `HeldLines.sentence(.unsigned)`/the History `.unsigned` row still assert "no device to admit" about a pre-first-seal stranger (the pane was reworded, these were not; a Send-to-Inbox in that window duplicates words once admitted); M3 one-way adoption also disagrees (B adopted A hears both; A hears its own) and adoption moves the later root's cliff at the moment of adoption; M4 the pane and `PieceWriters` list `chain(underRoot: myRoot)` while the table judges adopted roots' chains too; M5 the planted author-named file, once the real device record syncs, makes that key CONTESTED ⇒ that device's honest MCP annotations stop applying until the planted person is revoked (recoverable); M6 the census script needs a checkout + toolchain — checklist says "run from this Mac against each Mac's folders"; M7 tripwire 50 carries a prose count; M8 a P3a-dev narrowing event without `unsigned` reads as an EMPTY snapshot — **checked 2026-09-23: zero event records exist in any book on this Mac**. Carry 7: every later narrowing verb sweeps a snapshot that never governs — consider skipping the sweep once a governing snapshot exists.

**Denver's decisions carried from the build** (rulings the controller made on his behalf, each with cost-if-wrong in the ledger): retirement is one-way (§7.3's third question withdrawn); *Theirs* cuts before her held span (a settled piece's earlier refusals stay set aside, a later permit refusal in that stream is re-judged); earliest narrowing is chronological; only my chain's roots narrow my book; the §7.1 read-only-share reviewer pre-fill is not built (P3c, with Component A's retirement); Re-admit over a permit this build cannot read refuses.

**DENVER RULED 2026-09-23** on the whole-branch review's four: **I1, I2, I4 — document (ADR limits + the sentences), and file as future enhancements** (I1 the enclave-less Mac's standing line needs an unfiltered narrowing read; I2 held annotation lines: the sentence stops promising the Inbox for them). **I3 — option A, a P3c task:** an author of some pieces may OPEN a new piece nobody has claimed (the load mints it; `LocalWritePermit` gains a *may start a piece* arm; her own Mac applies her own lines under a standing line *Waiting for <root> to say this piece is yours*); she still may not write in a piece that exists and is not hers; §4.5's question becomes ordinary rather than a sync-window race. The six rulings made on Denver's behalf during the build stand.

**Added to P3c from the build:** skip the unsigned-snapshot sweep once a governing snapshot exists (carry 7); the pane and `PieceWriters` list people admitted by an ADOPTED root (M4); the pre-first-seal stranger's wording + a sent-memory keyed off the seal (M2); the census checklist says *run from this Mac against each Mac's folders* (M6); tripwire 50's prose count (M7). **Process for P3c's dispatches:** a disable experiment is the REAL removal (a name sort stayed green where FS order failed); every "unreachable" claim gets a test and the premise check is in the whole-branch brief; two implementers never share a file; the weekly opus limit will cut agents mid-gate — resume from the report files.

---

## P3b SMOKE OUTCOME (2026-09-24) — read before planning P3c

P3b was smoked on a four-Mac rig on 2026-09-23, fixed, re-smoked and merged to local main as `d3f88d4a` (2026-09-24). Record: `docs/superpowers/notes/2026-09-23-p3b-smoke-finds.md` — every find, every ruling, the re-smoke. **Several things above are SUPERSEDED by it:**

- ***Theirs* no longer cuts by position.** It re-judges BY REASON (Denver, 2026-09-24): a line of hers in the settled piece refused only for scope comes in wherever it sits; any other refusal stays set aside. `PermitEvent.settled` + `PermitTimeline` `Entry.judging`; the positional machinery (`markLine`'s cut, `settlingOrder`, `cutStream`, `settledStreams`) is gone. The rulings above that say "cuts that piece's streams BEFORE her held span" / "earlier refusals stay set aside" are replaced — see the finds note's four edge-case rulings and the truthful question after a removal.
- **Claim is never offered unprompted.** `ClaimModifier` is deleted; Claim is People & Devices' *This Book Is Mine…* (Denver, 2026-09-23).
- **An open window adopts a manifest another device wrote** (F7 — a defect since phase 1e): structural verbs hold an arriving manifest (`beginStructuralVerb` + census), remote rename follows, remote trash closes with a notice naming who; **Removed Elsewhere** lists and restores pieces that left without going to Trash, and emptying Trash records a **let-go**.
- **A mid-session actor key is declared before its first line**, and a registry record arriving after its line re-judges the open documents (`.registry` sidecar arm).
- The admission sheet says who and what, never merges by default, advances (F1/F2/F4).

**Added to P3c (Denver, 2026-09-24): F10** — the admission question is raised only for strangers whose lines are in chapters OPEN on the root (`AdmissionModifier.recompute`). Raise it also when a stranger's DEVICE RECORD arrives (the `.registry` arrival arm), with no log read, so a collaborator who wrote only in chapters the root hasn't opened is still asked about.

---

# P3c plan 1 OUTCOME — the posture, Component A retired, F10 (2026-09-24)

Branch `claude/signed-op-log-p3c-plan1-2026-09-24` (off main `5b2fa0d9`; plan
`docs/superpowers/plans/2026-09-24-signed-op-log-p3c-posture-and-component-a.md`,
commit `d6ee0b3d`). The ledger — every ruling with its cost — is
`.superpowers/sdd/2026-09-24-signed-op-log-p3c-posture-and-component-a/progress.md`.
ADR 0032's *P3c plan 1* addendum is the design record; this section is what the
next plan needs. UNMERGED and UNRELEASED: P3 ships whole.

## What shipped

- **`Posture`** (MaughamCore): one value built from `LocalWritePermit`, one
  `default:`-less verb→line switch (count `Posture.Verb`), `reason` naming why
  the words are not hers, `Posture.author`, and `Posture.settling` (the door's
  not-yet answer — the reviewer row alone).
- **The Mac's one door**, `DocumentStore+Posture.swift`:
  - `posture(forDocId:as:)` DRAWS and `settledPosture(forDocId:as:)` is what a
    verb's door ACTS on (ruling I).
  - It is fresh on every trust change, and every open `Document` — the
    manuscript registry's and every open statement editor's (fix wave I1) — is
    re-stamped (`stamp(localWritePermit:)`), so a demotion stops the next burst
    with no reopen.
  - The root yields cooperatively on somebody else's piece, with **Edit
    Anyway** per window, per piece, per session (R2, rulings H, T).
- **Door plus surface for every verb**:
  - dispositions (with loud undo declines), pass state, a round's Run (a check
    is anybody's)
  - statements and the letter's offers
  - the tree (cooperative)
  - tasks (with a task door)
  - translations and the desk (as the translator)
  - ⌘S / ⇧⌘S (the flash always, no op and no entry where refused)
  - History's rewind and restore, a checkpoint's revert, project Replace /
    Replace All, the rename's wiki-link sweep, and every statement write —
    the whole-branch fix wave's C1 (below)
  - the File menu's piece items (disabled)
  - the editor's standing line, including ruling K's *kept in History* clause.
- **Component A retired**:
  - `CollaborationRole`, `ShareIdentityMapper`, `ReviewPosturePolicy` and the
    phone's `SharingRoleBanner` are gone.
  - `SharingStatusPill` is an indicator.
  - A read-only share is an OS lock beside the posture.
  - `author_collaborator_id` is decoded and never written (ruling O; claim
    M5-AN-012 amended; census).
- **F10**:
  - The admission sheet is raised by a stranger's device RECORD, not only held
    lines.
  - Only on the Mac holding the book's root (ruling AA), recounted on a settle
    only, and never about a retired record (rulings AB, AC).
- **Tripwire 51**, the posture census, with a planted-offender control; Task
  10's check narrowed the translation pipeline's allow-list entry to the one
  spelling it uses.
- **The drawing door's cost, measured and fixed** (ruling AD):
  `PostureMissCostTests` (kept, env-gated). A 50-row queue's first redraw after
  a trust change went from 42 ms to 0.02 ms. The class is now read from the
  live manifest, and the refresh warms (overwriting) every asked key FIRST —
  into a staging dictionary since the fix wave's Minor 1 — then publishes the
  table and the staged answers, re-stamps the open Documents and bumps the
  epoch without clearing, in one main-actor turn (ruling AG). Gated by
  `DocumentStorePostureTests`' ordering (which now samples the drawn answer
  beside the stamp), overwrite and all-hits tests.
- **Docs**:
  - ADR 0032's P3c addendum and limits, and the struck §7.1 limit.
  - The constitution's must-not #1 storage-layer sentence and violation
    condition, and *roles guard the words, not the binder* in *Not for: Teams*.
  - The guide's *What their Mac shows them* and F10.
  - The WF1 spec header, and P3 spec §7.1/§8 annotated in place.
  - CLAUDE.md (tripwire 51; the Views, Editor and OpLog cells); the AREA.md
    files of `Maugham/Views/`, `Maugham/Editor/`, `Maugham/OpLog/` and
    `Maugham/Stores/`; the roadmap, `product.md`, `problem-map.md` and the
    annotations guide.

## The whole-branch fix wave (2026-09-24)

The whole-branch review was NOT READY: one Critical, two Importants, seven
minors. The report is
`.superpowers/sdd/2026-09-24-signed-op-log-p3c-posture-and-component-a/fix-wave-report.md`.

- **C1 — the manuscript writers outside the editor.** History's *Rewind to
  before this…* / the rewind window's *Restore here…* (and *Snapshot here…*,
  R5), a checkpoint's *Revert here…*, project *Replace* / *Replace All* and the
  rename's wiki-link sweep reached the manuscript with no gate; each now has a
  surface (hidden where refused) and a door (the restore door
  `Document.requireRestorePermitted`; `replaceInManuscript`'s settled posture
  plus the Document's stamp; the sweep's likewise; `PartialRestorePicker`'s
  per-document settled check). Replace All skips and names (ruling AI); the
  rename sweep skips and says which links were left (ruling AH). While in the
  population the wave also found `ProjectStore.mutateStatementText` had no door
  of its own — promotion's appends and the picture ingest reached statements
  behind no posture question — and gave it one (`StatementWriteRefused`). **The
  population is a grep**: `TripwireGrepTests.manuscriptWriterCallSites`
  (+ its planted-offender control). ADR 0032's *Every verb has a door and a
  surface* no longer claims a list.
- **I1** — open statement Documents are re-stamped with the rest.
- **I2** — `RegistryPresence.admitRemembered` never silently admits a RETIRED
  device, so project-open agrees with the mid-session pre-check (Core).
- **Minor 1** — staging pre-warm, published in the one turn.
- **Minor 2** — no door behind a host fails closed (tree, Collection pane,
  `StartAPieceDoor`, the translation surfaces).
- **Minor 3** — a round whose window closed while it asked says nothing
  (`mayRunRound` answers `Bool?`).
- **Minors 4, 5** — the prose count in `RulingPerformer`; `Reason.reviewer`
  names the translator.
- **Minor 6** — verified NOT a defect: `Document` is `@Observable`, so the
  standing line's History clause IS observed; pinned by a test.
- **Minor 7** — carried to plan 2 (ruling AJ).
- **CLAUDE.md was not edited by the fix wave** (an agent may not edit it on an
  agent's instruction): the census wants its own tripwire row (52) — the text
  is in the fix-wave report for whoever lands it.

## The rulings, with their costs

Plan rulings, approved by Denver with the plan:

- **R1** — the §7.1 share pre-fill was dropped on merit. The root cannot read
  another participant's share permission. *Cost:* one click per reviewer
  admission.
- **R2** — the root's override is per window / per piece / per session. *Cost:*
  pressed again after a relaunch.
- **R3** — pass state and structure are probed as the piece's text, and start a
  piece is the book author's. *Cost:* a pieces-author cannot add a chapter
  until plan 2.
- **R4** — a round is gated and a check is not. *Cost:* a reviewer asks the
  author for a round.
- **R5** — ⌘S where refused flashes and writes nothing. *Cost:* no labelled
  restore point of someone else's text.

Controller rulings made on Denver's behalf (confirm):

- **A** — Tasks 7/8 extend the census allow-list, by file and spelling.
- **B** — the door takes an actor.
- **C** — tasks ran sequentially.
- **D** — `Document+Load.swift` is admitted `.allows(.op(`.
- **E** — `isRestricted` means any verb is false; the standing line keys on
  `reason`.
- **F** — a refused non-author actor reads `.reviewer`.
- **G** — census disable-experiment target.
- **H** — a yielded piece's statement and translation yield too. *Cost:* an
  unexpected line on Sam's chapter statement.
- **I** — draw from `posture`, act on `settledPosture`. *Cost:* a refused act in
  the first frames after open.
- **J** — the re-stamp keeps the author actor.
- **K** — the own-lines clause is built exactly. *Cost:* one Core field; it
  counts a chain-break line inside her own file.
- **L** — ⌘S on the project row is unchanged.
- **M** — the census substring fix.
- **N** — a successful labelled ⇧⌘S flashes.
- **O** — `authorCollaboratorId` has no writer. *Cost:* the old WF1 field stops
  being written by a path nothing called.
- **P** — a reviewer's reopen of her own note is refused until plan 2. *Cost:*
  she cannot restore her own deleted note meanwhile; the refusal is loud.
- **Q** — disposition verbs outside the queue are gated in Tasks 7/8.
- **R** — `AnnotationRowVerbs` takes no kind.
- **S** — mechanical posture-argument edits to older tests.
- **T** — the acting doors honour the root's yield. *Cost:* one extra press for
  the root.
- **U** — the letter's task verbs are gated in Task 8; discarding a proposal
  needs no door. *Cost:* a reviewer can discard a proposal she can see.
- **V** — the translator disable experiment was a plan defect.
- **W** — Duplicate needs `.startAPiece`. *Cost:* a pieces-author cannot
  duplicate her own chapter until plan 2.
- **X** — the File menu is disabled, not hidden. *Cost:* a greyed item.
- **Y** — older F10 tests narrowed to their subject key. *Cost:* weaker
  assertions.
- **Z** — `ProjectSettingsSheet` edit.
- **AA** — only the root asks. *Cost:* a non-root Mac is not told a newcomer is
  waiting.
- **AB** — recount on a settle only; retired is not waiting.
- **AC** — unverified `retiredAt` in the pre-check. *Cost:* a forged value hides
  a stranger until the next verified read.
- **AD** — the drawing door's miss cost is fixed in plan 1, not deferred.
  *Cost if wrong:* a stall on every registry arrival with a long queue.
- **AE** — the drawing path's per-miss registry signature check stays
  unmemoised (memoising could put a registry read on the main actor). *Cost:*
  about 0.1 ms per first-ask miss.
- **AF** — departure rows' *Keep mine / Make it a rule* are hidden where the
  posture refuses, and the Collection's empty state stops pointing at a hidden
  +, saying what she can do instead — fixed in Task 10, not carried. *Cost:*
  none.
- **AG** — the Documents' re-stamp and the epoch bump are one main-actor turn
  AFTER the pre-warm; the pre-warm overwrites every asked key; the docs state
  the honest limit (between a registry change landing and its refresh
  completing, surfaces draw the last known answer). *Cost:* the pre-existing
  sub-second window stays, now stated.
- **AH** — a rename by a device that may not write every linking piece renames
  what it may, skips the wiki-link rewrite in pieces it may not write, and says
  so. *Cost:* dangling `[[links]]` in collaborators' chapters until they fix
  them.
- **AI** — project Replace All skips (and names) refused documents; a single
  Replace is hidden for such a match. *Cost:* a reviewer sees matches she
  cannot replace (read-only find stays).
- **AJ** — the root's Edit Anyway from the project-scope queue is carried to
  plan 2. *Cost:* the root opens the piece to press it.

## For the release notes (with P3a's and P3b's)

- A participant on a read-WRITE iCloud share is no longer locked as a
  "reviewer". What she may write is her permit, and a read-only share still
  locks.
- A reviewer's Mac offers only what the book will take. ⌘S still flashes there.
  The File menu's New Prose Story / New Screenplay / Link Existing Project are
  greyed for anybody who is not a whole-book author.
- A successful labelled checkpoint (⇧⌘S) now flashes, like ⌘S.
- The admission sheet can appear before a newcomer has written anything, and
  only on the Mac that holds the book.

## What plan 2 carries

- **Option A (Denver's I3 ruling, 2026-09-23).** An author of some pieces may
  OPEN a new piece nobody has claimed (the load mints it; `LocalWritePermit`
  gains a *may start a piece* arm; her own Mac applies her own lines under
  *Waiting for <root> to say this piece is yours*). This widens R3's
  `.startAPiece` and ruling W's Duplicate.
- **The phone**:
  - posture off `DeviceStanding`: dispositions per piece, capture always
    offered, Settings showing role and pieces, a refresh watcher
  - the P3a carry that the phone reads annotations WITHOUT the ownership rule
    (`AnnotationLoading.swift`, `AnnotationDetailView`)
  - **ruling P's table change on both surfaces together**: own-note reopen onto
    the ownership path in `Permit.swift` and `AnnotationOwnership` — her own ⇒
    allowed, somebody else's ⇒ still author-only (tripwire 19).
- **Carries from P3b and P2** (the handoff's lists above):
  - skip the unsigned-snapshot sweep once a governing snapshot exists (carry 7)
  - the pane and `PieceWriters` listing people admitted by an ADOPTED root (M4)
  - the pre-first-seal stranger's wording plus a sent-memory keyed off the seal
    (M2)
  - the census checklist's *run from this Mac against each Mac's folders* (M6)
  - tripwire 50's prose count (M7)
  - what a Mac on no chain is SHOWN
  - `announcePendingHistory` narrowed to strangers
  - I1, I2 and I4 stay filed as future enhancements, per Denver's ruling.
- **The whole-branch review's Minor 7 (ruling AJ):** the root, in the
  project-scope queue, sees a yielded piece's rows with no verbs and no *Edit
  Anyway*; the override lives only over the editor. A one-line hint on the
  row's disabled reason, or the override in the queue's header for a yielded
  document.
- **Deferred minors from this plan worth doing**:
  - **Plan 1's own limits:**
    - Project-stream tasks have no door (`ProjectStore.createProjectPaneTask`
      / `archiveProjectTask`); it needs a permit on `ProjectStore`.
    - A capture arriving while an F10 sheet is up does not refresh it.
    - A corrupt `people/<fp>.json` hides a record-only stranger from the
      pre-check.
    - A non-root Mac pays one resolve per settle before answering empty.
  - **Cost:**
    - A never-asked queue still pays about 0.36 ms a row (door check plus
      builder check).
    - An unreadable registry re-resolves on the main actor per miss (m2) —
      now stated in the ADR's limits.
    - `posture(forPath:)` decodes the manifest per call for an unknown path
      (m4).
  - **Tests and code hygiene:**
    - Untested: the provisional path, `forPath` on a closed document, and a
      re-stamp after a class-changing adoption (m7).
    - No disable experiments on the no-registry and second-window-override
      tests (m5).
    - `passOrderNudge` is not tested end to end.
    - The margin card's nil posture draws permissive (reachable only with no
      manuscript document selected).
    - `RulingPerformer.windowlessPosture`'s synchronous registry read; three
      near-identical `offersVerbs` wrappers.
    - `TasksPane`'s `.project` arm proxies through the active document.
    - `CollectionPieceModifier` computes the start-a-piece answer on
      non-Collection projects.
    - `PostureBook.asked` is remembered for the session, deleted ids included
      (a stated ADR limit); prune it if a long session on a large book ever
      shows a slow warm.
    - Keep mine's sheet still offers both homes when only one may be written
      (it opens on the one that may; the door refuses the other in words).
    - `AnnotationInverse`'s doc comment overstates *stamped with whoever pressed
      ⌘Z*.
    - Ruling H's translation half is pinned at the desk (Task 8), but the
      `.translation` arm of the door's yield lookup is unreachable
      (`DocumentClass.resolve` never yields `.translation`): delete it, or give
      a translation stream a class.
  - ~~UNVERIFIED (ledger, Task 7)~~ — the whole-branch reviewer confirmed
    QueryRuling / FirstReaderRuling / QueueLedgerVerbs dispositions are gated
    through Task 5's row verbs.
  - The dev build's `test_apply_edit` is deliberately ungated (the smoke rig's
    typing surrogate); the census names it.
  - `BinderView.structureVerbs`/`CollectionPiecesPane.structureVerbs`' fail-
    closed arms are pinned through `TreeStructureVerbs.none` and
    `StartAPieceDoor`, not through a mounted tree.

## Open for Denver

- **M5-AN-012's filing.** The claim is amended and pinned (*decoded from old
  logs, never written*). Its filing stays **NO_RULING_REACHES** because spec §8
  is not a register RULING-n. If Denver promotes spec §8's sentence — *`authorCollaboratorId` is decoded and never
  written; attribution is the signing device through the registry* — to a RULING-n in `_meta.rulings`,
  `scripts/flip-claim.py` flips the claim to COMPLIES.
- **Confirm the controller rulings above**, the ones marked with a cost first.
