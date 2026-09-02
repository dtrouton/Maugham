# Translation pipeline — handoff after Plan 4 (2026-09-01)

Written for a fresh session picking up Plan 5. Plan 4 is built on branch `translation-pipeline-p4` (nine tasks, six in-loop fix rounds across Tasks 2–8), base `d55fab03`. The gate record is at the bottom; read the kept xcresult, never the pipe's exit code.

## Where things stand

- **Spec (binding):** `docs/superpowers/specs/2026-08-28-translation-pipeline-design.md` — unchanged, with one amendment recorded below (spec §7's single `outcome` slot; see ruling 4). §13 lists the five plans; Plans 1–4 are built.
- **Plan 1 — built** (handoff `2026-08-29-translation-pipeline-p1-handoff.md`, on main at `ef538475`). **Plan 2 — built** (handoff `…-p2-handoff.md`, merge `2498d90b`). **Plan 3 — built** (handoff `…-p3-handoff.md`, merge `2c2d28ec`).
- **Plan 4 — built** (`docs/superpowers/plans/2026-08-29-translation-pipeline-p4-surfaces.md`). It surfaces P3's pipeline: before this branch nothing in the UI started it.
- **Plan 5 — NOT written and NOT built.** Spec §10 (proposals into statements) is recorded in [ADR 0030](../../adr/0030-three-people-seven-legs-directives-as-rulings.md) §7 precisely so a later plan cannot widen it into a write. Per CLAUDE.md rule 11 it is written against the built code of Plan 4.

## What Plan 4 built, by file

**The desk row runs the pipeline (Tasks 1–2).**

- `Maugham/Compiler/TranslationPreflight.swift` — new. `wordCount`/`sum`/`budgets`: source words + translated words over a document set, `Bootstrap`'s own whitespace split so the figure agrees with the checkpoint's count. `budgets` opens each document **once** across the language loop (the fix-round shape; asked per pair it derived a four-edition book's every chapter four times a pass).
- `Maugham/Views/Publish/DepartmentRunState.swift` — `Phase.running` widened from `translating: Int` to `RunningLeg` (`.translating(Int)` for a bare translator round, `.leg(Leg, book:)` for a pipeline one). New: `latestRound`/`trend`/`chapterWords`/`bookWords`/`bookDocumentCount`/`now` on the state; `detailLine` (pre-flight + trend sharing one slot per spec §8); `legLine`, `roundLine`, `ago`, `trendLine`, `preflightLine`; `runBookTitle`/`runBookHelp`/`bookRefusal`/`canRunBook`/`nothingInTheBook`; `showRoundTitle`/`showRoundHelp`; `cancelHelp` rewritten to promise only what a seven-leg cancel can keep. `DepartmentRunSession.read` takes `pipeline:` and the pipeline **outranks** the orchestrator's own `isRunning` (a cold leg holds no warm session).
- `Maugham/Views/Publish/DepartmentPane.swift` — Run, **Run Whole Book** (row button plus context-menu item), Cancel, and Show on the language row; the status/detail lines.
- `Maugham/Views/Publish/DepartmentPaneHost.swift` — `bookDocumentIds`, `latestRounds`, `trends`, `bookBudgets`, `chapterBudgets`; `runBook(language:)`; `bookAsk` (the naming sheet a whole-book run stands behind); `deriveChapterBudgets`; `refillsBudgets(pipeline:)` — the budget refill is **skipped while a round runs** and the round-ended event re-derives.
- `Maugham/Views/Publish/DepartmentCastSheet.swift` — `.nameForBookRun`, and the reader/collator fields carried through the rename/add asks.
- `Maugham/Stores/TranslationRoundStore.swift` — `update(_:)` beside `append` (a verb write rewrites a round in the ring).
- `Maugham/Events/MaughamEvent.swift`, `Maugham/Models/MaughamNotifications.swift` — `maughamTranslationRoundEnded` (`.project` scope, payload `language`/`document_id`/`round`) and `maughamRevealTranslation` (`.keyWindow`, payload `document_id`/`language`/`paragraph_id`), both through the one `MaughamEvent` door (tripwire 21).

**The round report (Tasks 3–5).**

- `Maugham/Views/Publish/TranslationRoundReport.swift` — new, and the file to read first: every row type and every sentence the surface can say, as pure functions. `DepartureRow` (carries `source`/`gloss`/`before`/`after`/`isDismissed` and **no translated text outside the disclosure fields**), `DisagreementRow` (two bylines plus `rightVerbTitle`), `ProposalRow`, `readerColumn`/`missingReaderText`/`legRecord`, `header`/`countsLine`/`provenance`, and the copy block.
- `Maugham/Views/Publish/TranslationRoundReportView.swift` — the six sections in spec §8's order, the verbs, the disclosure, the reveal lines, the four sheets behind one `ReportSheet` enum, and `run(_:)`'s one-press-one-sentence write-back.
- `Maugham/Views/Publish/DepartureRow.swift` — `DepartureRowView` + `DepartureRowCopy`, shared by the report and the Translation pane.
- `Maugham/Views/Publish/TranslationRoundReportHost.swift` — the four disk reads (sources through `currentParagraphState`, chapter title, the two names through `EditionStatus`, the round's open queries) resolved in a `.task` and handed down as values (tripwire 4).
- `Maugham/Views/Publish/RoundRuleSheet.swift` — the Make-it-a-rule sheet.
- `Maugham/Views/Publish/TranslationRoundActions.swift` — the nine verbs as closures with `.production(store:documentStore:…)` behind them: `dismiss` (Fine — writes `dismissed`), `keepMine` (→ `TranslatorsNote.commit` → `RulingPerformer.rule`), `makeRule`, `translatorsRight` (`rejectAnnotation`), `readersRight` (directive **first**, then `acceptAnnotation`; takes the row's verb title as its fifth argument), `adopt`/`skip` (glossary), `answer`/`answerAsRuling`.
- `Maugham/Views/Publish/PublishPreviewCentre.swift`, `Maugham/Views/ProjectWindow.swift`, `Maugham/Views/DetailPaneToggle.swift` — `PublishCentre.translationRound` as the fourth arm of the one switch; `publishSelectedRound` and `publishSelection(after:)` for the write-back.
- `Maugham/Views/TranslationReveal.swift` — new. `post`/`decode` (one spelling of the three payload keys), `plan` (is the chapter open?), `perform` (enter review, **await the translated surface**, then navigate). Production polls `EditorControl.translationBadges` for a badge model that differs from the pre-post one and holds the paragraph, 50 ms up to 3 s, skipping the wait when the edition was already showing.

**Spot-checks (Task 6).**

- `Maugham/Compiler/SpotCheck.swift`, `GlossBriefing.swift`, `GlossReport.swift` — new. **Gloss** (briefed with the translated paragraph and its neighbours off the pane's own badge entries, never the source) and **Ask the Collator** (the full collator briefing narrowed to one pair), the third and fourth `ColdCall` callers. `runSpotCheck(about:call:assign:)` captures the paragraph id at the call and drops the answer if the caret has moved.
- `Maugham/Views/TranslationReviewPane.swift` — the two buttons, the gloss result, the collation result drawn as `DepartureRowView`s with Fine / Keep mine / Make it a rule, the two sheets, and `.onChange(of: selected?.paragraphId)` clearing everything.
- `Maugham/Compiler/ColdCall.swift` — now `@Observable`, so `isRunning` re-draws the two buttons when a leg or a spot-check ends; the pane and the pipeline's cold legs share one busy answer.

**The statement pane (Task 7).**

- `Maugham/Views/RulingsStratum.swift` — `partition` (glossary / orphans / others), the glossary `Grid` table, the orphan row with `Remove`, `glossaryHeading`/`orphanCaption`/`removeTitle`.
- `Maugham/Views/StatementPane.swift` — `liveParagraphIds` resolved in a `.task` keyed on `LiveParagraphTaskKey` (kind|scope **plus** the directive id set **plus** the open documents' paragraph sequences off the `DocumentStore` registry), so a paragraph deleted in the open editor turns its directive into an orphan live.
- `Maugham/Views/TranslatorsNote.swift` — defaulted `provenance:` and `defaultHome:`/`seed:`, so ⌘⌥C's call site is unchanged while the report and the spot-check seed the sheet.

**Docs (Tasks 8–9).** `docs/adr/0030-…md` (new), `docs/adr/README.md`, `docs/adr/0024-translation-layer.md` (amendment note), `docs/roadmap.md`, `Maugham/Compiler/AREA.md`, `Maugham/Views/AREA.md`, `Maugham/Stores/AREA.md`, `Maugham/MCP/AREA.md`, `CLAUDE.md`, and the four guide topics plus the `translation-pass` skill (Task 9).

**Tests.** `TranslationRoundReportTests`, `TranslationRoundActionsTests`, `TranslationRevealTests`, `SpotCheckTests`, `GlossBriefingTests`, `TranslationPreflightTests`, `StatementPaneStrataTests`, `SelectionToolbarWidthTests`, `TestSupport/ColdCallSpy.swift`, plus additions to `DepartmentRunTests`, `DepartmentPaneTests`, `PublishPreviewCentreTests`, `TranslationRoundStoreTests`, `DesignGateTests`, `ColdCallTests`, `MaughamEventTests`, `TranslationReviewPaneLogicTests` and `TripwireGrepTests` (`test_aSpotCheckMintsNothing`, `test_theOnlySealedSpawnerIsColdCall`'s company, and the reveal census).

## The seams Plan 5 wires to

Spec §10 is the whole of Plan 5. Every seam it needs already exists and none of it is stubbed.

- **The two tools** — `propose_edition_brief(language, markdown, rationale?)` / `propose_visual_language(markdown, rationale?)` join `MCPToolCatalog.all`, mirroring `read_edition_brief`/`read_visual_language`'s shape in `Maugham/MCP/Tools/`. **The catalogue count moves for the first time this milestone** (every P1–P4 MCP change was a widening): `DocSyncTests.test_toolCountSyncedAcrossDocsAndCatalog` and `Maugham/MCP/AREA.md`'s list both move with it.
- **Neither goes in `CompilerAllowlist`**, and `CompilerAllowlistTests.statementWriters` gains `edition_brief` and `visual_language` under the existing write verbs, plus a second predicate over the `propose_` prefix (so `propose_craft_intent` is caught and `propose_edition_brief` passes) — both planted, per spec §10.
- **`StatementProposalStore`** — derived, `.maugham/statements/proposals/<key>.json`, one pending slot per key. Its kind is the two-case `ProposableStatement.editionBrief(String) | .visualLanguage`, so craft intent is unrepresentable rather than refused. It is a derived sidecar read: it needs an `// adr-0018-ok:` annotation, which is the tripwire that bit P3.
- **The gate lives in `StatementPane`** — the banner, the diff against the current text, Adopt, Discard. Adopt writes through the existing statement write path and **preserves the `## Rulings` stratum byte-for-byte**, appending the proposal's glossary-shaped lines. `RulingsStratum.partition` is what draws those once adopted, and `Ruling.glossary` (MaughamCore `RulingShapes.swift`) is the parser — a proposal's glossary rows must be composed with `Ruling.glossaryText`, never hand-built, or they will not parse back.
- **The "proposed" marks** go on the desk's language row (`DepartmentPane`'s row, beside Edition Brief) and on the Visual Language pane's entry.
- **The two skills** — `docs/skills/edition-brief/SKILL.md` and `docs/skills/visual-language/SKILL.md`, served through the existing SEP-2640 extension; `docs/skills/maugham-bootstrap/SKILL.md`'s "read visual language first" section points at the new one. `docs/skills/translation-pass/SKILL.md` now has an **"The in-app pipeline"** section that already tells a Desktop session to read `read_edition_brief` first — the brief skill is the other half of that.
- **Guide:** `docs/guide/right-pane.md` carries one forward-pointing sentence saying this is designed and not yet shipped. Plan 5 replaces that sentence; nothing else in the guide claims it.

## Carried forward

Decisions and small debts, not defects. Everything the ledger recorded as `minor (deferred)`, in task order, plus what P1–P3 left standing.

**From this plan's ledger:**

1. **T1** — `TranslationRoundStoreTests` has both a `temp` fixture and the older `makeStore()` helper; consolidate.
2. **T1** — `TranslationPreflight.wordCount`'s `|| $0.isNewline` is redundant with `isWhitespace` (copied from the brief; `Bootstrap` carries the same predicate).
3. **T2** — `TranslationPreflight.budgets`' trailing `where totals[language] == nil` loop is unreachable.
4. **T2** — `deriveChapterBudgets`' running-skip keeps chapter A's figures while the writer navigates to chapter B mid-round, so idle rows of *other* languages draw A's pre-flight under B until the round ends. Clearing `chapterBudgets` on the skip instead of keeping them is the honest shape.
5. **T2** — `showRound`'s nil arm is silent (unreachable: Show is hidden without a round).
6. **T3** — help copy inline in `TranslationRoundReportView` rather than beside `DepartureRowCopy`'s statics.
7. **T3** — `outstanding` increments *inside* the `Task`, so the disable lands a turn late.
8. **T3** — `noQuestionsLine` says "from this edition" while the list is round-windowed.
9. **T3** — `VerbBox` test helper mutated from nonisolated closures.
10. **T3** — `TranslationRoundReportHost` untested; unreachable probe arm at `PublishPreviewCentreTests:1885`.
11. **T3** — the `departureRows` test never passes a translator name.
12. **T3** — source lines on the report are not text-selectable.
13. **T4** — no pin on the weak-capture/`notWired` arm; a grep census that every closure opens with `guard let store` would do it.
14. **T4** — `test_answerRepliesAndAnswerAsRulingFilesTheRulingFirst` cannot see order; the name over-claims.
15. **T4** — `answerAsRuling`'s confirmation reads `round.language` while the commit files under `language(of: annotation)`.
16. **T4** — repeated presses of Keep mine / Reader's right mint duplicate directives and settle no row.
17. **T5** — a chapter with no translation burns the full 3 s surface wait then posts a harmless no-op navigate. Latency, not misnavigation; a notice rather than a shorter timeout is the honest surface if it ever wants one.
18. **T5** — the surface wait **polls** `EditorControl` at 50 ms rather than observing it; six seconds worst case (two 3 s waits) of silence before a reveal gives up.
19. **T5** — a reveal naming a deleted chapter selects a phantom subject and times out silently.
20. **T5** — the pure-half reveal tests never went red.
21. **T6** — `TranslationPipeline.coldLeg`'s `.started` arm still speaks in `unusableOutput`'s words (P3 code; its sentence lands in a round record). `SpotCheck.noAnswerDetail` is the corrected spelling one file over.
22. **T6** — three stacked `.sheet(item:)` on the Translation pane, unmounted. `DepartmentPane` recorded that two `.sheet` on one view do not coexist; this is a named risk, not an observed failure.
23. **T6** — a spot-check departure row keeps its verbs after Keep mine / Make it a rule (there is no record to dismiss into).
24. **T6** — the nil-language arm returns silently (unreachable); `textureLine` matches any line beginning "texture"; `askTheCollator` composes the whole briefing before the busy guard; `SpotCheckTests` temp dirs are never removed; `excerpt(for:)` falls back to the gloss for a vanished paragraph.
25. **T7** — `currentParagraphState`'s shape is duplicated across the two scope arms; the union path is tested over one manuscript doc only.
26. **T8** — ADR 0030 §3's "four callers" is a prose count with no census.

**Still standing from P1–P3:** the declined "reply" lives in the query **body** under the translator's name (no reply primitive; `declinedBody` is the one site to change if one ever exists); leg 4 skips when leg 3 wrote nothing; a failed round stops a book queue; `languageQueries` reads the OPEN document only, so a closed chapter's prior queries are not briefed in a book queue; a cancel landing inside `mintDeclinedQueries` leaves minted queries absent from the record; round-number collision is reachable only by starting a run in the instant after a `shutdown()` while the old round resolves a cold leg; `translation_status` decodes a per-language ledger once per row; `authorLanguage` re-reads `config.json` per gather; cross-object cancel is pinned per object rather than by one spanning test; a same-day directive re-directs its paragraph for the rest of the day. **The ⌘⌥C Translator's Note manual smoke is still owed**, and so is the P3 unlocked re-gate.

## Rulings made during execution (for Denver to rework if wrong)

Verbatim from the ledger, in order.

1. **T2** — *fix Important #1 now — skip the budget refill while `pipeline.status != .idle` (keep the last figures; a pre-flight has no meaning mid-round) and open each document once across the language loop — rather than carry it to the whole-branch review; cost if wrong: a stale pre-flight figure for one derive pass after a round ends (the round-ended event re-derives).*
2. **T2** — *Minor #2 — soften the comment; Task 3 threads `selectedRound` into PublishPreviewModifier (plan text). Minor #3 — fix (one line each). Minor #4 — deferred.* Cost if wrong: a comment and two refusal sentences; #4 is carried above as item 5.
3. **T3** — *Important #1 — the plan's `noQueryForThisNote` string is wrong for a departure row; replace with `noQueryForThisNote(rightVerb:)` interpolating the row's verb; cost if wrong: none (the sentence names the button that IS there).*
4. **T4** — *#1 — the writer's disposition is a SEPARATE fact from the pipeline's: add `DepartureRecord.dismissed: Bool?` (additive, optional → old records decode), "Fine" sets it and never touches `outcome`; `departureRows.isDismissed` reads it; the `DepartureOutcome.dismissed` case stays for decode compatibility but is no longer written; spec §7's single `outcome` slot is amended in the P4 handoff. Cost if wrong: one optional field on a derived record.* **This is the amendment to spec §7**, recorded here as that ruling required and in ADR 0030 §5.
5. **T4** — *#2 — widen the seam: `readersRight` takes the row's verb title (`rightVerbTitle`) as a fifth argument; the reply text and the provenance verb ("reader's right"/"collator's right") follow it. Cost if wrong: a five-argument closure.*
6. **T5** — *#1 — fix now: perform() keeps its order but the navigate waits for the translated surface — poll editorControl.translationBadges.entries for the paragraph (50 ms up to 3 s, the brief's own idiom; already true when the review is already up for that language), then post; comment corrected. Cost if wrong: a reveal that scrolls 50–100 ms later than it could.*
7. **T5** — *#2 and #5 fixed in the same round (one line each). #3, #4 deferred (minor).* Cost if wrong: an uncancelled poll task on teardown and one wasted iteration; #3 and #4 are carried above as items 19–20.
8. **T6** — *⚠️ keystroke — spec §9's 'keystroke-triggered' is ADR 0028's tempo contrast (a writer's act, never a timer or an event); a button press is that act, the brief chose buttons, and the plan forbids new shortcuts on these surfaces. Buttons stand; the handoff records a shortcut as a later decision. Cost if wrong: two menu items.* **Gloss and Ask the Collator have no keyboard shortcut**; giving them one is a later decision, and the guide describes them as buttons.
9. **T6** — *fix #1 now (capture the paragraph id at the call, drop the result unless the caret is still there — the comment at :226 promised exactly this) plus #2 (the companion must run the real census over a written file, the file's own idiom) and #4 (one static). #3, #5, #6, #7, #8 deferred (minor) — final review to triage; the three stacked sheets are a named risk for the whole-branch review (DepartmentPane recorded that two .sheet on ONE view do not coexist).* Cost if wrong: the deferred five are carried above as items 22 and 24.
10. **T7** — *#1 — key the .task on what CAN change under the pane: the directive id set plus the OPEN documents' paragraph sequences read off the DocumentStore registry (the one open doc for .document(id); every open manuscript doc for .project) — an observable in-memory read, no disk, so it is tripwire-4-safe on the body path; a closed document cannot change under the pane, and a document opening/closing changes the key too. No new event (none fires on ordinary edits, and inventing one for this is tripwire 21's shape). Cost if wrong: one extra re-resolve per keystroke that changes the paragraph set — bounded by the open docs' sizes.*
11. **T8** — *#1 and #2 join fix round 1 (accuracy, one line each); #3 resolves with Task 9; #4 deferred.* #3 was the roadmap's guide links landing on pre-Task-9 pages, which Task 9 has now made true; #4 is carried above as item 26.

## Gate record

- Gate 1 at `3e96ae14` (all nine tasks, before the whole-branch review): `maugham-full-20260902-010218.xcresult` — 7552 / **7537 passed / 0 failed** / 15 skipped, screen LOCKED (`CGSSessionScreenIsLocked=Yes`); the standard skip set (seven locked-screen click tests — `PaletteWallDoorTests` ×2, `TreeTravelRowMountingTests` ×5 — six perf probes/baselines, `EditorCoordinatorCycleTests`' scene-nav, `UpdateInstallerTests`' cross-volume) — none on this branch.
- Gate 2 at `0cd398a1` (the whole-branch fix wave, the merge head): `maugham-full-20260902-014237.xcresult` — 7553 / **7540 passed / 0 failed** / 13 skipped, screen still locked; the same standard set, with two of the seven click tests landing this run (the standing confounder flipping between gates, as P2 and P3 recorded).
- Release build at `0cd398a1`: `** BUILD SUCCEEDED **`, no type-check warning.
- Whole-branch review (opus) over `d55fab03..848a91f6`: 0 Critical, 0 Important, 5 Minor — four fixed in the one fix wave (`0cd398a1`: the mid-round chapter budget no longer keeps the previous chapter's figure; the report's busy count arms synchronously; a settled row offers its doctrine verbs once; `TranslationPreflight`'s unreachable loop deleted; `DepartmentPane`'s sheet comment narrowed to what was measured), one carried (the `StatementPane` orphan-check key copies every open document's sequence per body pass — bounded by `DerivedManuscriptCache`; a cheaper key if a large book ever shows a hitch). It also cleared the one named risk with evidence: three stacked `.sheet(item:)` on one view already ship in `AnnotationsPane` and `InboxPane`. Its triage of the deferred list: the Task 4 "guard-let census" idea would be WRONG (`dismiss`/`skip` legitimately capture no store) — do not file it.

## Process lessons from this run

- **The controller resumed a paused ledger rather than writing a second plan.** The 2026-09-01 session was told "write Plan 4" with a memory that lagged the repo by two days; it drafted a duplicate plan before `git branch --list` and `ls ../Maugham-wt/` showed this branch at Task 4. Before any "Plan N" work on a milestone: check the branches, the worktrees and the SDD ledger first.
- **Do not send a resumed implementer a follow-up until its report for the round is in.** A second message sent while `impl-t8` was mid-commit was answered against a stale tree and produced a whitespace-only commit (`c3cfbdfd`) after the next task's BASE.
- **A sub-agent that parks on a background run needs a nudge** (`impl-t7` waited on "the monitor's completion notification" that nothing would send); the dispatch now says foreground only, and the nudge is one line.
- Gate 1 ran concurrently with the whole-branch review (both read-only) as P3 did; the fix wave earned gate 2. One sleep hold (`teainate --session`) held for the whole run; the Mac did not sleep.

- **The Mac slept three times mid-run** (Tasks 3 and 4, ~07:31, ~11:35, ~14:47), each costing about an hour. A `teainate` hold was taken after the first and did **not** prevent the second and third: a lid close is outside its reach. Take the hold at the start of a long run, and expect it to cover idle sleep only.
- **Denver paused the run after Task 4** for usage reasons and resumed it in a new session at Task 5. The ledger carried the resume cleanly — the `BASE`/`FIX_BASE` commit on every line is what made a cold restart cheap. Keep writing them.
- **Opus on the state machine's reviews paid again**, as P3 recorded. The Task 5 review found a real defect the plan's own code carried (the reveal's two posts racing the surface swap) and a *second* one survived into fix round 1 (the navigate posted unconditionally after the await), which a sonnet re-review caught. Two fix rounds on one task is the price of a surface with an ordering contract in it.
- **A reviewer's report truncated after its Importants** on Task 8 and the tail had to be requested separately — P3's ~4–5 KB observation, repeated. Ask for Issues before Strengths and keep reports short.
- **The plan's own copy strings were wrong twice** in ways only a reviewer reading the surface could see: `noQueryForThisNote` naming one verb for two kinds of row (T3), and `readersRight` posting the reader's title over a collator's departure (T4). A plan that spells a user-facing sentence should spell the *function*, not the literal, wherever the row it lands on can vary.
- **Two branch-level tripwire suites bit P3 and were named in this plan's pre-commit list** (`TripwireGrepTests`, `AnnotationChangeEventTests`); nothing on this branch was caught late by either. The advice held — keep both in every implementer's pre-commit list.
- **Worktree guard:** one command per Bash call, no `git -C`, absolute paths. As P2 and P3 recorded.
