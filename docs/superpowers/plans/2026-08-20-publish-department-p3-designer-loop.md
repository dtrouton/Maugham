# Publish Department P3 — The Designer's Loop

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A design round, inside the app: Tschichold (or the writer's renamed designer) reads the visual language, the element census, and the current templates; returns a spec plus complete proposed template files; Maugham stages them under `.maugham/design/`, compiles SAMPLE PAGES through the preview pipeline against the staged set with nothing live touched; approval promotes the staged files to the live templates as one recorded, revertible act.

**Architecture:** The orchestrator is `TranslatorOrchestrator`'s sibling on the same rails (`CompilerRunner`/`ClaudeCLISession`, closure Environment, generation guards, warm session, failure-runs-no-ingest). The sample compile is the existing `PreviewCompiler` pointed at a SCRATCH project URL whose `.maugham/publish/` is the live dir overlaid with the staged files, with the REAL project's AST source filtered to the sample pieces — verified seam: `PreviewCompiler.init(projectURL:astSource:configStore:jobManager:maughamVersion:tectonicVersion:language:allowStale:)` takes all three injection points (`PreviewCompiler.swift:44-51`). Element census and page selection are pure functions over `ProjectAST`. Nothing here mints a Publication or touches `PublishMintGate` (previews are exempt by design).

**Tech Stack:** Swift, Mac target. No new dependencies, no schema change (proposals are derived state under `.maugham/`, deletable without loss — the photographs rule does not apply: staged files are copies).

**Spec:** `docs/superpowers/specs/2026-08-19-publish-department-design.md` §3 (designer loop + sample-pages gate) + §6. P1/P2 merged (`195afdf5`, `6b57c266`) provide `ProductionRole.presetDesigner`, `ProjectStore.designerRole()` (never mints), the edition brief, and the orchestrator rails.

## Global Constraints

- **Confinement identical to the compiler/translator**: `--tools ""` + allowlist + `--strict-mcp-config`; NO write tool joins `CompilerAllowlist`. The spawned designer reads templates via the bridge's existing `read_publish_file`/`list_publish_files`/`read_visual_language`/`read_edition_brief`.
- **Report-materialized (Approach A)**: the session returns; Maugham stages. Live templates change ONLY at approval. A dead session stages nothing.
- **Sample compiles touch nothing live**: scratch dir, preview pipeline, `PublishMintGate` untouched, a tectonic failure rides the proposal with the compile error (RULING-7's cause-on-the-result shape, `PreviewCompiler.swift:66-78` is the precedent).
- **Keystroke-only trigger; shutdown owned by every window-ending path** (the third orchestrator joins the census in `CompilerRunModifier` + `ProjectWindow`).
- **`designerRole()` never mints/writes** — identity reads it; renames are the writer's (P1).
- **The designer may not propose `config.json`** — publication metadata is the writer's, via config tools; the report parser refuses it, plus any path traversal or absolute path.
- Gates as P2: Core `swift test`, `./scripts/test.sh` iterating (real exit codes), `full` before merge; disable experiments on negative assertions; any suite really compiling calls `try await TectonicProbe.requireReady()`.

---

### Task 1: `ElementCensus` — what the book actually contains

**Files:** Create `Maugham/Publish/ElementCensus.swift`; Test `MaughamTests/ElementCensusTests.swift`.

**Interfaces:** Produces `ElementCensus.take(from: ProjectAST) -> ElementCensus` — a value with `kinds: Set<Kind>` and per-kind first-occurrence piece ids (`firstPiece: [Kind: String]`). `Kind` enumerates the block/inline classes a DESIGN must account for — derive the case list from `ProjectAST`'s actual node vocabulary (read `Maugham/Publish/ProjectAST.swift` first; the census must be compiler-exhaustive over its node enum via a `switch` so a new AST node kind breaks this census at compile time, the `SynthesisSource` discipline).

**Contract.** Pure; no I/O. Fountain elements census as their own kinds (the AST distinguishes them). Tests: a fixture AST containing each kind reports it with the right first piece; an empty project reports empty; the switch is exhaustive (compile-time — state it in a comment, no test can pin it better than the build).

- [ ] Steps: failing tests → implement → gate → commit — `feat: the census of what the book contains`

---

### Task 2: `SamplePageSelection` — which pieces demonstrate the design

**Files:** Create `Maugham/Publish/SamplePageSelection.swift`; Test `MaughamTests/SamplePageSelectionTests.swift`.

**Interfaces:** Consumes Task 1. Produces `SamplePageSelection.choose(census: ElementCensus, ast: ProjectAST) -> Selection` — `pieceIds: [String]` (ordered: the first chapter always; then the minimal additional pieces covering every census kind, preferring pieces already chosen), `maxPages: Int` (a small constant — enough for an opener + a spread + specials; name it and say why), and `demonstrates: [String]` (writer-facing lines: "chapter opener — ‘The Fog’", "verse — ‘Interlude’").

**Contract.** Pure, deterministic (stable tie-break by piece order, never by hash iteration). Tests: full coverage of a multi-kind fixture; the first chapter is always first; a kind appearing only in piece N pulls piece N in; determinism (two calls, equal result).

- [ ] Steps: failing tests → implement → gate → commit — `feat: sample pages are chosen by what they must demonstrate`

---

### Task 3: `DesignerReport` — the wire shape

**Files:** Create `Maugham/Compiler/DesignerReport.swift`; Test `MaughamTests/DesignerReportTests.swift`.

**Interfaces:** Produces `DesignerReport` — `specMarkdown: String` (non-empty), `files: [ProposedFile]` (`path: String`, `content: String`); `parse(_:) -> DesignerReport?`; `schemaDescription` (the briefing embeds it — Task 5). Follow `TranslatorReport`'s discipline exactly (last complete fenced JSON, wire names in one place, all-or-nothing, `nonEmptyString` on spec and on every path; file content MAY be empty — an empty partial is a legitimate design choice — but say so in the schema).

**Contract.** Path rules refuse the whole report: absolute paths, `..` traversal, `config.json` (any case), paths outside `.maugham/publish/`-relative space (the wire carries paths RELATIVE to the publish dir — `template.tex`, `styles.css`, `partials/…`), duplicate paths. An empty `files` with a non-empty spec is VALID (a words-only round — the writer asked a question).

- [ ] Steps: failing tests (round-trip; each refusal; empty-files-valid; prose-wrapped fence) → implement → gate → commit — `feat: the designer's report has one wire shape`

---

### Task 4: `DesignProposalStore` — staging under `.maugham/design/`

**Files:** Create `Maugham/Stores/DesignProposalStore.swift`; Test `MaughamTests/DesignProposalStoreTests.swift`.

**Interfaces:** Consumes Task 3's `DesignerReport`. Produces a `@MainActor` store over `.maugham/design/proposals/<proposalId>/`: `stage(report:round:) throws -> Proposal` (writes `spec.md`, `files/<relative paths>`, `proposal.json` metadata: id, designer name, round number, created stamp, status `pending`), `list() -> [Proposal]` (newest first), `load(id:)`, `updateStatus(id:_:)` (`pending`/`approved`/`rejected`/`superseded`), `delete(id:)`, plus `sampleResult(id:)`/`recordSampleResult(id:...)` for Task 7's compile outcome (pages path or the error text). Proposal ids minted via the store (ULID-style like `ProjectStore.newId`).

**Contract.** Everything here is DERIVED state — deleting `.maugham/design/` costs proposals, never content (state it in the type doc; it's the spec's storage rule). A second `stage` while one `pending` proposal exists for the same scope marks the old one `superseded`, never deletes it. JSON decoding is ADR-0015-tolerant (unknown status → preserved raw, the lossless pattern).

- [ ] Steps: failing tests (stage/list/load round-trip; supersede; tolerant status; delete) → implement → gate → commit — `feat: a design proposal stages where derived things live`

---

### Task 5: `DesignerBriefing`

**Files:** Create `Maugham/Compiler/DesignerBriefing.swift`; Test `MaughamTests/DesignerBriefingTests.swift`.

**Interfaces:** Consumes Tasks 1–3. Produces `DesignerBriefing.compose(inputs:) -> String` over pure `Inputs`: designer name + `effectiveBrief`; the visual language text (or honest absence — "no visual language declared; ask before assuming"); the census (kinds + the demonstrates lines from Task 2, so the model knows what the samples will show); the current template files (path + content, with a per-file size cap and an elision note — templates can be big; cap constant named); the publish config SUMMARY (trim/format facts a design needs — read `PublishConfig` and pick the design-relevant fields; never the whole JSON); the edition brief when a language is in play; the writer's direction-in-words when given; `DesignerReport.schemaDescription` referenced never restated; the config.json refusal stated to the model ("propose template/style/partial files only").

**Contract.** Pure; `TranslatorBriefing`'s shape (caps discipline, stripAnchors on embedded manuscript-derived text). Tests: fixture assembly, caps, absence honesty, schema referenced.

- [ ] Steps: failing tests → implement → gate → commit — `feat: the designer's briefing carries the visual doctrine and the census`

---

### Task 6: `DesignerOrchestrator`

**Files:** Create `Maugham/Compiler/DesignerOrchestrator.swift`; Test `MaughamTests/DesignerOrchestratorTests.swift` (fake-runner harness, `TranslatorOrchestratorTests`' shape).

**Interfaces:** Consumes `CompilerRunner`, Tasks 3/5. Produces the sibling orchestrator: Environment closures `briefRound` (gathers `DesignerBriefing.Inputs` + designer identity — reads `designerRole()`, never mints), `makeRunner`, `writeMCPConfig`, `stage` (parsed report → `Proposal` — Task 4 + Task 7's sample kickoff live BEHIND this closure in Task 8's wiring), `onRunEnded`; `runDesign(direction: String?, language: String?)`, `requestChanges(_ feedback: String)` (a follow-up send on the SAME warm session — the gate's iterate arm; refused while running or when no proposal round is open), `cancel()`, `shutdown()`, `runState`.

**Contract.** All of P2's hard-won rules restated and tested here: one run at a time refused-not-queued (both windows); failure stages nothing (structural — `stage` reachable only past a successful parse; disable experiment); unusable-output vocabulary; warm session per project (the designer has no (doc,language) pair — warm until shutdown/model change; note the divergence and why); deinit-cannot-reap restated; no timers.

- [ ] Steps: failing tests → implement → gate → commit — `feat: the designer runs on the same rails`

---

### Task 7: The sample compile — staged templates, scratch project, nothing live

**Files:** Create `Maugham/Publish/SampleCompiler.swift`; Test `MaughamTests/SampleCompilerTests.swift`.

**Interfaces:** Consumes Tasks 2/4. Produces `SampleCompiler.compile(proposal:projectURL:astSource:configStore:jobManager:versions...) async -> Outcome` — assembles a scratch dir (`.maugham/design/proposals/<id>/scratch/` or a temp dir named by proposal id): copy the live `.maugham/publish/` tree, overlay the proposal's `files/`, then run `PreviewCompiler` with `projectURL: scratchURL`, a `configStore` reading the scratch, the REAL project's AST source filtered to `SamplePageSelection`'s piece ids (reuse the existing filtered-source shape at `PreviewCompiler.swift:178/195`), and the selection's `maxPages`. Outcome = pages PDF path + the selection's `demonstrates` lines, or the tectonic diagnostics (cause on the result, never thrown away). Records onto the proposal via Task 4.

**Contract.** The overlay is files-on-top-of-copy — never a symlink, never a write into the live dir (a test asserts the live publish dir's bytes are untouched by a full sample compile — the disable experiment target). EMISSION.md refresh lands in the scratch (it already writes under the compiler's `projectURL` — verify, don't assume). Tests: scratch assembly + overlay + live-untouched are pure-ish (no tectonic); ONE end-to-end compile test gated on `try await TectonicProbe.requireReady()` producing a real PDF from a staged template tweak that provably took effect (e.g. a distinctive `\pagecolor`-class marker the test greps the scratch template for and confirms compile success — do not assert pixels).

- [ ] Steps: failing tests → implement → gate → commit — `feat: sample pages compile against the staged set and touch nothing live`

---

### Task 8: Approval — promotion and revert

**Files:** Create `Maugham/Publish/ProposalPromotion.swift`; Test `MaughamTests/ProposalPromotionTests.swift`.

**Interfaces:** Consumes Task 4. Produces `ProposalPromotion.approve(proposal:projectURL:jobManager:) throws` — backs up every live file the proposal touches (and records which staged paths were NEW, i.e. had no live counterpart) into `proposals/<id>/backup/`, writes staged over live, marks `approved`; and `revert(proposal:projectURL:jobManager:) throws` — restores the backup (deleting files that were new), marks the proposal `rejected` with a note. Both REFUSE while a compile job is active (`CompileJobManager` — read its API for the active-job question; a compile reading half-swapped templates is the failure this guard exists for).

**Contract.** Promotion is all-or-nothing in effect: backup completes before the first live write (a failure mid-write leaves the backup whole, and revert recovers — test a forced mid-write failure via a read-only file, the P1 rollback-test idiom). This is the spec's "one versioned, undoable act": versioned = the backup + proposal record; undoable = `revert`, a stored reversal, NOT NSUndoManager (⌘Z in a text pane must never un-ship a book's templates; state this in the type doc). Ledger-visible ruling, pre-made: this interpretation is the controller's.

- [ ] Steps: failing tests (approve writes + backup + new-file record; revert restores byte-identically incl. deleting new files; busy-compile refusal both verbs; mid-write failure recovery; disable experiment on the busy guard) → implement → gate → commit — `feat: approval promotes the staged set; revert takes it back whole`

---

### Task 9: Production wiring

**Files:** Create `Maugham/Compiler/DesignerEnvironment+Project.swift`; Modify `Maugham/Views/ProjectWindow.swift` + `Maugham/Views/CompilerRunModifier.swift` (third orchestrator joins ownership + every shutdown/detach site — extend the paired-count census test from P2); Test `MaughamTests/DesignerEnvironmentTests.swift`.

**Interfaces:** Consumes Tasks 4–8. Produces `DesignerOrchestrator.Environment.production(...)`: weak captures throughout; `briefRound` gathers visual language via `statementText(of:)` (tripwire 20), census+selection from a fresh `ProjectASTBuilder` build (read how `PreviewCompiler` gets its source from `ProjectStoreASTSource` and reuse), current templates read from the live publish dir, config summary, edition brief when `language != nil`, `designerRole()` identity; `stage` = Task 4 stage + Task 7 sample compile kicked off and recorded (compile failure rides the proposal, run still "succeeds" — the gate view shows the error, spec §6); `onRunEnded` summary carries proposal id + sample outcome.

**Contract.** The census from P2 (`test_everyWindowEndingPathShutsTheTranslatorDownToo`) grows a third paired count rather than a new test shape. No trigger UI (P4's desk; runDesign stays headless — the roadmap says so already for P2, extend the sentence).

- [ ] Steps: failing tests (stage→sample recorded; weak captures audit; shutdown census extended; identity reads without minting — bytes-unchanged idiom) → implement → gate (`full`) → commit — `feat: a design round stages, samples, and waits for the writer`

---

### Task 10: Docs

**Files:** Modify `Maugham/Compiler/AREA.md` (third orchestrator; the stage/sample/approve lifecycle; where proposals live), `Maugham/Stores/AREA.md` (DesignProposalStore, derived-deletable), `Maugham/Publish/`… note if that area has an AREA.md (check; if not, the Compiler AREA carries it), `docs/roadmap.md` (P3 shipped-headless honestly; P4 = desk + gate view + brief UI + open-doc trigger restriction + refused-click affordance — the two P2 requirements RIDE HERE so they cannot be lost).

- [ ] Steps: grep falsified claims → edit → fast gate → commit — `docs: the designer's loop is on the record`

---

## Self-review notes (applied)

- Spec §3 coverage: census ✓(T1), briefing ✓(T5), report=spec+files ✓(T3), staging ✓(T4), sample pages via preview pipeline ✓(T2/T7), gate=approve/request-changes ✓(T6.requestChanges + T8), EPUB-CSS-on-the-spec's-word honest edge (T3 carries CSS files; only PDF samples compile — roadmap/AREA say so) ✓(T10).
- §6: tectonic failure rides the proposal ✓(T7/T9); PublishMintGate untouched ✓(GC); promotion undo = stored reversal ruling ✓(T8, pre-ledgered).
- Deliberately absent: all UI (P4), designer allowlist additions (already reads publish files via bridge — verified `read_publish_file`/`list_publish_files` in `CompilerAllowlist.tools`).
- Type consistency: `ElementCensus`/`SamplePageSelection.Selection`/`DesignerReport.ProposedFile`/`Proposal` each defined once; consumers cite defining tasks.
