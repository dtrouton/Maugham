# Signed op log P3 — session handoff into P3c (2026-09-23)

**Why this note exists.** The session that ruled P3b's three decisions, planned it, built it (ten tasks, eight fix rounds) and merged it ran out of room. This is the door for the next one: where things stand, what to read, what Denver has already ruled, and what to do first. It points at the records; it does not repeat them.

## State of the world

- **P3a and P3b are both merged to LOCAL main** — P3b as `02d199e8` (2026-09-23), with two docs commits after it (`d2022fbd`, `bc5c7167`). Local main is **~103 commits ahead of origin**. Not pushed, not tagged.
- **Denver's ruling stands: P3 ships whole.** Nothing of P3 is pushed, tagged or released until P3c's closing smoke. Do not cut, tag or push a release from main until then.
- Gates at merge: branch full gate **8,977 / 0, no skips**; Core **1,769 / 0**; phone **274 / 0**; fast gate on merged main exit 0.
- Branch `claude/signed-op-log-p3b-2026-09-20` still exists locally (merged; safe to delete). Scratch — the ledger, ten task reports, every gate log and review diff — is in `.superpowers/sdd/2026-09-20-signed-op-log-p3b/` (git-ignored). **Verify every name in a report against source** before it goes in a plan.
- The dev app on this Mac has NOT been smoked on P3b. The first move is a smoke of the dev build, before P3c is planned against surfaces nobody has pressed.

## Read first, in this order

1. `docs/superpowers/notes/2026-09-17-signed-op-log-p3-handoff.md` from **"P3b OUTCOME"** to the end: what shipped, the release-notes lines, *Carries into P3c — added by P3b*, the **whole-branch review** (READY, no Critical, four gaps), and **"DENVER RULED 2026-09-23"** — his answers to the four and what the build adds to P3c. **This is the list P3c is planned against**, together with the earlier *Carries into P3c* section (from P3a) and the P2 carries C4/C5/C7/C10+C17/C12/C14 in the same file.
2. `docs/superpowers/specs/2026-09-19-signed-op-log-p3-roles-scope-collaborator-design.md` — §8 (the membrane), §9 (inbox + phone), §10 (constitution, ADR, docs), §12 (testing incl. the closing smoke), §13 (shipping), and its dated amendments (*As built in P3a*; retirement one-way, `cb513541`).
3. `docs/adr/0032-the-signed-op-log.md` — the **P3b addendum and its limits** (Task 10 rewrote them; the whole-branch review names five limits still to add — see below). `Maugham/OpLog/AREA.md` (P3b section, rows 21–22), `Maugham/Views/AREA.md`, CLAUDE.md tripwires 38–50.
4. `.superpowers/sdd/2026-09-20-signed-op-log-p3b/ledger.md` — every ruling with its cost-if-wrong. Hand it to P3c's whole-branch reviewer with the P3a ledger.
5. `docs/superpowers/plans/2026-09-20-signed-op-log-p3b-scope-lifecycle-and-surfaces.md` — house style only (contracts, signatures at file+line, disable experiments, both directions, the seam list at the end).

## What Denver has ruled — do not re-ask

- **2026-09-20 (P3b's three):** the unsigned door closes by snapshot at the first NARROWING, earliest governs (chronologically, across my chain's roots only); `claimedAt` stays, adopted rows dated device-locally; the release census is a kept script and the load's three bursts carry a `synthesisSource` that changes no judgment.
- **2026-09-23 (the review's four):** I1 (the enclave-less Mac's standing line), I2 (held annotation lines have no way back), I4 (the gate's in-session window) — **document and file as future enhancements**; the sentence in I2 must stop promising the Inbox for held notes. **I3 — option A, a P3c task**: an author of some pieces may OPEN a new piece nobody has claimed; the load mints it; her own Mac applies her own lines under a standing line (*Waiting for <root> to say this piece is yours*); she still may not write in a piece that exists and is not hers.
- **Rulings made on Denver's behalf during the build, confirmed 2026-09-23:** retirement is one-way (§7.3's third question withdrawn); *Theirs* cuts a settled piece's streams before her held span (earlier refusals stay set aside; a later permit refusal in that stream is re-judged); only a root of my chain narrows my book; Re-admit over a permit this build cannot read refuses; the §7.1 read-only-share reviewer pre-fill is P3c's.
- **Still open, for the release task:** should an OLD build refuse a narrowed book / a book with events (leave it; refuse; a one-way notice)? The gate answers the NARROWED case; the eventless-book case is still Denver's.

## What P3c is (re-derive against the BUILT code — rule 11; cap ~10 tasks — rule 12; probably two plans)

Spec §8, §9, §10 plus what P3a/P3b handed forward:

- **`Posture`** — one Core value derived from *this device's own permit for the document shown* (`OpLogStore.localWritePermit` is the write-side question; ask `Permit.allows`, never a rung — tripwires 44/47), and every surface gates on it: locked editor; no dispositions in queue or margin; no pass chips; statement panes read-only; no structural verbs in the tree (cooperative); no Run for a round. The root on somebody else's piece gets a warning and an override. **⌘S keeps its flash and writes NO op on a piece this device may not write** (P3a carry); `flushBurstNow` is not permit-guarded by design and the membrane is what makes that safe. A census with a planted offender: posture is asked of the permit, spelled once.
- **Component A retires**: `CollaborationRole`, `ShareIdentityMapper`, `ReviewPosturePolicy`, `ProjectWindow.resolvedRole`/`shareReader`/`effectivePosture`, the phone's `SharingRoleBanner`; `SharingStatusPill` stays as an indicator; `FileURLShareMetadataReader` survives with one caller — the admission sheet's defaults, which is where **§7.1's read-only-share suggests reviewer** finally lands.
- **Option A** (above), touching the P3a load seam — its own task and its own opus review.
- **Inbox attribution** (`InboxByline` resolves a row's `deviceId` to a person: *from Sam*).
- **The phone**: apply `AnnotationOwnership` (it honours what the Mac judges away — `AnnotationLoading.swift` ~68/74, `AnnotationDetailView` ~561); `DeviceStanding` gains the permit; posture per piece in the Annotations tab, capture always offered; role + pieces in Settings with a refresh watcher (C5); the two `ChainPolicy` sites take their closures from the table (C7). The phone signs no record and no event; its censuses stay empty.
- **Carries from P3b** (Denver's additions, 2026-09-23): skip the unsigned-snapshot sweep once a governing snapshot exists; the pane and `PieceWriters` list people admitted by an ADOPTED root; the pre-first-seal stranger's unsigned wording + a sent-memory keyed off the seal; the census checklist says *run from this Mac against each Mac's folders*; tripwire 50's prose count. ADR limits to add: the gate's in-session window; an acknowledged loss feeding the unsigned photograph is irreversible; one-way adoption disagrees; the planted author-named file makes that key CONTESTED once the real record syncs (recoverable by revoking the planted person); a P3a-dev narrowing event without `unsigned` reads as an empty snapshot (checked 2026-09-23: zero event records on this Mac).
- **P2 carries** C4, C5, C7, C10 + C17 (one fixture factory and its census), C12, C14 (tripwire 33's click arm).
- **Constitution + guides**: *AI is never the author* gains its storage-layer sentence and falsification condition; *roles guard the words, not the binder* stated as a limit; `docs/guide/people-and-devices.md` gains posture; the WF1 spec gains *Component A retired*.
- **Then the closing smoke and the release**: the two-Mac rig (`scripts/second-mac.sh`, `--name third`): a co-author; an author of some pieces; a reviewer; a demotion while she is typing; a piece she starts (option A); *Not now* then *Theirs*; Send to Inbox (both doors); a truncated file and its Acknowledge. **Closing smoke with a second Apple ID** — WF1's participant-side iCloud review is still unverified. Run `scripts/census-load-bursts.sh` from this Mac against every Mac's folders. Paired Mac + phone release on schema 9; release notes carry *a book made on this build starts at 9*. Push main and the tag by name (never `--tags`).

## First moves for the next session

1. **Smoke the dev build on P3b** (People & Devices: make a reviewer; the admission sheet with a rung; History's drawer and doors; the new-piece sheet via the sync window) BEFORE planning — P3b's surfaces have never been pressed by a person. Fix finds on a branch off main.
2. Read the list above. Do not re-derive P3a or P3b.
3. Put the one open release question (the old build over an eventless book) in front of Denver when the release task is planned, not before.
4. `superpowers:writing-plans` for **P3c**, against the built code, ~10 tasks per plan, first plan built before the second is written (rule 11). Verify every signature at file+line.
5. Subagent-driven build on a new branch off main; opus implementers; **the most capable model for the whole-branch review, with BOTH ledgers and the seam list.**

## Process notes that paid in P3b (keep doing these)

- **The controller's trust rulings were half-stated four more times** (earliest-by-id; a claimant root could narrow the book; the snapshot expected every stream; a promotion's clause (b)). Every one was caught because reviews were told to *check the ruling, not just the code* and to state both directions. Keep both instructions in every dispatch and every review brief.
- **A disable experiment must be the REAL removal.** A name sort stayed green where the actual code path is FS order; the guard was real and the experiment was too weak. Ask "what does the code do without this line", not "what is a plausible alternative".
- **"Unreachable" was false twice** (a claimant root's narrowing; §4.5 on honest Maugham). Grep the diff for *unreachable / cannot occur / nothing in P3x / never* and test each in the whole-branch brief.
- **Census production before wiring enforcement** found the honest stranger whose held lines sit only in her assistant file (she would have stopped being offered), and the five holder shapes one sentence would have lied about.
- **Two implementers never share a file**; sequence fix rounds behind whoever holds the file. A read-only reviewer can run beside anyone.
- **Every commit builds alone** — two on this branch did not (39da7e52+68b37fcd; ac3e0927 until d75b3eeb). Say so in the dispatch; check by reading the dependency direction.
- **The weekly opus limit will cut agents off mid-gate.** Their commits and gate files survive; resume them from the report files, re-run the gates, write the missing report section yourself if the agent stalls on resume.
- The automated security review flags in-flight `EXPERIMENT` blocks as Criticals every time. The answer is still the marker grep over the COMMITTED diff before accepting a task.
- Never read a gate's exit status through a pipe; `pgrep -x xcodebuild`; no wait loop naming xcodebuild; stray `git worktree`s from other sessions' scratchpads are not yours to remove.
