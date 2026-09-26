# Signed op log P3 — session handoff into plan 3 (2026-09-26)

**Why this note exists.** The session that planned, built and merged P3c plans 1 and 2 is handing over. This is the entry point for the next one. It **replaces** `2026-09-24-p3c-session-handoff.md`; read that one only for its smoke-rig notes. This note points at the records rather than repeating them.

## State of the world

- **Local main is `5d1b46cb`** plus this note and the CLAUDE.md edits committed with it. It holds signed-op-log P3a, P3b, the P3b smoke fix wave, **P3c plan 1** (`cc4cac11`: Posture, Component A retired, F10, tripwires 51/52) and **P3c plan 2** (`5d1b46cb`: Option A, own-note reopen, the phone, the carries). It is **about 235 commits ahead of origin**. Nothing is pushed or tagged.
- **Denver's ruling stands: P3 ships whole.** Nothing is pushed, tagged or released until plan 3's closing smoke passes and the release task runs.
- **RULING-55** is recorded in the register (attribution is the signing device), and M5-AN-012 is COMPLIES.
- **Gates on plan 2's final head** (branch `aa418ee7`; the merge changed nothing else):
  - full Mac gate: 9304 passed, 0 failed, the standing 11 skips;
  - Core: 1868 tests, green;
  - phone: 317 tests, green;
  - Release build: succeeds.
- **The disk ran out once** in this session. I deleted 27 GB of DerivedData whose `WorkspacePath` no longer existed. Check `df -h /System/Volumes/Data` before a full gate.

## Read first, in this order

1. The P3 handoff, `docs/superpowers/notes/2026-09-17-signed-op-log-p3-handoff.md`: the **P3c plan 1 OUTCOME** and **P3c plan 2 OUTCOME** sections, then **"Plan 3 — what is left before P3 ships"**. That last section is the list plan 3 is written against. Every ruling made on Denver's behalf is there with its cost if wrong (plan 1 A–AL, plan 2 A–W).
2. ADR 0032 (`docs/adr/0032-the-signed-op-log.md`): the P3c plan-1 and plan-2 addenda and their **limits**, which are the honest list.
3. CLAUDE.md: the Bootstrap hard invariant (reworded for Option A), the build-flow bullet on the **`xctest` kill**, tripwires 38–52, and the OpLog / Views / MaughamPhone cells.
4. The SDD ledgers, which are git-ignored scratch. Hand them to plan 3's whole-branch reviewer along with P3a's and P3b's.
   - `.superpowers/sdd/2026-09-24-signed-op-log-p3c-posture-and-component-a/progress.md` (plan 1)
   - `.superpowers/sdd/2026-09-24-signed-op-log-p3c-plan2-option-a-and-the-phone/progress.md` (plan 2)
5. `docs/superpowers/notes/2026-09-23-p3b-smoke-finds.md`, for the smoke rig and what the last smoke found.

## What plan 3 is (write it against the built code: rule 11; cap it at about 10 tasks: rule 12)

The list lives in the P3 handoff's **Plan 3** section. In outline:

- **The P2 carries:**
  - **C4:** pending counts from closed documents are invisible to the admission sheet.
  - **C10 + C17:** one test-fixture factory plus a census, for fixtures leaking into `$TMPDIR` and into the dev `TestWorkspace/`.
  - **C12:** the derived `.md` lags after a trust change.
  - **C14:** tripwire 33's click arm.
- **The deferred minors** the handoff lists (whole-branch triage and the final fix). Among them:
  - Ruling U's yield lifts only at the door's next rebuilt answer.
  - People & Devices has no hint for pieces stranded by a starter that has vanished.
  - The phone draws its posture after a write that throws.
  - `PostureDoor`'s header is stale.
  - Creating a large duplicated group mints every opening on the main actor.
  - Further small items.
- **The closing smoke** on the four-Mac rig (`scripts/second-mac.sh [--reset] [--name third|fourth]`), **plus a second Apple ID**; WF1's participant-side iCloud review is still unverified. Cover:
  - a co-author;
  - an author of some pieces who **starts a piece** (Option A) and writes in it;
  - the root pressing *Not now*, then *Edit Anyway*, then *Theirs*;
  - a reviewer, including **Restore of her own deleted note**;
  - a demotion while she is typing;
  - **the phone's posture and Settings row**;
  - both Send to Inbox doors;
  - a truncated file and its Acknowledge;
  - `scripts/census-load-bursts.sh`, run from this Mac against each Mac's folders.
- **The release.** A paired Mac + phone release on schema 9; the release notes say *a book made on this build starts at 9*. Push main and the tag **by name** (never `--tags`). Before the release task, **ask Denver the one question still open**: should an OLD build refuse a book that has permit events but has narrowed nobody?

## Process notes that paid in these two plans (keep doing them)

- **The whole-branch review found the Critical again, both times.**
  - Plan 1: manuscript writers that were not on the plan's verb list.
  - Plan 2: guarding who writes a piece's opening but not who writes in it.

  Tell the reviewer to assume there is a Critical, and give it every ledger and a seam list.
- **"Who may write X" lists written from prose were incomplete three times.** Only a census derived from the code closed the gap (tripwire 52's `guardedDocumentMutators`, the `StructureItem` census). Derive; never enumerate.
- **My rulings were half-rules again.** Option A needed rulings L, M, N, U and W, and each "who may" answer turned out to have a second path. Keep *check the ruling, not just the code* in every dispatch, and state both directions.
- **Permissive defaults were caught twice** (a margin card's nil posture, the phone's `.honourEverything`). Make the parameter required, so the compiler acts as the census.
- **The `xctest` kill.** Any `xcodebuild test` SIGKILLs every process named `xctest`, so a bare `swift test` in Core loses a test whenever a build starts anywhere on the Mac. Run Core through `./scripts/test.sh core`.
- **Agents stall, and tool approvals can fail for a while.** A fixer stalled after committing everything; read its report and the git log rather than re-dispatching. The auto-mode permission check failed three times in a row once; retrying later worked.
- **Subagents cannot edit CLAUDE.md on an agent's instruction.** Have them put proposed text in their report, and the controller applies it once Denver says OK.

## First moves for the next session

1. Read the list above. Do not re-derive P3a, P3b or P3c.
2. Use `superpowers:writing-plans` to write **plan 3** against the built code: the carries and minors as tasks, then the smoke and release as the last task or a plan of their own.
3. Build it subagent-driven on a new branch off main, with opus implementers working sequentially, a review per task, and fable for the whole-branch review.
4. Run the closing smoke on the rig with Denver, then the release task, asking the open question first.
