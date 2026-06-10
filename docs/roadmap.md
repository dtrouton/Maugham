# Roadmap

The live roadmap, grouped by writer intent. See [ADR 0002](adr/0002-roadmap-by-writer-intent.md) for the rationale behind the group structure. Phases 1–3 (foundation, novel depth, screenplay) shipped as phase-numbered milestones and are summarized below as historical record.

Within each group, items are listed roughly small-first. Each group's "next up" is the suggested first concrete milestone, but groups are independent — pick what to work on based on day-to-day friction, not a linear order.

Status legend: ✓ shipped, • open, ⤴ superseded.

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
- ✓ UI Polish (2026-05-22) — right-pane width resilience + status footer + scene-row layout. New shared `AdaptiveFilterRow` control (ViewThatFits-based, with `.layoutPriority(1)` claim so the filter row keeps labels and the trailing button falls to icons first) used by `HistoryPane` and `AnnotationsPane`; `LinkedResearchPane` / `OutlinePane` / `HistoryPane` / `AnnotationsPane` outer VStacks now top-anchor their action bars and expand empty-states to fill below; new `EditorStatusFooter` (session words · ¶pid·element · pages/words progress) mounts via `.safeAreaInset(edge: .bottom)` on `contentColumn` and supersedes the floating `GoalIndicatorView` capsule (hidden in no-chrome `⌘\` and full-screen focus `⌘⇧F`); `SceneNavigatorPane` rows are now single-line with compact trailing `p1 · ½` caption via new `formatPagesCompact`; HistoryPane `Rewind…` button is icon-only at all widths. Tag `milestone-ui-polish`; 809 tests passing (added 7 EditorStatusFooter formatter tests + 8 SceneNavigatorPane compact-format tests; deleted 4 throwaway PreferenceKey-fit tests when AdaptiveFilterRow switched to `ViewThatFits`).
- ✓ UI Polish follow-ups (2026-05-22) — wire ¶pid + element abbreviation to the status footer center column (new `Document.paragraphId(at:)` + new `EditorCoordinator.onElementChanged` callback fed from `lastParsedScript` + `ElementGutterView.abbreviation`); session start exposed via `DocumentStore.currentSessionStart`; orphan `lengthLabel(for:)` deleted from SceneNavigatorPane; `DateFormatter` cached on EditorStatusFooter; tooltips on the right-pane segment picker icons (`DetailPaneToggle.segmentPicker`) — closes the Annotations-vs-History affordance carry-forward from `milestone-editing`. **Regression fix:** restored the lost `recordWordCount` + `recordSessionActivity` call sites in EditorHost's binding setter (silently broken since the 2026-05-19 document-first-class refactor — `projectWordCount` was returning 0 forever, no session ever started, SessionLog stayed empty). `DocumentStore.liveSessionWordsNet` exposes the live session delta so the footer ticks per-keystroke; `goalIndicatorState.wordsToday` sums the persisted log + the live delta. Tag `milestone-ui-polish-followups`; 814 tests passing (added 5 `Document.paragraphId(at:)` tests).
- ✓ Inline emphasis contract (2026-06-03, v0.6.1-adjacent) — `***bold italic***` + nested `*a **b** a*` unified across all four surfaces (Mac prose, Mac screenplay, phone reader, publish) via a shared `InlineEmphasisScanner` + `EmphasisTraits` OptionSet; Mac prose was the outlier (mutually-exclusive Bool). Asterisk-only for now; underscore on Mac prose deferred. Merge `a405b0b`.

**Open:**

**Phase 4a — Screenplay Intelligence (IDE-like editing):**
- • Inline character autocomplete — NSTextView-driven inline ghost-text with Tab-to-accept (carry-forward from 3b where NSPopover proved too brittle)
- • Slugline reuse — suggest previously-used `INT. KITCHEN — DAY` when typing a new heading; avoids drift across drafts
- • Fountain prefix completion — `I` at line start offers `INT.` / `I/E.` / `INT/EXT.`; `E` offers `EXT.` / `EST.`; transitions get `FADE OUT:` / `CUT TO:` etc.
- • Outline minimap (optional) — slim secondary sidebar with section/scene structure

**Prose-mode parallel:**
- • Inline character/place autocomplete in prose mode — uses parsed `[[Wiki Links]]` from 2c plus proper-noun frequency

**Screenplay editing depth:**
- ✓ Dual dialogue (2026-05-26, shipped in v0.4.0) — `^` for side-by-side speakers; trailing-`^` cue fades, dual-second blocks render with deeper indents, page-count treats the pair as max-of-pair. Merge `c0676cf`.

**Visual reference:**
- • Mood board — a board surface for arranging images, swatches, and notes when thinking through a project's visual identity (colour palettes, character looks, locations). Project-level (not per-document). Needs brainstorming on scope: dedicated binder pane vs. new project type vs. extension of the Research browser.

**Right-pane onboarding polish (carry-forward from the editing milestone):**
- • Annotations vs History pane onboarding affordance — they're sibling right-pane segments with opposite affordances (Annotations = action surface with Accept/Reject/Archive buttons; History = read-only forensic log). Today the segment-picker icons read as a generic "right pane mode" picker without communicating the difference, which led to real confusion during editing-milestone testing. Smallest fix: tooltips on the segment icons. Bigger fix: empty-state hints that point across ("looking for action buttons? Press ⌘⌥A").

**Author's IDE — analytical layers (tracking, lookup, lint):**

A new arc of "code-tool-style" author surfaces. Each layer is structured author-owned side-data anchored to paragraph IDs, surfaced as a right-pane mode, op-log derived, and MCP-readable. Tasks shipped first as the pathfinder (v0.3.0); symbol DB / lint / writing analytics reuse the same architectural shape.

- ✓ **Tasks — the issue-tracker layer** (shipped v0.3.0, 2026-05-25; MCP `list_tasks`/`get_task` included) — unified task surface combining three capture paths: inline `- [ ]` markdown checkboxes in any `.md`, Fountain `[[todo: …]]` / `[[done: …]]` boneyards in `.fountain`, and pane-created tasks (no text representation, ops only). One right-pane segment (⌘⌥5) with **Document / Project** scope filter, status filter (Open / Done / Archived / All), drag-and-drop **priority** reorder (rewindable, ops), single-level parent/child nesting (drag-to-nest), in-pane checkbox toggle that **rewrites the underlying text** for inline tasks, click-row-to-navigate, and `+ New task` for pane-created entries. MCP read-only (`list_tasks` / `get_task`). Pathfinder establishes the typed cross-area seam (`TaskKind` / `TaskStatus` / `TaskAnchor`), the op-log derivation pattern (mirrors `AnnotationDeriver`), the synthetic `__project__` doc-id approach for project-scope ops, and the editor-side clickable-checkbox interaction that future analytical layers can reuse.

---

## Group 2 — Claude integration

AI assist for drafting, transcription, and project understanding.

**Shipped:**
- ✓ MCP Foundation (2026-05-16) — live-only Unix-socket bridge to Claude Desktop with 14 tools (8 read + list_research + list_documents_by_tag + list_all_links + add_note + link_research + unlink_research), the one-click Set up Claude Desktop sheet, and the Settings toggle. See [ADR 0003](adr/0003-mcp-live-only-unix-socket.md) (transport) and [ADR 0004](adr/0004-mcp-foundation-scope.md) (scope).
- ✓ Editing — annotations + history viewer (2026-05-19) — Claude-as-collaborative-editor end-to-end. 4 new OpKind cases (claudeComment / claudeQuery / claudeCraftNote / claudeArchive) + 6 new MCP tools (add_comment / add_suggested_change / add_query / add_craft_note / list_annotations / get_annotation; registry grew 14 → 20). New AnnotationsPane (⌘⌥A) with Accept/Reject/Archive/Reply per kind, stale-confirm alert, and reject-reasoning capture. HistoryPane (replaces CheckpointBrowserPane) shows unified op + checkpoint timeline with filter pills (All / Checkpoints / Edits / Annotations / External). Structured MCP error envelopes (`isError: true` with paragraph_not_found / prior_text_capture_failed factories). Tag `milestone-editing`. The "manuscript is yours" membrane held: Claude proposes via the annotation layer; the writer disposes via the UI.

**Open:**
- • **Handwritten note import** — drag photos of handwritten pages in, Claude transcribes to `.md` using phone-camera filenames as ordering hints, page-by-page accept/edit/reject UI, automatic placement into manuscript or research. The annotation-layer approval UX from the editing milestone is the model.
- • **Project-level Claude prompt templates** — curated prompts like "Brainstorm character motivations for this scene" / "Find continuity errors in Chapter 3", pre-wired to MCP read-tools so Claude is grounded.
- ✓ **Voice notes / Whisper transcription** (2026-05-30, via the iPhone companion) — record voice in the phone Capture tab → inbox → WhisperKit transcribes → promote to research. *Still open:* a Mac-side drag-audio-file-in entry point (the shipped path is phone-capture, not desktop drop).
- • **Read-only Claude Code companion view** — sidebar in Maugham showing Claude responses without leaving the writing context.
- • **Human reviewer / collaborator layer (single-author lock)** — generalize the annotation membrane from "Claude proposes, writer disposes" to "any **non-author** proposes, the **author** disposes." A transferable **author lock** governs who may edit the manuscript; everyone else — human collaborators *and* Claude — operates in the existing annotation layer (comments, queries, suggested changes, surfaced in `AnnotationsPane` with Accept/Reject/Archive). **Design direction (provisional, 2026-06-06):**
  - **Three roles.** *Project owner* — persistent, singular (whoever created the project). *Author* — the current per-document lock-holder; the only one who may edit that doc. *Reviewer* — everyone else (human collaborators and Claude), annotation layer only.
  - **Lock = a transferable baton.** One holder per document; only the holder can edit. Only the holder can **release** (or flip themselves to review mode); once released, another collaborator may **claim** it. The **project owner** — and only the owner — can **force-takeover** a held lock (warned override), so an unreachable lock-holder can't freeze the project.
  - **Per-document granularity** (rides the per-doc op-log / per-device-JSONL grain), with **project-level "Claim all / Release all"** so the solo-writer case is one action and the co-authored collection case (Alice owns story 1, Bob owns story 2) works in parallel.
  - **Attribution:** reuse the existing annotation `OpKind`s; add an `author`/`source` provenance field so a named human reviewer is distinguished from Claude in the pane. Identity is a per-device display name set in Settings — no accounts.
  - **Access models, both in scope:** (1) shared iCloud-Drive folder, each collaborator on their own Mac, comments sync via per-device JSONL ([ADR 0012](adr/0012-per-device-jsonl-partitioning.md)); (2) a local **reviewer-mode toggle** on the writer's own Mac (the degenerate single-device case of the same lock).
  - **Deferred questions:** how owner identity is established and stamped on a shared folder (candidate: at project creation, alongside the minted `ProjectManifest.id`); where the lock lives for collection *project-references* vs loose docs; whether Claude's annotations should be visually grouped separately from human ones. Brainstorm to full spec before scoping.
  - **VCS-steals to fold in when scoping** (surfaced in the 2026-06-07 backup brainstorm): **patch commutation / real merge** (Darcs/Pijul) to replace crude LWW-by-paragraph for multi-author concurrent edits; **signed generations/checkpoints** (git/hg signed tags) so a collaborator's contribution carries verifiable provenance (ties to the **Backup & integrity** signing primitive); **blame / annotate** per-paragraph who/when-last-changed (the op log already holds per-op device/session/at).
  - **Skew-aware LWW + same-paragraph conflict surfacing is owned here** (deferred out of the 2026-06-07 hardening milestone, which shipped only merge/derive *determinism* — see `Maugham/OpLog/AREA.md`). Starting point: the audit's 0.2 (skew-induced cross-device LWW loss) + the `prior`-snapshot divergence-detection idea in `docs/superpowers/notes/2026-06-07-codebase-audit.md`; the authored-but-skipped `CrossDeviceIntegrationTests` case 4 records the scenario.
  - **Supersedes** the deferred "Shared folder collaboration" surface — the author lock *is* the locking/conflict-avoidance model that surface said it needed.

**Annotation-layer follow-ups (carry-forwards from the editing milestone):**
- • **Sub-paragraph range anchors for suggested_change** — today an annotation anchors a whole paragraph; for tight edits ("change this clause") the writer wants character-range precision. Op schema needs a range field; UI needs inline highlight.
- • **Inline annotation marks in the editor** — gutter glyphs or margin chips next to paragraphs with open annotations, so the writer sees what Claude flagged while editing rather than only in the side pane.
- • **Bulk annotation operations** — Accept-all / Reject-all from the AnnotationsPane, filtered by kind. Today every annotation is one click.
- • **Cross-document annotation views** — surface annotations across every doc in a project, not just the active one. Useful when Claude reviews a whole novel and leaves notes per chapter.
- • **`craft_principles.md` aggregation** — accepted `craft_note` annotations live only in the op log today; future Claude sessions read them via `list_annotations(kind:craft_note, status:accepted)`. A project-level digest file would make them human-readable too and let the writer edit/curate them. See `docs/superpowers/specs/2026-05-19-editing-annotations-history-design.md` §1.4 for the deferred design.

---

## Group 3 — Publishing flow

Delivery, sharing, and mixed-media compilation.

**Shipped:**
- ✓ **Publishing pipeline** (merged to main 2026-05-29) — PDF (bundled tectonic/LaTeX) + EPUB (HTML/CSS), driven by per-project Claude-authored LaTeX templates + a small `config.json`. `EMISSION.md` body-emission contract; per-piece `style_file` overrides; fonts via fontspec; `Exports/` view in the binder. MCP surface 20 → 40 tools. Specs: `docs/superpowers/specs/2026-05-26-publishing-pipeline-design.md`, `…/2026-05-29-publishing-feedback-design.md`.
- ✓ **Mixed-content collection** (shipped 2026-05-17, tag `milestone-mixed-content-collection`) — `ProjectType.collection` made functional: a single project holding both "loose" mixed-content docs (each declares its own `mode: prose` / `mode: fountain` in the manifest) AND references to standalone Maugham projects, coexisting in one binder with per-item icons/affordances. Plus `read_document` MCP went polymorphic on images (crop-on-demand). 630 tests passing. *Still-open follow-ups:* "split a loose Collection doc out into its own standalone project later"; submission-tracker semantics for loose items vs. referenced projects.

**Compile (cross-type):**
- ✓ Compile to **PDF + EPUB** — shipped via the publishing pipeline (2026-05-29). Still open: Word / plain-text output.
- • Markdown manuscript export for novels — Shunn standard (Times New Roman 12pt, double-spaced, 1" margins) for short-fiction submissions
- ✓ EPUB cover image handling — `config.cover.path` (+ `epub_specific_path`); embedded by the EPUB packager.
- • **Clean export to `Exports/`** — "Export → Clean Markdown" / "Export → Clean Fountain" action generates anchor-stripped copies of `.md` / `.fountain` files into an `Exports/` directory next to the project. Removes paragraph anchors (`<!-- ¶XXXXXX -->`) AND task anchors (`<!--t-XXXXXX-->`) so the output is portable to any text editor. Writer-selectable filters: include/exclude `- [x]` done items, include/exclude `[[todo: …]]` segments. Provides a clean handoff to collaborators, version-control diffs, or production pipelines that don't speak Maugham's anchor convention.

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
- ✓ **Backup & integrity** (shipped **v0.8.0**, 2026-06-07) — an **integrity primitive** (Merkle manifest; surface + quarantine the previously-silent op-log parse-skip; conflict-twin + dangling-checkpoint-pointer + semantic garbage-paragraph-id checks) + a **filesystem-only backup system** (Backups Settings tab → any local/cloud-synced/external folder; safe-by-default; per-project keying by minted `ProjectManifest.id` so several projects can share one destination; per-destination retention; atomic copy-on-write generations; skip-unchanged via a content signature that ignores per-save checkpoint churn; **integrity-checked before every backup so corruption can't propagate**; per-project "backups paused" banner) + **restore** (`RestoreWindow` reached from the banner and File → Restore from Backup…; restore-**beside** never-overwrite; integrity badges; auto-bisect-to-good). Complements (doesn't replace) Time Machine; encryption deferred to the destination. Spec `docs/superpowers/specs/2026-06-07-backup-and-integrity-design.md`; plans under `docs/superpowers/plans/2026-06-07-*`. *Replaced the old "iCloud version-history surfacing / Time Machine note" sketch.* **Manifest-shadow recovery** shipped post-v0.8.0 — a corrupt/truncated `project.maugham.json` now self-heals on open from a verified (checksummed) shadow under `.maugham/`, so a damaged manifest no longer means "can't open the project." **Remaining deferred follow-ons** (capture for later, roughly in priority): (1) **single-document restore** — op-log surgery to pull one doc's content from a generation back into the live project as new rewindable ops; the marquee piece, wants its own milestone; (2) **derive-and-compare** — re-derive the manuscript and flag structural breakage to catch valid-but-wrong corruption; needs care so legit external `.md` edits don't false-positive; (3) **essential/full file classification** — trim regenerable artifacts (`Exports/`, build outputs) from *remote* backups; pure bandwidth optimization, lowest urgency.

**Future-proofing:**
- • **Manifest schema versioning** — `project.maugham.json` is at `schemaVersion: 1`. Define migration story before it evolves (e.g., when 4a adds pageTarget per-item). A coordinated rename pass to clean up the [ID prefix inconsistency](adr/0007-id-prefix-no-migration.md) would fit naturally here.
- • Performance pass — long-haul project simulation (100k words, 30 chapters): editor responsiveness, Project Statistics, cross-document operations stay O(scale)-aware. **Typing-latency leg shipped 2026-06-10** (branch `oplog-growth`, found during the M2 seal smoke at 70-page single-file scale): per-keystroke 325 ms → ~40 ms at 100 KB via (a) windowed typography application (whole-`NSTextStorage` restyle 227 ms → 0.8 ms, per-character equivalence-pinned; dual-dialogue `^` state folded into token identity), (b) `setFullText` parse-once (4 whole-doc parses → 1) + indexed exact-match tier (O(N²) → O(N), deterministic stored-order FIFO), (c) scanner ASCII fast paths + `TaskAnchorAlignment` unchanged-paragraph early-out (differential-pinned vs verbatim pre-fix oracles). Remaining at ~500 KB (≈250 pp, 2× a real feature): ~200 ms/keystroke in Debug; the floor is `FountainTokenizer`'s per-character walk — **future item: tokenizer buffer rewrite** with its own differential harness (`MaughamTests/Performance/TypingLatencyProbeTests` is the re-baselining probe; stage chunks at `/tmp/maugham-perf-probe`).
- ⤴ **Op-log compaction (Automerge/CRDT-style)** — **superseded** by [ADR 0016](adr/0016-op-log-growth-without-compaction.md): truncation breaks the append-only invariant and dangles checkpoint pointers / pre-horizon rewind / Merkle signatures. Replaced by the growth plan below.
- • **Op-log growth plan ([ADR 0016](adr/0016-op-log-growth-without-compaction.md))** — bound disk, sync churn, and derive time *without* deleting history: (1) ✓ **sequence keyframing** (M1, 2026-06-09, branch `oplog-growth`) — emit `sequence` on a burst only when ordering changed (+ first-burst-after-load + every-50 keyframe floor); kills the dominant redundancy for single-file screenplays. Fixture: novel op-log −39%, screenplay −78% / load 208→97 ms; the <5% sequence-share budget holds for typical drafting (the perf fixture's aggressive 1-in-7-burst reorder cadence is fully decomposed in `docs/superpowers/notes/2026-06-09-oplog-growth-m0-baseline.md`); (2) ✓ **sealed compressed segments** (M2, 2026-06-09, branch `oplog-growth`) — rotate each per-device JSONL at a size threshold into immutable SHA-256-checksummed LZFSE `.mzseg` segments; iCloud uploads each once (no more whole-history re-upload per burst) and the checksum closes most of the torn-append window (audit 0.6). Scope (T14): never the legacy unsuffixed file, never another device's tail, Mac-only seal; the phone reads segments for free through the shared MaughamCore helpers (`.mzseg`/seal grep tripwires on both targets); (3) **derived-state cache** under `.maugham/cache/` — pure deletable cache for load time, never truth. Sequence after the 100k-word perf fixture (performance pass) quantifies which terms dominate; keyframing first.

**Distribution & onboarding:**
- ✓ Production release pipeline (2026-05-23) — first installable Maugham as a `.dmg` from GitHub Releases + Tier 1.5 auto-update (silent background download, banner nudge on each ProjectWindow, state-derived **Maugham → Check for Updates…** menu hosted as a separate Window scene) + tag-triggered CI on `macos-15` with `latest-stable` Xcode + scripts/cut-release.sh local pre-flight + dev/stable variant coexistence (`BuildVariant.current` enum drives bundle id, display name, support folder, MCP socket path, Claude Desktop config key, MCP `serverInfo.name`, and updater on/off — Debug builds run as `Maugham Dev` at `com.maugham.Maugham.dev` with their own state and their own `maugham-dev` MCP entry). Version is tag-derived (CI rewrites `CFBundleShortVersionString` from the tag). Tag `milestone-production-release`; v0.2.0/0.2.1/0.2.2 cut through the pipeline (four shakedown bugs caught + fixed); 873 tests passing.
- ✓ **Code-signing & notarization** (shipped v0.6.0, 2026-06-03) — Developer ID Application cert + hardened runtime; CI notarizes and staples, so downloaded `.dmg`/`.zip` launch Gatekeeper-clean (no right-click → Open). Shipped alongside an **in-place auto-updater** (verified `.zip` → detached-helper swap → relaunch, or applied silently on next ordinary quit) that replaces the earlier reveal-the-`.dmg`-in-Finder behavior. Dev builds stay ad-hoc (`com.maugham.Maugham.dev`, updater disabled). Tag `milestone-mac-autoupdate`; spec `docs/superpowers/specs/2026-06-01-mac-auto-update-design.md`.
- • Welcome experience for new writers / future-you on a new Mac — clearer New Project sheet, better empty states, walkthrough
- • Project templates — Three-Act Novel, Hero's Journey, Short Story, etc.; pairs with distribution since templates are onboarding-flavored

---

## Group 5 — iPhone companion (mobile surface)

A phone surface for what the desk app can't reach — capture out-and-about, read on the go, triage Claude's annotations away from the desk. Built on iCloud Drive + the op log; the manuscript stays Mac-only-for-editing. Plan: `docs/superpowers/plans/2026-05-24-iphone-companion-v1.md`; ADR [0012](adr/0012-per-device-jsonl-partitioning.md) (per-device JSONL).

- ✓ **Mac groundwork** (merged 2026-05-29, merge `98128d1`) — extracted `Packages/MaughamCore` (Foundation-only shared substrate) + minted `ProjectManifest.id`; per-device JSONL partitioning so phone + Mac never conflict-twin a shared file; capture **inbox** (`InboxPane` ⌘⌥6, badge/promote/audio/edit/trash) with **WhisperKit** re-transcription behind a `Transcriber` seam; MCP 40 → 43 tools (`list_inbox`/`read_inbox_entry`/`promote_inbox_entry`).
- ✓ **iOS app — Phases D0–F** (merged 2026-05-30, merge `3fff8b5`) — the `MaughamPhone` four-tab app: **Capture** (text/photo/voice → inbox; on-device speech draft), **Read** (Markdown blocks + semantic Fountain), **Annotation review** (Accept/Reject/Archive op-log writes; opt-in Face ID gate). iCloud-Drive eviction handling; security-scoped bookmarks; shared `MaughamCore`. Two anti-duplication consolidations (`Deriver` + `MarkdownDisplayFilter` promoted to MaughamCore) + the `ScreenplayEmphasis` cross-surface contract. Smoke-verified on the simulator — six real bugs found + fixed (see `MaughamPhone/AREA.md`). Mac 1467 / phone 126 tests green.
- ✓ **Phase G — TestFlight pipeline + AppIcon** (shipped; first release `phone-v0.1.0` build 854, 2026-05-31) — `phone-v*` tag namespace, `phone-release.yml` GH Actions → TestFlight (archive → `-exportArchive` upload, altool-free on purpose), `cut-phone-release.sh`, signing secrets, M+¶ app icon. Five on-device bugs surfaced via the dry-run-is-the-integration-test loop; a follow-up doc-id contract fix shipped in `phone-v0.1.1`. Setup: `docs/release-notes/phone/SETUP.md`.
- ✓ **Cross-surface contract enforcement** (merged 2026-06-03; v0.6.1 / phone-v0.1.2) — a three-tier model (shared-impl / contracted-divergence / free-divergence) with action-triggered guards (MaughamCore choke-points + reach-around grep tripwires) so the phone can't reimplement what the Mac owns. Registry: `docs/superpowers/notes/cross-surface-contracts.md`. Fixed two real bugs (phone Fountain emphasis dropped; Mac task-anchor leak). Merge `ce46402`.
- • **Polish backlog** (uncommitted, may change) — Annotations show-resolved + undo; inbox preview in the Capture tab. See the plan's Phase H backlog.

---

## Deferred surfaces (not on the roadmap)

Considered and explicitly de-prioritized. Each gets a fresh brainstorm if/when prioritized.

- • **iPad companion** — read-only first, then drafting. Separate engineering bet on a different surface; not a feature of the desktop Mac app.
- ⤴ **Shared folder collaboration** — **superseded** by the **Human reviewer / collaborator layer (single-author lock)** in Group 2. The author lock is exactly the locking / conflict-avoidance model this surface said it needed; promoted from "deferred" to an active, scoped roadmap item.
- • **Goal-tracking calendar widget** — macOS widget extension; separate target from the app proper.

---

## Sequencing notes

- **Group 1's Tasks milestone** is the pathfinder for the analytical-layer arc and an immediately-useful daily-flow improvement; pickable independent of Phase 4a. The three subsequent layers (symbol DB, lint, writing analytics) are not on the roadmap yet — each gets a fresh brainstorm once Tasks is live and the shape is proven.
- **Group 1's screenplay intelligence (Phase 4a)** is the natural next drafting-flow milestone — picks up the inline-autocomplete and slugline-reuse work that was carry-forwarded from 3b/3c.
- **Group 2's manuscript-edit loop is closed** as of the editing milestone (2026-05-19): Claude can propose via the annotation layer; the writer disposes via the AnnotationsPane. The next AI-assist milestones are pickable in any order — Handwritten note import reuses the proposal/approval UX from the editing milestone, so it's the most natural follow-up if AI assist is the priority. The **human reviewer / collaborator layer** generalizes that same membrane to human collaborators behind a single-author lock — it's the largest open Group 2 bet and supersedes the old deferred shared-folder surface.
- **Group 3 (Compile)** is the "I want to send this to my agent" feature. Premature while still drafting; pick it up when there's something to ship.
- **Group 4 (Foundations)** items are pickable any time. **History Rewind** is the most interesting new candidate — the op log infrastructure makes it cheap to compute, and the "time travel over your own writing" affordance lands somewhere between Snapshots and the milestone-editing history view. Distribution becomes urgent only when Maugham needs to leave the dev Mac. Schema versioning becomes urgent only when a non-additive manifest change forces it.
