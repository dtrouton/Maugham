# Session handoff — "coach", 2026-09-01 → 2026-09-02: editorial letter P1 merged, P2/P3 open

## State

- **Local `main` is at `6194e3b4`** — editorial letter **P1** merged by fast-forward (21 commits, 59 files, +8811/−251). **UNPUSHED.** The milestone (P1 → P2 → P3) ships whole; do not push or tag until P3 is merged and Denver has smoked.
- Origin's `main` is still `92837972` (the spec-only commits). Everything from `6373684c` onward is local.
- Full gate (`./scripts/test.sh full`) and a Release build are both green on `6194e3b4`; no warnings in any branch file; the gate's skips are the known set (perf probes, oplog baselines, locked-screen click tests, cross-volume swap).
- The plan workspace (`.superpowers/sdd/2026-09-01-editorial-letter-p1-…`) is deleted; git history is the record. The per-task reports are gone with it — the ledger's rulings are reproduced below.
- Memory: `~/.claude/projects/-Users-denver-src-Maugham/memory/project_milestone_editorial_letter_p1.md`.

## Read these, in this order (next session)

1. `docs/superpowers/specs/2026-08-29-the-editorial-letter-design.md` — the spec, revised 2026-09-01 (§4.1 the seat is a manifest field; §4.2 reader line; §4.3 depth in both homes; §6 offers not automatic; §3.4 the Add-to-intent offer, "conflict" dropped from the list; §3.5 the ring carries no letters).
2. `docs/superpowers/plans/2026-09-01-editorial-letter-p1-the-letter-and-le-guin.md` — P1's plan; its Global Constraints are still the milestone's constraints.
3. `Maugham/Compiler/AREA.md` (the letter, `ScenePosition`, `LetterMarkdown`, the coach paragraph) and `Maugham/Views/AREA.md` (the seat on the board).
4. `docs/guide/compiler.md` (the new **The letter** subsection, the four depths) and `docs/guide/review-passes.md` (the seat) — what the writer is told.
5. This note's "Rulings" and "Carries" sections.

## What P1 built (by file, so a fresh session can find it)

| Concern | Where |
|---|---|
| The letter value on the run | `Maugham/Compiler/Letter.swift`; `CompilerRun.letter` (`Diagnostic.swift`, hand-written decoder — every new field needs its own `decodeIfPresent` line) |
| Sixth section: schema + ingest + mint | `CompilerPrompt.sectionSchemaDescription` + `letterInstruction`; `DiagnosticIngest.parseLetter` (caps, per-entry ref helper, id-leak scrub on every prose field, fix-shape scrub on questions only); `DiagnosticKind.letterQuestion` → `.query` via `CompilerNote` |
| Scene position | `Maugham/Compiler/ScenePosition.swift` — `derive(projectType:statement:passBrief:)` over the WHOLE statement (rulings included); raws `none/weak/strong_declared/strong_default`; `ScenePosition.live(store:docId:)` for the offer; per-run `scenePositionSection` in `runMessageV2`, outside the briefing hash; `Environment.projectType` closure |
| The coach and the seat | `ReviewPass.coachPreset` (NOT in `presets`); `ProjectManifest.coachVacated` (tolerated-missing) + `effectiveCoach`; `ProjectStore.setCoachVacated`; `ReviewPass.pass(id:in:)` + `laneDisplayName` (the one stamp-to-name search); `ReviewPassEditorLogic` refuses the coach's id on a stage |
| The one reader resolution | `Maugham/Models/PieceReader.swift` — `ProjectManifest.reader(forPiece:memory:)` → `.stage/.coach/.nobody`; `PieceReader.nobody.editorName` is the ONLY production use of `CompilerOrchestrator.passlessEditorName` (census in `TripwireGrepTests`, planted offender); `ActivePass.isCoach` for `passSection`'s "workshop teacher" phrasing |
| Review surfaces | `ReviewBoardPane` seat row (`coach:` input); `ReviewRoundCockpit` `coach:` + lane label; `AnnotationPassFilter.matches` always shows a coach-stamped note; `AnnotationsPane.cockpitReader` + empty-queue teaching; `ProjectSettingsSheet.coachSection()` Vacate/Restore |
| Author surface | `DiagnosticsPane` `reader:` + `onOpenBoard:` — the reader line (a label; click → Review persona + project subject via `DetailPaneToggle.openBoardInReview`), and the "Press ⌘R and <name> reads…" promise off the same value |
| Depth | `Maugham/Views/CompilerModelMenu.swift` (one view, both homes; census: `CompilerModelChoice.allCases` iterated in exactly one production view); `.exhaustive` → `"fable"`; `UIState` decode already tolerant (pinned) |
| The letter on screen | `Maugham/Views/LetterSection.swift` (parts in reading order; `runId` keys the accepted-exercise memory); `Maugham/Views/TurnClauseOffer.swift` (predicate, tenses, scope resolution, the ruling call — both hosts call it, census forbids `ScenePosition.live(`/`effectiveIntent(forDocId:`/a second `RulingPerformer.rule(` in either host); Accept as task → `Document.createPaneTask` (a `.taskCreate` op, never manuscript text) |
| Keep this letter | `Maugham/Compiler/LetterMarkdown.swift` (pure render, never emits a `¶id`); `Maugham/Views/LetterKeep.swift` (`createResearchNote(scope: .document(docId))` so `ResearchScope` routes, then the body write through an injectable `write:` seam — RULING-7 ordering pinned by a thrower); census: `createResearchNote(` production callers = Inbox, Promotion, BinderPieceFold + LetterKeep (BinderTreeSections only names it in a comment) |

**What P1 deliberately did NOT build** (they are P2/P3's, and the schema has no key for them yet): `answer` (§3.7), `retired` and the `lesson` consumption / `lessonHeading` (§6), `process` and dosage (§5/§3.8). `Letter.Habit.lesson` is parsed and stored, consumed by nothing.

## Rulings made on Denver's behalf (all in the merged code; rework any he disagrees with)

1. **Add to intent files at the scope the intent RESOLVED to** (`store.effectiveIntent(forDocId:)?.scope ?? .document(docId)`), and the button says **"Add to the book's intent"** when that is the project statement. This was the whole-branch review's Critical: the naive `.document(docId)` scope minted an empty document-scoped intent for a chapter living off the book's, and from that click on the book's intent no longer briefed that chapter, silently. The other horn — a project-scope clause binds every chapter — is visible and revocable in the intent pane. *If Denver wants per-chapter always, the change is one line in `TurnClauseOffer.scope(store:docId:)`, but then the click must ALSO seed the essay, or the detachment returns.*
2. The offer is withdrawn when the LIVE intent derives `.strongDeclared` or `.none`; it stands for `.strongDefault` and `.weak` (a brief-opted prose piece derives `.weak` live because `ScenePosition.live` has no pass brief).
3. The bare word **"conflict"** is out of the opt-in list ("avoid conflict-driven plotting" read as a declaration). Turn phrases only: "every scene must turn", "moves by dramatic turns". "lyric" matching "lyrical" stands.
4. A note stamped with the coach's lane is **always shown** by the pass filter (she is not a selectable lane, so nothing could bring her notes back once a piece is assigned); a coach stamp names **"Le Guin"** even after the seat is vacated (the note was hers when she wrote it).
5. The queue's empty-state teaching reads the piece's reader (coach for an unassigned held piece).
6. Letter prose gets the id-leak scrub on every field; the fix-shape scrub applies to `questions` only (`exercise` legitimately says "rewrite the scene without…"); neither touches `droppedDangling`.
7. `Letter.scenePosition` is the one mutable field; explicit snake_case raws.
8. The word-budget ceiling moved once, 450 → 715, with `letterInstruction` measured at 564 standing words per run — the largest addition this feature has made. **P2 should tighten the doctrine** when `answer` and `retired` want room in the same budget.
9. `ProjectManifest.pass(id:)` was removed (no production caller); `ReviewPass.pass(id:in:)` is the one search.

## Carries (verified at handoff)

- **Denver's smoke is owed** (CLAUDE.md format plus): new Novel → 800 words → ⌘R → the letter renders at the top signed Le Guin; the Diagnostics header reads *Le Guin reads this piece*; Review → the board's seat row; Project Settings → Vacate → ⌘R → "Claude"; the cockpit carries the gear; a scene-heavy piece shows the scenes table and, with no intent, the *Hold every scene to a turn?* offer. **One thing to look at deliberately:** a letter question draws in BOTH the letter and This check. Spec §3.2/§3.5 ask for exactly that, and it is the first surface in the app that draws one finding twice — Denver's eye, not a code fix.
- MCP `list_annotations` returns `review_pass_id: "workshop"` while `get_outline`'s `review_passes` never mentions the coach, so an outside reader gets an id it cannot resolve (the `author` field says "Le Guin", so nothing misleads). One sentence in the tool description; P2's.
- An older build re-saving a manifest drops `coachVacated` (tolerated-missing, no schema bump) — a preference, recoverable. Release-notes line.
- The workshop brief's process-signals clause is phrased conditionally ("Shown that the frontier has not moved…") until P3 gives her a signal.
- `Environment.projectType` is keyed by docId but answers project-wide (deliberate).
- `Environment.activePass` now returns the coach for an unassigned piece; the orchestrator's `??` at the mint site never fires for a held seat. `test_aPasslessRunMintsAsClaudeWithNoStamp` is the VACATED-seat case now; the held-seat sibling pins Le Guin/`workshop`/round 1→2.
- `sectionName(of:)`'s three arms are unreachable in practice (`standingRound` carries strains only since M4 P1) — pre-existing, documented in the arm's comment.
- `ReviewRoundCockpitTests` still defaults `coach: nil` (coach cases pass it explicitly); `ReviewBoardPaneTests`' default is the held seat.

## P2 — the ask and the ledger (spec §3.7, §6): what a fresh session should know before planning

Rule 11 applies: **re-derive P2 against the built code**, not against the spec's imagined API. Things P1's shape already decides:

- `answer` and `retired` are two more optional keys on the `letter` line (`SectionField` constants + the schema census; `Letter` gains `var answer: String?`, `var retired: [String]` — synthesized Codable handles a missing key). `parseLetter` is where they land; `LetterSection`'s reading order puts `answer` first and `retired` after scenes (the offer-on-Fresh-Eyes / line-on-warm split is `run.freshEyes`).
- The ask is per document in the diagnostics sidecar — `DiagnosticsStore.FileContent` has the hand-written decoder pattern; `CompilerRun` should NOT carry it (it is not per run).
- The briefing carries the ask as its own section OUTSIDE `briefingHashInput` (it changes with the writer, like the pass and dispositions; `CompilerPromptTests` has two hash pins to mirror). The `lessonsSection` DOES fold into the hash (spec §6: "the hash covers it").
- `.lessons` is a fourth `Statement.Kind` (raw `lessons`), project scope only — `StatementPane` already coerces every non-intent kind to `.project`; `StatementEssay.carriesRulings` must include it; it needs a `DetailSegment` case (`.lessons`) in Author and Review beside `.intent`, a place in `PersonaPaneRegistryTests.canonicalPaneOrder`, a `⌘⌥` shortcut read off `MaughamApp`'s bindings (`DocSyncTests` gates the shortcut table and `right-pane.md`).
- Keep as lesson / This is a choice / Retire are all `RulingPerformer.rule(..., kind: .lessons, forScope: .project, ...)` with a provenance naming the voice and lane — the same verb the intent's rulings use. Retiring is "dated, in place" — that is `RulingPerformer.edit`, not a new op.
- A minted letter question needs to carry its habit heading for the stet-twice offer — `CompilerNote` gains an optional `lessonHeading`, stamped at ingest from `habits[].name` when the question cites a habit. `Annotation` will need a field for it (schema? check `AnnotationDeriver` — an op-log field addition is tolerated-missing by construction, but the phone reads annotations; confirm `MaughamPhone` decodes unknown annotation fields).
- `read_lessons` is a fourth spine reader on `read_craft_intent`'s shape through `ProjectStore.statementText(of:)`; the catalogue count moves by one (`MCPToolCatalog.all`; `DocSyncTests` gates the tool count).
- The word budget: see ruling 8.

## P3 — process and dosage (spec §5, §3.8): notes from P1's reconnaissance

- `SessionLog` events are project-level (start/end/net words/device) with NO document id; the per-document session evidence is `Op.session` + `Op.at` on every op. `ProcessSignals` is a pure value over the document's ops (walk by `sequence` through the rewind machinery). Time away can come from either.
- `CompilerOrchestrator.DeltaCounts` has `new`/`revised` — the drafting/revising split needs the frontier on top of that.
- The Statistics window is `Maugham/Views/statistics/ProjectStatisticsView.swift` (four sections today).
- The `process` key is one more optional on the letter line; the lane line gains the stage ("Le Guin · drafting").

## Process notes (what this slice paid for)

- The whole-branch review found the Critical **again** (the streak resumed after three clean slices), in a seam no task's diff contained (`TurnClauseOffer` × `effectiveIntent`'s fallback). Give the final reviewer the named seams; it earns its seat.
- Three per-task reviews found a census that asserted nothing (a `prefix(N)` slice that never reached the second arm; a read-only FOLDER that made the store throw before the code under test; a `try`→`try?` that stayed green). **Every negative assertion gets the disable experiment**, and a census locates by anchor, never by a character budget.
- A `./scripts/test.sh full` and a Release `xcodebuild` launched concurrently lock DerivedData's build database — `TEST FAILED` with zero failed cases. Never overlap them; `test.sh`'s lock does not cover a raw `xcodebuild`.
- Implementers park on a background gate; tell them the Bash `timeout` parameter goes to 600000 and to run it foreground.
