# Second Draft Plan 1 — the declared world

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The writer's declared world becomes real: rulings as an op-logged stratum of the statement, Claude-derived clauses/rules as a hash-keyed cache, and the Intent pane's three strata with bless/correct/revoke — all provable without touching the run.

**Architecture:** A pure `RulingsSection` parser in MaughamCore (the `PaletteCardParser` precedent — forgiving rendering over writer-editable markdown); a `DeclaredWorldDeriver` behind a seam (the `CompilerRunner` pattern) writing a per-device derivation cache; a `BibleStore` sidecar (per-device, disposable) whose entries graduate to rulings only through explicit writer acts; `StatementPane` grows the strata. Spec: `docs/superpowers/specs/2026-08-07-compiler-second-draft-design.md` §3. Spike evidence (derivation quality + costs): `docs/superpowers/notes/2026-08-07-second-draft-spike.md`.

**Tech Stack:** Swift 6 / SwiftUI, XCTest, one-shot `claude -p` for derivation (same confinement flags as the compiler).

## Global Constraints

- Contracts and verified signatures, never function bodies (`memory/feedback_plan_code_is_a_liability.md`).
- **`StatementEditorHost.swift` has produced three Criticals and four Importants** — every one a value trusted after the thing it described moved. Any task touching it must ask "what does this change make newly possible?" as its own step (the 2026-08-01 handoff's rule).
- The membrane (spec §3.4): nothing enters the writer-owned layer except bless / correct / rule / the writer's own editing. Claude's derivations live only in caches that decay. A planted-offender test proves no automatic path exists.
- Statements stay human-readable markdown; every derived store under `.maugham/`, per-device (`DeviceSlug` filename builders, tripwire 24), corrupt-reads-as-empty.
- `./gen.sh` discipline; flat `-only-testing`; warm-build warning census; Release build for view-touching tasks; commit register per `git log --oneline -10`; **no push**.
- MaughamCore changed ⇒ run BOTH schemes + `cd Packages/MaughamCore && swift test`.
- Subagent models: opus for tasks 2, 4, 6; sonnet for 1, 3, 5, 7; reviewers haiku, sonnet where a task touches StatementPane/Host or concurrency.

## File Structure

```
Packages/MaughamCore/Sources/MaughamCore/RulingsSection.swift    pure parser/renderer (new)
Maugham/Compiler/DeclaredWorld.swift          Clause/Rule/DerivedWorld models + cache store (new)
Maugham/Compiler/DeclaredWorldDeriver.swift   seam + one-shot CLI derivation (new)
Maugham/Compiler/BibleStore.swift             facts cache, per-device sidecar (new)
Maugham/Compiler/RulingPerformer.swift        rule/bless/correct/revoke writes (new)
Maugham/Views/StatementPane.swift             the three strata (modify)
MaughamTests/ + Packages/MaughamCore/Tests/   one test file per new source file
```

---

### Task 1: RulingsSection — the parser that forgives

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/RulingsSection.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/RulingsSectionTests.swift`

**Interfaces — Produces:**
```swift
public struct Ruling: Equatable, Sendable, Identifiable {
    public let id: String          // stable digest of the line's text (no minted ids in the file)
    public let text: String        // the writer's sentence
    public let ruledOn: Date?      // parsed from the provenance suffix when present
    public let provenance: String? // the free suffix after the em-dash, verbatim
}
public enum RulingsSection {
    public static let heading: String                    // "## Rulings"
    public static func parse(_ markdown: String) -> (essay: String, rulings: [Ruling])
    public static func render(essay: String, rulings: [Ruling]) -> String
    public static func appending(_ ruling: String, provenance: String, on: Date, to markdown: String) -> String
    public static func removing(rulingId: String, from markdown: String) -> String
}
```

**Consumes:** `PaletteCardParser` (`Packages/MaughamCore/Sources/MaughamCore/PaletteCard.swift:109`) as the forgiving-parser precedent — read its section-detection discipline AND its known F-A footgun (a body line spelling a heading is claimed by section detection; the roadmap carries the fix shape: promote to a section only when blank-delimited after the first real heading). Do not reimport that bug.

**Contracts (TDD, red first):**
- [ ] `parse` on a statement with no Rulings section → whole text is essay, empty rulings.
- [ ] `parse` finds `## Rulings` only when blank-delimited (the F-A lesson) — a body line quoting the heading stays essay: `test_aBodyLineSpellingTheHeadingStaysProse`.
- [ ] List items parse: text, optional `— ruled <date>, <provenance>` suffix; a hand-written bare line (`- Kelly never lies`) parses with nil date/provenance — hand edits are legal: `test_handWrittenRulingsAreLegal`.
- [ ] `appending` creates the section (blank-delimited) when absent; appends one line when present; round-trips through `parse`.
- [ ] `removing` by id deletes exactly one line; unknown id is a no-op returning the input unchanged.
- [ ] Byte-fidelity: `render(parse(x))` == x for files this code wrote; for hand-edited files, parse→render is idempotent from the second pass (the palette convergence rule): `test_handEditsConvergeBySecondRender`.
- [ ] Ruling ids are stable across re-parses (digest of text) and collide only when text is identical — assert two identical lines get disambiguated by index: `test_duplicateRulingLinesRemainIndividuallyRemovable`.
- [ ] `cd Packages/MaughamCore && swift test`; then BOTH schemes build+test (Core changed); `./gen.sh` first. Commit.

---

### Task 2: DeclaredWorld models + the derivation cache store

**Files:**
- Create: `Maugham/Compiler/DeclaredWorld.swift`
- Test: `MaughamTests/DeclaredWorldStoreTests.swift`

**Interfaces — Produces:**
```swift
struct DerivedClause: Codable, Equatable, Sendable { let quote: String; let check: String }
struct DerivedRule: Codable, Equatable, Sendable { let subject: String; let quote: String; let constraint: String }
struct DerivedWorld: Codable, Equatable, Sendable {
    let sourceHash: String          // SHA256 of the statement text it was derived from
    let clauses: [DerivedClause]
    let rules: [DerivedRule]
    let derivedAt: Date
}
@Observable @MainActor final class DeclaredWorldStore {
    private(set) var version: Int
    func cached(forScopeKey: String, sourceHash: String) -> DerivedWorld?   // nil when absent OR hash mismatch
    func store(_ world: DerivedWorld, forScopeKey: String)
    func invalidate(forScopeKey: String)                                    // revoke/edit path calls this
    static func sidecarURL(projectRoot: URL, scopeKey: String, device: DeviceSlug) -> URL
        // .maugham/derived/<scopeKey>.<slug>.json — tripwire 24 at the filename point
}
```

**Consumes:** `DiagnosticsStore` (`Maugham/Compiler/DiagnosticsStore.swift`) as the sidecar-store precedent — same corrupt-reads-as-empty, same version-counter idiom, same per-device layout. The scopeKey is the statement's scope spelled as a filename-safe token (define one spelling; Task 4's performer and Task 6's pane both use it).

**Contracts:**
- [ ] Hash-gate: `cached` returns nil when sourceHash differs — a stale derivation can never be served: `test_aChangedStatementInvalidatesTheCache`.
- [ ] Round-trip, corrupt-reads-as-empty, per-device filename, version bumps — the four `DiagnosticsStoreTests` shapes, re-asserted here (copy the discipline, not the file).
- [ ] `invalidate` removes the entry and bumps version.
- [ ] `./gen.sh`; `-only-testing:MaughamTests/DeclaredWorldStoreTests`; commit.

---

### Task 3: DeclaredWorldDeriver — the seam and the one-shot derivation

**Files:**
- Create: `Maugham/Compiler/DeclaredWorldDeriver.swift`
- Test: `MaughamTests/DeclaredWorldDeriverTests.swift`

**Interfaces — Produces:**
```swift
protocol WorldDeriver: AnyObject {
    @MainActor func derive(statementText: String) async -> DerivedWorld?   // nil = derivation failed (honest, non-fatal)
}
@MainActor final class ClaudeWorldDeriver: WorldDeriver {
    init(model: String, cliOverride: URL?, isEnabled: @escaping () -> Bool)
    static let derivationSchemaDescription: String   // the wire shape; tests pin prompt AND parser to it (Task 3 owns both sides here, unlike the split in M2)
}
```

**Consumes:** `ClaudeCLISession.locateCLI`/spawn-argument conventions (`Maugham/Compiler/ClaudeCLISession.swift`) — but this is a ONE-SHOT `claude -p` per derivation (no warm session, no MCP config: derivation needs no tools — spawn with `--tools ""` and NO `--mcp-config`, strictly less capable than the compiler). The spike's derivation prompt (`docs/superpowers/notes/2026-08-07-second-draft-spike.md` and the scratchpad script it cites) is the starting text: verbatim-quote clauses, "do not invent standards the writer did not state".
- `UserPreferences.mcpEnabled` governs the spawn (the one toggle, ADR 0028).

**Contracts:**
- [ ] Fake-CLI fixture tests (the Task-5-of-M2 pattern, no network): well-formed output → DerivedWorld with sourceHash stamped by the CALLER-visible contract (derive returns clauses/rules; the store call site stamps hash — decide and pin where the hash is computed, one place).
- [ ] Fenced and bare JSON both parse; garbage → nil, never throws.
- [ ] Toggle off → nil before spawn: `test_theToggleGovernsDerivationToo`.
- [ ] Empty/whitespace statement → nil WITHOUT spawning (absence mints nothing, and no tokens are spent deriving nothing): `test_anEmptyStatementSpawnsNothing`.
- [ ] The spawn arguments carry `--tools ""` and NO `--mcp-config`: `test_derivationIsMoreConfinedThanTheCompiler` (assert both).
- [ ] One LIVE probe against the real CLI (haiku, the real prompt, a two-sentence fixture intent) run ONCE and its output pasted into the report — the spike proved sonnet on real prose; this proves the shipped prompt still parses end-to-end. Not a repeating test.
- [ ] `./gen.sh`; flat run; commit.

---

### Task 4: RulingPerformer — rule, bless, correct, revoke

**Files:**
- Create: `Maugham/Compiler/RulingPerformer.swift`
- Test: `MaughamTests/RulingPerformerTests.swift`

**Interfaces — Produces:**
```swift
@MainActor enum RulingPerformer {
    static func rule(_ text: String, provenance: String, forScope: Statement.Scope,
                     store: ProjectStore) async throws
    static func revoke(rulingId: String, forScope: Statement.Scope, store: ProjectStore) async throws
    static func edit(rulingId: String, newText: String, forScope: Statement.Scope, store: ProjectStore) async throws
    // bless/correct are `rule` with provenance derived from the bible entry — no separate verbs on the wire
}
```

**Consumes:** `ProjectStore.statement(kind:scope:)` (`Stores/ProjectStore+Statements.swift:145`), `createStatement` (`:187`), `appendToStatement` (`:267`), `lockStatementOpen` (`:124`); `RulingsSection` (Task 1); `IntentAppendPerformer` (`Maugham/Compiler/IntentAppendPerformer.swift`) as the op-logged outside-writer precedent — **and its replacement**: the performer this task builds SUPERSEDES the shipped free-text append; `IntentAppendPerformer` is deleted in this task, its tests migrated to the new shapes (the census question: grep its callers first; DiagnosticsPane's reply field is Stage 2's concern — if the pane still calls it, leave a thin deprecation shim that routes to `rule` and mark it for Stage 2 removal, recorded in the report).

**Contracts:**
- [ ] `rule` writes ONE Rulings line through the op log (assert a real op; assert the on-disk markdown gained exactly the rendered line), minting the statement via `createStatement` when absent.
- [ ] `revoke` removes exactly the line; `edit` = remove + append in ONE undo step (read ADR 0023's manual-group conventions; assert one ⌘Z restores).
- [ ] Every mutation calls `DeclaredWorldStore.invalidate` for the scope — the derivation cache can never outlive the prose it read: `test_aRulingInvalidatesTheDerivation`.
- [ ] **The membrane planted offender**: assert by construction there is NO API accepting a `DerivedClause`/`DerivedRule`/bible entry that writes a statement — the only write inputs are `String` text from the caller (the writer's words). The planted variant adds such an API name to a census list and the census fails: `test_nothingDerivedCanWriteItself` (grep-census over RulingPerformer's public surface + a control).
- [ ] Unreadable statement → typed refusal, nothing written (must #1).
- [ ] `./gen.sh`; flat run + re-run `IntentAppendPerformerTests`' successors; commit.

---

### Task 5: BibleStore — the cache that decays

**Files:**
- Create: `Maugham/Compiler/BibleStore.swift`
- Test: `MaughamTests/BibleStoreTests.swift`

**Interfaces — Produces:**
```swift
struct BibleFact: Codable, Equatable, Sendable, Identifiable {
    let id: String                 // ULID
    let subject: String            // "Kelly"
    let fact: String
    let establishedAt: String?     // ¶id
    let docId: String
    let recordedAt: Date
}
@Observable @MainActor final class BibleStore {
    private(set) var version: Int
    func facts(subjects: Set<String>) -> [BibleFact]     // the run's slice (Stage 2 consumes)
    func allFacts() -> [BibleFact]                        // the pane's stratum
    func record(_ candidates: [BibleFact])                // dedupe by (subject, fact) case-insensitive
    func dismiss(_ id: String)
    static func sidecarURL(projectRoot: URL, device: DeviceSlug) -> URL   // .maugham/bible.<slug>.json
}
```

**Contracts:**
- [ ] The DiagnosticsStore discipline again: round-trip, corrupt-empty, per-device, version.
- [ ] `record` dedupes on (subject, fact) so re-running over the same delta cannot double the ledger: `test_reindexingIsIdempotent`.
- [ ] `dismiss` removes; a re-`record` of the same fact CAN return (it's a reading, spec §3.3) — asserted, with the message saying it is intended.
- [ ] Project-scoped (one file, not per-doc) — facts carry their docId; `facts(subjects:)` filters by subject only. (Cross-piece aggregation is out of scope per spec §9 — the SLICE is by subject, and the pane's stratum for a piece shows facts whose docId matches; assert both filters.)
- [ ] `./gen.sh`; flat run; commit.

---

### Task 6: StatementPane — the three strata

**Files:**
- Modify: `Maugham/Views/StatementPane.swift` (+ `StatementEditorHost.swift` only if unavoidable — see constraint), `Maugham/Views/ProjectWindow.swift` (wiring the two new stores, the `CanvasModel` ownership pattern)
- Test: `MaughamTests/StatementPaneStrataTests.swift`

**Interfaces — Consumes:** `RulingsSection.parse/render` (Task 1), `DeclaredWorldStore` (Task 2), `RulingPerformer` (Task 4), `BibleStore` (Task 5).

**Contracts:**
- [ ] The essay editor edits ONLY the essay half: the pane splits via `RulingsSection.parse`, the editor binds the essay, and saves recompose via `render` — **ask the mandated question in the report: what does splitting the bound text make newly possible?** (Known answer to rule out: a save race where the editor's essay overwrites a ruling landed mid-edit by an answer from the run — Stage 2's flow. The recomposition must read the CURRENT rulings at write time, not the parse-time snapshot: `test_aRulingLandedMidEditSurvivesTheEssaySave` — this is this task's hardest test and the reason StatementEditorHost's history is in the constraints.)
- [ ] Rulings stratum: itemized rows (text, date, provenance), edit and revoke on the row, one undo step each, empty state absent (no section → no stratum header, not an empty list).
- [ ] Bible stratum: visibly provisional register (derived styling — dimmer, no writer-ink styling; pick values from the canvas's Claude-tint precedent and cite them), establishing-¶ shown, bless/correct/dismiss actions calling Task 4/5's verbs; empty state absent.
- [ ] Bless lands as a ruling with provenance "blessed from the bible, <date>" and the fact leaves the bible stratum (it graduated — assert both halves).
- [ ] Tripwires 9/15 as applicable; version-counter re-render tests for both new stores.
- [ ] RELEASE build (ProjectWindow + pane surface); `./gen.sh`; flat runs incl. existing `StatementPaneTests`; commit.

---

### Task 7: Docs + the derivation trigger decision

**Files:**
- Modify: `Maugham/Compiler/AREA.md`, `docs/guide/compiler.md` + `docs/guide/` intent topic, `docs/roadmap.md` (second-draft entry, stage 1 ✓ pending smoke), `docs/adr/0027-...md` (the §3.4 bible paragraph)
- Create: nothing
- Test: `DocSyncTests`/`HelpTopicIndexTests` green

**Contracts:**
- [ ] **The derivation trigger is decided and recorded here** (the one wiring question Stage 2 needs answered): derivation runs lazily — the first consumer to find `cached == nil` for the current hash triggers `derive` (the pane's conformance-preview if open, else Stage 2's run). NO background derivation, no derive-on-save (on-demand only, constitution). AREA.md states it; the guide's intent topic gains the Rulings section's writer-facing sentence (how to write a rule; that hand-editing the file is legal).
- [ ] ADR 0027 gains the derived-bible paragraph (spec §3.4's shape: persistent cache of readings, subordinate stratum, never truth until blessed).
- [ ] Roadmap: stage 1 entry, stages 2–3 open; the shipped answer-append flow marked superseded.
- [ ] Docs describe what ships (strata + derivation cache; the RUN still speaks the old contract until Stage 2 — say so plainly).
- [ ] Full Mac suite (with the MCP skip) + Core `swift test` + phone scheme (Core changed in Task 1); commit.

---

## Self-review notes (run at write time)

- Spec §3.1→Tasks 1-3, §3.2→Tasks 1+4, §3.3→Tasks 5+6, §3.4→Task 4's planted offender + Task 7's ADR, §8 stage 1 boundary held (no run changes; Stage 2 owns §5). The §4 experience rows that belong to stage 1 (see/revoke/bless) are Task 6's contracts.
- Type consistency checked: `DerivedWorld` (2→3→6/7), `Ruling` (1→4→6), `BibleFact` (5→6), scopeKey spelling (2→4→6).
- No placeholders; test names concrete; models per Global Constraints.
