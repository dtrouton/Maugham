# M4 P1 — The Wire and the Briefing: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The compiler's note-natured findings (continuity questions, reader reports) become pass-stamped, editor-authored **annotations** minted app-side at ingest — one finding, one home — while verdicts (clause summary, drift, since-last-round) stay report-side; the briefing gains the five spike-validated additions including the pass's brief and the writer's dispositions; passes carry briefs and named editors (Perkins/Lish/Gould/Argus); rulings minted from answers carry the note they answered.

**Architecture:** Everything is additive on shipped machinery. `ReviewPass` gains two optional fields with preset-resolution helpers; `Op.Provenance` gains four flat optional scalars (the anti-toolArgs precedent, no new OpKind ⇒ **no schema bump**); minting goes through the one `Document.addAnnotation` funnel (gaining an `announcing:` seam that mirrors `appendLifecycleOp`'s) behind a new `Environment` closure; the pane slims in the same commit the mint lands (a finding must never appear in both homes); since-last-round recounts from annotation state via one pure function. The spawned model's tools do not change — ADR 0029 records the amendment to ADR 0028 §3's framing.

**Tech Stack:** Swift / SwiftUI / AppKit; MaughamCore SPM; XCTest.

**Spec:** `docs/superpowers/specs/2026-08-17-one-loop-two-tempos-design.md` (§2 routing + one-open rule, §3 constitutional accounting, §4 briefs/editors, §5 briefing, §6 rulings context; §7 surfaces are P2's). Spike record backing §5: the six-variant run over `Playlist/pieces/02-tribute`, 2026-08-17.

## Global Constraints

- **No schema bump.** No new `OpKind` case (`OpKind.swift:85-92` scopes the bump rule to cases; the op log is append-only so additive Provenance fields face no re-save loss — `ProjectManifest.swift:55-57` says so). The whole-branch review must verify this reasoning against the tree, not take it.
- **One home per finding, atomically.** The task that makes continuity/reader findings mint as annotations ALSO removes them from the sidecar and the pane, in the same commit. A build where a note appears in both homes must never exist on the branch.
- **Preview persists nothing** (DiagnosticsStore.swift:165-181 discipline): annotations are minted at `finish`'s `.resultText` arm only — never from a streamed section, never from a preview; a cancelled run mints nothing.
- **Announce once.** N mints in one run = ONE `maughamAnnotationsChanged` post (the deletion sweep's rule, `Document+Annotations.swift:1000-1008`; `AnnotationChangeEventTests` polices the family).
- **The compiler's confinement does not move**: `CompilerAllowlistTests` and `ClaudeCLISessionTests.test_spawnArgumentsMatchTheSpike` pass unmodified. The section schema is unchanged — all five briefing additions are input-side.
- **The mint never fails the run**: a note that cannot be minted (paragraph gone, span unresolvable, doc refuses) is dropped with a count, DiagnosticIngest's drop-don't-fail discipline.
- **ADR 0023 binds**: minted annotations are ordinary creation ops — no undo work here (creation ops are not undoable today; dispositions carry the existing verbs).
- **No phone surface.** Phone compiles untouched (all-optional provenance decodes nil; `Annotation` init defaults keep call sites source-compatible).
- **Gates**: `./scripts/test.sh` iterating; `./scripts/test.sh full` (no skips) pre-merge; `swift test --parallel --package-path Packages/MaughamCore` after touching the package; `./gen.sh` after adding package/app sources. `grep -a` on gate logs (NUL fixture).
- **Dispatch notes**: FOREGROUND gates only; poll with repeated Read calls; a turn ended without a tool call in flight is a stall. Reviewers report, don't fix. Demand falsification: every guard's test shown red with the guard deleted. Opus for Tasks 2–5; sonnet acceptable for 1, 6, 7.
- Commits end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

**Decisions of record this plan encodes** (spec §8): findings routed by nature; strains report-side; one open annotation per issue with the ingest-side fingerprint dedupe as the backstop (load-bearing on the Fresh Eyes path); editors Perkins/Lish/Gould/Argus, renameable; personality dials out of scope.

---

### Task 1: Core — pass briefs and named editors

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/ReviewPass.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/ReviewPassTests.swift` (extend)

**Interfaces:**
- Consumes (verified): `ReviewPass { let id; var name }`, fully synthesized Codable (no CodingKeys/init(from:)); presets at `:20-25` with stable ids `structural/line/copyedit/proof`; `ProjectManifest.effectiveReviewPasses` (`:145-147`) returns presets only when the stored array is EMPTY — a customized manifest stores preset-id passes that will lack the new fields; synthesized decoders use `decodeIfPresent` for optionals, so legacy JSON decodes nil.
- Produces:
  - `ReviewPass.brief: String?` and `ReviewPass.editorName: String?` — `public var`, defaulted `nil` in the memberwise init (existing `ReviewPass(id:name:)` call sites compile untouched).
  - `ReviewPass.effectiveBrief: String?` and `ReviewPass.effectiveEditorName: String` — resolution: own field → preset-by-id lookup → fallback (brief: nil, meaning the briefing's name-based fallback sentence; editorName: the pass's `name`). **The ONE spelling of resolution** — consumers never inline the chain.
  - Preset doctrine, verbatim in code (each ~70–90 words, adapted from the editing-pass skill registers + the spike texts):
    - **Perkins / Structural**: structure, pacing, stakes, POV, whether scenes and beats earn their place and the shape delivers the intent; no sentence notes, no typo flags — a scene that needs rebuilding makes sentence notes worthless.
    - **Lish / Line**: rhythm, diction, echoes, filtering words, imagery, the sentence as the unit of attention; structure is settled — do not reopen it; no copyediting.
    - **Gould / Copyedit**: grammar, punctuation, spelling, continuity of names, timeline, and physical fact; the diegetic-error rule — in an unconventional form, apparent errors may be the piece's own (a character's typo, a machine's register): query, never correct; no structural or line notes.
    - **Argus / Proof**: typos, layout artifacts, nothing else; advises that its rounds be run as **Fresh Eyes (⌘⇧R)** — a reader who remembers the manuscript cannot see its surface.

- [ ] **Step 1: Failing tests.** Legacy raw-JSON fixture (`{"id":"line","name":"Line"}`) decodes with both fields nil; a customized stored pass with preset id resolves `effectiveBrief` to the preset's brief and `effectiveEditorName` to the preset's editor; a custom pass with its own brief/name wins over everything; a custom pass with neither yields brief nil and editorName == its `name`; presets carry all four briefs and the four editor names; round-trip with fields present is byte-stable; Proof's brief mentions Fresh Eyes (pins the doctrine, not a count).
- [ ] **Step 2: Run** `swift test --parallel --package-path Packages/MaughamCore` — FAIL.
- [ ] **Step 3: Implement.** Fields, resolution helpers with the preset-lookup doc comment, the four briefs as code constants.
- [ ] **Step 4: Package tests + `./scripts/test.sh`** — green (both schemes build; nothing else consumes the fields yet).
- [ ] **Step 5: Commit** — `feat(core): review passes carry briefs and named editors — Perkins, Lish, Gould, Argus`

---

### Task 2: Core — compiler provenance on the wire and the projection

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/Op.swift` (Provenance)
- Modify: `Packages/MaughamCore/Sources/MaughamCore/Annotation.swift`
- Modify: `Packages/MaughamCore/Sources/MaughamCore/AnnotationDeriver.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/` (extend the deriver/provenance suites)

**Interfaces:**
- Consumes (verified): `Op.Provenance` — 26 all-optional fields, synthesized Codable, explicit snake_case `CodingKeys`, three "Additive: legacy op logs decode with all nil" precedents; the anti-precedent comment at `Op.swift:86-89` (flat optional scalars, never smuggled through `toolArgs`); `AnnotationDeriver` surfaces a flat scalar in one line (`:185`'s `reviewPassId: prov?.reviewPassId` precedent); `Annotation` init defaults everything from `author` onward, so trailing additions are source-compatible; `Annotation` is deliberately NOT Codable (pure projection).
- Produces:
  - `Op.Provenance.compilerRunId: String?` (`"compiler_run_id"`), `.compilerRound: Int?` (`"compiler_round"`), `.compilerFreshEyes: Bool?` (`"compiler_fresh_eyes"`), `.compilerFingerprint: String?` (`"compiler_fingerprint"`) — flat optionals, CodingKeys, init defaults nil.
  - `Annotation.compilerRunId: String?`, `.compilerRound: Int?`, `.compilerFingerprint: String?` — derived from the CREATION op's provenance (freshEyes is not projected; nothing reads it off the annotation). A convenience `Annotation.isCompilerAuthored: Bool` == `compilerRunId != nil`.

- [ ] **Step 1: Failing tests.** Round-trip an op with all four fields (raw-JSON key spellings pinned); a hand-written legacy JSONL line (no new keys) decodes all nil; the deriver projects the three fields from a creation op and nil without; `isCompilerAuthored` truth table; an op carrying the fields through encode is byte-stable.
- [ ] **Step 2: Run package tests** — FAIL.
- [ ] **Step 3: Implement.** Fields + keys + deriver lines, with the "Additive: legacy op logs decode with all nil" comment continuing the house pattern and a comment citing the no-bump reasoning (no new OpKind; append-only log).
- [ ] **Step 4: Package tests + `./scripts/test.sh`** — green.
- [ ] **Step 5: Commit** — `feat(core): compiler run provenance on annotation ops — run id, round, fresh eyes, fingerprint`

---

### Task 3: The mint and the slimming — one commit, one home

**Files:**
- Modify: `Maugham/OpLog/Document+Annotations.swift` (`addAnnotation` gains `announcing: Bool = true` + compiler provenance params)
- Modify: `Maugham/Compiler/DiagnosticIngest.swift` (the outcome splits: strains stay, notes route)
- Modify: `Maugham/Compiler/CompilerOrchestrator.swift` (`Environment.mintAnnotations` closure; `finish` calls it after `replace`)
- Modify: `Maugham/Compiler/CompilerEnvironment+Project.swift` (production wiring)
- Modify: `Maugham/Compiler/RoundHistory.swift` (`RoundFingerprint` becomes the shared fingerprint spelling for the dedupe)
- Modify: `Maugham/Views/DiagnosticsPane.swift` (continuity/reader rows leave; `DiagnosticPromotion`'s scope note)
- Modify: `Maugham/Views/AnnotationChangeEventTests.swift`'s family + `MaughamTests/` end-to-end suites
- Test: extend `MaughamTests/CompilerRunCommandTests.swift`, `MaughamTests/DiagnosticsPaneTests.swift`, `MaughamTests/AnnotationChangeEventTests.swift`

**Interfaces:**
- Consumes (verified): `Document.addAnnotation(kind:paragraphId:body:suggestedText:prompt:toolArgs:span:author:reviewPassId:) async throws -> String` (`Document+Annotations.swift:72-91`) — posts `announceAnnotationsChanged()` unconditionally at `:179`; `appendLifecycleOp`'s `announcing:` flag + the announce-ONCE-after-the-loop rule (`:1000-1008`, sweep posts once at `:1106`); `AnnotationAuthor(sourceKind: .claude, displayName:)` buckets by exact display-name label (`AnnotationAuthorPresentation.swift` — a new displayName IS a new filter bucket, which is the feature); kinds map `.query→.claudeQuery`, `.comment→.claudeComment`; `AnnotationFilter(statuses: [.open])` default; `SectionedOutcome { accepted, facts, conformance, droppedDangling, truncatedReader, intentDriftVerdict }` with `Diagnostic.kind` distinguishing strains/continuity/reader; `finish`'s `.resultText` arm (parse → record → replace → recordFacts); ⌘R requires `reading(docId) != nil`, so the target document is always open.
- Produces:
  - `Document.addAnnotation` gains `announcing: Bool = true` and passes compiler provenance through (either dedicated params `compilerRunId:round:freshEyes:fingerprint:` defaulted nil, or a small `CompilerProvenance?` value — implementer's call, ONE spelling, threaded into `Op.Provenance`). Existing callers untouched.
  - `struct CompilerNote` (in the compiler area): `{ kind: AnnotationKind, paragraphId: String?, body: String, fingerprint: String }` — built by the ingest from continuity (`.query`, body = the question, anchored at the first resolving ref) and reader (`.comment`, body = the report) entries. **Whole-paragraph anchors in P1** (the entries carry quotations in prose, not a span field — span minting is not attempted).
  - `RoundFingerprint.stringValue` (or equivalent) — the ONE fingerprint spelling shared by the mint, the dedupe, and Task 4's standing-notes briefing; computed from the same identity `RoundFingerprint.make` already defines (kind + clauseQuote/cites + anchor paragraph). A note with no discriminator mints WITHOUT a fingerprint (dedupe cannot see it; accepted, matches `make`'s nil rule).
  - `Environment.mintAnnotations: @MainActor ([CompilerNote], CompilerMintContext) async -> Int` (defaulted no-op returning 0) where the context carries `(docId, passId, round, freshEyes, editorName)`. Production wiring: weak documentStore/store; resolves the open `Document`; **dedupe backstop first** — skip any note whose fingerprint matches an OPEN compiler-authored annotation on the doc (`isCompilerAuthored` + fingerprint equality); mints the rest via `addAnnotation(announcing: false, author: AnnotationAuthor(sourceKind: .claude, displayName: editorName), reviewPassId: passId, …)`; posts `MaughamEvent.postAnnotationsChanged` ONCE if anything minted; returns the minted count; every per-note failure is caught and counted, never thrown.
  - `finish` routes: `outcome.accepted` splits by kind — strains → `replace` (sidecar) as today; continuity/reader → `mintAnnotations`. The sidecar and pane never see continuity/reader again: `DiagnosticsPane`'s `questions`/`readerReports` groups go, `driftLine`/summary/strains/round-line stay; `DiagnosticPromotion` doc gains the strains-only scope note. Streaming preview: the pane previews clause statuses as today; streamed continuity/reader sections accumulate but render nothing and mint nothing until `finish`.
  - Editor identity: `beginRun` resolves `(passId, editorName)` together — the active pass's `effectiveEditorName` via a widened `Environment.activePass` return (becomes `(passId: String, editorName: String, brief: String?)?` or a sibling closure; ONE resolution site). A passless run mints with `editorName = "Claude"` (the M2 identity) and no pass stamp.

- [ ] **Step 1: Failing tests.**
  - End-to-end (real orchestrator, CompilerRunCommandTests harness): a run whose answer carries one continuity question + one reader report mints TWO annotations on the open doc — kinds query/comment, author displayName == the active pass's editor ("Gould" for a copyedit lane), `review_pass_id` stamped, provenance carrying runId/round/fingerprint (assert against the op log's raw JSONL line, not just the projection); the diagnostics sidecar's raw JSON contains NO continuity/reader entries; the pane renders neither (mounted assertion) while the strain row still renders.
  - **One event**: two mints in one run post exactly one `maughamAnnotationsChanged` (extend AnnotationChangeEventTests' pattern; falsification: `announcing: true` in the loop → two posts → red).
  - **Dedupe backstop**: run 2 re-raising the same continuity question (same fingerprint) mints NOTHING new — one open annotation before and after; a fresh-eyes run re-raising it also mints nothing (the spec's load-bearing path); a note whose fingerprint matches a RESOLVED annotation DOES mint (only open blocks).
  - A passless run mints with author "Claude" and no stamp; a mint failure (paragraph deleted between parse and mint) drops that note, mints the rest, and the run still succeeds.
  - A cancelled streaming run mints nothing (ride the byte-identical-sidecar cancel test's neighbourhood).
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement**, in the order: funnel seam → ingest split → closure + wiring → pane slimming. Keep the one-home rule inside this commit.
- [ ] **Step 4: `./scripts/test.sh`** — green. Also run the three `CanvasViewMounting*` skips-free full gate ONLY at merge; here the fast gate suffices.
- [ ] **Step 5: Commit** — `feat(compiler): continuity questions and reader reports mint as pass-stamped annotations — one finding, one home`

---

### Task 4: The briefing — five additions, and the writer's dispositions reach the model

**Files:**
- Modify: `Maugham/Compiler/CompilerPrompt.swift`
- Modify: `Maugham/Compiler/CompilerOrchestrator.swift` (gathers the annotation context in `beginRun`'s synchronous prefix; fresh path omissions)
- Modify: `Maugham/Compiler/CompilerEnvironment+Project.swift`
- Test: extend `MaughamTests/CompilerPromptTests.swift`, `MaughamTests/CompilerRunCommandTests.swift`

**Interfaces:**
- Consumes (verified): `runMessageV2`'s linear `sections: [String]` assembly — briefing block (hash-gated) → listings → round section → delta → schema; the round section's never-hash-elided precedent and its placement tests; `Annotation` fields incl. `status`, `userResponse`, `triage`, `compilerRunId`, `compilerFingerprint` (Task 2/3); `Document.annotations(filter:)` with `statuses: nil` for settled ones; the spike texts (reader bar, dedup, drift stabilizer — final wording in the spike record, adapted verbatim).
- Produces:
  - **Pass section**: when the run has a pass, a section carrying the role frame ("You are <editor>, this manuscript's <pass name> editor") + the pass's `effectiveBrief` (or the name-based fallback sentence when nil). Placed with the round section (between listings and delta); never in `briefingHashInput`.
  - **Dispositions section** (same placement): the piece's OPEN compiler-authored annotations ("standing — confirm or let resolve; never re-raise as new") and its settled compiler-authored ones with the writer's verdicts — declined triage with reason, stetted, rejected with `userResponse` ("settled; do not re-raise in any section"). Empty section omitted. Gathered in `beginRun`'s synchronous prefix via `Environment.annotationContext: @MainActor (String) -> [CompilerAnnotationDisposition]` (a small value: fingerprint?, body excerpt, state, reason?).
  - **Schema-adjacent additions** to `sectionSchemaDescription`'s surrounding instruction text (NOT the five lines themselves): the reader bar, cross-section dedup, drift stabilizer — the spike's wordings.
  - **Fresh path**: omits the round section (shipped), the dispositions section, AND `previousRound` — cold means cold; the Task-3 dedupe is the duplicate guard.
- [ ] **Step 1: Failing tests.** Prompt: pass section present with editor name + brief for a briefed preset lane, fallback sentence for a briefless custom pass, absent for passless; dispositions section lists an open note as standing and a declined one with its reason; briefing hash byte-identical across two rounds with unchanged intent while both sections churn (the never-elided guard); schema census (`DiagnosticIngestTests` :82-110 family) still passes untouched — the five lines didn't move; reader-bar/dedup/stabilizer strings present (pin by distinctive phrase, not full text). End-to-end: run 2's sent message carries run 1's declined note with the writer's reason; a fresh-eyes message carries none of round/dispositions.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: `./scripts/test.sh`** — green.
- [ ] **Step 5: Commit** — `feat(compiler): the briefing carries the pass's editor and brief, the writer's dispositions, and the spike's three disciplines`

---

### Task 5: Since-last-round recounts from the queue

**Files:**
- Modify: `Maugham/Compiler/RoundHistory.swift` (the note-comparison half retires; clause machinery stays)
- Modify: `Maugham/Views/DiagnosticsPane.swift` (`sinceLastRoundLine` inputs)
- Modify: `Maugham/Compiler/DiagnosticsStore.swift` (RoundRecord fingerprints stop being written — tolerant decode keeps old sidecars readable)
- Test: extend `MaughamTests/RoundHistoryTests.swift`, `MaughamTests/DiagnosticsPaneTests.swift`, `MaughamTests/CompilerRunCommandTests.swift`

**Interfaces:**
- Consumes: Task 3's annotations with `compilerRound`/`reviewPassId`/`resolvedAt`; the ring's `RoundRecord` (passId/round/at survive; `fingerprints` becomes write-empty, decode-tolerant); the shipped guard `previous.round == run.round - 1` and the fresh-eyes exclusion.
- Produces:
  - `enum SinceLastRound { struct Outcome { let resolved: Int; let persisting: Int; let new: Int }; static func compute(annotations: [Annotation], lane passId: String?, currentRound: Int, previousRoundAt: Date) -> Outcome }` — pure, the ONE spelling: **new** = compiler annotations in the lane with `compilerRound == currentRound`; **persisting** = open, lane, `compilerRound < currentRound`; **resolved** = non-open, lane, `compilerRound < currentRound`, `resolvedAt > previousRoundAt`.
  - `sinceLastRoundLine` reads it (annotations arrive as an input the pane already has via the queue's data path); `RoundComparison.compare` and its fingerprint matching retire from production use (kept only if a test still exercises tolerance; `replace` writes `fingerprints: []`).
- [ ] **Step 1: Failing tests.** `compute` truth table incl. lane isolation, the resolved-time boundary, round-1 (no line); end-to-end: run 1 mints two notes, writer stets one, run 2 → line reads "1 resolved · 1 persisting · 0 new" (with the model's re-raise deduped, not double-counted); old sidecar with fingerprints still decodes; new sidecars carry `"fingerprints":[]` (raw JSON).
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: `./scripts/test.sh`** — green.
- [ ] **Step 5: Commit** — `feat(compiler): since-last-round counts the queue's truth`

---

### Task 6: Rulings carry the note they answered

**Files:**
- Modify: `Maugham/Views/DiagnosticsPane.swift` (`answeredNoteProvenance` becomes a builder)
- Test: extend `MaughamTests/DiagnosticsPaneTests.swift`, `MaughamTests/CompilerRunCommandTests.swift` (the answer→ruling→next-briefing chain)

**Interfaces:**
- Consumes (verified): `RulingPerformer.rule(_:provenance:forScope:store:world:)` — **unchanged**; the provenance string is free text rendered as `<sentence> — ruled <d MMM yyyy>, <provenance>` (`RulingsSection.swift:270-277`); the parser splits on the RIGHT-MOST " — ", so the provenance blob may not itself introduce a parse-breaking " — " (`parseItem` :249-266); `commitAnswer` builds the call at `DiagnosticsPane.swift:1019-1021` with `answeredNoteProvenance` (`:987`).
- Produces: `DiagnosticsPane.answeredNoteProvenance(for diagnostic: Diagnostic) -> String` — `"answered a compiler note: «<excerpt>»"` where excerpt = the note's `clauseQuote` (a strain's clause — the only answerable kind post-Task-3) trimmed to ≤60 chars with any " — " collapsed (em-dash sanitation, the parser rule). The rendered ruling reads *…— ruled 17 Aug 2026, answered a compiler note: «the dread stays unnamed»*.
- [ ] **Step 1: Failing tests.** Builder truth table (short quote verbatim; long quote truncated with ellipsis; embedded " — " collapsed; nil clauseQuote falls back to the bare legacy string); the round-trip: answer a strain end-to-end, re-parse the statement's rulings — one ruling whose provenance contains the excerpt and whose TEXT is exactly the writer's sentence (the parser survived); the next run's briefing carries the enriched line.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: `./scripts/test.sh`** — green.
- [ ] **Step 5: Commit** — `feat(compiler): a ruling remembers the note it answered`

---

### Task 7: ADR 0029 + the docs that move with the code

**Files:**
- Create: `docs/adr/0029-the-compilers-report-is-materialized.md`
- Modify: `Maugham/Compiler/AREA.md`, `Maugham/OpLog/AREA.md` (if the annotation funnel note lives there — verify), `CLAUDE.md` (Compiler cell: one-home routing, editors, briefing additions; MCP cell untouched — no tool moved)
- Test: none (docs); `./scripts/test.sh` for the DocSync family

**Interfaces:**
- Consumes: everything Tasks 1–6 shipped (write against the tree, not this plan); ADR 0028's structure (the two-flag table, the falsifiable clause).
- Produces: ADR 0029 — status Accepted, amends 0028 §3's framing: *the compiler reads and never writes; its parsed report is materialized by Maugham into the layers the writer governs* (annotations join bible facts and promoted tasks as the third materialization); names what did NOT move (confinement flags, allowlist censuses, statement prohibition) and the falsifiable clause (if the spawned model ever gains a tool that writes an annotation, the decision is violated — the writes are the app's, at ingest, after parse). AREA.md: the mint joins the seam map (Environment.mintAnnotations row), the four-fates section reworks (continuity/reader fates now live in the queue), the pass/editor resolution gets a paragraph. CLAUDE.md Compiler cell: surgical.
- [ ] **Step 1: Write the ADR** (cite spec §3, the spike record, this plan).
- [ ] **Step 2: Sweep the named files**; grep `docs/ Maugham/*/AREA.md` for now-false claims about the four fates and the pane's contents (`grep -rn "continuity" Maugham/Compiler/AREA.md docs/guide/compiler.md` — guide moves in P2, but a claim the P1 tree already falsifies gets a minimal truth fix now, flagged for P2's full sweep).
- [ ] **Step 3: `./scripts/test.sh`** — green.
- [ ] **Step 4: Commit** — `docs(m4): ADR 0029 — the report is materialized; area notes follow the wire`

---

## Self-review record (spec §2–§6 → tasks)

§2 routing table → T3 (mint + slimming, one commit); one-open rule + fresh-eyes backstop → T3 dedupe; resolved/persisting/new redefinition → T5. §3 amendment → T7 ADR 0029; confinement censuses untouched → global constraint. §4 briefs/editors/effective resolution/Proof-advises-fresh-eyes → T1; editor-as-author + role frame → T3/T4. §5 five additions + dispositions + fresh-path omissions → T4 (backstop in T3). §6 ruling context → T6 (via provenance string — no RulingPerformer change; survey-verified). §7 surfaces, `review_passes.brief` in get_outline, skill rewrite, guide sweep → P2, deliberately absent here.

Cross-task names: `effectiveBrief`/`effectiveEditorName` (T1) ← T3/T4; provenance fields + `isCompilerAuthored` (T2) ← T3/T5; `CompilerNote`/`mintAnnotations`/fingerprint spelling (T3) ← T4 (dispositions) and T5 (counts); `SinceLastRound.compute` (T5) self-contained; `answeredNoteProvenance(for:)` (T6) self-contained.

Whole-branch seams for the final review: (a) T3×T4 — the fingerprint spelling shared by mint, dedupe, and dispositions briefing must be ONE function; (b) T3×T5 — a stet in the queue must move the since-last-round counts without any compiler involvement; (c) the no-bump reasoning (T2) verified against `OpKind.swift`'s rule and a phone build; (d) the one-home invariant — grep the tree for any surface still rendering continuity/reader diagnostics.
