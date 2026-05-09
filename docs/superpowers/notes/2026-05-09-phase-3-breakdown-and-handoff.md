# Phase 3 Plan + Session Handoff

**Date:** 2026-05-09
**Status:** Phase 1 + 2 shipped (milestones 1a–2c tagged on `main`) plus a 2d hot-patch. 275 tests passing. This note records the Phase 3 decomposition AND the context a fresh Claude session needs to pick up the work.

**Who this is for:** A new Claude session starting Phase 3 implementation. Read this doc end-to-end before doing anything. Do not skim.

---

## TL;DR — What you should do first

1. Read this whole doc (~10 min).
2. Skim `docs/superpowers/specs/2026-05-07-maugham-master-design.md` Section 2 (the editor architecture) — that's the source of truth for screenplay behavior.
3. Read `Maugham/Editor/ScreenplayMode.swift` — it's the stub you'll be replacing.
4. Pick the first sub-milestone (3a per the recommendation below) and start the **brainstorm → spec → plan → subagent-driven execute** cycle.
5. Tag your milestones as `milestone-3a`, `milestone-3b`, `milestone-3c`, `milestone-3d` and push.

You will need every workflow skill the previous milestones used: `superpowers:brainstorming`, `superpowers:writing-plans`, `superpowers:subagent-driven-development`. These are the user's preferred flow.

---

## Phase 3 per master spec

From `docs/superpowers/specs/2026-05-07-maugham-master-design.md`:

> **Phase 3 — Screenplay parity (basic)**: ScreenplayMode full — Fountain parser, auto-format, Tab/Enter cycling, character autocomplete, scene navigator, page count.

This is the screenwriting milestone. The editor's ScreenplayMode currently exists as a stub (just monospace plain text, no parser). Phase 3 turns Maugham into a real screenwriting tool comparable to (a small subset of) Final Draft.

### What's already done

The Phase 1+2 base gives Phase 3 a lot of free machinery:
- `ScreenplayMode` already conforms to `WritingMode` (1d). Just needs implementation.
- `WritingModeFactory.mode(for:)` already routes `.fountain` files to ScreenplayMode (1d).
- The Screenplay project type creates `manuscript/01-screenplay.fountain` on disk (1d).
- The editor pipeline (NSTextView, theme, typography, focus chrome, autosave, conflict detection) is mode-agnostic and works as-is for screenplay.
- Per-project typography lets Screenplay projects default to JetBrains Mono.

### What's left for Phase 3

Six work items per master spec:

1. **Fountain parser** — text → tokenized scenes / characters / dialogue / parentheticals / action / transitions / centered text.
2. **Auto-format / styling** — render each Fountain element with the right typography:
   - Scene headings: ALL CAPS, bold, sometimes underlined
   - Characters: CENTERED ALL CAPS
   - Dialogue: indented (~12 chars from left) with narrower column
   - Parentheticals: indented further, italic
   - Action: full-width plain
   - Transitions: right-aligned ALL CAPS
3. **Tab/Enter cycling** — pressing Tab on a line cycles its element type (Action → Character → Dialogue → ...). Pressing Enter at end-of-line follows screenplay flow conventions.
4. **Character autocomplete** — when the cursor is on a Character line, suggest names from previously-used characters in the script.
5. **Scene navigator** — a binder-replacing or binder-supplementing pane that lists all scenes (sluglines) with click-to-jump. For Screenplay project types, this might replace the manuscript binder entirely.
6. **Page count** — calculate pages using Final Draft's classic formula (1 page ≈ 55 lines of monospaced text at the configured page width). Display somewhere (goal indicator extension? new metric in InspectorView?).

---

## Recommended sub-milestone decomposition

Phase 3 is too big for one milestone (~35 tasks). Decompose into four (originally three; expanded to four during 3a brainstorm to give multi-file screenplay its own slot):

### 3a — Fountain foundation + styling

**Scope:** Fountain parser + per-element auto-format styling + page count. Ships a viewer/styler — the screenwriter sees their `.fountain` text formatted properly but still types it manually with brackets/colons/etc. (no Tab cycling yet).

**Deliverables:**
- `FountainTokenizer` (pure logic, ~15 tests covering each element type and edge cases)
- `ScreenplayMode.applyTypography` does real per-element styling (paragraph styles, indents, alignments, casing)
- `ScreenplayMode.metrics` returns page count alongside word count
- Goal indicator shows page count for screenplay projects

**Why first:** Foundation. Everything else builds on the parser. Also gives the writer immediate visual payoff — opening a Fountain file in Maugham now looks like a real screenplay instead of plain monospace.

**Estimate:** ~12-14 tasks.

### 3b — Editing UX (Tab/Enter cycling + character autocomplete)

**Scope:** Real screenwriting input experience. The user types a line, hits Tab, the line transforms into a Character / Dialogue / etc. Hit Enter, the next line's element type is inferred from screenplay flow rules.

**Deliverables:**
- `ScreenplayElement` enum (action, character, dialogue, parenthetical, scene, transition, centered)
- `ScreenplayCycle` pure logic mapping current element + Tab → next element
- `ScreenplayFlow` pure logic mapping current element + Enter → next-line element type
- NSTextView keystroke interception in EditorCoordinator (when mode is ScreenplayMode)
- Character autocomplete: track character names from prior dialogue blocks; popup completion when typing a Character line
- Inline element-type indicator in the gutter (optional)

**Why second:** Once the styler in 3a renders elements correctly, the user wants to type efficiently — and Tab/Enter cycling is the primary screenwriting input idiom.

**Estimate:** ~10-12 tasks.

### 3c — Scene navigator + title page + polish

**Scope:** Scene-by-scene navigation overlay for screenplays, plus the Fountain title page block, plus inline emphasis inside dialogue if capacity allows, plus the syntax help overlay.

**Deliverables:**
- `SceneNavigator` view: extracts sluglines from current Fountain text, lists them with INT./EXT., scene headings, and page numbers
- Click a scene → jumps cursor to that line
- For Screenplay project types: the manuscript binder pane segments to "Manuscript / Scenes" (similar to 2b's Manuscript / Research toggle)
- For Novel/Short Story: scene navigator hidden or disabled
- **Title page block** parsed (key-value pairs separated from body by blank line): `Title:`, `Credit:`, `Author:`, `Source:`, `Draft date:`, `Contact:`, `Notes:`. Rendered as a styled block at the head of the document; optionally mirrored in Inspector.
- **Inline emphasis** inside dialogue/action — `*italic*` and `**bold**` mid-line. Extends `inlineSpans` with `.italic` / `.bold` kinds. (May fall to Phase 4 if 3c gets squeezed.)
- **⌘? syntax help overlay** — keyboard shortcut surfaces a HUD-style popover showing the active mode's syntax reference (markdown or fountain). Source content is the committed `docs/markdown-syntax.md` / `docs/fountain-syntax.md` (added during 3a). Dismissed with Escape, click-outside, or another `⌘?`. The popover renders the markdown content via `NSAttributedString` with the editor's current theme colors. Mode-aware: prose docs show markdown reference; screenplay docs show fountain reference. Mirrors the existing `SaveFlashOverlay` pattern but as a longer-lived dismissible popover rather than an auto-fading flash.
- Optional: scene-by-scene word/page count summary in Statistics window (extends 2c's Words by Chapter to "Words/Pages by Scene" for screenplay projects)

**Why third:** Less load-bearing than 3a/3b. A screenwriter can absolutely use 3a+3b without a navigator (just scroll). 3c is polish + the discrete title-page feature.

**Estimate:** ~8-10 tasks.

### 3d — Multi-file screenplay

**Scope:** Optional multi-file structure for Screenplay project types — one `.fountain` per scene, similar to how Novel breaks into chapter files.

**Deliverables:**
- ProjectFactory creates a Screenplay project with optional multi-file vs single-file choice at creation time
- Manuscript binder shows the scene file list for multi-file Screenplay projects (mirrors Novel's chapter binder)
- DocumentStore loads each scene file as its own document; switching scenes loads the right file
- Page count sums across all scene files for the project-level goal indicator
- Migration: existing single-file Screenplay projects keep working unchanged (no forced migration)
- Tidy Filenames extends to multi-file Screenplay (already supports Novel; reuse the 2a primitives)

**Why fourth:** Architectural change. Touches binder, factory, store, page-count aggregation. Big enough to deserve its own milestone with focused testing. A solo screenwriter can ship a feature in a single `.fountain` without 3d; multi-file is for writers who prefer scene-per-file workflow (or for production refinement).

**Estimate:** ~7-9 tasks.

### Order recommendation

3a → 3b → 3c → 3d, sequentially. Each tags as a milestone. Total ~35 tasks across the phase.

After 3d the master spec's Phase 4 (Final Draft parity: scene numbers, dual dialogue, MORE/CONT'D, revisions, FDX import/export) is the next chunk — but the user may want to pause and use Phase 1+2+3 for actual writing before deciding.

---

## Out of scope for Phase 3

Listed for clarity; these are NOT in Phase 3 even if they relate to screenplay:
- FDX import/export (Phase 4)
- Scene numbers (Phase 4)
- Dual dialogue (Phase 4)
- Revisions / coloured pages (Phase 4)
- Compile UI (Phase 5)
- Snapshots (Phase 5)
- Bundled MCP server / Claude integration (Phase 6)

### Phase 2 leftover triage (already decided)

These were flagged as "out of scope" during 2c brainstorming. Re-triaged on 2026-05-09:

| Item | Decision | Rationale |
|---|---|---|
| Wiki-link rename propagation | **Done — milestone-2d** (already shipped) | Correctness bug, not a feature. Renames rotted body-text cross-references. Hot-patched before this handoff. |
| Search across documents | **Schedule as own milestone after Phase 3** | Foundational feature, not polish. Deserves its own brainstorm/spec/plan. Lands as `milestone-4-search` or in early Phase 4. (Note: `milestone-3d` is now taken by multi-file screenplay per the 3a brainstorm — see "Recommended sub-milestone decomposition" above.) |
| Tag rename / merge across documents | **Discarded** | Cheap to add but rare in practice; writers settle vocabulary early. Re-evaluate only if a real user complains. |
| Notes pane (`notes/` folder) | **Discarded** | Research browser already covers most use cases. Don't fragment user mental model on speculation. The `notes/` folder stays scaffolded; no UI. Re-evaluate only after sustained real-world usage surfaces a need. |
| Drag-research-into-editor | **Discarded for now** | Without inline-image rendering in NSTextView (Phase 5+), this would just insert text the user could type manually. Group with image-attachment work in a future phase. |

---

## Project state — what you're inheriting

### Tagged milestones

```
milestone-1a   Foundation: Welcome window, Recents, project create/open
milestone-1b   Editor: ProseMode, themes, Settings
milestone-1c   Focus chrome: centered column, typewriter, focus dimming, ⌘\, ⌘⇧F
milestone-1d   Three-pane window, binder, inspector, all four project types,
               per-project typography, ScreenplayMode stub
milestone-1e   DocumentStore + NSFileCoordinator/Presenter + 750ms autosave +
               conflict resolution + UI state persistence
               *** Phase 1 complete ***
milestone-2a   Binder polish: drag-reorder, Duplicate, Tidy Filenames
milestone-2b   Surfaces: Research browser (5 inline renderers), Conflict diff sheet
milestone-2c   Metadata + Metrics: Inspector growth (tags/word target/links + [[]] wiki),
               session tracking, Project Statistics window
               *** Phase 2 complete ***
milestone-2d   Hot-patch: wiki-link rename propagation. ProjectStore.renameStructureItem
               now rewrites [[oldTitle]] → [[newTitle]] in every other manuscript doc body.
```

Test count: **275 passing**. Build via `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`.

### Repo structure

```
Maugham/
├── Editor/                      ← all editor stuff
│   ├── EditorSurface.swift      ← NSViewRepresentable wrapping NSTextView
│   ├── EditorCoordinator.swift  ← NSTextViewDelegate + tokenize/style cycle
│   ├── WritingMode.swift        ← protocol; ProseMode + ScreenplayMode conform
│   ├── ProseMode.swift          ← prose Fountain parser + styling
│   ├── ScreenplayMode.swift     ← STUB — your job to flesh out for Phase 3
│   ├── Token.swift              ← token kinds (heading, emphasis, link, wikiLink, etc.)
│   ├── Tokenizer/MarkdownTokenizer.swift  ← prose tokenizer
│   ├── FocusFinder.swift        ← sentence/paragraph focus dimming logic
│   ├── SmartTypography.swift    ← --, ..., curly quotes
│   ├── WritingModeFactory.swift ← extension → mode mapping
│   └── EditorMetrics.swift      ← word count, char count, reading minutes
├── Models/                      ← project model + plain data types
│   ├── ProjectManifest.swift    ← project.maugham.json
│   ├── ProjectTargets.swift     ← totalWords + deadline
│   ├── StructureItem.swift      ← manuscript tree node (gained tags + links in 2c)
│   ├── ResearchItem.swift       ← research tree node (asset/group, 5 kinds)
│   ├── BinderSegment.swift      ← manuscript/research toggle (2b)
│   ├── GoalIndicatorState.swift ← bottom-right capsule state (2c)
│   ├── MaughamNotifications.swift  ← all NotificationCenter names
│   └── (...)
├── Stores/                      ← stateful types (mostly @MainActor @Observable)
│   ├── ProjectStore.swift       ← manifest + manuscript text + word-count cache
│   ├── DocumentStore.swift      ← single open document, NSFileCoordinator coordination,
│   │                              session tracking, sessions.json read/write
│   ├── ProjectFolderPresenter.swift  ← NSFilePresenter
│   ├── UIState.swift            ← .maugham/ui-state.json (v2 schema)
│   ├── ConflictState.swift      ← document conflict snapshot
│   ├── DebounceScheduler.swift  ← generic debounce
│   ├── RenamePlan.swift         ← multi-file rename validator (2a)
│   ├── LineDiff.swift           ← line diff for conflict view (2b)
│   ├── ResearchKindInference.swift  ← extension → AssetKind (2b)
│   ├── SessionLog.swift         ← session events with conflict-merge (2c)
│   ├── SessionTracker.swift     ← activity-bracketed session state machine (2c)
│   ├── WikiLinkProject.swift    ← protocol; ProjectStore conforms (2c)
│   ├── WikiLinkRewriter.swift   ← pure-logic [[oldTitle]] → [[newTitle]] (2d)
│   ├── ProjectFactory.swift     ← creates new projects on disk
│   ├── RecentsStore.swift       ← Recents list
│   └── FileNaming.swift         ← NN-prefix slug helpers
├── Views/                       ← all SwiftUI views
│   ├── ProjectWindow.swift      ← main three-pane window
│   ├── BinderView.swift         ← manuscript binder (left pane, manuscript segment)
│   ├── BinderRow.swift          ← row template; rename + draggable subtree split
│   ├── BinderPaneToggle.swift   ← Manuscript/Research segment (2b)
│   ├── ResearchView.swift       ← research pane (left, research segment)
│   ├── ResearchRow.swift
│   ├── ResearchPreview.swift    ← dispatches to per-kind renderer
│   ├── research/                ← per-asset-kind renderers
│   │   ├── ImagePreview.swift   ← NSImageView
│   │   ├── PDFPreview.swift     ← PDFKit
│   │   ├── TextPreview.swift
│   │   ├── AudioPreview.swift   ← AVKit
│   │   └── LinkPreview.swift    ← WKWebView
│   ├── EditorHost.swift         ← center pane; loads doc, drives EditorSurface
│   ├── InspectorView.swift      ← right pane; tags/target/links sections
│   ├── InspectorTagsField.swift ← chip field (2c)
│   ├── InspectorLinksSection.swift  ← links + backlinks (2c)
│   ├── InspectorResearchPanel.swift ← inspector for research segment (2b)
│   ├── ConflictBanner.swift     ← top-of-editor conflict notice
│   ├── ConflictDiffSheet.swift  ← side-by-side line diff (2b)
│   ├── GoalIndicatorView.swift  ← bottom-right capsule (2c-extended)
│   ├── SaveFlashOverlay.swift   ← ⌘S "Saved" flash
│   ├── ProjectSettingsSheet.swift  ← per-project typography
│   ├── HelpClaudeDesktopSheet.swift ← Claude Desktop config snippet
│   ├── AddResearchLinkSheet.swift  ← title+URL sheet (2b)
│   ├── DropIntent.swift         ← drag-drop position classifier (2a)
│   ├── ProjectStatisticsWindow.swift  ← new window scene (2c)
│   └── statistics/
│       ├── ProjectStatisticsView.swift
│       ├── ProjectTotalSection.swift
│       ├── DailyHeatmapSection.swift
│       ├── WordsByChapterSection.swift
│       └── RecentSessionsSection.swift
├── Preferences/                 ← user prefs (not project)
│   ├── UserPreferences.swift    ← @Observable singleton
│   ├── TypographySettings.swift
│   └── Theme.swift
├── MaughamApp.swift             ← App entry, scenes, command groups
└── (...)

MaughamTests/                    ← XCTest target — 265 tests
docs/superpowers/
├── specs/                       ← architectural design docs (committed)
│   ├── 2026-05-07-maugham-master-design.md  ← THE source of truth
│   ├── 2026-05-08-maugham-phase-2a-binder-polish-design.md
│   ├── 2026-05-08-maugham-phase-2b-surfaces-design.md
│   └── 2026-05-08-maugham-phase-2c-metadata-metrics-design.md
├── plans/                       ← per-milestone implementation plans
│   ├── 2026-05-08-maugham-phase-2a-binder-polish.md
│   ├── 2026-05-08-maugham-phase-2b-surfaces.md
│   └── 2026-05-08-maugham-phase-2c-metadata-metrics.md
└── notes/
    ├── 2026-05-08-phase-2-breakdown.md
    └── 2026-05-09-phase-3-breakdown-and-handoff.md  ← THIS FILE
```

### Build commands

```bash
# Regenerate Xcode project (xcodegen reads project.yml)
./gen.sh

# Run all tests
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1

# Build only (faster sanity check)
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3

# Run only specific test class
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/<ClassName> test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

---

## Workflow conventions established across 8 milestones

This codebase uses a tight loop: **brainstorming → writing-plans → subagent-driven-development**. Use `superpowers:` skills (loaded per-session). Don't deviate without good reason — the user has signed off on this process eight times.

### Per-milestone cycle

1. **Brainstorm** — `superpowers:brainstorming` skill. Spawns visual companion if there are layout/UI decisions. Ask one question at a time. Settle scope, hierarchy, behavior, edge cases. Save spec to `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`. Commit.
2. **Write plan** — `superpowers:writing-plans` skill. ~15-20 tasks each with full code blocks, no placeholders. Save to `docs/superpowers/plans/YYYY-MM-DD-<topic>.md`. Commit.
3. **Execute** — `superpowers:subagent-driven-development` skill. Dispatch fresh subagent per task. Read plan once, extract tasks, call subagents one at a time.
4. **Smoke + tag** — manual smoke test, fix what breaks, merge ff-only to main, tag `milestone-NN`, push.

### Model selection for subagents (memory-banked user preference)

- **Haiku** — mechanical isolated tasks: small SwiftUI views, simple model additions, view-modifier wiring.
- **Sonnet** — substantive integration tasks: pure-logic with non-trivial test cases, multi-file edits, view composition.
- **Opus** — complex coordination: NSFileCoordinator dual-write, recursive ProjectStore mutators, multi-file refactors with type-checker concerns, signature changes that ripple.

The user said early on: *"1 but for anything complex use opus"* — interpret liberally. When in doubt go up a tier.

### Skip the formal two-stage review for trivial tasks

The user has banked a feedback memory: skipping spec-compliance + code-quality review subagents is OK when a task is small and clearly correct. Read the implementer's status report; if DONE with no concerns and tests pass, mark complete and move to the next task. Reserve formal reviews for tasks where the implementer flagged DONE_WITH_CONCERNS or where the change is complex enough to warrant a second look.

### Subagent prompts: be specific and self-contained

Subagents don't see the conversation history. Every dispatch includes:
- Project context (working dir, branch, last commit, test baseline)
- Existing primitives they can rely on (with file paths)
- Strict scope (which files they can/can't modify)
- TDD discipline (tests first, fail, implement, pass, commit)
- Full code blocks for every step
- Status reporting format

The plan files in `docs/superpowers/plans/` are written this way. When dispatching, copy-paste task content verbatim into the subagent prompt — don't summarize.

### Commit discipline

- Each plan task commits independently. ~17-20 commits per milestone.
- When a smoke fix is needed, commit it on top, OR `git commit --amend` if it logically belongs with the previous task and that task hasn't been pushed.
- Every commit message starts with `feat:` (new feature), `fix:` (bug fix), or `docs:`. The body explains *why* succinctly.
- After all tasks: ff-only merge to main, annotated tag `milestone-3a` etc., push commits + tag.

---

## Recurring lessons banked across milestones

These have bitten across at least 3 milestones each. Internalize them.

### Smoke catches what unit tests can't (8 milestones running)

Pure-logic and integration tests cover the data model. SwiftUI ↔ AppKit seams produce visual/timing bugs that ONLY surface in the running app. Every milestone since 1b has had at least one smoke-only fix. Examples:
- 1e long-chapter cursor mis-restore on chapter switch (race between SwiftUI tear-down and async load)
- 1e paste cursor jitter at end-of-file (NSTextView async layout pass moves cursor after delegate returns)
- 2a inline rename TextField couldn't accept input (`.draggable` parent shadowing keyboard events)
- 2b editor centered column gutters disappeared when pane was squeezed below typography column width
- 2c Statistics window all zeros (fresh ProjectStore had empty word-count cache)
- 2c heatmap cells stretched horizontally and squashed vertically (RoundedRectangle.fill.frame can flex)

**Practice:** Always do the manual smoke before tagging a milestone. Document each fix as it lands. The recurring patterns matter.

### SwiftUI body type-checker timeouts (3 milestones running)

`ProjectWindow.body` has hit Swift's expression-type-check timeout three times — each time after adding new `.onReceive`/`.onChange` modifiers or nested switch statements. The standard fix is extracting chunks into private `@ViewBuilder` methods or `ViewModifier` structs.

**Practice:** When a SwiftUI body grows past ~5 modifiers + a few conditional branches, factor it. The `SessionAndNavigationModifier` pattern from 2c is the canonical relief.

### Color.clear + .background for fixed-size visual cells

`Shape().fill().frame(width:height:)` chains can flex inside flex layouts despite the explicit frame, because `.fill` returns an inherently-flexible view. The reliable pattern for fixed-size visual cells is `Color.clear.frame(width:height:).background(Shape().fill(...))`. Color.clear holds its frame rigidly. (Banked from 2c heatmap fix.)

### `.formatted(.number)` in string interpolation eats SourceKit's budget

SwiftUI Text labels with multiple `.formatted(.number)` calls inside a single `"\(...) \(...) \(...)"` interpolation hit Swift's type-check ceiling. Refactor to `+` concatenation with explicit `let s: String = X.formatted(.number)` bindings. (Banked from 2c GoalIndicatorView fix.)

### NavigationSplitView detail column needs explicit max

Without an explicit `max:` in `.navigationSplitViewColumnWidth(min:ideal:max:)`, the detail column absorbs all extra width on window resize, leaving content (the editor) pinned at minimum. Set a max. (Banked from 2b inspector cap.)

### NSTextView width tracking under SwiftUI doesn't always fire AppKit autoresizing

When wrapping NSScrollView in NSViewRepresentable, AppKit's autoresizing chain can fire too early (during initial layout before final geometry) and never again. The fix is force-tracking `scrollView.contentSize.width` onto `textView.frame.size.width` in `updateNSView`, plus an `async`-deferred call in `viewDidMoveToWindow`. (Banked from 2b editor gutter fixes.)

### Subagent flagging DONE_WITH_CONCERNS is honest, not lazy

When a subagent finishes a task but flags concerns, READ the concerns. They're often catching genuine ambiguities or scope issues. The 2a T2 RenamePlan slot-aware collision rule, the 2c T6 protocol-witness-default-arg gotcha, and the 2c T10 close()-vs-MaughamApp lifecycle decision all came from subagent concerns that were better than what was dictated. Honor them.

### Lifecycle hooks belong in the lifecycle method itself

When you find yourself needing to call a flush/cleanup at multiple call sites, put it inside the `close()` (or equivalent terminal) method instead. Single end-of-life entry point. Future call sites get the hook for free. (Banked from 2c session-flush placement.)

### Existing tests can become stale; update them deliberately

When a subagent's correct implementation breaks pre-existing tests because those tests assert behavior that's deliberately changed (e.g. UIState v1 → v2 migration in 2b T4), the fix is the tests, not the implementation. Amend the implementation commit to include the test updates so the change stays atomic.

---

## User preferences (memory-banked)

These persist across sessions:

- **Ambitious scope by default.** When given the choice, the user picks the more comprehensive option. Don't underdesign on their behalf.
- **Respect UI muscle memory.** ⌘S flashes "Saved" even though autosave makes it redundant — the reflex matters.
- **Subagent execution as default.** Skip formal two-stage review for trivial tasks; use it for complex/contested work.
- **Skill-driven workflow.** brainstorming → writing-plans → subagent-driven-development.

---

## Memory you have (auto-loaded)

The user's auto-memory at `/Users/denver/.claude/projects/-Users-denver-src-Maugham/memory/` contains:
- `MEMORY.md` (the index)
- `project_maugham.md` — top-level project description
- `project_milestone_1a.md` through `project_milestone_2c.md` — what shipped, what bugs were found, what was learned
- `user_writer.md` — user is a creative writer (prose, novels, screenplays)
- `feedback_scope_ambition.md`
- `feedback_ux_reflexes.md`
- `feedback_subagent_execution.md`

You should read at least `MEMORY.md` and `project_milestone_2c.md` for the most recent state.

---

## Recommended starter prompt for the new session

Paste this into the new session as the first message:

> I'm picking up Maugham development at Phase 3. Phases 1 and 2 are complete; milestones 1a–2c are tagged on main. Read `docs/superpowers/notes/2026-05-09-phase-3-breakdown-and-handoff.md` end-to-end before doing anything — it's the comprehensive context dump for this work.
>
> Then start the brainstorm cycle for milestone 3a (Fountain foundation + styling) per the breakdown's recommendation. Use `superpowers:brainstorming`. The visual companion will help with screenplay layout decisions.
>
> Conventions to follow: brainstorm → spec → plan → subagent-driven-development. Model selection: haiku for mechanical, sonnet for substantive, opus for complex coordination. Skip formal two-stage review for trivial tasks. Manual smoke before tagging.

---

## Final notes for the new session

- **The Phase 3 spec doesn't exist yet** — write it via brainstorming. The breakdown above is just decomposition, not the spec itself.
- **The Phase 3 plan doesn't exist yet either** — written after spec is approved, via writing-plans.
- **Don't shortcut the brainstorm.** Even when the master design is detailed, the brainstorm settles edge cases that only become visible during a structured conversation. The user has approved 8 brainstorms; trust the process.
- **The visual companion is worth using** for any layout decision. Screenplay element layout (indents, alignments, spacing) will benefit. Show mockups before committing to specifics.
- **Test discipline matters.** Pure-logic types get full TDD. Integration tests for store/persistence layers use real `NSFileCoordinator` + temp dirs. SwiftUI views are smoke-build only — manual smoke catches what tests can't.
- **xcodegen via `./gen.sh`.** New files in `Maugham/` and `MaughamTests/` are picked up automatically by the existing globs. New subdirectories (e.g. `Maugham/Editor/Fountain/`) just work.
- **Commit hygiene.** Each plan task = one commit. Smoke fixes commit on top OR amend if they belong with the last task and main hasn't been pushed.

Good luck. The codebase is in good shape — 265 tests, clean architecture, well-documented patterns. Phase 3 is genuinely interesting screenwriting work. Have fun with it.
