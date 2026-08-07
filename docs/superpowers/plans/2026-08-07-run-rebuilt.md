# Second Draft Plan 2 — the run rebuilt

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The run speaks the second draft's contract: conformance against the writer's derived clauses, continuity questions, a reader's report, and fact-candidates feeding the bible — with no bare ¶id anywhere the writer reads and no silent two-minute wait.

**Architecture:** A v2 line-delimited section contract in `CompilerPrompt` + a v2 sectioned ingest; the orchestrator's briefing switches ATOMICALLY from whole statement text to essay-half + derived clauses (the load-bearing carry) and gives `ClaudeWorldDeriver.derive` its first production caller; the pane reorganizes into a conformance-led report with excerpt chips, incremental section arrival, and a legible running state. Spec §5: `docs/superpowers/specs/2026-08-07-compiler-second-draft-design.md`. The five Stage 2 requirements: `docs/superpowers/notes/2026-08-07-second-draft-handoff.md`.

**Tech Stack:** Swift 6 / SwiftUI, XCTest, the existing warm `claude -p` session.

## Global Constraints

- Contracts and verified signatures, never function bodies. `./gen.sh` discipline; flat `-only-testing`; warm-build census; Release build for pane/window tasks; commit register; **no push**.
- **The atomic switch (load-bearing carry #1):** the intent briefing moves to essay-half + derived clauses IN THE SAME task that makes the run consume clauses — never split across commits that could ship separately.
- **No bare ¶ids in anything the writer reads** (requirement 3): the contract forbids ids in note prose; references travel in a structured `refs` field; the schema instruction and the ingest's validation both enforce it.
- The register: no severity field, no suggestion field, notes end as questions where they ask one; the planted-offender ingest test (fix-shaped body refused) carries over to v2.
- Drift-as-pattern is **Stage 3's** — v2 drops the `intent_drift` field and nothing replaces it this stage; docs say so plainly.
- Diagnostics sidecar decode must tolerate v1 records (a writer's existing file must not crash or wipe; v1 notes may simply be dropped as a superseded run — decide, pin, and say so).
- Subagent models: opus for tasks 2, 3, 5; sonnet for 1, 4, 6; reviewers haiku, sonnet on orchestrator/pane diffs.

## File Structure

```
Maugham/Compiler/CompilerPrompt.swift        v2 contract + prompt (modify)
Maugham/Compiler/DiagnosticIngest.swift      v2 sectioned parser (modify)
Maugham/Compiler/Diagnostic.swift            kind + refs + clause fields (modify)
Maugham/Compiler/DiagnosticsStore.swift      v1-tolerant decode (modify)
Maugham/Compiler/CompilerOrchestrator.swift  briefing switch + derive() caller + incremental ingest (modify)
Maugham/Compiler/DeclaredWorldDeriver.swift  pipe-drain fix (modify, same commit as first caller)
Maugham/Views/DiagnosticsPane.swift          the report + chips + running state (modify)
Maugham/Views/CompilerRunModifier.swift      in-flight acknowledgment (modify)
```

---

### Task 1: The v2 contract — sections, refs, and no ids in prose

**Files:**
- Modify: `Maugham/Compiler/CompilerPrompt.swift` (`outputSchemaDescription:27`, `sessionSystemPreamble:40`, `runMessage:64`)
- Test: `MaughamTests/CompilerPromptTests.swift`

**Interfaces — Produces:**
```swift
// CompilerPrompt gains:
static let sectionSchemaDescription: String   // v2: four line-delimited JSON objects, one per section, in order:
// {"section":"conformance","checks":[{"clause_quote":..., "status":"holds|strains|silent", "refs":[pid], "what_pulls":...}]}
// {"section":"continuity","questions":[{"cites":..., "refs":[pid], "question":...}]}
// {"section":"reader","reports":[{"kind":"dream_break|belief","refs":[pid],"report":...}]}
// {"section":"facts","candidates":[{"subject":...,"fact":...,"refs":[pid]}]}
static func runMessageV2(delta: CompilerDelta, world: DerivedWorld?, essay: String?,
                         bibleFacts: [BibleFact], paletteListing: [String], pinnedListing: [String],
                         previousBriefingHash: String?) -> (message: String, briefingHash: String?)
```

**Consumes (verified in tree today):** `DerivedWorld` (clauses/rules), `BibleFact`, `CompilerDelta`; the v1 `outputSchemaDescription` stays until Task 2 deletes its readers (one commit may not leave both live in production paths — Task 3 flips the caller).

**Contracts:**
- [ ] The schema instruction: one JSON object per line, section order fixed, `refs` arrays for EVERY paragraph reference, and an explicit prohibition: *note prose never contains paragraph ids; refer to prose by short quotation*. Pinned by `test_theSchemaForbidsIdsInProse` (asserts the prohibition text) — the enforcement with teeth is Task 2's.
- [ ] No severity, no suggestion field anywhere in the schema — `test_theSchemaHasNowhereForYouShould` (grep the schema string for the absent fields, control-planted).
- [ ] The briefing embeds: the delta (unchanged labeling), the ESSAY text (not whole statement) when present, the derived clauses/rules quoted verbatim, the bible slice (subjects from the delta's fact-candidate... no — subjects aren't known pre-run; the slice is by subjects seen in PRIOR facts whose subject string occurs in the delta text, case-insensitive contains — decide, pin, doc), listings as v1.
- [ ] `briefingHash` covers essay+world+facts (the diff-in rule widened): unchanged briefing → one-line marker, changed → re-embed. `test_theBriefingDiffsInAsOneUnit`.
- [ ] Reader-report cap (≤3) stays in the instruction.
- [ ] `./gen.sh`; flat CompilerPromptTests; commit.

---

### Task 2: The v2 ingest — sectioned, incremental-capable, id-free

**Files:**
- Modify: `Maugham/Compiler/DiagnosticIngest.swift`, `Maugham/Compiler/Diagnostic.swift`
- Test: `MaughamTests/DiagnosticIngestTests.swift`

**Interfaces — Produces:**
```swift
// Diagnostic gains (additive, sidecar-tolerant):
enum DiagnosticKind: String, Codable, Sendable { case conformanceStrain, continuity, readerReport }
var kind: DiagnosticKind?           // nil on legacy v1 records
var refs: [Ref]?                    // struct Ref: Codable { let paragraphId: String; let excerpt: String }  — excerpt captured AT INGEST from live text (the anchorText discipline applied to refs)
var clauseQuote: String?            // conformance strains carry the writer's own words
// DiagnosticIngest gains:
struct SectionedOutcome: Equatable { let accepted: [Diagnostic]; let facts: [BibleFact]; let conformance: [ClauseStatus]; let droppedDangling: Int }
struct ClauseStatus: Equatable, Codable { let clauseQuote: String; let status: String; let refs: [Diagnostic.Ref] }
static func parseSection(line: String, runId: String, docId: String, liveParagraphText: (String) -> String?) -> PartialSection?   // one line → one section's contents
static func parseAll(resultText: String, ...) -> SectionedOutcome?   // whole-turn fallback (splits lines, folds parseSection)
```

**Contracts:**
- [ ] Each section line parses independently (`parseSection`) so arrival can be incremental; `parseAll` = fold of the same function — ONE spelling, asserted by a test that runs both over the same fixture and compares.
- [ ] **The id-scrub with teeth**: any note/question/report whose PROSE contains a token matching a delta ¶id is refused at ingest (dropped + counted) — `test_anIdInProseIsRefused`, planted-offender control. Refs validate against live text and capture excerpts at ingest (first ~8 words).
- [ ] `holds`/`silent` conformance entries become `ClauseStatus` only (no Diagnostic); `strains` produce BOTH a ClauseStatus and a `.conformanceStrain` Diagnostic with `clauseQuote` + refs.
- [ ] Facts section → `[BibleFact]` (ULID-minted, docId stamped, establishedAt from refs.first).
- [ ] The fix-shaped-body refusal (v1's planted offender) re-pinned against v2 fields.
- [ ] Fenced/garbage tolerance as v1; unknown section names skipped without failure (forward tolerance).
- [ ] v1 sidecar decode: a file with v1 records loads without crash; v1 notes surface... **decide and pin: dropped as superseded** (replace-on-run semantics make them one run from gone anyway) with a doc-comment stating it.
- [ ] `./gen.sh`; flat DiagnosticIngestTests + DiagnosticsStoreTests; commit.

---

### Task 3: The atomic switch — the orchestrator briefs the declared world

**Files:**
- Modify: `Maugham/Compiler/CompilerOrchestrator.swift`, `Maugham/Compiler/CompilerEnvironment+Project.swift`, `Maugham/Compiler/DeclaredWorldDeriver.swift` (pipe-drain, THIS commit)
- Test: `MaughamTests/CompilerRunCommandTests.swift`

**This is load-bearing carry #1 and #2 in one task, and it is ONE commit:** the run consumes derived clauses AND stops briefing whole statement text in the same change; `derive()` gains its first production caller AND the pipe-drain read-after-exit shape is fixed together.

**Consumes (verified):** `DeclaredWorldStore.cached(forScopeKey:sourceHash:)` / `.store` / `scopeKey(for:)` (`DeclaredWorld.swift:116,136,144`), `WorldDeriver.derive(statementText:)` (`DeclaredWorldDeriver.swift:8`), `StatementEssay.half(of:)` (`StatementEssay.swift:77`), `BibleStore.facts(subjects:)` (`BibleStore.swift:73`) / `.record` (`:97`), Task 1's `runMessageV2`, Task 2's `parseSection`/`parseAll` + `SectionedOutcome`.

**Contracts:**
- [ ] The run path: resolve statement → essay half → hash-check the derivation cache (`cached`) → on miss, `derive` (the lazy trigger AREA.md records; the toggle-off/derive-nil path degrades to briefing the essay WITHOUT clauses — honest, not fatal) → `runMessageV2` → send → ingest → `BibleStore.record(facts)` + store diagnostics + persist `ClauseStatus` list on the run record (the pane's summary needs it; extend `CompilerRun` additively).
- [ ] **The whole-text briefing is gone**: a test asserts the prompt contains the essay and the clauses and NOT the rulings section's raw lines — `test_rulingsAreBriefedAsClausesNotProse` (the double-count guard, the carry's exact words).
- [ ] Pipe-drain fix in `runOneShot`: read stdout concurrently with the wait (the reviewer's shape), pinned by a fixture emitting >64KB — `test_aLargeDerivationDoesNotDeadlock`.
- [ ] Derivation failure / no intent at all: the run proceeds sections-capable with conformance section instructed as absent (the schema tolerates an empty checks array; absence is valid) — `test_noDeclaredWorldStillRuns`.
- [ ] Incremental arrival: the orchestrator feeds `parseSection` per stream event when the session yields partial text, else `parseAll` at turn end — **verify against `ClaudeCLISession`'s actual event surface first** (it resolves per-turn `result` today; if partial assistant events are NOT already surfaced, DO NOT rebuild the session — land whole-turn v2 now and record the streaming upgrade as a named follow-on; requirement 4's other half (legible wait + acknowledgment) is Task 5's and does not depend on it).
- [ ] `./gen.sh`; flat CompilerRunCommandTests + DeclaredWorldDeriverTests; commit.

---

### Task 4: The store and run record — clause statuses, v1 tolerance

**Files:**
- Modify: `Maugham/Compiler/DiagnosticsStore.swift`, `Maugham/Compiler/Diagnostic.swift` (CompilerRun extension)
- Test: `MaughamTests/DiagnosticsStoreTests.swift`

**Contracts:**
- [ ] `CompilerRun` gains `clauseStatuses: [DiagnosticIngest.ClauseStatus]?` (additive-optional); round-trip; v1 sidecar (no field) loads clean.
- [ ] `live(docId:currentText:)` unchanged for anchored notes; `.conformanceStrain`/`.continuity`/`.readerReport` all dismiss on their ANCHOR paragraph change as v1 (refs do not pin liveness — the anchor rule stays single); a doc-comment states refs are display-only.
- [ ] `./gen.sh`; flat run; commit.

---

### Task 5: The pane — a conformance report, chips, and a legible wait

**Files:**
- Modify: `Maugham/Views/DiagnosticsPane.swift`, `Maugham/Views/CompilerRunModifier.swift`, `Maugham/Views/SaveFlashOverlay.swift` (only if the flash variant needs it)
- Test: `MaughamTests/DiagnosticsPaneTests.swift`

**Contracts:**
- [ ] **Layout**: conformance summary FIRST — each clause quoted (the writer's words), status glyph (holds/strains/silent), strains expandable to their note; then continuity questions; then the reader's report. (v1/kind-nil notes never reach the pane — Task 2's ingest drops them as superseded, a ruled plan correction; the pane needs no legacy section.)
- [ ] **Excerpt chips**: every `Ref` renders as its excerpt (~8 words) in a chip; click posts the same jump the anchor row uses; NO raw pid is rendered anywhere — `test_noParagraphIdIsEverRendered` (walk the pane's AX tree for delta pids, planted offender).
- [ ] **The legible wait** (requirements 4b/5): running state says what it's reading — "Checking 14 new paragraphs…" from the delta summary, available BEFORE the send (the orchestrator knows the delta first — verify the ordering exposes it; if not, thread it through RunState.running's payload additively).
- [ ] **The in-flight acknowledgment**: a second ⌘R during a run flashes "Still checking…" (revisiting Task 7-of-M2's judgment, WITH the original reasoning answered: the flash no longer claims work started because its copy says still) — delivery-path test through the real event.
- [ ] **Fates rework**: answer (→ `RulingPerformer.rule`, questions only — continuity questions and strains get the answer affordance; reader reports do not), the shim dies (delete `IntentAppendPerformer` + its remaining callers; the reply field routes to rule with provenance "answered a compiler note, <date>"), promote unchanged, category tag UI removed (kind sections replace it).
- [ ] Streaming rows if Task 3 landed incremental arrival; otherwise the batch renders per-section in order.
- [ ] Release build; `./gen.sh`; flat DiagnosticsPaneTests + IntentAppendPerformer's successor suites; commit.

---

### Task 6: Docs, guide, roadmap — the bible fills, drift waits

**Files:**
- Modify: `Maugham/Compiler/AREA.md`, `docs/guide/compiler.md`, `docs/guide/right-pane.md`, `docs/roadmap.md`, `docs/superpowers/specs/2026-08-07-compiler-second-draft-design.md` (dated stage-2 line)
- Test: DocSync/HelpTopicIndex suites green

**Contracts:**
- [ ] The guide now describes the report (clauses quoted back, questions, the reader), the bible stratum FILLING from runs, bless/correct as the graduation path, and the wait's copy. Drift: one honest sentence that pattern-drift arrives in Stage 3; the v1 drift note is gone.
- [ ] AREA.md: the v2 contract pointer, the atomic-switch rationale (why essay+clauses, the double-count guard test by name), derive()'s caller recorded (the lazy-trigger section updated from "zero callers").
- [ ] Roadmap: stage 2 ✓ pending smoke; stage 3 open (cold start, drift-as-pattern, streaming upgrade if Task 3 recorded it).
- [ ] CLOSING RUNS: full Mac suite (MCP skip), Core `swift test`, phone scheme if Core changed (it should NOT this stage — verify and say). Counts + discriminator by name.
- [ ] Commit.

---

## Self-review notes

- Spec §5 → Tasks 1-5; requirement 3 (quotes-not-ids) → Tasks 1 (schema) + 2 (teeth) + 5 (chips); requirement 4 → Task 5 (+Task 3's streaming attempt with recorded fallback); requirement 5 → Task 5; carries #1/#2 → Task 3 atomically. Stage 3 boundary held (no cold start, no drift-pattern).
- Type consistency: `SectionedOutcome`/`ClauseStatus`/`Ref` (2→3→4→5); `runMessageV2` (1→3); `briefingHash` naming consistent.
- Six tasks, all under the cap.
