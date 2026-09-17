# Signed op log P3 — roles and the collaborator (handoff, 2026-09-17)

**Why this note exists.** P2 (people and admission, labels only) is complete on LOCAL main — P2a `c610a7c2`, P2b `08b7dedd` — unpushed by Denver's ruling (*"we aren't pushing half a milestone just because we split this into sub plans"*). P3 is the milestone's last plan. This is its brief: what P3 is, what P2 actually built that P3 stands on, what P2 left owed, and the decisions that are Denver's before a plan can be written. P3 is unspecced and unplanned; rule 11 held — nothing was written against an API that did not exist.

**Read first, in this order:**

1. `docs/superpowers/specs/2026-09-05-signed-op-log-design.md` §4.9 (roles, and the 2026-09-08 paragraph mapping the four actors onto the role table), §4.10 (the inbox), §4.11 (the phone), §5 (surfaces), §6 (constitution accounting), §8 (the P3 bullet).
2. `docs/superpowers/specs/2026-09-09-signed-op-log-p2-people-and-admission-design.md` — status BUILT; §3's root order is the amended, as-built one.
3. `docs/adr/0032-the-signed-op-log.md` §6/§8 and the P2b addendum; `Maugham/OpLog/AREA.md` tripwires 10–11 and its P2 sections.
4. `CLAUDE.md` tripwires 38–42 — every one is a census P3 will touch or extend.
5. `docs/superpowers/specs/2026-06-17-wf1-human-reviewers-design.md` — Component A is the thing P3 retires; its 2026-09-05 header note says how.
6. The P2b plan's header (`docs/superpowers/plans/2026-09-10-signed-op-log-p2b-admission-and-surfaces.md`) for decisions P1–P5 and D-C, and the P1 handoff's Decisions owed for the form a ruling takes here.

## Before P3 starts — what Denver owes P2

1. **Wipe the dev registries, then smoke.** P2a-era records do not verify under P2b's lossless digest (changed deliberately while nothing had shipped). In each dev project remove `.maugham/people` and `.maugham/devices`; remove the dev variant's `registry-cache.json` and `admission-memory.json` from Application Support. The script is the P1 handoff's Smoke section, step 0 and steps 11–20.
2. **Push** local main (40+ commits ahead of origin).
3. **Paired release** `v0.39.0` / `phone-v0.13.0` — drafts at `docs/release-notes/v0.39.0.md` and `docs/release-notes/phone/v0.13.0.md`; numbers and dates are placeholders. One tag by name, never `--tags`.

A smoke find changes P3's ground. Plan P3 after the smoke, not before.

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
2. **Should a retired device keep applying its own later writes?** Today a retired Mac keeps applying what it writes and is told so (`DeviceStanding`); every OTHER device holds those lines. That is the words-are-safe direction locally and a divergence across devices. Options: keep (told, safe, divergent); refuse further manuscript appends on a retired device (consistent, but a writer can be locked out of their own typing by their own act); allow but mark every such line so re-admission has something to show.
3. **A durable trust-event log.** Events are DERIVED from the records, and a re-admission clears the revocation, so revoke-then-re-admit reads as one admission. Options: an append-only signed event file under `.maugham/people/` (a new record kind, a fourth thing `RegistryWriter` spells); keep superseded records instead of re-signing in place; accept the loss and say so in the guide. Roles make this sharper — *was Sam an author when she wrote this?* is unanswerable from current state alone, and the role check must be evaluated against the role AT THE TIME of the span or it rewrites history on every demotion. **This one is load-bearing for P3's design, not a side question.**
4. **Carried from the P1 handoff, still open:** #6, the truncation rule's honest close (*an adopted head must be at or descended from the last trusted seal*) — ADR 0032 still names it as P2's and P2 did not build it; and #8, whether History should say once per project that a Mac with no Secure Enclave is unsigned. Confirm each is P3's, later, or dropped on merit.
5. **New with roles:** who may change a role (the root only, as with revoke?); whether a reviewer's DEVICES are admitted silently under `AdmissionMemory` the way an author's are; what a demoted author's already-applied manuscript ops read as (they stay applied — confirm the sentence).

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
