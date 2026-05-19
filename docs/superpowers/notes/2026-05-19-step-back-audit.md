# Step-Back Audit — 2026-05-19

**Context:** Three editor races in 24 hours (cursor jump on trailing-space autosave, async cursor restore racing key events, SwiftUI binding loop reading stale documentText) plus a build of new infrastructure (op log) prompted user to call a pause for an architecture / quality / maintainability check before pushing on.

## Backlog as captured at this point

### Foundational follow-ups from shipped milestones
- `ParagraphParser` trims trailing whitespace inside paragraphs → on-disk data loss when user types and pauses with a trailing space. Cursor symptom fixed; data-loss twin still live. ~1 commit.
- First MCP call after Maugham restart still flaky after three rounds of patches. User-deferred (memory: `project_deferred_mcp_first_call.md`).
- PDF / audio research items error in MCP `read_document`. Image envelope plumbing is in place; adding them is a focused change.
- `ShingleMatcher` rename to `overlapCoefficient` was correct; the third fallback tier (char-bigrams) added late in T16 lives in `RenderFilter`, not `ShingleMatcher`. Worth folding back.

### Carry-forwards from older milestones
- Cross-Mac re-link UI for Collection references (ADR 0009)
- "Split loose piece into project" beyond context menu (File menu item)
- Bidirectional research↔manuscript links + outline drag-reorder + regex/multi-line search
- MCP id-prefix mix cleanup, search/graph perf ceiling, link/unlink discoverability

### Next major features (sketched, not specced)
- **Editing** — annotation schema (suggested_change / comment / query / craft_note), accept/reject UX, the membrane between Claude's annotation layer and the manuscript. Op-log foundation now in place.
- **`craft_principles.md`** — project-local durable craft norms, loaded on session start. User flagged this should ship as the *foundation* before the full editing milestone.
- **Compile / typesetting** — LaTeX through pandoc, design specs as version-controlled artifacts, per-target compile (paperback / EPUB / etc.), preview-compile for visual design conversations.
- **History-pane forensic view** — burst-level scrub on top of the checkpoint browser that shipped.

## Architectural concerns worth scrutinising

1. **EditorHost ↔ EditorCoordinator ↔ EditorSurface integration** is now its third version in a week. Current shape (`$documentText` + `onChange`) looks correct but grew through bug-driven evolution. Fresh-read question: "is this what we'd write today knowing what we know now?"

2. **Three large accreting files**: `ProjectStore.swift` (2700+ lines), `EditorCoordinator.swift` (700+), `DocumentStore.swift` (587). None pathological yet, all doing multiple jobs. ProjectStore especially has accreted Collection logic, search state, trash, word-count cache, wiki-link resolution, etc.

3. **RenderFilter has three ID-matching tiers** (exact → shingle → char-bigram). Third tier added late as a fix. Tiering may not be the cleanest abstraction.

4. **OpLog ↔ Editor integration is brand new and had three race bugs in 24 hours.** Fixes are correct but the structural pattern (heavy work in a synchronous binding setter) was a smell the design didn't catch. Check nothing else in the new code has the same shape.

5. **No editor integration tests.** 706 unit tests; the bugs hit lived in the binding-and-NSTextView interaction layer that's not really exercised by the suite. User found them by typing; suite was always green.

6. **Concurrency warnings** were just cleaned up; probably not the last batch. Worth a sweep before they accumulate.

## Plan — two passes, both lightweight

### Pass 1 — Codebase walk-through (this exercise)
A few hours, no implementation. Read major files end-to-end with notes:
- What does each unit do?
- Where are the boundaries fuzzy?
- What surprises me?
- What looks structurally risky vs imperfect-but-fine?

**Output:** a 1–2 page "state of the code" summary (not a refactoring plan — observations). Dispatched as parallel subagents for read scope, synthesized at the end.

### Pass 2 — Targeted brainstorm
Pick the 2–3 things from pass 1 that genuinely need addressing vs imperfect-but-fine. Each gets the brainstorm → spec → plan flow scoped tight. Output: a small set of refactoring milestones interleaved with the feature work — not "stop everything and refactor."

## Subagent dispatch plan for pass 1

Two parallel general-purpose subagents on opus, with disjoint scopes:

**Subagent A — Editor + OpLog layers**
- `Maugham/Views/EditorHost.swift`
- `Maugham/Editor/EditorSurface.swift`
- `Maugham/Editor/EditorCoordinator.swift`
- `Maugham/Editor/ProseMode.swift`, `ScreenplayMode.swift`, `WritingMode.swift`, `WritingModeFactory.swift`
- `Maugham/Editor/Fountain/*`
- `Maugham/Editor/Tokenizer/*`
- `Maugham/Editor/RenderFilter.swift`
- `Maugham/Editor/ScreenplayLayoutManager.swift`
- `Maugham/Editor/FocusFinder.swift`
- `Maugham/OpLog/*`

**Subagent B — Stores, MCP, Views**
- `Maugham/Stores/DocumentStore.swift`
- `Maugham/Stores/ProjectStore.swift`
- `Maugham/Stores/*` (smaller stores)
- `Maugham/Models/*`
- `Maugham/MCP/*`
- `Maugham/Views/ProjectWindow.swift`
- `Maugham/Views/Collection*`
- `Maugham/Views/*Pane.swift`, `*Sheet.swift`
- `maugham-mcp/JSONRPCBridge.swift`
- `MaughamTests/` (test coverage gap analysis)

Each returns:
- Per-unit summary: what it does, surface area, dependencies, fitness for purpose
- Boundary observations: where responsibilities are fuzzy, where a refactor would have leverage
- Structural risks: places where small changes could trigger surprises
- Test coverage gaps: what isn't exercised
- Quality flags: dead code, naming inconsistencies, parking-lot comments, anything fishy
