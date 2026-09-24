# Signed op log P3c plan 1 — Posture, Component A's retirement, and F10 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every surface of the Mac asks ONE value — `Posture`, derived from this device's own permit for the thing shown — whether it may offer a verb, so a reviewer's Mac never offers what the table will set aside; the WF1 share-role system (Component A) is deleted in favour of it; and the admission question is raised the moment a stranger's device record arrives (F10).

**Architecture:** `Posture` is a pure MaughamCore value built from a `LocalWritePermit` (tripwire 46's one answer) plus an optional *yielding-to* name for the root on somebody else's piece. It answers `allows(_ verb: Posture.Verb) -> Bool` through ONE exhaustive switch that maps each verb to a `Permit.Written` probe and asks `LocalWritePermit.allows` — it never compares a rung (tripwire 47). The Mac reaches it through `DocumentStore.posture(forDocId:)`, cached per trust epoch, and every surface gates on it; the verbs that write (Document's disposition mutators, `RulingPerformer`, `CheckpointCapture`, `CompilerOrchestrator`'s round, the translation pipeline) refuse at their own door as well, so a surface that forgets is a flash, not a set-aside record.

**Tech Stack:** Swift 6, SwiftUI/AppKit, XCTest. MaughamCore + the Mac target + the phone (Component A's phone banner is deleted here; the phone's own posture is plan 2).

**Spec:** `docs/superpowers/specs/2026-09-19-signed-op-log-p3-roles-scope-collaborator-design.md` §8 (the membrane), §10 (docs), with its dated amendments. Rulings and carries: `docs/superpowers/notes/2026-09-24-p3c-session-handoff.md`, `docs/superpowers/notes/2026-09-23-p3b-smoke-finds.md` (F10, "Observed as designed"), `docs/superpowers/notes/2026-09-17-signed-op-log-p3-handoff.md` (*Carries into P3c* from P3a — ⌘S, `close()`'s failed flush). **Where this plan, the spec and a ruling differ, stop and say so — do not pick.**

## How to read this plan

Contracts, the failure each must not have, and **signatures verified at file+line on 2026-09-24 against main `5b2fa0d9`** — no function bodies (memory: *a plan's code is a liability*). If a cited line has moved, find the symbol. If a cited signature is WRONG, stop and report: that is a plan defect.

**The disable experiment is required on every negative assertion** (*is not offered*, *writes nothing*, *refuses*, *is locked*): remove the REAL guard (not a plausible alternative — ask *what does the code do without this line*), watch the test fail, restore it, put the failing output in your report. Wrap the experiment in a line containing the literal word `EXPERIMENT` so the controller's marker grep finds one you forgot.

**Every rule is stated in both directions.** A demotion locks what a promotion unlocks, mid-session, in the same window. If you find yourself building one half, the other half is in the task. **Check the ruling, not just the code** — the controller's relayed rulings have been half-rules six times in P3; stop if one looks half-stated against the code.

**"Unreachable" is a claim to test.** Any guard you describe as unreachable, redundant or belt-and-braces gets a test of the state, or it goes.

## Global Constraints

- **Behaviour-neutral for every book whose device has no narrowing permit.** `LocalWritePermit.unrestricted` / `.bookAuthor` as `.author` ⇒ `Posture` allows every verb ⇒ every existing suite passes UNTOUCHED, except the Component A suites Task 4 deletes and the two F10 premise tests Task 9 names. Any other pre-P3c test needing an edit is a stop-and-report.
- **`Posture` is asked, never re-derived.** No surface file under `Maugham/Views`, `Maugham/Editor`, `Maugham/Compiler` or `Maugham/Publish` names `LocalWritePermit`, `localWritePermit`, `Permit.allows`/`.allows(.op(`, a rung, or `CollaborationRole`. They ask `posture.allows(.someVerb)`. Task 1's census enforces it.
- Tripwires 38–50 bind. In particular 44/47 (the one table; no rung comparisons outside the permit layer), 46 (`OpLogStore.localWritePermit` is the one *may this actor write here* — `Posture` is built FROM it, never beside it), 21 (every new event is a `MaughamEvent` with a declared scope), 15 (any new empty state), 33 (no test presses a mounted control and waits — pin the decision on the pure model; assert only that the control is drawn or absent), 3 (no heavy work in a binding setter — `posture(forDocId:)` must be O(1) in a view body after the first call per epoch).
- **Hide, don't disable.** A verb the posture forbids is not drawn (a greyed Accept reads as broken). The ONE exception is the editor, which stays selectable/copyable and simply refuses mutation — the P2 membrane's shape (`EditorEditPolicy`, `shouldChangeTextIn` only; `isEditable` untouched).
- **⌘S always flashes** (constitution position; `feedback_ux_reflexes`). What it writes depends on posture; the flash does not.
- **The AI actor is never given a product name** in any sentence: *the assistant*.
- **Roles guard the words, not the binder** (ADR 0032 limit). Structural verbs are hidden by posture COOPERATIVELY — nothing at storage refuses a reviewer's manifest write, and no sentence may claim otherwise.
- **An iCloud read-only share is a separate, OS-level lock** and survives Component A: `ShareMetadata.canWrite == false` still locks the editor and shows `ViewOnlyShareNotice`. It claims no role.
- Fixtures register their roots and remove them in `tearDown`. Reuse `DocumentWaitingTests`' `narrow(...)`, `PermitLoadTests`' and `RegistryAdmissionTests`' helpers; every test asserting *verified* injects the test signer (tripwire 36). New suites that style text call `FontWarmup.ensure()` in `class setUp`.
- **Process:** branch `claude/signed-op-log-p3c-plan1-2026-09-24` off `main`; implementers in **worktrees**, never two sharing a file (the file lists below are the contract — if you must touch a file another task owns, stop). `git commit -- <paths>`; never amend a reviewed commit; every commit builds alone; `./gen.sh` in the same step as any file add/delete (and first thing in a fresh worktree); `pgrep -x xcodebuild`, never `-f`; no wait loop with `xcodebuild` in its argv; never read a gate's exit status through a pipe — redirect to a file and `echo $?`. Each agent writes only under its own scratch directory. Gates per task: `swift test --parallel --package-path Packages/MaughamCore` for any Core change, `./scripts/test.sh`, `./scripts/test.sh phone` for any Core or phone change; `./scripts/test.sh full` on Tasks 3, 4, 10 and after every integration of parallel branches. **END YOUR TURN WITH THE HAND-BACK** (report file + final message), always.
- **Models:** opus for every task. Task reviewers: sonnet (opus for Tasks 1, 2, 9), told to check the RULING as well as the code. Whole-branch review: the most capable model (fable), given both P3 ledgers, the smoke finds note and the seam list at the end.

## Review Focus

The inputs the spec implies but no single task's happy path exercises, most likely first — each has its pinning test in the owning task:

1. **A demotion arriving while she is typing** — the editor locks at the next keystroke and no burst of refused text is signed in her name (Task 2's re-stamp + Task 3's mirror; the seam list's first line).
2. **A queue showing several documents at once** — each row judged by ITS document's posture, never the window's selection (Task 5).
3. **A statement or translation document id** — its posture follows the piece it belongs to (a piece statement, a translation) or the book (a project statement), and a translation is judged as the translator actor (Tasks 7, 8).
4. **The root opening a collaborator's piece in two windows** — Edit Anyway in one leaves the other cooperative (Task 2).
5. **A stranger whose device record and first lines arrive in one settle** — one sheet, not two (Task 9).

## Rulings this plan makes on Denver's behalf (confirm at plan review)

Each with its cost if wrong. The controller records them in the ledger as `Ruling:` lines.

- **R1 — Spec §7.1's share pre-fill is DROPPED on merit, and `FileURLShareMetadataReader` keeps its non-role callers.** The spec assumed the admitting root can read *this stranger joined through a read-only share*. It cannot: on the root's Mac the URL keys (`ubiquitousSharedItemCurrentUserPermissions` et al., FileURLShareMetadataReader.swift:45–90) describe the ROOT's own participation — always owner/read-write — and nothing names another participant's permission. And a read-only participant cannot upload into the shared folder at all, so its device record never arrives and no sheet is ever raised about it. The reader survives for `SharingStatusPill` (an indicator claiming no role), `ProjectShareEligibility` and `ViewOnlyShareNotice`. *Cost if wrong:* the sheet keeps defaulting to the whole book (P2b's behaviour) — one extra click per reviewer admission.
- **R2 — The root's override on somebody else's piece is per window, per piece, for the session.** The root opening Sam's piece sees the review posture with a standing line *This is Sam's piece — Edit Anyway*; pressing it lifts the posture for that piece in that window until the window closes. Not persisted, not synced. *Cost if wrong:* the root presses it again after a relaunch.
- **R3 — Pass state and structural verbs are probed as *may you write this piece's text*.** Neither is an op (pass state is a manifest field — `RefusedWhat.passState` is produced by no `OpKind`, Permit.swift:360–366), so `Posture`'s switch maps them to `.op(.typingBurst)` in the piece's class. New Document / New Group at the root of the tree maps to the book-author probe (`LocalWritePermit.hardestClass`, LocalWritePermit.swift:59) — plan 2's Option A widens *start a piece* for an author of some pieces. *Cost if wrong:* a pieces-author cannot add a chapter until plan 2 lands (P3 ships whole, so no writer ever sees this build).
- **R4 — Round Run is gated; Author's check is not.** A round moves pass lanes and stamps a pass (manifest writes a reviewer's posture forbids); a check mints unstamped annotations, which is the reviewer row. *Cost if wrong:* a reviewer who wants a round asks the author.
- **R5 — ⌘S on a piece this device may not write flashes and writes nothing — no op AND no checkpoint entry; ⇧⌘S's label sheet says why instead of opening.** A checkpoint of text she cannot change marks nothing of hers, and an entry without its op is a dangling reference. *Cost if wrong:* a reviewer who wanted a labelled restore point of someone else's text has none (she can still Backup).

## File structure

New:

| file | one responsibility |
|---|---|
| `Packages/MaughamCore/Sources/MaughamCore/Posture.swift` | the value, `Posture.Verb`, the ONE verb→probe switch, the standing-line inputs |
| `Packages/MaughamCore/Sources/MaughamCore/ShareMetadata.swift` | `ShareMetadata` + `ShareMetadataReading`, moved out of the deleted `CollaborationRole.swift` unchanged |
| `Maugham/Stores/DocumentStore+Posture.swift` | the Mac's one door: `posture(forDocId:)`, the per-epoch cache, the root's yielding name, the override set, re-stamping open documents |
| `Maugham/Views/PostureStandingLine.swift` | the pure sentence model + the thin view for the editor's standing line (replaces `ReviewModeIndicator`'s role use) |
| `Packages/MaughamCore/Tests/MaughamCoreTests/PostureTests.swift`, `MaughamTests/Stores/DocumentStorePostureTests.swift`, `MaughamTests/Views/PostureSurfaceTests.swift`, `MaughamTests/Views/PostureStandingLineTests.swift` | tests |

Deleted: `Packages/MaughamCore/Sources/MaughamCore/CollaborationRole.swift`, `ShareIdentityMapperTests.swift`, `ReviewPosturePolicyTests.swift`, `MaughamPhone/Read/SharingRoleBanner.swift`.

---

### Task 1: `Posture` — the value, the one switch, and its census

**Files:** Create `Posture.swift`, `PostureTests.swift`. Modify `MaughamTests/TripwireGrepTests.swift` (new census + planted offender only — append; do not edit other censuses).

**Verified facts:**
- `LocalWritePermit` LocalWritePermit.swift:24 — `permit` :27, `actor` :35, `documentClass: DocumentClass?` :38, `.unrestricted` :48, `hardestClass` :59, `func allows(_ what: Written) -> Allowed` :62 (uses `documentClass ?? hardestClass`), `allows(_:signedBy:)` :74.
- `Permit.Written` Permit.swift:340 (`.op(OpKind)`, `.translationRecord`, `.inboxRow`); `Allowed` :388 (`.yes`, `.no(RefusedWhat)`, `.cannotJudge`); `WrittenGroup` :403 — `claudeAccept`/`claudeReject`/`claudeAcceptRevert` are **manuscriptText**; `claudeArchive`/`annotationReopen`/`annotationStet`/`annotationTriage` are **disposition**; `checkpoint` its own group; tasks follow `maySignTasks`.
- `DocumentClass` DocumentClass.swift:23 — `piece`, `pieceStatement(piece:)`, `projectStatement`, `projectStream`, `translation(piece:)`, `inbox`, `unplaceable`.
- Census helpers: `grepSwift(in:patterns:allowedSpellings:excludeLine:onlyFiles:)` TripwireGrepTests.swift:7468; `admissionExcludeLine` :7419; model census `test_aPermitRungIsComparedOnlyInThePermitLayer` :8270 with `permitLiteralAllowed` :8256; planted-offender control `test_thePermitCensusesFireOnPlantedOffenders` :8417 (part 4, :8567–8610, the move-to-allow-listed-filename trick).

**Contract:**
- `public struct Posture: Equatable, Sendable` built by `public init(_ permit: LocalWritePermit, yieldingTo: String? = nil)`. `public static let author = Posture(.unrestricted)`.
- `public enum Verb: CaseIterable, Sendable` — exactly: `writeText`, `acceptOrReject`, `dispose` (stet/archive/triage/reopen), `setPassState`, `editStatement`, `restructure`, `startAPiece`, `runRound`, `checkpoint`, `task`, `translate`, `annotate`. `public func allows(_ verb: Verb) -> Bool`.
- **ONE switch, no `default:`**, mapping each verb to a `Permit.Written` probe (R3's mapping for `setPassState`/`restructure`/`runRound`; `startAPiece` probes with `documentClass` forced to `LocalWritePermit.hardestClass`; `annotate` probes `.op(.claudeComment)`; `task` probes `.op(.taskCreate)`; `translate` probes `.translationRecord`; `checkpoint` probes `.op(.checkpoint)`), answered by `LocalWritePermit.allows(_:)`. `.cannotJudge` ⇒ **false** for every verb except `annotate` (a permit this build cannot read still lets her leave a note — the reviewer row — and NEVER lets her change text). `yieldingTo != nil` ⇒ every verb except `annotate` answers false (the cooperative review posture; R2's override is the Mac's business — it builds the posture WITHOUT `yieldingTo`).
- `public var isRestricted: Bool` (any verb false) and `public var yieldingTo: String?`. `public var reason: Reason?` — `.reviewer`, `.notYourPiece`, `.yielding(to:)`, `.cannotJudge` — derived INSIDE Posture.swift from the permit (this is the one sanctioned place outside `Permit.swift` that may read the rung, and only to name the reason; add Posture.swift to `permitLiteralAllowed` with the exact spellings it uses, file-plus-spelling).
- **Census (new CLAUDE.md tripwire 51, written in Task 10):** `test_postureIsAskedOfThePermitInOnePlace` — over `Maugham/` and `MaughamPhone/`, the spellings `LocalWritePermit`, `localWritePermit`, `.allows(.op(`, `.allows(.translationRecord`, `Posture(` (construction) are offenders outside an allow-list of: `Maugham/Stores/DocumentStore+Posture.swift` (all), `Maugham/OpLog/Document.swift`, `Document+Load.swift`, `Document+Waiting.swift`, `Document+Tasks.swift`, `Document+Annotations.swift` (`localWritePermit` only — the P3a sites, listed by file AND spelling). Plus: `CollaborationRole`, `ReviewPosturePolicy`, `ShareIdentityMapper`, `effectivePosture` anywhere in the three roots ⇒ offender (this half goes green only after Task 4; mark it `XCTExpectFailure` in THIS task with a message naming Task 4, and Task 4 removes the expectation). Planted-offender control: a temp file with one of each spelling, asserting the exact hit count, then moved to an allow-listed filename to prove file-plus-spelling.

**Both directions:** `.unrestricted` ⇒ all twelve verbs true; `.reviewer` in `.piece(x)` ⇒ only `annotate`; `.author(.pieces(["a"]))` ⇒ everything in `.piece("a")`, only `annotate` in `.piece("b")`, `task` true in `.projectStream`, `editStatement` false in `.projectStatement`; `startAPiece` true only for the book author; unjudgeable ⇒ only `annotate`; `yieldingTo: "Sam"` over `.unrestricted` ⇒ only `annotate`.

**Must not:** compare a rung outside `reason`; add a second verb→probe table anywhere; make `Posture` depend on `Registry` or I/O.

- [ ] Red: the full verb × {unrestricted, reviewer, pieces-in, pieces-out, unjudgeable, yielding} table as one table-driven test (every cell asserted, not sampled); the census + control. **Disable:** replace the `.cannotJudge` arm with `true` and watch `writeText` go red; drop Posture.swift from the allow-list and watch the census fire.
- [ ] Implement. Core + Mac + phone gates. Commit `feat(core): Posture — one value, asked of the permit, twelve verbs`.

---

### Task 2: The Mac's one door — `DocumentStore.posture(forDocId:)`, fresh on every trust change

**Files:** Create `Maugham/Stores/DocumentStore+Posture.swift`, `MaughamTests/Stores/DocumentStorePostureTests.swift`. Modify `Maugham/Stores/DocumentStore.swift` (only `invalidateTrust` and the manifest-adoption point call into the new file), `Maugham/OpLog/Document.swift` (make the `localWritePermit` stamp re-assignable through one internal setter used by the new file).

**Verified facts:**
- `OpLogStore.localWritePermit(as:documentClass:) -> LocalWritePermit` OpLogStore.swift:254 — sync, non-throwing; `registerTable()` :288 (nil when nothing to resolve; falls back to `TrustResolution.rememberedOrKeyless` on a throw). Class closure called only when `answersWithoutTheClass` is false.
- `Document.localWritePermit` Document.swift:160 is stamped ONCE, Document+Load.swift:655 (`let writePermit = opStore.localWritePermit { Document.documentClass(forDocId: docId, in: projectURL) }` :381). **Nothing re-stamps it**: `registryChanged()` DocumentStore.swift:1344 → `invalidateTrust()` :1615 → `reReadAfterExternalChange` never touches it. Readers: `mayWriteThePendingFile` :186, Document+Tasks.swift:97–98/:138, Document+Annotations.swift:1321.
- `Document.documentClass(forDocId:in:)` Document+Waiting.swift:63 (wraps `OpLogStore.documentClass(forDocId:in:)` OpLogPermitContext.swift:372).
- `PieceWriters.resolve(registry:table:pieces:)` PieceWriters.swift:113 / `read(projectURL:pieces:) async` :167 — who authors which piece; `TrustTable.myRoot` TrustTable.swift:71.
- Manifest adoption (F7): `DocumentStore.handleManifestChanged` (find it; `Maugham/Stores/AREA.md` F7 section) — a class can change when a piece moves or a statement is added.

**Contract:**
- `@MainActor func posture(forDocId docId: String) -> Posture` — O(1) after the first call per `(docId, postureEpoch)`; the first call builds `LocalWritePermit` through `OpLogStore.localWritePermit(as: .author) { Document.documentClass(forDocId:in:) }` (the ONE builder — tripwire 46) and wraps it. `var postureEpoch: Int` is observable and bumps on `invalidateTrust()` and on manifest adoption; the cache clears with it. Views read `posture(forDocId:)` in `body` and re-render on the epoch.
- **Yielding (R2):** when this device is a root (`myRoot` is mine) and `PieceWriters` names somebody else as the holder of `docId` (an author-of-some-pieces grant — a co-writing book author is NOT yielded to), the posture carries `yieldingTo: <their label>` unless `overridden.contains(docId)`. `func overrideYield(docId:)` inserts; the set is per `DocumentStore` (per window), never persisted. `PieceWriters` is resolved off-main (it is already async) at open and after every epoch bump, and the epoch bumps again when it lands; until then, no yielding (never a lock the writer did not earn).
- **Re-stamp:** on every epoch bump, every open `Document`'s `localWritePermit` is re-stamped from the same builder — so a demotion mid-session stops `mayWriteThePendingFile`, `mayAnchor`, `mayRebalance` and the automation guard at the next keystroke, and a promotion restores them. (P3a carry: `close()`'s failed-flush arm declines to re-persist on a not-permitted device — with Task 3's lock nothing un-bursted accumulates there; pin that a demoted, locked document's `close()` loses no keystroke that was typed while it was still permitted.)
- The document shown in the window has a path, not just an id: add `posture(forPath:)` delegating through `document(for:)`/the manifest, never a second computation.

**Both directions:** demotion (P3b `changePermit` driven through the test root) while a document is open ⇒ epoch bumps, `posture(forDocId:).allows(.writeText)` false, `document.mayWriteThePendingFile` false; promotion back ⇒ both true, no reopen. Root + Sam's piece ⇒ `yieldingTo == "Sam"`; after `overrideYield` ⇒ nil; a second window's store still yields. A book with no registry ⇒ `.author` and the builder is never asked for a registry read (pin: zero calls to `TrustResolution.resolveVerified` — reuse `RegistryCacheTests.test_aProjectWithNoRegistryNeverReachesForTheEnclave`'s shape).

**Must not:** read the registry on the main thread in `posture(forDocId:)`; build a `LocalWritePermit` any other way; persist the override; yield to a co-writing book author.

- [ ] Red: both directions above; the re-stamp; the no-registry zero-read pin; the epoch bumps on manifest adoption. **Disable:** remove the re-stamp call and watch the demotion test's `mayWriteThePendingFile` stay true; remove the cache clear and watch the promotion test read the stale posture.
- [ ] Implement. Mac gate. Commit `feat(posture): the window's one door — posture per document, fresh on every trust change`.

---

### Task 3: The editor, the statement editor, ⌘S and the standing line

**Files:** Modify `Maugham/Views/ProjectWindow.swift` (`EditorControlMirrorModifier` :4844 and its call :695–698, the ReviewModeIndicator site :1437–1438, `CheckpointModifier` :4238–4285, the ⇧⌘S label sheet :405–427), `Maugham/Views/StatementEditorHost.swift` (seed :599–603, image paste :1132), `Maugham/Views/StatementPane.swift` (pass the posture in). Create `Maugham/Views/PostureStandingLine.swift`, `MaughamTests/Views/PostureStandingLineTests.swift`. Tests also in `MaughamTests/Editor/ReviewModeMembraneTests.swift` (append only).

**Verified facts:**
- The membrane: `EditorEditPolicy.allowsTextMutation(isReviewMode:lockEditing:isTranslationReview:)` EditorEditPolicy.swift:10, consulted ONCE at `EditorCoordinator.textView(_:shouldChangeTextIn:replacementString:)` EditorCoordinator.swift:950. Values arrive via `EditorControl.isReviewMode`/`.lockEditing` EditorControl.swift:20–21 → `applyControl` EditorCoordinator.swift:919–922. ⌘⌥⇧R flips `isReviewMode` directly :537–538. `isEditable` is set only by recovery (EditorSurface.swift:253).
- Today `EditorControlMirrorModifier` mirrors `effectivePosture` (iCloud role) into `editorControl.isReviewMode`/`.lockEditing` (:4852–4855 onChange, :4870–4871 onAppear). `ReviewModeIndicator(collaboratorName:)` shows when `effectivePosture.isReviewMode` (:1437).
- The statement editor never sets `lockEditing` (StatementEditorHost.swift:347 `@State private var editorControl`, seed :599–603) and always wires image paste (:1132). `ResearchNoteEditor.swift:141` is the precedent: it nils the paste handler when locked.
- ⌘S: `.maughamSaveCheckpoint` handled in `CheckpointModifier` (:4258–4285): `activeDoc?.flushBurstNow()` → `CheckpointFlashDecision.run(projectURL:onSuccess:capture:)` (:4211–4228) → `CheckpointCapture.run(projectURL:activeDocId:allDocIds:device:session:label:activeDocument:)` CheckpointCapture.swift:16, which appends `Op(kind: .checkpoint, …)` with no permit check. The table refuses `.checkpoint` unless `authors(class)` (Permit.swift:839).

**Contract:**
- The mirror reads `posture(forPath: selected)` (Task 2) instead of `effectivePosture`: `lockEditing = !posture.allows(.writeText) || shareIsReadOnly`, `isReviewMode = manualReview || !posture.allows(.writeText)` (a reviewer's Mac opens in review mode so the selection toolbar offers annotation — the Component A shape, now from the permit). Keep `shareIsReadOnly` as a plain `Bool` input for now; Task 4 re-sources it. Mirror on `postureEpoch` change as well as selection.
- `CheckpointCapture.run` gains a door: it refuses with a typed error `CheckpointRefusal.notYourText` when the active document's posture forbids `.checkpoint` — BEFORE the op or the checkpoint entry (R5: neither). `CheckpointModifier` flashes regardless and swallows exactly that refusal; any other error keeps today's behaviour. ⇧⌘S over a forbidden document shows the refusal sentence (one sentence, in `PostureStandingLine`'s phrasebook) instead of the label sheet.
- The statement editor locks through its own `EditorControl` from `posture(forDocId: statement's doc id).allows(.editStatement)` and nils its image-paste handler while locked.
- `PostureStandingLine` (pure model + thin view, status-footer register, tripwire 15 N/A — it is a line, not an empty state): given a `Posture` and the piece title, one sentence per `Posture.Reason` — *You're reviewing this book — your notes reach <root>; the text is theirs.* / *"<title>" isn't one of your pieces — you can leave notes.* / *This is <name>'s piece.* + **Edit Anyway** (calls `overrideYield`) / *This Mac can't read the permission it was given — update Maugham to write here.* — and, when this document holds set-aside or held lines SIGNED BY THIS DEVICE'S OWN KEYS (the smoke's *observed as designed* item: her own dropped lines), a second clause *Some of what you wrote here is kept in History* with a History link. Find the provenance API for this document's own set-aside/held lines (`document.provenance`, `HeldLines`, `JSONLAppendStore.setAside` records); if none can answer *signed by my keys* without a disk read on the main actor, **stop and report** — do not add a read.
- Replaces `ReviewModeIndicator`'s role-driven display; manual review mode (⌘⌥⇧R) keeps its existing indicator with no role text.

**Both directions:** reviewer ⇒ typing refused, selection + copy work, review mode on, standing line shown; promoted mid-session ⇒ typing accepted, line gone, no reopen. ⌘S reviewer ⇒ flash, **zero new ops in any stream and zero new checkpoint entries** (count both); ⌘S author ⇒ op + entry as today. Statement pane on a project statement for a pieces-author ⇒ locked; for the book author ⇒ editable. Root on Sam's piece ⇒ locked with Edit Anyway; after it ⇒ editable, line gone.

**Must not:** set `isEditable`; lose the flash; write a checkpoint entry without its op; add a main-actor disk read for the standing line.

- [ ] Red: the mirror decision as a pure function test (inputs → `(lockEditing, isReviewMode)`); the ⌘S counts through `CheckpointCapture.run` directly (not the mounted keystroke — tripwire 33); the statement lock decision; every standing-line sentence; the own-lines clause from a fixture with one set-aside line of this device's. **Disable:** remove the capture door and watch the reviewer count go to 1; remove the statement lock and watch the pieces-author test mutate.
- [ ] Implement. **Full gate.** Commit `feat(posture): the editor, the statement editor and ⌘S ask the posture; the standing line says why`.

---

### Task 4: Component A retires

**Files (after Task 3 merges):** Delete `Packages/MaughamCore/Sources/MaughamCore/CollaborationRole.swift`, `ShareIdentityMapperTests.swift` (6 tests), `ReviewPosturePolicyTests.swift` (5 tests), `MaughamPhone/Read/SharingRoleBanner.swift`. Create `Packages/MaughamCore/Sources/MaughamCore/ShareMetadata.swift`. Modify `Maugham/Views/ProjectWindow.swift` (:251 `collaborator`, :320 `shareSnapshot`, :333 `shareReader`, :687–691 resolve task, :783–802 `resolveCollaborator`/`resolvedRole`/`effectivePosture`, :817–820 `isViewOnlyReviewer`, :1403 pill, :1447 notice), `Maugham/Views/SharingStatusPill.swift`, `MaughamPhone/Read/BinderView.swift` (:63–66), `Maugham/OpLog/Document+Annotations.swift` (`authorId` params :274/:306/:415 and the writes :204/:354/:396/:443), `Packages/MaughamCore/Sources/MaughamCore/FileURLShareMetadataReader.swift` (doc comment only), `Maugham/Editor/EditorEditPolicy.swift` (doc comment naming the role), `MaughamTests/TripwireGrepTests.swift` (remove Task 1's `XCTExpectFailure`; fix the :8243 comment), `CLAUDE.md` tripwire 47's cell (drop the `CollaborationRole.reviewer` clause — the ambiguity it explained is gone).

**Verified facts:** see the inventory in Task 3's facts and: `Collaborator` CollaborationRole.swift:29, `ShareMetadata` :75, `ShareMetadataReading` :106, `ShareIdentityMapper` :111, `ReviewPosturePolicy` :157. `ShareMetadata` is also consumed by `ProjectShareEligibility.evaluate(isInICloudDrive:metadata:)` ProjectShareEligibility.swift:27 (reads `isShared` only) and `ProjectShareSheetPresenter.present(projectURL:snapshot:in:)` (ProjectWindow.swift:557–558). `SharingStatusPill` switches on role at :49/:64/:72/:80/:96. `authorCollaboratorId` Op.swift:65 has no production writer passing a value (EditorHost.swift:792/869/877 and AnnotationsPane.swift:1849/1866 omit `authorId`); `ReviewPalette.swift:43` reads the derived `collaboratorId` for colour.

**Contract:**
- `ShareMetadata` + `ShareMetadataReading` move to `ShareMetadata.swift` byte-identical in API. `FileURLShareMetadataReader` keeps its API and its three non-role consumers (R1). `ICloudShareMetadataReader` typealias stays.
- `ProjectWindow` keeps `shareSnapshot` (renamed nothing) and derives `shareIsReadOnly = shareSnapshot?.canWrite == false && shareSnapshot?.isShared == true` → Task 3's mirror input and `ViewOnlyShareNotice`. `collaborator`, `resolvedRole`, `effectivePosture`, `isViewOnlyReviewer` and `resolveCollaborator` are deleted; the re-read on `didBecomeActive` stays for the snapshot.
- `SharingStatusPill(snapshot:)` — *Shared* / *Shared by <owner>* / hidden when unshared; no role word, no *reviewer*, no *author*. While the snapshot is unresolved it draws nothing (not *Checking…* — a role-free pill has nothing to check).
- The phone's `BinderView` loses the banner and its section if that leaves it empty. The phone's posture is plan 2 — say so in the commit message.
- `authorCollaboratorId` is **decoded and never written**: delete the `authorId` parameters from the three `Document+Annotations` write paths (so nothing CAN write it); `Op`'s decode and `AnnotationDeriver.swift:137`/`AnnotationInverse.swift:69` stay (old logs carry it). Tests that passed `authorId:` (`ReviewerAnnotationCreationTests` :34/:42/:60, `AnnotationsCharacterization` :288/:292/:975) — rewrite each to decode a hand-built LOG LINE carrying `author_collaborator_id` instead of writing one; a characterization claim that pins *writing* it is a register change: stop and report with the claim id.
- Incidental test users (`ReviewModeMembraneTests` :123 messages, `DetailPaneColumnHeightCensusTests`' `ViewOnlyShareNotice` mounts, `ProjectShareEligibilityTests`) keep passing with at most an import/message edit; list every edit in the report.

**Both directions:** a read-only iCloud share (snapshot `canWrite: false`) still locks the editor and shows the notice on a book with no registry; a read-write share over an author posture does not lock. `grep -rn "CollaborationRole\|ShareIdentityMapper\|ReviewPosturePolicy\|effectivePosture\|resolvedRole\|SharingRoleBanner" Maugham MaughamPhone Packages/MaughamCore/Sources` is empty.

**Must not:** delete `FileURLShareMetadataReader` or `ShareMetadata`; leave a role word in the pill; keep any writer of `authorCollaboratorId`.

- [ ] Red: Task 1's census now passes without `XCTExpectFailure`; the read-only-share lock decision (pure, through Task 3's mirror function); the pill's three texts as a pure function. **Disable:** re-add a stray `CollaborationRole` reference and watch the census fire.
- [ ] Implement; `./gen.sh`. **Full gate** + phone. Commit `refactor: Component A retires — the share role gives way to the permit; the share stays an indicator`.

---

### Task 5: Dispositions — the queue, the bulk bar and the margin

**Files:** Modify `Maugham/Views/AnnotationsPane.swift` (row build :1315–1357, `bulkButton` :1466, `bulkTriageMenu` :1486, `dispositions(useIcons:)` :2289–2327, `stetButton` :2394, Reopen in `actions` :2275), `Maugham/Views/Review/AnnotationBulkActions.swift` (`perform` :249), `Maugham/Editor/ReviewCardActions.swift` (`actions(for:isOwn:)` :78), `Maugham/Editor/EditorCoordinator+ReviewRender.swift` (`performReviewCardAction` :193), `Maugham/OpLog/Document+Annotations.swift` (`acceptAnnotation` :490, `rejectAnnotation` :822, `stetAnnotation` :888, `archiveAnnotation` :988, and the triage/reopen mutators — find them). Tests `MaughamTests/Views/PostureSurfaceTests.swift` (create), `ReviewCardActionsTests` (append).

**Verified facts:** queue rows are gated today only by `AnnotationScopePolicy.verbsEnabled(documentIsOpen:)` AnnotationScope.swift:41; bulk by `.disabled(planned.isEmpty || bulkInFlight)` :1478. The Document mutators' only guards are `rejectMutationIfNotWritable`/`requireWritable` (Document.swift:1701/1722 — closed or recovery documents). Margin card actions are chosen by `ReviewCardActions.actions(for:isOwn:)` with `isOwn` from `AnnotationOwnership` (ReviewRenderViews.swift:27–30).

**Contract:**
- **The door:** each Document disposition mutator refuses with a typed error (reuse the `AutomationNotPermitted` family if its shape fits; otherwise `PostureRefusal(kind:)`) when `localWritePermit.allows(.op(kind)) != .yes` — Task 2 keeps that stamp fresh. This is the P3a automation guard (Document+Annotations.swift:1321) widened from automations to every caller. `localWritePermit` is already allow-listed in this file by Task 1's census.
- **The surfaces:** a queue row draws Accept/Reject only if `posture(forDocId: row's doc).allows(.acceptOrReject)`, Stet/Archive/Triage/Reopen only if `.dispose`; the answer-as-ruling / make-choice / keep-as-lesson closures only if `.editStatement` for the statement they write (Task 7 owns the door; here, only hide). The bulk bar plans over the rows it would act on and drops any the posture forbids; if that empties it, the bar's verb is not drawn. `ReviewCardActions.actions(for:isOwn:posture:)` — Edit/Delete of her OWN note stays (the reviewer row: `ownAnnotation`); every disposition follows the posture.
- Each row's posture is ITS document's, not the window's — the cross-document queue (M3 P2) shows a pieces-author's own piece with verbs and another's without, side by side.

**Both directions:** reviewer ⇒ no disposition drawn anywhere, own-note Edit/Delete still drawn, and a direct call to `acceptAnnotation` throws and appends nothing; author of piece A ⇒ A's rows carry verbs, B's rows none, in one queue; promoted ⇒ verbs return after the epoch bump.

**Must not:** disable instead of hide; gate annotation creation or own-note edit/withdraw; judge a row by the window's selected document.

- [ ] Red: the row-verb decision as a pure function over `(Posture, AnnotationKind, isOwn)`; the bulk planning filter; `ReviewCardActions` with the posture; the mutator doors (count ops before/after). **Disable:** remove the mutator door and watch a reviewer's accept append.
- [ ] Implement. Mac gate. Commit `feat(posture): dispositions are offered where the permit allows them, and refused at the door`.

---

### Task 6: Pass state and the round

**Files:** Modify `Maugham/Views/InspectorView.swift` (`setPass` :207, `PassLadder(onSet:)` :58), `Maugham/Views/PieceInspector.swift` (`setPass` :149, call :129), `Maugham/Views/Review/ReviewBoardPane.swift` (`chipMenuItems` :484, menu :356–380, Run round :365), `Maugham/Views/ProjectWindow.swift` (board host closures :2155–2157 and :2171–2175, nudge host :3199–3201, `runRoundWhenPieceOpens` :3655/:3671), `Maugham/Views/AnnotationsPane.swift` (cockpit `onRun` :736–739, `onSetPassState` :1048–1049 — coordinate: Task 5 owns this file; this task runs AFTER Task 5 merges), `Maugham/Compiler/CompilerOrchestrator.swift` (`runRequested(docId:kind:freshEyes:)` :654 + `Environment`), `Maugham/Compiler/CompilerEnvironment+Project.swift` (production wiring of the new closure), `Maugham/Compiler/CompilerRunModifier.swift` (:78–91). Tests append to `PostureSurfaceTests`, `CompilerRunCommandTests`.

**Verified facts:** `ProjectStore.setPassState(id:passId:_:) async throws` ProjectStore+Metadata.swift:68 — a manifest write, no permit check. `PersonaPaneRegistryTests.passStateWritingFiles` is an existing file-scoped census of pass-state writers — keep it green. `runRequested`'s guards today: environment/diagnostics present, `!isRunning`, `reading(docId) != nil`, and for `.round` `roundEditor(docId) != nil` (refusal flashes `Acknowledgment.noEditor`).

**Contract:**
- Pass ladder, piece inspector, board chips and the pass-order nudge draw their state-setting items only where `posture(forDocId: piece).allows(.setPassState)`; the chips still DRAW (the board is how a reviewer sees where the book stands) — only the menu's setting items and *Run round* are withheld.
- `CompilerOrchestrator.Environment` gains `mayRunRound: (String) -> Bool` (docId); `runRequested(kind: .round)` refuses when it answers false, with a new `Acknowledgment.notYourPiece` flash, starting nothing (no session, no marker move, `runState` still `.idle` — the `noEditor` refusal's exact shape). Production wires it to `posture(forDocId:).allows(.runRound)`. A `.check` is never asked (R4). The cockpit's Run and the board's Run round are not drawn when it would refuse.
- `setPassState` itself stays unguarded at storage (roles guard the words, not the binder) — the ADR limit already says so; do not add a store-level refusal.

**Both directions:** reviewer ⇒ ⌘R in Review flashes *not your piece* and `runState == .idle`; ⌘R in Author runs a check; author of A ⇒ round on A runs, round on B refuses; chips draw for both, setting items only on A.

**Must not:** hide the board's chips; refuse a check; make the refusal a fallback to another reader (tripwire 34's spirit).

- [ ] Red: the orchestrator refusal through its existing test harness (`CompilerRunCommandTests`' environment); the chip-menu items as a pure function of the posture; the ladder/inspector decision. **Disable:** make `mayRunRound` return true and watch the reviewer's round start.
- [ ] Implement. Mac gate. Commit `feat(posture): pass state and the round follow the permit; a check is anyone's`.

---

### Task 7: Statements — the ruling door and its surfaces

**Files:** Modify `Maugham/Compiler/RulingPerformer.swift` (`rule` :150, `revoke` :183, `edit` :219, `restore` :267), `Maugham/Views/RulingsStratum.swift` (Revoke :341/:370/:406, Edit :404), `Maugham/Views/StatementPane.swift` (proposal banner :407–419 — coordinate: Task 3 touched this file for the editor's posture; this task runs AFTER Task 3 merges), `Maugham/Views/StatementProposalBanner.swift` (:55/:60), `Maugham/Compiler/StatementProposalGate.swift` (`adopt` :89, `discard` :154). Tests append to `PostureSurfaceTests`; `RulingPerformerTests` (append).

**Verified facts:** `rule(` has thirteen production callers (TurnClauseOffer:137, FirstReaderRuling:189, LessonLedgerVerbs:126/169, BibleStratum:211, TranslatorsNote:111, QueryRuling:149, TranslationReviewPane:636, DiagnosticsPane:1893, Publish/TranslationRoundActions:174/194/241/285, StatementProposalGate:124) — count them again; the door makes their number irrelevant. `RulingPerformer` takes `store: ProjectStore`; find how a `ProjectStore` reaches its window's `DocumentStore` (or the project URL + identities to build a `LocalWritePermit`). If the only way is a new stored reference, **stop and report** — do not thread a `DocumentStore` through thirteen call sites.

**Contract:**
- **The door:** all four verbs refuse with `RulingRefusal.notYours(statement:)` when this device may not `.editStatement` the statement's document — resolved through the ONE builder (Task 2's `posture(forDocId:)` or, if `RulingPerformer` cannot reach a `DocumentStore`, `OpLogStore.localWritePermit` wrapped in `Posture` right there, with `RulingPerformer.swift` added to Task 1's allow-list by file AND spelling). Refusal happens before any op. Each caller already surfaces thrown errors loudly (verify per caller; one that swallows is listed in the report).
- **The surfaces:** Revoke/Edit in `RulingsStratumView` and Adopt/Discard in the proposal banner are not drawn without `.editStatement`. A reviewer still READS every statement (the pane stays; only the verbs go).
- A project statement's `.editStatement` is book-author only; a piece statement follows its piece (the ladder, spec §2).

**Both directions:** reviewer ⇒ `rule` throws and appends nothing; pieces-author ⇒ may rule on her piece's statement, refused on the project intent; book author ⇒ all as today.

**Must not:** add thirteen caller-side checks; hide the statement's text.

- [ ] Red: the door for each verb × {reviewer, pieces-in, pieces-out, book}; the stratum/banner decisions. **Disable:** remove the door from `rule` and watch the reviewer's ruling land.
- [ ] Implement. Mac gate. Commit `feat(posture): a statement is ruled on by whoever may write it — refused at RulingPerformer's door`.

---

### Task 8: The tree, tasks and translations

**Files:** Modify `Maugham/Views/BinderView.swift` (root menu :85–93, row menu :269–296), `Maugham/Views/CollectionPiecesPane.swift` (row menu :179–194, new-piece buttons :299–305), `Maugham/Views/TasksPane.swift` (`toggleStatus` :313, `archive` :367, `archiveProjectTask` :475, `moveTask` :667, `commitNewTask` :695, `apply` :608), `Maugham/Views/Publish/DepartmentPaneHost.swift` (`run(language:)` :503, wired :330), `Maugham/MCP/Tools/TranslationWritePipeline.swift` (`perform` :77). Tests append to `PostureSurfaceTests`; `TranslationWritePipelineTests` (append).

**Verified facts:** store structural verbs `addStructureItem` ProjectStore+Structure.swift:11, `moveStructureItem` :88, `renameStructureItem` :323, `duplicateStructureItem` :701, `tidyFilenames` :796, `deleteStructureItem` :953 — no guards, and none are added (roles guard the words). Research verbs (`BinderTreeVerbs`, BinderTreeSections.swift:659) are NOT structural — research is outside the permit's document classes; leave them. `write_translation` reaches `TranslationStore.appendBatch` (:161) unguarded; the read side judges `.translationRecord` (OpLogPermitContext.swift:338) — under the TRANSLATOR actor's row. Task ops on `__project__` are allowed to any author rung and to no reviewer.

**Contract:**
- Tree: New Document/New Group (root) only with `.startAPiece`; a row's Rename/Delete/Duplicate/move-by-drag only with `.restructure` on that row's piece (a group: on every piece it contains — a pieces-author may not delete a group holding someone else's chapter); Link Research… and Tidy Filenames follow `.restructure` of the row. `CollectionPiecesPane` likewise. Cooperative only — no store guard, and the drop delegate refuses the drop rather than letting it land and bounce.
- Tasks pane: create/toggle/archive/move per task's document with `.task` (`__project__` → `.projectStream`); a toggle that is an inline manuscript edit (`InlineToggleUndo`) also needs `.writeText`. Hidden, not disabled.
- Translation desk Run and the `write_translation` pipeline: refuse per piece whose posture — **built as the TRANSLATOR actor** (`localWritePermit(as: .translator)`, the actor that signs these lines; the one builder) — does not allow `.translate`, before any append, naming the refused pieces. The desk does not draw Run for a language whose every piece is refused.

**Both directions:** reviewer ⇒ tree shows no structural verbs, tasks pane read-only, desk Run absent, `write_translation` refuses and appends nothing; pieces-author of A ⇒ A's row verbs present, B's absent, root New Document absent (R3), task create on `__project__` allowed, translation of A allowed and of B refused.

**Must not:** guard `ProjectStore`'s structural verbs; touch research verbs; judge a translation by the author actor.

- [ ] Red: row-menu decisions as a pure function over `(Posture, row kind)`; group containment; tasks decisions; the pipeline refusal with append counts; the desk's Run visibility. **Disable:** build the translation posture as `.author` and watch the reviewer-with-a-translator-key case pass wrongly (then restore).
- [ ] Implement. Mac gate. Commit `feat(posture): the tree, tasks and translations offer only what the permit allows (the binder stays cooperative)`.

---

### Task 9: F10 — a stranger's device record raises the question on arrival

**Files:** Modify `Maugham/Views/AdmissionDecision.swift` (`requests` :136, `refreshedRequests` :309, `anyRemembered` :341), `Maugham/Views/AdmissionSheet.swift` (`waitingLine(for:)` :110, `waitingLine(count:)` :103), `Maugham/Views/PeopleAndDevicesModel.swift` (`PendingRequest.sentence` :173, pending rows :760), `Maugham/Views/AdmissionModifier.swift` (`recompute` :142–197 — only the pre-check's call). Tests: `AdmissionDecisionTests`, `AdmissionSheetTests`, `PeopleAndDevicesModelTests`, `MaughamTests/Stores/RegistryArrivalTests.swift` (append).

**Verified facts:**
- The trigger already fires: a non-echo registry arrival runs `registryChanged` DocumentStore.swift:1344 → `invalidateTrust()` → `MaughamEvent.postAdmissionSettled` → `AdmissionModifier`'s `.maughamAdmissionSettled` (:83) → `recompute(forced:false)`. **Two gates then drop a record-only stranger:** `refreshedRequests` returns `[]` when `heldLines()` is empty (:317), and `requests` requires `waiting > 0` (:146). `anyRemembered(pending:memory:)` gates the mid-session silent admission on a HELD count (:318/:341), though `RegistryPresence.admitRemembered` (RegistryPresence.swift:589) needs no held lines.
- `Registry.isStrangerDevice(_:)` RegistryReader.swift:440 = not an unsigned holder and no person record. `DeviceRecord` RegistryRecord.swift:101 has `retiredAt`. Records are filed by fingerprint: `RegistryWriter` `<directory>/<fingerprint>.json` (RegistryWriter.swift:29–32/:61), devices under `.maugham/devices`, people under `.maugham/people`.
- The recompute's resolve is detached (`TrustResolution.resolveVerified`), and `anyRemembered` exists so a book of admitted people never pays for it (AdmissionDecision.swift:297–301).
- Premise tests that F10 moves (controller-approved, the only two): `AdmissionDecisionTests.test_aFingerprintWithNothingWaitingIsNobodyToAskAbout` (:110) and `test_nothingHeldAnywhereAsksNobodyAndAdmitsNobody` (:489). Re-read each: if it is about a fingerprint with NO device record, it stays as is.

**Contract:**
- **Candidates:** the requests are the union of (a) today's held-line holders and (b) every verified device record in `registry.devices` whose `device` `isStrangerDevice`, is not `retiredAt`, is not this device's own, and passes `standing(...)`'s other rules — with `waitingCount` 0 and `described` nil for (b)-only. Sorted with held-line strangers first.
- **Cost:** `refreshedRequests` resolves when anything is held OR a cheap unverified pre-check finds a `devices/<fp>.json` with no `people/<fp>.json` (a directory listing of two folders, run detached, never a signature check). A book whose every device has a person file never resolves on a settle or an open — pin it with a resolve counter, as `test_nothingRememberedIsWaitingSoNoSilentAdmissionIsAttempted` does.
- **Silent admission:** `anyRemembered` also answers true for a remembered device whose record has arrived with no person record (so a known machine joins on arrival, silently, mid-session).
- **Copy (F2's shape):** a (b)-only request's sheet line is *Nothing from it has reached this Mac yet.*; People & Devices' pending row says the same, never *0 notes waiting*. The title stays *X wants to write in Y*.
- *Not now* still dismisses per window; a forced recompute (the writer's own Admit… press) re-asks, as today.

**Both directions:** a stranger's record arriving with no lines ⇒ the sheet comes up (through the settle event, no reopen); the same stranger with lines ⇒ one request, held count shown, no duplicate; a remembered machine's record ⇒ silently admitted, no sheet; an admitted person's second device record (label merge already done) ⇒ not a stranger, no sheet; a retired record ⇒ no sheet; a device record under ANOTHER root's chain with a person record there ⇒ no sheet; a book of admitted people ⇒ zero verified resolves on settle.

**Must not:** verify signatures on the pre-check; read an op log; raise a sheet for this Mac's own record or for an unsigned holder.

- [ ] Red: every row above, through `refreshedRequests` with injected closures and through `RegistryArrivalTests`' arrival path. **Disable:** restore the `heldLines().isEmpty` early return and watch the record-only arrival stay silent; drop the pre-check and watch the zero-resolve pin fail.
- [ ] Implement. Mac gate. Commit `feat(admission): a stranger's device record raises the question when it arrives, not only their lines (F10)`.

---

### Task 10: The census closes, the docs, and the gate

**Files:** `MaughamTests/TripwireGrepTests.swift` (verify Task 1's census covers every file Tasks 5–8 added to the allow-list, by file AND spelling), `CLAUDE.md` (tripwire 51 row; the Views per-area cell's Component A mentions; the OpLog cell's *P3c* sentence), `Maugham/Views/AREA.md`, `Maugham/Editor/AREA.md` (the membrane now reads the posture), `Maugham/OpLog/AREA.md` (re-stamp on trust change), `docs/adr/0032-the-signed-op-log.md` (P3c addendum: Posture, the door-plus-surface shape, R1–R5, Component A retired; limits: the binder is cooperative, a read-only iCloud share is an OS lock and no role; strike the §7.1 limit per R1), `docs/constitution.md` (*AI is never the author* gains its storage-layer sentence and falsification condition — the `assistant` row; *roles guard the words, not the binder* as a stated limit), `docs/guide/people-and-devices.md` (what a reviewer's Mac shows and offers; the root's Edit Anyway; F10), the WF1 spec header (`docs/superpowers/specs/2026-06-17-wf1-human-reviewers-design.md`: *Component A retired in P3c; the permit replaces the share role*), the spec §7.1/§8 annotated in place (R1), `docs/roadmap.md` (`EditorEditPolicy` mention :319), the P3 handoff's new *P3c plan 1 OUTCOME* section.

**Contract:**
- Docs describe what SHIPS; sweep every now-false claim (*a read-only share suggests reviewer*, *Component A*, *the membrane locks one thing*, *the phone's banner*). Count arrays, not prose — no number about a list in any doc touched here.
- The constitution edits quote the principle's existing identity/position marking and add a falsification condition in its house form; if the constitution's structure does not fit a limit, stop and report rather than invent a section.

- [ ] Implement; **full gate** + Core + phone. Commits `test(tripwire): posture is asked of the permit in one place (51)`, `docs(oplog): P3c plan 1 — posture, Component A retired, F10`.

---

## Order and parallelism

Task 1 first (everyone consumes `Posture`). Then Task 2. Then **Task 3**, then **Task 4** (both touch `ProjectWindow`'s mirror). Tasks **5, 8, 9** can run in parallel after Task 2 (disjoint files). Task 6 after Task 5 (`AnnotationsPane`); Task 7 after Task 3 (`StatementPane`). Task 10 last. Run the full gate after every integration of parallel branches (*parallel branches cross silently*).

## Whole-branch review — seams to name to the reviewer

Give the reviewer both P3 ledgers, the smoke finds note, R1–R5, and this list — and tell it to assume there is a Critical:

- **T2×T3** — the epoch bump and the editor mirror: does a demotion arriving MID-KEYSTROKE lock the editor before the next burst is signed, or can one burst of refused text be signed and set aside in her name? (P3a carry: `flushBurstNow` is not permit-guarded by design — is the membrane now truly in front of it?)
- **T2×T5/T7/T8** — the surface asks `DocumentStore.posture`, the door asks `Document.localWritePermit` or the builder: can they disagree for one document at one moment (a closed document has no stamp; a statement's doc id vs its piece's)?
- **T3×T4** — the read-only iCloud lock and the posture lock are two inputs to one mirror: does either ever unlock what the other locks?
- **T2 yielding × T5/T6** — the root's cooperative posture hides dispositions; after Edit Anyway, does every surface agree the override is on, in that window only?
- **T6** — a refused round moves nothing: marker, session, pass memory, `runState`.
- **T8** — the translator actor's posture vs the author's: a pieces-author whose translator key signs a translation of someone else's piece.
- **T9 × silent admission** — a remembered machine's record arriving, the sheet and the silent path racing on one settle; a stranger's record and her first lines arriving in the same settle (one request, not two).
- **The premise check:** grep the branch diff for *unreachable / cannot occur / never / always* and test each. Which states does this plan's own shipped code create that a guard calls impossible?
- **Hygiene:** no pbxproj, no `EXPERIMENT` marker in the committed diff, only the declared test moves (the two F10 premises, the Component A suites, the `authorId` rewrites).
