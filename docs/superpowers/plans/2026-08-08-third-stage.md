# Second Draft Plan 3 — cold start, drift, and the loop closed

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stage 3 closes the second draft: an existing manuscript gets its one refusable read-it-whole offer, drift becomes the pattern the spec promised, blessing converges instead of looping, sections stream as they arrive, and the derivation gets a measured deadline.

**Architecture:** A small clause-status history on the diagnostics sidecar feeds a pure `DriftDetector`; `BibleStore` learns the one distinction bless created (graduated ≠ dismissed); `ClaudeCLISession` surfaces the CLI's partial-message deltas (spiked 2026-08-08: `--include-partial-messages` emits `stream_event`/`content_block_delta` mid-turn, first at ~4s) so the orchestrator's existing per-line `parseSection` finally streams; the cold-start offer is a pane state, not a ceremony. Spec §4/§8; the inherited list in `docs/superpowers/notes/2026-08-07-second-draft-handoff.md`.

**Tech Stack:** Swift 6 / SwiftUI, XCTest, the warm session.

## Global Constraints

- Contracts not bodies; `./gen.sh` discipline; flat `-only-testing`; warm-build census; Release build on pane/window tasks; commit register; **no push**.
- On-demand only: the cold-start read happens on the writer's click, never automatically; the refusal is remembered per doc and NEVER re-asked as a nag (constitution).
- The register: drift's copy is the spec's ("your line may have moved — draft's right, or intent's right?"); nothing pushed, nothing counted at the writer.
- Drift is computed from records, never a background process; the history kept is small and derived (sidecar, per-device, decode-tolerant).
- Graduated-fact memory is the bless/dismiss DISTINCTION: dismissed facts may return (spec §3.3, unchanged); GRADUATED facts are suppressed because they are now declared (the ruling is the memory). Both directions tested; the AREA.md door paragraph is replaced by the design it asked for.
- Streaming: the session change is additive (a delta callback beside the result path); the generation/teardown discipline (Task 5-of-M2's hard-won guards) must survive untouched — every existing ClaudeCLISessionTests case stays green unmodified.
- Subagent models: opus for tasks 3, 4; sonnet for 1, 2, 5; reviewers haiku, sonnet on session/pane diffs.

## File Structure

```
Maugham/Compiler/DriftDetector.swift          pure pattern over clause-status history (new)
Maugham/Compiler/DiagnosticsStore.swift       clauseStatuses history ring (modify)
Maugham/Compiler/BibleStore.swift             graduated keys (modify)
Maugham/Views/BibleStratum.swift              graduate() records the key (modify)
Maugham/Compiler/ClaudeCLISession.swift       partial-delta surface (modify)
Maugham/Compiler/CompilerOrchestrator.swift   incremental ingest + cold-start run (modify)
Maugham/Compiler/DeclaredWorldDeriver.swift   deadline (modify)
Maugham/Views/DiagnosticsPane.swift           drift line, offer state, streaming rows (modify)
```

---

### Task 1: The clause-status history and the drift detector

**Files:**
- Modify: `Maugham/Compiler/DiagnosticsStore.swift`, `Maugham/Compiler/Diagnostic.swift`
- Create: `Maugham/Compiler/DriftDetector.swift`
- Test: `MaughamTests/DriftDetectorTests.swift` + DiagnosticsStoreTests additions

**Interfaces — Produces:**
```swift
// DiagnosticsStore: the sidecar keeps, beside the (still single) run record, a small ring:
func clauseStatusHistory(docId: String) -> [[DiagnosticIngest.ClauseStatus]]   // oldest→newest, capped
static let clauseHistoryDepth: Int   // 5 — enough for the k=3 pattern with headroom, small enough to stay a sidecar
// appended on every successful ingest that carried statuses; replace-on-run does NOT clear it (history outlives runs by design — doc-comment why)
struct DriftFinding: Equatable { let clauseQuote: String; let runsStraining: Int }
enum DriftDetector {
    static let consecutiveRunsThreshold: Int   // 3
    static func drift(history: [[DiagnosticIngest.ClauseStatus]]) -> [DriftFinding]
    // a clause straining in each of the last k runs (matched by clauseQuote; a clause absent from a run breaks the streak — re-derivation renamed it, honest reset)
}
```

**Contracts:**
- [ ] History appends per ingest, caps at depth (oldest dropped), round-trips, v1/v2 sidecars without the field load clean; replace-on-run leaves it.
- [ ] Drift fires only on k consecutive strains of the SAME quote; holds/silent/absence breaks the streak; two clauses can drift independently; empty history → empty.
- [ ] A revoked-ruling scenario: the clause vanishes from later runs' statuses (re-derivation) → streak broken, no ghost drift.
- [ ] `./gen.sh`; flat runs; commit.

---

### Task 2: Drift on the pane

**Files:**
- Modify: `Maugham/Views/DiagnosticsPane.swift`
- Test: `MaughamTests/DiagnosticsPaneTests.swift`

**Contracts:**
- [ ] When `DriftDetector.drift` is non-empty for the shown run's doc, ONE line above the conformance summary: *“Your line may have moved — ‘<clause…>’ has strained three runs running. Draft’s right, or intent’s right?”* (truncate the quote on a word boundary; one line even for two findings — name the first, “and one more” for the rest; the register).
- [ ] Its action opens the Intent pane (`postDetailSegment(.intent)` — the existing drift-note affordance's successor).
- [ ] It is NOT a Diagnostic: no dismissal, no answer field; it disappears when the pattern breaks (the next run's history does that) — asserted.
- [ ] AX: the line is spoken with the clause quote; no counts beyond "three runs".
- [ ] Release build; flat DiagnosticsPaneTests; commit.

---

### Task 3: Bless converges — graduated is not dismissed

**Files:**
- Modify: `Maugham/Compiler/BibleStore.swift`, `Maugham/Views/BibleStratum.swift`, `Maugham/Compiler/AREA.md` (the door paragraph becomes the design)
- Test: `MaughamTests/BibleStoreTests.swift`, `MaughamTests/StatementPaneStrataTests.swift`, `MaughamTests/CompilerRunCommandTests.swift` (the composed bible-loop test — the final review's named gap)

**Interfaces — Produces:**
```swift
// BibleStore:
func markGraduated(subject: String, fact: String)      // called by graduate() AFTER rule succeeds, BEFORE dismiss
func isGraduated(subject: String, fact: String) -> Bool
// record(_:) drops candidates whose (subject, fact) dedupe key is graduated — same key spelling as dedupe (one function)
// graduated keys persist in the sidecar (per-device, additive field); dismissed-plain still keeps NO memory
```

**Contracts:**
- [ ] Bless → later run re-emits the same fact → it does NOT return to the stratum — `test_aBlessedFactDoesNotComeBack`.
- [ ] Plain dismiss → re-emit → RETURNS (spec §3.3 unchanged) — both directions in one file, adjacent, each naming the other.
- [ ] Revoking the ruling does NOT resurrect bible emission automatically (the graduated key stays; a revoked ruling is a decision made and unmade by the writer, not a return ticket — doc-comment; if smoke says otherwise it is one delete).
- [ ] **The composed bible-loop test** (the named gap): run 1 emits a fact → stratum shows it → bless (real graduate through the mounted control, the Stage-1 machinery) → run 2 re-emits → not double-briefed (the prompt's bible section omits it; the derived clause from the ruling is the only appearance) and not re-shown. Falsify by removing the record() suppression.
- [ ] AREA.md's door paragraph replaced by the shipped design + the test's name.
- [ ] `./gen.sh`; flat runs; commit.

---

### Task 4: Streaming — sections as they arrive

**Files:**
- Modify: `Maugham/Compiler/ClaudeCLISession.swift`, `Maugham/Compiler/CompilerRunner.swift`, `Maugham/Compiler/CompilerOrchestrator.swift`, `Maugham/Views/DiagnosticsPane.swift`
- Test: `MaughamTests/ClaudeCLISessionTests.swift`, `MaughamTests/CompilerRunCommandTests.swift`, `MaughamTests/DiagnosticsPaneTests.swift`

**Spiked reality (2026-08-08, scratchpad probe):** `--include-partial-messages` with the existing stream-json flags emits `{"type":"stream_event","event":{"type":"content_block_delta","delta":{...}}}` lines mid-turn (first ~4s, ~20 deltas on a trivial turn). The session adds the flag and a delta path; capture ONE real event fixture during implementation for the fake CLI.

**Interfaces — Produces:**
```swift
// CompilerRunner gains (additive, default no-op so every existing conformer/test compiles):
@MainActor func setPartialHandler(_ handler: (@MainActor (String) -> Void)?)   // accumulated-text chunks, generation-guarded
```

**Contracts:**
- [ ] The session forwards delta text through the handler ONLY for the live generation (a retired process's late deltas are dropped — the Task-5-of-M2 discipline extended, with a stale-delta planted test).
- [ ] Every EXISTING ClaudeCLISessionTests case passes UNMODIFIED (the additive bar).
- [ ] The orchestrator accumulates chunks, splits on newlines, feeds complete lines to `parseSection` as they close, stores incrementally (conformance can render while the reader section is still generating); the final `result` runs `parseAll` as reconciliation over the full text and REPLACES the incremental state (one source of truth at turn end; incremental is preview — doc-comment) — `test_theFinalResultReconcilesTheStream`.
- [ ] Mid-stream cancel/toggle-off: incremental state discarded with the run (no half-report survives) — asserted.
- [ ] The pane renders sections as stored (the version-counter idiom already does this — assert rows appear across two bumps in one "run").
- [ ] The wait copy stays until the first section lands, then the report grows in place.
- [ ] `./gen.sh`; flat runs; Release build; commit.

---

### Task 5: Cold start, the deadline, and the close

**Files:**
- Modify: `Maugham/Views/DiagnosticsPane.swift`, `Maugham/Compiler/CompilerOrchestrator.swift`, `Maugham/Compiler/DeclaredWorldDeriver.swift`, `Maugham/Compiler/DiagnosticsStore.swift` (refusal memory), docs (`docs/guide/compiler.md`, `docs/roadmap.md`, `Maugham/Compiler/AREA.md`, spec §8 dated line)
- Test: `MaughamTests/DiagnosticsPaneTests.swift`, `MaughamTests/CompilerRunCommandTests.swift`, `MaughamTests/DeclaredWorldDeriverTests.swift`

**Contracts:**
- [ ] **The offer**: never-run doc whose manuscript is non-trivial (>1 paragraph — the discriminator from live paragraphs, not ops) → the pane's empty state offers *“I haven’t read this piece. Read it whole and take notes?”* with one Read button and one “Not now”. Refusal remembered per doc in the sidecar (additive field); the offer never re-renders for that doc (the pane shows plain never-run copy after) — nag-free asserted both directions. Reading = `runRequested` with first-run semantics (the marker-nil path that already treats everything as new — verify nothing special-cases; the offer is UI, not a new run kind).
- [ ] A doc ALREADY run never shows the offer (marker exists).
- [ ] **The derivation deadline**: 120s, matching the session's runTimeout and cited to the spike's 30s sonnet measurement (4× headroom) — a doc-comment carries both numbers; timeout → nil (the honest degrade path that already exists), process terminated (no orphan billing) — fixture test with an injected short deadline.
- [ ] Docs: the guide gains cold start + drift + streaming sentences (what ships); roadmap Stage 3 ✓ pending smoke, the second draft CLOSED pending Denver's full-loop smoke; the spec's §8 dated line; AREA.md coherence pass.
- [ ] CLOSING RUNS: full Mac suite (skip flag, tee), Core `swift test`, phone only if Core changed (expect not). Counts + discriminator.
- [ ] Release build; commit(s).

---

## Self-review notes

- Handoff's Stage 3 list → Task 1+2 (drift), 3 (bless + the named test gap), 4 (streaming), 5 (cold start + deadline + docs). Spec §4's drift copy verbatim in Task 2. The strip/pane one-spelling watch item: nothing here touches either spelling — noted, not tasked.
- Types: ClauseStatus (existing) → history (1) → DriftDetector (1) → pane (2); graduated keys (3); setPartialHandler (4).
- Five tasks, under the cap.
