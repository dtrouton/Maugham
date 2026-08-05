# M2 Plan 2 — the Author surfaces

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The compiler's context made visible and the writing posture completed: the pinned-reference union feeds the run AND a References pane, one pin promotes into an assistant column, and the intent strip keeps the signature in view.

**Architecture:** A pure `PinnedReferences` projection (links ∪ canvas bindings, resolved) consumed by three readers — the References pane, the assistant column, and `CompilerContext`'s listings (Task 7 of Plan 1 left them `[]`). The strip is a `safeAreaInset` twin of `EditorStatusFooter`. Spec: `docs/superpowers/specs/2026-08-04-m2-author-compiler-design.md` §6–§7. Written 2026-08-05 against the tree at the end of Plan 1 (`2bce9b3e`+ADRs); every signature below was read from that tree.

**Tech Stack:** Swift 6 / SwiftUI, XCTest. No new subprocess or MCP work.

## Global Constraints

- Same as Plan 1's (contracts not bodies; `./gen.sh` discipline; flat `-only-testing`; warm-build warning census; MaughamEvent-only posts; commit register; no push). Additionally:
- **Any `ProjectWindow.body` change → local Release build before reporting** (assistant column and strip both qualify).
- The strip renders the WRITER's words only (ADR 0027's identity invariant — nothing AI-produced in editor chrome).
- A widening of `RegionBinding.references` moves `list_canvas.piece_references` with it — the projection has one spelling and the MCP tool calls it (`RegionBindingTests.test_theProjectionHasAProductionCaller`); phone untouched.
- Subagent models: opus for tasks 2, 4, 5; sonnet for 1, 3, 6; reviewers haiku, sonnet for ProjectWindow-touching diffs.

## File Structure

```
Maugham/Compiler/PinnedReferences.swift        the union projection + resolution (new)
Maugham/Views/IntentStrip.swift                the strip (new)
Maugham/Views/ReferencesPane.swift             the shelf (new)
Maugham/Views/AssistantColumn.swift            the studied reference (new)
Maugham/Canvas/RegionBinding.swift             widened (card-level bindings)
Maugham/Compiler/CompilerEnvironment+Project.swift  listings wired
Maugham/Models/DetailSegment.swift + Persona.swift + Views/DetailPaneToggle.swift + MaughamApp.swift   .references registration
```

---

### Task 1: Widen the binding projection to card-level associations

**Files:**
- Modify: `Maugham/Canvas/RegionBinding.swift:48` (`references(forPiece:in:)`)
- Test: existing `RegionBindingTests` (+ new cases)

**Verified reality:** the projection filters regions on `boundPieceID == piece` and unions residents (`RegionBinding.swift:48-52`). Cards carry their own `CanvasNode.boundPieceID` (1C-c2a) which the projection ignores today. `list_canvas`'s `piece_references` calls this projection (M1A) — it moves with the widening, which is the point (one rule, all readers).

**Contracts:**
- [ ] A card whose OWN `boundPieceID` names the piece joins the set even when loose or resident in an unbound region — `test_aCardBoundByItself_isReferenced`.
- [ ] Union, dedupe: a self-bound card resident in a bound region appears once — `test_selfBoundResidentIsNotDoubled`.
- [ ] Residents-only rule for REGIONS unchanged (a visitor citation still excluded) — existing tests stay green untouched.
- [ ] An MCP-side test observing `piece_references` widen (find the `list_canvas` test that pins the projection's output and extend its fixture with a self-bound card).
- [ ] Run canvas + MCP suites; commit.

---

### Task 2: PinnedReferences — the union, resolved

**Files:**
- Create: `Maugham/Compiler/PinnedReferences.swift`
- Test: `MaughamTests/PinnedReferencesTests.swift`

**Interfaces — Produces:**
```swift
struct PinnedReference: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case research(itemId: String), palette(cardId: String), photo(path: String), scrap(nodeId: String) }
    let id: String        // stable across recomputation: the underlying id/path
    let kind: Kind
    let title: String     // real titles; a scrap's = first line of its text, truncated
}
enum PinnedReferences {
    static func pinned(forDocId: String, links: [String]?, scene: CanvasScene?,
                       resolveTitle: (String) -> String?) -> [PinnedReference]
}
```

**Verified reality:** linked research ids live on `StructureItem.links: [String]?` (`Packages/MaughamCore/Sources/MaughamCore/StructureItem.swift:36`); canvas residents resolve per node provenance (referenced `referenceId` / owned `ownedPath` / scrap text — read `CanvasNode` in `Maugham/Canvas/` for the exact fields before coding).

**Contracts:**
- [ ] Links resolve to research pins with real titles (`resolveTitle`); a dangling link id is dropped, not rendered as a raw id.
- [ ] Canvas set (Task 1's projection) resolves: referenced item → its kind (research/palette by id shape — find the discriminator the canvas itself uses; never reimplement it), owned → photo, scrap → scrap text pin.
- [ ] Dedupe across sources (an item both linked and on canvas appears once, canvas kind wins nothing — same pin).
- [ ] Deterministic order: linked first (manifest order), then canvas set sorted by title.
- [ ] `scene == nil` (no canvas / not Plan-initialized) degrades to links-only.
- [ ] Commit.

---

### Task 3: The compiler reads what the writer pinned

**Files:**
- Modify: `Maugham/Compiler/CompilerEnvironment+Project.swift` (production closures gain listing providers), `Maugham/Compiler/CompilerOrchestrator.swift:174` (context construction fills `pinnedListing`/`paletteListing`)
- Test: `MaughamTests/CompilerRunCommandTests.swift` (+ cases)

**Verified reality:** `CompilerContext` (`CompilerPrompt.swift:8`) already carries the listing fields; the orchestrator constructs it at `CompilerOrchestrator.swift:174` with `[]`; the prompt omits empty sections (Plan 1 Task 3, tested).

**Contracts:**
- [ ] `pinnedListing` = Task 2's pins as "title (id)" lines with the tool name they're fetchable by; `paletteListing` = `list_palette_cards`-shaped id+title lines — find the store's existing palette index rather than reading files.
- [ ] A run's prompt now carries the listings when non-empty (spy runner captures the message; assert section presence) and still omits them when empty — both directions tested.
- [ ] The listing provider closures follow the existing weak-capture discipline in `CompilerEnvironment+Project.swift:22-59` (window closed mid-run → nil → empty listing, honest not crashed).
- [ ] Cross-doc intent-hash note from Plan 1 (ledger): while in this file, key `previousIntentHash` per docId (the session outlives a doc switch) — the orchestrator already tracks per-doc state; verify and pin with `test_intentHashIsPerDocument_notPerSession`.
- [ ] Commit.

---

### Task 4: The intent strip

**Files:**
- Create: `Maugham/Views/IntentStrip.swift`
- Modify: `Maugham/Views/ProjectWindow.swift` (content column inset, Author-only)
- Test: `MaughamTests/IntentStripTests.swift`

**Verified reality:** `EditorStatusFooter` mounts via `.safeAreaInset(edge: .bottom, spacing: 0)` at `ProjectWindow.swift:974`; there is an EXISTING `.safeAreaInset(edge: .top)` at `:984` — read what owns it and compose (two top insets stack; order matters; the strip goes nearest the prose). Intent resolution: `statement(kind: .intent, scope: .document(docId))` piece-first, `.project` fallback — the identical spelling `CompilerEnvironment+Project.swift:54-59` uses; the strip and the compiler MUST read one spelling (extract a shared helper if none exists; do not write a third).

**Contracts:**
- [ ] Pure `IntentStrip.line(from statementText: String?) -> String?`: nil/empty → nil; skips markdown heading lines and blanks; first real line, truncated ~90 chars on a word boundary with ellipsis. One test per rule.
- [ ] No intent → NO strip (nil view, not an empty bar). Author persona only. Hidden in ⌘\ with the chrome (find the chrome-visibility flag the persona bar uses and ride it).
- [ ] The strip renders the writer's statement text only — its input is `statementText(of:)` output, nothing model-produced; assert the data path by construction (the view takes a `String`, and the only production caller passes statement text).
- [ ] Click opens the Intent pane at the strip's scope (`postDetailSegment(.intent)`; scope follows binder selection already — verify Intent pane's scope-follow behavior makes this true, and if Open-sets-scope machinery is needed, STOP and record: that is the reverted three-round M1A work, not a ride-along).
- [ ] Dimmed register: footnote size, `.secondary` at reduced opacity — match `EditorStatusFooter`'s values; hover reveals the affordance (underline on hover only).
- [ ] The strip updates when the statement changes (it reads through the statement Document's observation — find how IntentPane observes and mirror the cheapest correct signal; never poll).
- [ ] Release build; commit.

---

### Task 5: References pane + assistant column

**Files:**
- Create: `Maugham/Views/ReferencesPane.swift`, `Maugham/Views/AssistantColumn.swift`
- Modify: `Maugham/Models/DetailSegment.swift` (case `references`), `Maugham/Models/Persona.swift` (Author: after `.intent`; Review: available per the umbrella matrix), `Maugham/Views/DetailPaneToggle.swift`, `Maugham/MaughamApp.swift` (⌘⌥E), `Maugham/Views/ProjectWindow.swift` (the column), `Maugham/Stores/UIState.swift` (column width, additive-defaulted, NO schema bump), `MaughamTests/PersonaPaneRegistryTests.swift`, `MaughamTests/DocSyncTests` guide rows
- Test: `MaughamTests/ReferencesPaneTests.swift`, `MaughamTests/AssistantColumnTests.swift`

**Contracts:**
- [ ] Registration: the same four exhaustive switches + canonical order + matrix + ⌘⌥E View-menu binding + guide rows (`docs/guide/reference.md`, `right-pane.md`) — the Task 8 (Plan 1) commit is the worked example; `Persona.swift:146-147`'s reservation comment loses `.references`.
- [ ] Pane rows: thumbnail (photos via the canvas's existing `CGImageSource` downsampling path — REUSE `Maugham/Canvas/`'s cache, tripwire-22-keyed by path; never a second loader), kind glyph, title. Empty state: "Nothing pinned yet." + one sentence naming the two ways in (link research, cluster on the canvas) — tripwire 15 frame chain.
- [ ] Click a pin → assistant column with that ONE item between binder and editor; click again or promote another → back/replace. Esc dismisses. Width persisted in `UIState` (additive field, decode-defaulted; extend `test_everyFieldSurvivesTheHandWrittenEncoder`).
- [ ] The column renders: research note → the existing preview surface (find `ResearchNotePreviewPane`'s reusable core); palette card → its read view; photo → fit image; scrap → text at reading size. REUSE existing renderers — a second markdown renderer is the defect `MarkdownBlockParser` exists to prevent.
- [ ] The centred writing column yields width only while the column exists (the ⌘\ and focus-mode interactions: the column hides with chrome — assert with the same flag as Task 4).
- [ ] `ProjectWindow.body` stays under the type-checker ceiling: extract a `ViewModifier` (the file's own pattern); Release build mandatory.
- [ ] Commit.

---

### Task 6: Docs, roadmap, and the milestone's own record

**Files:**
- Modify: `docs/guide/compiler.md` (+ strip/references sections — they SHIP now), `docs/guide/reference.md`, `docs/roadmap.md` (M2 entry: loop + surfaces, pending smoke), `CLAUDE.md` (Compiler area row updated: strip/references), `Maugham/Compiler/AREA.md` (PinnedReferences seam), `docs/superpowers/specs/2026-08-04-m2-author-compiler-design.md` (§6.3's no-posture finding: add the dated "built as designed" line; §10 sequencing note that surfaces landed same branch)
- Test: `DocSyncTests` + `HelpTopicIndexTests` green

**Contracts:**
- [ ] Docs describe what ships, no prose counts over lists, `count the tests` register.
- [ ] The ledger's deferred minors that are DOC-shaped get their sentences (the promoted task's frozen intent excerpt — one guide line).
- [ ] Full Mac suite (with the skip) + MaughamCore `swift test`; the clock-flake discriminator on any red; commit.

## Self-review notes

- Spec §6.1 (strip), §6.2 (references/assistant), §7 (union + resolution + widening), §3.3's listing wiring → Tasks 1–5; §6.3 posture-none is already recorded in the spec and Task 6 dates it. Streaming rows, session-retirement header word, I3 polish: deliberately NOT here — deferred with reasons in the ledger.
- Names cross-checked: `PinnedReference(s)` (2→3→5), `IntentStrip.line` (4), `.references` (5), listings (3).
