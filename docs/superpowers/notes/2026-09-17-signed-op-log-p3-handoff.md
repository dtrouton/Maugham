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
