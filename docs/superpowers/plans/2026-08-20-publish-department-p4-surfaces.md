# Publish Department P4 — The Surfaces

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The department becomes visible and clickable: a desk pane in Publish (Design row + language rows, Run buttons with visible refusals), the sample-pages gate in the centre (spec + pages + which templates the sample used + Approve/Request Changes/Revert/Finalize), the edition brief's writer door (statement pane arm + rulings + query-answer→ruling), and the mint sheet for unlisted languages. Closing this plan closes the milestone.

**Architecture:** Every surface joins an existing mechanism: the desk is a `DetailSegment` case + one registry entry + one `canonicalPaneOrder` seat + one `⌘⌥` binding (`ReviewBoardPane` is the sibling shape); the gate is a new arm composed by `ProjectWindow.publishCentre` (`ProjectWindow.swift:1495`, the books/notice precedent); the brief door is a third statement arm beside `DetailPaneToggle.swift:413-415`'s intent/visualLanguage arms — which finally cashes the two traps recorded in `StatementEssay.carriesRulings`' doc (RulingsStratum kind-widening; bibleFacts' own question); dispositions ride the annotations pane's existing row affordances.

**Tech Stack:** Swift/SwiftUI, Mac target. No schema change. No new MCP tools.

**Spec:** `docs/superpowers/specs/2026-08-19-publish-department-design.md` §5 (desk, centre, run state) + §2/§4's writer-side ends (queries → rulings) + §1's mint sheet. P1–P3 merged (`195afdf5`, `6b57c266`, `478e1b1a`).

## Global Constraints — the accumulated P4 requirements (each one is a ledgered promise; none may be silently dropped)

1. **The translation Run is restricted to OPEN documents** (P2): the desk runs the WINDOW'S CURRENT manuscript document when it is open; any other subject state disables the Run with the reason visible.
2. **Every refused or abandoned click gets a visible answer** (P2/P3): a refused second run, a malformed tag, a briefing-gather abandon, `requestChanges` returning false, approve's busy-compile/backup-slot refusals — all render words, never a silent no-op.
3. **The gate names the templates a sample used** (P3): staged files listed; language editions' caveat (samples compile against BASE templates — say it on the gate when `language != nil`).
4. **Approve/Revert/Finalize are ProposalPromotion's three verbs** (P3 single-slot ruling): the gate renders the slot refusal and the two ways out.
5. UI discipline: tripwires 9 (`Button(.plain)` not onTapGesture in sidebar lists), 15 (`ContentUnavailableView` full-frame + top-aligned VStack), 21 (`MaughamEvent` scoped, never raw NotificationCenter); mounted tests read their premise off the window they got and skip by name where unattainable; new styling suites wire `FontWarmup.ensure()`; keystroke-only — no timer anywhere.
6. Registry discipline: the new pane takes a seat in `PersonaPaneRegistryTests.canonicalPaneOrder` (`PersonaPaneRegistryTests.swift:121`); `.inspector` stays last; the shortcut is read off `MaughamApp`'s bindings by tests, never a doc list.
7. Gates as before; `./scripts/test.sh full` before merge; disable experiments on negative assertions. Implementers COMMIT IMMEDIATELY after reading a gate result.

---

### Task 1: The desk takes its seat

**Files:** Modify `Maugham/Models/DetailSegment.swift` (new case `department` with a doc comment naming the milestone), `Maugham/Views/DetailPaneToggle.swift` (arm), `MaughamApp` (the `⌘⌥`-letter binding — read the existing bindings and pick a free letter; the test reads it off the bindings), `Persona.panes` registry (membership: Publish only); Create `Maugham/Views/Publish/DepartmentPane.swift` (skeleton: header + Design section + Languages section, ContentUnavailableView-with-full-frame when the project has neither translations nor proposals); Test: extend `PersonaPaneRegistryTests` (canonical seat) + new `DepartmentPaneTests` (skeleton renders; empty state honest).

**Contract.** Read `Maugham/Views/Review/ReviewBoardPane.swift` first — the desk is its sibling in structure and idiom. Membership: Publish's `panes` only; every other persona unchanged (the registry test proves membership by filtering, never position). The pane reads; it does not yet run (Task 3/4 wire verbs).

- [ ] Steps: failing registry/order tests → implement → gate → commit — `feat: the department has a desk in Publish`

---

### Task 2: The language rows and the brief's door

**Files:** Modify `Maugham/Views/Publish/DepartmentPane.swift`; Test `DepartmentPaneTests`.

**Contract.** One row per language — union of `TranslationStore.languages` across manuscript docs and open-query languages (read how `translation_status`'s handler unions them in `TranslationTools.swift:~330-375` and derive through the same helpers; the pane must not invent a third union). Each row: translator `effectiveName` (stored else preset table, NEVER minting — the read rule), fresh/stale/missing project-wide counts, open query count, and an **Edition Brief** button: opens the brief for that language — `createStatement(kind: .editionBrief(lang), scope: .project)` find-or-create then present the statement editor the way the existing statement surfaces do (read `DetailPaneToggle.swift:413-415` and `StatementEditorHost`'s construction there; the brief presents in the SAME pane host, not a new window). Creating on click is correct — the door mints the file the writer is about to write in.

- [ ] Steps: failing tests (row derivation matches translation_status's for a fixture project; unminted language shows preset name with manifest bytes unchanged; brief door creates-once) → implement → gate → commit — `feat: every language has a row and its brief has a door`

---

### Task 3: Run translation — the keystroke arrives

**Files:** Modify `DepartmentPane.swift` + whatever run-state view it grows (`Maugham/Views/Publish/DepartmentRunState.swift` if extracted); Test `DepartmentRunTests`.

**Contract.** The Run button on a language row calls the window-owned `TranslatorOrchestrator.runTranslation(docId:language:)` with the WINDOW'S CURRENT manuscript document — Global Constraint 1: enabled only when the window's subject resolves to an OPEN manuscript document (read how `ProjectWindow` resolves the current subject/document — `BinderTreeSelection`'s `shown/resolved` + the open-doc registry); otherwise the button is disabled WITH the reason as its help/subtitle ("open a chapter to translate it"). Run state renders from `runState` (running/cancel/cost of the cockpit idiom — read `ReviewRoundCockpit` for the vocabulary, reuse its shapes where they lift); every refusal arm (already running, malformed tag abandon, briefing-gather abandon) surfaces as a transient row message — Global Constraint 2. The run summary (entries written, queries minted, mid-run-edit rejection naming paragraphs, construct warnings) renders when a run ends.

- [ ] Steps: failing tests (disabled-with-reason states; refusal messages appear; summary renders from a fake onRunEnded) → implement → gate → commit — `feat: a translation run is one click on an open chapter`

---

### Task 4: The Design row runs

**Files:** Modify `DepartmentPane.swift`; Test `DepartmentRunTests` (extend).

**Contract.** The Design row: designer `effectiveName`, the pending proposal's badge (store `list()` newest pending), the latest proposal's age/status line, a direction text field + Run (calls window-owned `DesignerOrchestrator.runDesign(direction:language:)` — language nil in this plan's desk; the per-edition design round is offered from the language row later ONLY if trivial, else it stays out of scope — do not build a language picker), and Request Changes (visible only while `hasOpenProposalRound`; a false return from `requestChanges` renders its refusal — Constraint 2). Run state as Task 3's idiom.

- [ ] Steps: failing tests → implement → gate → commit — `feat: Tschichold takes direction from the desk`

---

### Task 5: The gate view — sample pages in the centre

**Files:** Modify `Maugham/Views/ProjectWindow.swift` (`publishCentre` at :1495 grows a `.designProposal` arm — compose, don't fork: the arm outranks books/notice only while a proposal is SELECTED from the desk; window `@State` holds the selected proposal id, cleared on persona change); Create `Maugham/Views/Publish/DesignGateView.swift`; Test `DesignGateTests`.

**Contract.** The gate shows: the spec markdown; the sample pages (PDF at the proposal's recorded sample path — render with the same PDF view `PublishPreviewCentre` uses; a `.failed` sample shows the tectonic diagnostics with the cause, RULING-7's shape, never a blank); **the templates the sample used** — the staged file list, plus the base-templates caveat line when the proposal round carried a language (Constraint 3); and the sample's `demonstrates` lines. Selection arrives from the desk (a Show/click on the Design row's proposal). Read `PublishPreviewCentre` first for the PDF idiom and the notice/banner shapes.

- [ ] Steps: failing tests (arm routing: selected proposal takes the centre, deselect restores books/notice; failed-sample shows cause; templates named) → implement → gate → commit — `feat: the sample pages face the writer`

---

### Task 6: The gate's verbs

**Files:** Modify `DesignGateView.swift` (+ its actions seam); Test `DesignGateTests` (extend).

**Contract.** Approve / Request Changes / Revert / Finalize — `ProposalPromotion.approve/revert/finalize` + the orchestrator's `requestChanges`. Every refusal renders its OWN sentence (Constraint 2/4): busy compile (names the job), the backup slot (names the proposal holding it and the two ways out — Revert it or Finalize it), standing-backup double-approve, finalize-without-backup. Status transitions reflect immediately (approved shows Revert+Finalize; rejected/superseded read-only with the note). Approve/revert/finalize are the writer's acts — confirm nothing here registers with NSUndoManager (the stored-reversal ruling; a grep-shaped test if cheap, else a stated check in the review).

- [ ] Steps: failing tests (each refusal sentence; verb→status flow with a fixture store; no NSUndoManager registration) → implement → gate → commit — `feat: approve, request changes, revert, finalize — with reasons when refused`

---

### Task 7: The brief joins the statement pane — and the two recorded traps get sprung

**Files:** Modify `Maugham/Views/DetailPaneToggle.swift` (third statement arm), `Maugham/Views/StatementPane.swift` (`bibleFacts` gets its OWN question — the trap recorded at `StatementEssay.swift`: it gates on `carriesRulings` as an intent proxy and would show the project's bible under a brief; give it an explicit is-intent predicate), `Maugham/Compiler/RulingsStratum.swift` (the six verbs + `currentId`/`currentRows` widen to take `kind: Statement.Kind` — the second recorded trap: they hardcode `.intent`, so a brief's Revoke/Edit would refuse); Test: extend `StatementPaneStrataTests` + the RulingsStratum suites.

**Contract.** How the brief PRESENTS: Task 2's door hosts the statement editor for `(.editionBrief(lang), .project)`; this task makes the pane's strata honest for it — essay + `## Rulings` rows render, ruling rows' Revoke/Edit work against the brief, bible facts do NOT appear under a brief. The `.intent` behavior is bit-for-bit unchanged (existing suites pass with only call-site kind additions — the RulingPerformer widening's own precedent).

- [ ] Steps: failing tests (brief pane shows rulings rows; revoke/edit round-trip on a brief through the stratum; bible absent under brief, present under intent — disable experiment on the new predicate) → implement → gate → commit — `feat: the edition brief is a first-class statement surface`

---

### Task 8: A query's answer can become a ruling

**Files:** Modify the annotations surface where a query's reply/disposition affordances live (read `Maugham/Views/AnnotationsPane.swift` and the translation review pane's query cards — put the affordance where the writer actually answers: both hosts if they share the card component, which they should); Create the small performer call-through (no new door: `RulingPerformer.rule(_:provenance:kind:forScope:store:world:)` with `kind: .editionBrief(lang)`, `scope: .project`, provenance naming the query); Test `QueryRulingTests`.

**Contract.** On a `language`-tagged query (or language-tagged craftNote — P2's whole-document questions) the reply affordance gains **"Answer as ruling…"**: the writer's text goes to the brief's `## Rulings` (dated, «excerpt» = the query's text, the strain-answer shape), AND posts as the reply on the thread so the translator's next briefing sees it in dispositions — one act, two records, both stated in the confirm affordance. Undo: through the statement's own ops (the performer's existing story); the annotation reply disposes normally. The ruling lands in the LANGUAGE the query carries — no picker.

- [ ] Steps: failing tests (ruling lands under the right brief with the excerpt; reply posted; non-language queries show no affordance) → implement → gate → commit — `feat: answering a translator hardens into doctrine`

---

### Task 9: The mint sheet for unlisted languages

**Files:** Modify `DepartmentPane.swift` (+ a small sheet view); Test extend `DepartmentRunTests`.

**Contract.** When Run (translation) targets a language whose translator would mint with a nil name (`defaultTranslatorName` answered nil and no stored role), a sheet asks the writer to name them BEFORE the run starts (name field, default placeholder explaining who this is; Cancel aborts the run — a visible abandon per Constraint 2). The name lands via `renameProductionRole` on the freshly minted role (or mint-then-rename in one act — read `translatorRole(for:)`'s semantics and keep it one visible mint). Preset-table languages never see the sheet.

- [ ] Steps: failing tests (unlisted prompts; cancel aborts visibly; preset language runs straight through; the named role persists) → implement → gate → commit — `feat: an unlisted language's translator gets their name from the writer`

---

### Task 10: Docs — the milestone closes

**Files:** Create `docs/guide/publish-department.md` (writer-facing: the desk, the people, running a translation, the design gate's verbs, the brief and rulings — what SHIPS, no futures) + register it in `HelpTopicIndex`'s source of truth (read how guide topics register); Modify `docs/roadmap.md` (the milestone entry flips to ✓ COMPLETE with every P4 item accounted; the paired-release note stands until release), `CLAUDE.md` (Publish row gains the department in its area cell; Views row's registry note unaffected — verify), `Maugham/Views/AREA.md` + `Maugham/Compiler/AREA.md` sweeps, and the spec's status header (Approved → Built, with a dated line). Rule 10: sweep siblings for now-false claims in the same commit.

- [ ] Steps: grep falsified claims → write/edit → full gate (DocSyncTests + help-topic tests) → commit — `docs: the publish department ships whole`

---

## Self-review notes (applied)

- Every accumulated requirement from P2/P3's ledgers appears as a Global Constraint or task contract (open-doc restriction T3; visible refusals T3/T4/T6/T9; templates-named T5; three verbs + slot rendering T6; brief UI T2/T7; query→ruling T8; mint sheet T9).
- Spec §5 desk rows ✓(T1-T4); centre gate ✓(T5-T6); run-state cockpit idiom ✓(T3); §4 membrane's writer end ✓(T7-T8); §1 mint sheet ✓(T9).
- Out of scope, stated: per-edition design rounds from the desk (language stays nil unless trivial); EPUB sample rendering; a translation Run over closed documents.
- Type consistency: no new model types beyond view state; every store/orchestrator symbol cited exists on merged main.
