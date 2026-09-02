# Session handoff — "coach", 2026-09-01 → 2026-09-02: editorial letter P1 merged, P2/P3 open

## State

- **Local `main` is at `6194e3b4`** — editorial letter **P1** merged by fast-forward (21 commits, 59 files, +8811/−251). **UNPUSHED.** The milestone (P1 → P2 → P3) ships whole; do not push or tag until P3 is merged and Denver has smoked.
- Origin's `main` is `881c758e` (verified with `git rev-parse origin/main`). Everything from `6373684c` onward is local.
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

> **P2 is built (2026-09-02). This section is kept as the historical prediction; where it guessed wrong, the P2 addendum below is what is true.** The six corrections: the ask does **not** live in the run sidecar's `FileContent` — it is a per-device `.maugham/diagnostics/asks.<slug>.json` keyed by docId, because a sidecar is written by a run and an ask is typed before one; `CompilerRun` **does** carry the ask after all, as a stamp of what the run was briefed on (`StreamingRun.ask` → `Letter.asked`), which is a different claim from "it is per run"; the briefing hash folds the **rendered** `lessonsSection`, not the ledger's markdown; the uncommitted ask draft is promoted in `CompilerOrchestrator.beginRun`, not by a view-side subscription; the ask's commit closure **returns** the refusal (`AskField.Input.commit`) instead of the host carrying a parallel notice input; whether the round read the piece cold is a **stated** `freshEyes: Bool` input to `LetterSection`, not something inferred from which closures the host wired; and the pane's shortcut is **⌘⌥G**.


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

---

# P2 addendum — 2026-09-02: the ask and the ledger

## State

- **Branch `claude/editorial-letter-p2-2026-09-02`.** HEAD is the fix-wave commit; `git log 0db22789..HEAD` is the record (`0db22789` is the P2 plan commit, on top of P1's `6194e3b4`). **Not merged, not pushed.** The milestone (P1 → P2 → P3) still ships whole: do not push or tag until P3 is merged and Denver has smoked.
- Origin's `main` is `881c758e` (verified with `git rev-parse origin/main`). Everything from `6373684c` onward is local.
- The plan and spec are `docs/superpowers/plans/2026-09-02-editorial-letter-p2-the-ask-and-the-ledger.md` (written against the built P1 code, rule 11) and the spec's §3.7 and §6.
- The SDD workspace `.superpowers/sdd/2026-09-02-editorial-letter-p2-…` will be deleted with the branch; the rulings and carries below are the record.

## What P2 built (by file, so a fresh session can find it)

| Concern | Where |
|---|---|
| A fourth statement kind | `Statement.Kind.lessons` (raw `lessons`) + `StatementConvention.lessonsPath` (`lessons.md`, project scope only — `newPath` has no document row); `StatementEssay.carriesRulings` yes, `BibleStratum.belongsTo` no |
| The ledger's grammar | `Maugham/Compiler/LessonsLedger.swift` — `Entry`/`Kind` over a ruling's **text**, the `Choice: ` prefix, the `(retired <date>)` suffix (retirement wins; an unparseable date is still retired), `heading(of:)`, `open`/`choices`, `matches` (exact after trimming, case-sensitive). Dates through `RulingsSection.formatted`/`date(from:)`, both made public for it |
| The ask's storage | `DiagnosticsStore.ask(docId:)`/`setAsk`/`notePendingAsk`/`discardPendingAsk`/`commitPendingAsk`, `askLimit` (400 characters), `asksURL` — `.maugham/diagnostics/asks.<slug>.json`, per device, keyed by docId (tripwire 24: `.raw` interpolated only there) |
| The ask in a run | `CompilerOrchestrator.beginRun` calls `commitPendingAsk` then reads the ask; carried on `StreamingRun.ask`, stamped onto `Letter.asked` in the one `record(...)` spelling, briefed by `CompilerPrompt.askSection` **outside** `briefingHashInput` |
| The ledger in a run | `Environment.lessons` (a no-argument closure, defaulted to nothing) wired in `CompilerEnvironment+Project.swift`; `CompilerPrompt.lessonsSection` renders preamble + open lessons + choices and briefs a retired entry to nobody; `briefingHashInput` folds that **rendered section**, so the four declared things still diff in as one unit |
| The letter's new parts | `Letter.answer`/`asked`/`retired` (+`retiredHeadings`), `Letter.Question.lessonHeading`; `DiagnosticIngest` `SectionField.answer`/`habit`/`retired`, `letterRetiredCap` (6), habits capped **before** the citable names are taken off them |
| The habit stamp's wire | `Diagnostic.lessonHeading` → `CompilerNote.lessonHeading` → `Op.Provenance.compilerLessonHeading` (`compiler_lesson_heading`) → `AnnotationDeriver` → `Annotation.lessonHeading`; `Document.addAnnotation`'s fifth defaulted compiler scalar |
| The writer's verbs | `Maugham/Views/LessonLedgerVerbs.swift` — `keepAsLesson`/`makeChoice`/`makeChoices`/`retire` (`RulingPerformer.edit`, never `revoke`), `ledgerText`, `provenance`; `LessonOffer` is the pure half (`retirable`, `lessonHeading(for:)`, `keepIsOffered`, `allChoicesIsOffered`) and `LessonLedgerHandlers`/`LessonOffer.handlers` build all four together off one read |
| The letter on screen | `LetterSection` gains `ledgerText`, `freshEyes`, `onKeepAsLesson`, `onAllChoices`, `onRetire`, the answer part (first, with the ask as its caption) and the not-found lines in two tenses; `LetterMarkdown` renders the answer and its caption |
| The queue's doors | `Maugham/Views/QueueLedgerVerbs.swift` — *This is a choice* (ruling first, then stet), *Keep as lesson…* on an **accepted** compiler craft note, `secondStetOffer` over the **unfiltered** annotation query, `ChoiceOffer`/`LessonHeadingSheet`; wired into `AnnotationsPane` |
| The ask on screen | `Maugham/Views/AskField.swift` — one view, both homes, `Input` carrying docId/text/commit/note, `commit` returning the refusal, `fieldIdentifier`; hosted by `DiagnosticsPane`'s header and `ReviewRoundCockpit`'s `ask:` input |
| The pane | `DetailSegment.lessons` (⌘⌥G, *What I've Learned*), `Persona.panes` for Author and Review, `DetailPaneToggle.segmentContent`'s `statementPane(kind: .lessons)`, `MaughamApp`'s View-menu button, `KeyboardShortcuts`, `StatementPane.headerCaption`'s scope-blind arm, `RulingsStratumView.title(for:)` (**Ledger**), `ProjectWindow`'s kind→segment map, `ArtifactIndex.lessonsTitle` |
| MCP | `Maugham/MCP/Tools/LessonsTools.swift` — `read_lessons`, the fourth spine reader, catalogue **57**; `lesson_heading` added to `list_annotations` **and** `get_annotation` (the file's own parity test pins the two DTOs key-for-key) |
| Censuses | `TripwireGrepTests.test_theLessonsLedgerIsWrittenFromOneFile` + planted offender + a `revoke(`-catching companion; `DiagnosticsPaneTests.test_bothHostsCommitTheAskThroughTheOneFunction`, a literal-match census over both hosts' sources that forbids either spelling `diagnostics.setAsk(` itself |

## Rulings made on Denver's behalf (all in the merged code; rework any he disagrees with)

1. **The `(retired …)` grammar is positional.** A lesson whose own heading ends in a parenthetical beginning "(retired" classifies as retired with a nil date. Accepted: a heading is a short principle and that spelling is pathological. Costs one misclassified entry the writer can rename.
2. **`get_annotation` widened alongside `list_annotations`.** The file's own parity test pins the two DTOs key-for-key, so widening one alone would have broken a documented invariant. `lesson_heading` is `encodeIfPresent` (absent, not null) — absence has no second meaning here, unlike `triage`/`review_pass_id` — so every existing note's wire stays byte-identical.
3. **`Letter.answer`/`asked` take `= nil` memberwise defaults** (they are `var`s, SE-0242) rather than editing every `Letter(` site.
4. **The briefing hash folds the RENDERED lessons section, not the ledger's markdown.** Retiring an entry only ever *removes* something from the briefing; hashing the file would re-embed essay + world + bible to communicate a deletion. Costs one stale "unchanged" if a change to the file that leaves the rendered section identical should have re-briefed — none exists by construction, because everything briefed *is* the section.
5. **`onRetire`'s PRESENCE does not carry the warm/Fresh-Eyes split.** `onAddTurnClause`'s precedent was followed at first and then corrected: `freshEyes` is a stated `LetterSection` input, built through one static builder that returns a nil `onRetire` unless `run.freshEyes == true`. A host that bypassed the builder would otherwise have made the app *say* something false over a delta.
6. **The plan-mandated optimistic disable is corrected in the view for the ledger verbs**: press memory is cleared when `ledgerFailure` becomes non-nil, because P2 is the slice that made the refusal reachable. The one-file census anchors gained `revoke(`/`restore(` (spec §6, "never deleted").
7. **`AskField.Input.commit` returns the refusal** (`(String?) -> String?`) so the field still holding the typed text can show it, rather than a parallel notice input (tripwire 6's shape). `AskField.fieldIdentifier` is the codebase's first `accessibilityIdentifier`, added to discriminate the standing ask field from revealed fields in existing mount tests.
8. **The uncommitted-draft promotion lives in `CompilerOrchestrator.beginRun`, not in a `MaughamEvent` subscription.** A view-side `.onReceive` kept a stale `.keyWindow` filter when measured, and would have covered only the two keystrokes; `beginRun` is the one line every trigger passes. The draft is an in-memory per-`(store, docId)` buffer that never touches the file or `version`.
9. **A separate `ledgerNotice` refusal channel rather than `rulingNotice`** — that alert is titled "That answer could not be filed", and a choice's refusal says the opposite.
10. **The second stet's Escape ABANDONS, not stets.** A dialog that acts on dismissal is a verb the writer did not press. *Just stet* stays a real button and a third `.cancel`-role *Cancel* does nothing. Costs one extra button if Denver prefers Escape = Just stet.
11. **`LessonLedgerVerbs.makeChoice` is idempotent by heading**, in the one file, so a row-level choice cannot file twice.
12. **The "read the ledger first" pointer lands in `docs/skills/editing-pass/SKILL.md`** (where `read_craft_intent`'s read-first instruction actually lives) plus a generic sentence in `maugham-bootstrap` — the plan named the wrong skill file.

## Carries (verified at handoff)

- **Denver's smoke is owed, and P2 adds to P1's list** (which still stands): type an ask in Author's Diagnostics header and press ⌘R **without** submitting — the letter should open with *You asked: "…"* and the answer above the say-back; ⌘⌥G opens *What I've Learned* (empty, in Author and in Review); **Keep as lesson** on a habit, then ⌘⌥G — the row is there, dated, with the lane in its provenance; ⌘⇧R and look for a *didn't find "…" anywhere in this piece* line with **Retire** beside it (only if the model reports one — a warm round says *in what changed* and offers no button); in the queue, **This is a choice** on a letter question, and then a second **Stet** of another note under the same heading to see the dialog (press **Escape** — the note must still be open); and `read_lessons` from Claude Desktop.
- **The release-notes line has nowhere to go yet.** There is no draft under `docs/release-notes/` for the next release (`v0.33.0` is the newest, already tagged), so the sentence is parked here: *the ledger is an ordinary statement document and the ask is per-device derived state, so no manifest schema moved in P2 and an older build re-saving a manifest is unaffected.* Fold it into the release notes when they are written, beside P1's `coachVacated` line.
- **A pre-existing flake, not this branch**: two `AnnotationChangeEventTests` cases failed one gate and were green in isolation and on re-run. The failing worker had just run `StatementPaneSelectionDeliveryTests`, whose observer does not filter by project — announcements carrying a foreign project's scope id leaked into it. Worth a hardening pass.
- **A second in-suite-only flake, seen on this branch's docs gate (2026-09-02)**: `AnnotationsPaneChoiceTests.test_theKeepButtonInTheRealPaneOpensTheSheetAndFiles` failed one `./scripts/test.sh` run, passed alone, and passed on an immediate re-run with no source change between them (the change under test was documentation only). No other `xcodebuild` was running. It is a mounted-pane sheet test, so the sheet-presentation timing under parallel workers is the first place to look if it recurs.
- The empty-delta (`nothingNew`) return skips the ask promotion, so a pending draft stays pending over untouched prose; a pending draft over `askLimit` is refused silently at run time (a submitted one is refused visibly).
- `LessonOffer.handlers(now:)`'s `now:` seam reaches only `retire`. `DiagnosticsPane` has two refusal channels (`answerFailures[keepFailureKey]` and `ledgerFailure`). The Review-side ledger re-read after a successful write is unpinned. The Author-side "starts no run" test is a tautology by name.
- A refusal clears all three press memories, so a verb whose own press landed reads as pressable again — re-press is find-or-create for keep and choice, and retire would surface `notOpen`. Hosts re-read `ledgerText` after a successful write so the "already stands" hide takes over.
- `makeChoices` is N ops, not one; its "filed N of M" copy counts a silently-skipped duplicate as landed (a rare partial-failure string, untested with a duplicate in the list). `LessonsLedger.kind(of:)` was added off-list as the public face of the private classify. `"retired": null` parses as `[]` where absent parses as `nil` (indistinguishable downstream). `get_annotation`'s description does not name `lesson_heading` (`list_annotations`' does).
- `StatementPane`'s no-project placeholder shows Intent's icon and sentence for the ledger — pre-existing shape, shared with `editionBrief`.
- **The second stet's twin search is same-document while the ledger is project-scope** — a P3 ruling for Denver. `QueueLedgerVerbs.secondStetOffer(for:in:ledgerText:)` looks for the stetted twin among one `Document`'s annotations, so in the queue's **All Pieces** scope a writer who stets the same habit in chapter one and again in chapter two sees no offer, even though the ledger the offer would write to is the project's. Widening it means holding every open document's annotations at the point of the press, which the pane does not do today.
- **`RulingsSection.parseItem` splits on the LAST em-dash**, so a hand-typed ledger row whose own words contain an em-dash and which carries no `— ruled <date>, <provenance>` suffix is truncated at that dash: the tail becomes the provenance. Pre-existing and shared with intent rulings — every statement kind that carries rulings has it — and the ledger makes it likelier only because its rows are the writer's own sentences.
- **The word budget** (P1's ruling 8) took the ask section, the lessons section and the letter instruction's rewrite in P2; `letterInstruction`'s existing sentences were tightened in the same pass, but it still grew (measured 2026-09-02: 263 standing words to 321). P3's `process` key wants room in the same budget — measure before adding, and expect to tighten further rather than raise the ceiling again.

## P3 — process and dosage (spec §5, §3.8): notes updated

P1's P3 reconnaissance still stands (`SessionLog` is project-level with no docId; per-document session evidence is `Op.session` + `Op.at`; `CompilerOrchestrator.DeltaCounts` has `new`/`revised` and the drafting/revising split needs a frontier on top of it; the Statistics window is `Maugham/Views/statistics/ProjectStatisticsView.swift`). Two things P2 changes about it:

- **The lane line's stage** ("Le Guin · drafting") now has to agree with a lane string that is already being read in two more places: `LessonLedgerVerbs.provenance(voice:lane:)` writes it into every ledger entry, and `QueueLedgerVerbs.provenance(for:store:)` writes it into every entry filed from the queue. A stage appended to the lane will appear in ledger provenance from that moment on — decide deliberately whether it should.
- **`process` is one more optional key on the letter line**, and the letter now has three P2 fields ahead of it in the schema (`answer`, the question-level `habit`, `retired`). `Letter`'s Codable is synthesized, so it falls out; the cap discipline (`letterRetiredCap`'s comment) is the pattern to follow for anything list-shaped.
