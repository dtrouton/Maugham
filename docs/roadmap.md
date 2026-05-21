# Roadmap

The live roadmap, grouped by writer intent. See [ADR 0002](adr/0002-roadmap-by-writer-intent.md) for the rationale behind the group structure. Phases 1–3 (foundation, novel depth, screenplay) shipped as phase-numbered milestones and are summarized below as historical record.

Within each group, items are listed roughly small-first. Each group's "next up" is the suggested first concrete milestone, but groups are independent — pick what to work on based on day-to-day friction, not a linear order.

Status legend: ✓ shipped, • open.

## Phase 1–3 — Shipped foundation, 2026-05-07 to 2026-05-10

These milestones established the editor, the novel + screenplay project shapes, and the file-coordinated DocumentStore. See `docs/superpowers/plans/` for the dated milestone breakdowns and `docs/superpowers/specs/` for per-milestone designs.

- ✓ Phase 1a — Foundation (welcome window, recents, short-story project, basic DocumentStore)
- ✓ Phase 1b — Editor + theming + typography + smart typography + ProseMode
- ✓ Phase 1c — Focus chrome (centered column, typewriter, focus dimming, ⌘\, ⌘⇧F, goals, ⌘S flash)
- ✓ Phase 1d — Three-pane window, Novel binder, inspector, all four project types, per-project typography
- ✓ Phase 1e — DocumentStore with NSFileCoordinator/Presenter, 750ms autosave, conflict resolution, UI state, per-doc cursor restore
- ✓ Phase 2a — Binder polish (drag-reorder, cross-group move, Duplicate, Tidy Filenames)
- ✓ Phase 2b — Surfaces (Research browser with 5 inline renderers, Conflict diff sheet)
- ✓ Phase 2c — Metadata + Metrics (inspector growth: tags / word target / links / [[wiki]] / session tracking / Project Statistics)
- ✓ Phase 2d — Hot-patch: wiki-link rename propagation
- ✓ Phase 3a — Fountain foundation (parser, per-element styling, page count + target)
- ✓ Phase 3b — Editing UX (Tab/Shift+Tab element cycling, element gutter, forced-syntax markers)
- ✓ Phase 3c — Screenplay parity (title page, scene navigator, inline emphasis, ⌘/ syntax help)
- Phase 3d — Multi-file screenplay: attempted and abandoned. See [ADR 0001](adr/0001-multi-file-screenplay-abandoned.md).

---

## Group 1 — Editing flow polish

Daily-writing improvements. Reduces friction in the surface you spend hours in.

**Shipped:**
- ✓ Research polish (2026-05-13) — New Text Note + click-to-edit research docs + rename-renames-on-disk + inline images with ⌘⇧P preview + [Trash & undo](adr/0006-trash-and-undo.md)
- ✓ Cross-document Find/Replace (2026-05-14) — in-doc find re-enabled (⌘F) + cross-document find (⌘⌥F) via grouped results, options (case-sensitive, whole-word), per-row + Replace All, click-to-jump
- ✓ Writing Companion (2026-05-14) — bundled three quality-of-life features around the [right-pane mode-swap pattern](adr/0005-right-pane-mode-swap.md):
  - Research ↔ manuscript linking with click-to-view markdown preview
  - Structure views: Outline (table) + Corkboard (cards) with layout toggle
  - Keyboard cheatsheet tab in ⌘/
- ✓ History Rewind (2026-05-21) — per-doc time-travel modal: scrubber over every op with color-coded legend, Doc/Diff preview, Snapshot or Restore, per-row ↺ button on HistoryPane; SynthesisSource enum refactor + RewindCursor / RewindAction / RewindScope / RewindRestoreResult typed contracts; SweepReason enum→struct carries `cause: SynthesisSource`; multi-window-scoped notification (`object: projectURL`); tag `milestone-history-rewind`; 794 tests passing; carry-forwards: project-scope rewind (multi-doc clock UX), live-update of scrubber during MCP writes, un-archive annotation lifecycle action, scrubber pan/zoom beyond 1k ops, and accuracy on legacy projects whose ops predate the always-capture-sequence-on-burst fix (first-appearance fallback is approximate — can't recover post-burst reorders or deletions).

**Open:**

**Phase 4a — Screenplay Intelligence (IDE-like editing):**
- • Inline character autocomplete — NSTextView-driven inline ghost-text with Tab-to-accept (carry-forward from 3b where NSPopover proved too brittle)
- • Slugline reuse — suggest previously-used `INT. KITCHEN — DAY` when typing a new heading; avoids drift across drafts
- • Fountain prefix completion — `I` at line start offers `INT.` / `I/E.` / `INT/EXT.`; `E` offers `EXT.` / `EST.`; transitions get `FADE OUT:` / `CUT TO:` etc.
- • Outline minimap (optional) — slim secondary sidebar with section/scene structure

**Prose-mode parallel:**
- • Inline character/place autocomplete in prose mode — uses parsed `[[Wiki Links]]` from 2c plus proper-noun frequency

**Screenplay editing depth:**
- • Dual dialogue (`^` for side-by-side speakers)

**Visual reference:**
- • Mood board — a board surface for arranging images, swatches, and notes when thinking through a project's visual identity (colour palettes, character looks, locations). Project-level (not per-document). Needs brainstorming on scope: dedicated binder pane vs. new project type vs. extension of the Research browser.

**Right-pane onboarding polish (carry-forward from the editing milestone):**
- • Annotations vs History pane onboarding affordance — they're sibling right-pane segments with opposite affordances (Annotations = action surface with Accept/Reject/Archive buttons; History = read-only forensic log). Today the segment-picker icons read as a generic "right pane mode" picker without communicating the difference, which led to real confusion during editing-milestone testing. Smallest fix: tooltips on the segment icons. Bigger fix: empty-state hints that point across ("looking for action buttons? Press ⌘⌥A").

---

## Group 2 — Claude integration

AI assist for drafting, transcription, and project understanding.

**Shipped:**
- ✓ MCP Foundation (2026-05-16) — live-only Unix-socket bridge to Claude Desktop with 14 tools (8 read + list_research + list_documents_by_tag + list_all_links + add_note + link_research + unlink_research), the one-click Set up Claude Desktop sheet, and the Settings toggle. See [ADR 0003](adr/0003-mcp-live-only-unix-socket.md) (transport) and [ADR 0004](adr/0004-mcp-foundation-scope.md) (scope).
- ✓ Editing — annotations + history viewer (2026-05-19) — Claude-as-collaborative-editor end-to-end. 4 new OpKind cases (claudeComment / claudeQuery / claudeCraftNote / claudeArchive) + 6 new MCP tools (add_comment / add_suggested_change / add_query / add_craft_note / list_annotations / get_annotation; registry grew 14 → 20). New AnnotationsPane (⌘⌥A) with Accept/Reject/Archive/Reply per kind, stale-confirm alert, and reject-reasoning capture. HistoryPane (replaces CheckpointBrowserPane) shows unified op + checkpoint timeline with filter pills (All / Checkpoints / Edits / Annotations / External). Structured MCP error envelopes (`isError: true` with paragraph_not_found / prior_text_capture_failed factories). Tag `milestone-editing`. The "manuscript is yours" membrane held: Claude proposes via the annotation layer; the writer disposes via the UI.

**Open:**
- • **Handwritten note import** — drag photos of handwritten pages in, Claude transcribes to `.md` using phone-camera filenames as ordering hints, page-by-page accept/edit/reject UI, automatic placement into manuscript or research. The annotation-layer approval UX from the editing milestone is the model.
- • **Project-level Claude prompt templates** — curated prompts like "Brainstorm character motivations for this scene" / "Find continuity errors in Chapter 3", pre-wired to MCP read-tools so Claude is grounded.
- • **Voice notes / Whisper transcription** — drop audio in, Claude transcribes to draft `.md` files (placed in `research/voice-notes/` for review before manuscript placement).
- • **Read-only Claude Code companion view** — sidebar in Maugham showing Claude responses without leaving the writing context.

**Annotation-layer follow-ups (carry-forwards from the editing milestone):**
- • **Sub-paragraph range anchors for suggested_change** — today an annotation anchors a whole paragraph; for tight edits ("change this clause") the writer wants character-range precision. Op schema needs a range field; UI needs inline highlight.
- • **Inline annotation marks in the editor** — gutter glyphs or margin chips next to paragraphs with open annotations, so the writer sees what Claude flagged while editing rather than only in the side pane.
- • **Bulk annotation operations** — Accept-all / Reject-all from the AnnotationsPane, filtered by kind. Today every annotation is one click.
- • **Cross-document annotation views** — surface annotations across every doc in a project, not just the active one. Useful when Claude reviews a whole novel and leaves notes per chapter.
- • **`craft_principles.md` aggregation** — accepted `craft_note` annotations live only in the op log today; future Claude sessions read them via `list_annotations(kind:craft_note, status:accepted)`. A project-level digest file would make them human-readable too and let the writer edit/curate them. See `docs/superpowers/specs/2026-05-19-editing-annotations-history-design.md` §1.4 for the deferred design.

---

## Group 3 — Publishing flow

Delivery, sharing, and mixed-media compilation.

**Open — needs design first:**
- • **Mixed-content collection** — a single project containing both prose stories AND screenplays. The existing `ProjectType.collection` is a 1d placeholder; this milestone makes it functional. Touches manifest schema (per-item writing mode), binder (mixed icons/affordances per item), and compile (mixed typography in one output). **Design direction (provisional, 2026-05-16):** hybrid — a Collection contains both "loose" mixed-content documents (each declares its own `mode: prose` / `mode: fountain` in the manifest) AND references to standalone Maugham projects. Loose docs and project-references coexist in one binder. Matches the writer's mental model where a short story collection has some pieces large enough to warrant their own project folder and others that don't. **Deferred questions** (captured for the brainstorm): can a loose Collection document be "split out" into its own standalone project later? Submission tracker semantics for Collection items vs. referenced projects. Brainstorm before scoping.

**Compile (cross-type):**
- • Compile UI — assemble manuscript into Word / EPUB / PDF / plain text
- • Markdown manuscript export for novels — Shunn standard (Times New Roman 12pt, double-spaced, 1" margins) for short-fiction submissions
- • EPUB cover image handling

**Screenplay-specific production polish:**
- • FDX export and import (Final Draft binary format)
- • Scene numbers (`INT. KITCHEN - DAY #5#`)
- • MORE / CONT'D markers across page breaks
- • Revisions — color-coded change marks per draft

**Submission workflow (speculative — confirm interest before scoping):**
- • Submission tracker — "this story is at Magazine X (sent 2026-04-12, awaiting response)"; per-item state machine, deadlines, reminders.

---

## Group 4 — Foundations & safety

Reliability the writer doesn't think about until it bites. Not glamorous, but each item builds Maugham's "trust me with your novel" credibility.

**Day-to-day reliability:**
- ✓ Trash & undo for binder operations — shipped under Group 1's research polish milestone. See [ADR 0006](adr/0006-trash-and-undo.md).
- • Snapshots — versioned manuscript saves with labels ("before-rewrite", "agent submission"). Lighter-weight than History Rewind: an explicit named bookmark rather than a scrub-anywhere capability. The two pair well — Snapshots is the user-curated index, History Rewind is the open-ended exploration.
- • Backup & recovery story — iCloud version-history surfacing, Time Machine compatibility note, cross-session undo

**Future-proofing:**
- • **Manifest schema versioning** — `project.maugham.json` is at `schemaVersion: 1`. Define migration story before it evolves (e.g., when 4a adds pageTarget per-item). A coordinated rename pass to clean up the [ID prefix inconsistency](adr/0007-id-prefix-no-migration.md) would fit naturally here.
- • Performance pass — long-haul project simulation (100k words, 30 chapters): editor responsiveness, Project Statistics, cross-document operations stay O(scale)-aware.

**Distribution & onboarding:**
- • App icon, version stamping, code-signing, notarization, auto-update — without this, Maugham is "the thing that runs in Xcode"
- • Welcome experience for new writers / future-you on a new Mac — clearer New Project sheet, better empty states, walkthrough
- • Project templates — Three-Act Novel, Hero's Journey, Short Story, etc.; pairs with distribution since templates are onboarding-flavored

---

## Deferred surfaces (not on the roadmap)

Considered and explicitly de-prioritized. Each gets a fresh brainstorm if/when prioritized.

- • **iPad companion** — read-only first, then drafting. Separate engineering bet on a different surface; not a feature of the desktop Mac app.
- • **Shared folder collaboration** — writing-partner / editor edits the same project. Needs locking + multi-author conflict UI beyond what 1e provides.
- • **Goal-tracking calendar widget** — macOS widget extension; separate target from the app proper.

---

## Sequencing notes

- **Group 1's screenplay intelligence (Phase 4a)** is the natural next drafting-flow milestone — picks up the inline-autocomplete and slugline-reuse work that was carry-forwarded from 3b/3c.
- **Group 2's manuscript-edit loop is closed** as of the editing milestone (2026-05-19): Claude can propose via the annotation layer; the writer disposes via the AnnotationsPane. The next AI-assist milestones are pickable in any order — Handwritten note import reuses the proposal/approval UX from the editing milestone, so it's the most natural follow-up if AI assist is the priority.
- **Group 3 (Compile)** is the "I want to send this to my agent" feature. Premature while still drafting; pick it up when there's something to ship.
- **Group 4 (Foundations)** items are pickable any time. **History Rewind** is the most interesting new candidate — the op log infrastructure makes it cheap to compute, and the "time travel over your own writing" affordance lands somewhere between Snapshots and the milestone-editing history view. Distribution becomes urgent only when Maugham needs to leave the dev Mac. Schema versioning becomes urgent only when a non-additive manifest change forces it.
