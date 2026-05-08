# Phase 2 Breakdown — Sub-milestone Plan

**Date:** 2026-05-08

**Status:** Phase 1 complete (milestones 1a–1e tagged). This note records how Phase 2 is decomposed into sub-milestones, given that several Phase 2 items per the master design were already shipped during Phase 1.

**Anchor:** This builds on Section 5 of `docs/superpowers/specs/2026-05-07-maugham-master-design.md`, where Phase 2 is described as *"Novel Project Depth — A novelist's working environment"*.

---

## What's already done (Phase 1 outran the schedule)

The master design specifies Phase 2 as containing several items we landed during 1d/1e:

| Master spec'd for Phase 2 | Already shipped in |
|---|---|
| Binder right-click menu (rename, delete) | 1d |
| Status indicators in binder | 1d (Draft/Revising/Final colored dot in `BinderRow`) |
| Multi-document handling through store | 1e (`DocumentStore` + `NSFileCoordinator`) |
| Manifest reads/writes through store | 1e (`DocumentStore.writeManifest` / `readManifest`) |
| Multi-document editor: switch between docs without losing focus state | 1e (per-document cursor restore via `DocumentStore.cursorPositions`) |

This left less in Phase 2 than the master spec implies — but the remaining work is still substantial enough to warrant decomposition.

---

## What's actually left in Phase 2

Six work areas, grouped into three sub-milestones below.

### 1. Drag-reorder in binder

Was deferred from 1d explicitly because multi-file rename wasn't safe without `DocumentStore`. Now that 1e shipped, this is the natural first task: drag a chapter, all sibling NN prefixes renumber atomically through the coordinator. Pulls in **"Tidy filenames"** (compact gaps in NN sequence after deletes) as a related cleanup pass, since both involve the same coordinated multi-file-rename primitive.

### 2. "Duplicate" right-click action

Master spec mentions `rename, duplicate, delete-to-trash, snapshot` for the binder context menu. We have rename and delete already; snapshot is Phase 5; **duplicate** is small but missing.

### 3. Research section UI

A pane (or new tab in three-pane window) listing files under `research/`, with basic preview for images (`NSImageView`) and PDFs (`PDFView`). New SwiftUI surface; manifest already has a `research: [ResearchItem]` field from 1a.

### 4. Inspector growth

Current inspector has synopsis + status + word count. Add: **tags** (free-form list, comma/chip UI), **per-document word target** (Stepper, 0 = no target), **links** (cross-references to other documents — design TBD).

### 5. Word goals + session tracking

Track *words written this session* and *words written today*, compare against per-document and project-level targets. Likely a small dashboard in the inspector or a separate "Project Statistics" window.

### 6. Conflict diff view

Replace the disabled "Show diff (Phase 2)" button in `ConflictBanner` with a real diff. Likely a sheet showing local vs external side-by-side or unified-diff style.

### 7. Project Statistics window

Master spec calls this out separately. Aggregate view: total words, target progress, words-by-chapter heatmap, session history. Similar surface to Scrivener's Project Statistics.

---

## Sub-milestone decomposition

Splitting Phase 2 into three milestones rather than one monolith — each lands as a tag, each merits its own brainstorm → spec → plan → execute cycle:

### 2a — Binder polish

**Scope:** Drag-reorder + Tidy filenames + Duplicate.

**Why grouped:** All multi-file-rename ops; share the same `DocumentStore`-coordinated batching primitive; cohesive *binder polish* slice. Pays off the 1e DocumentStore investment immediately.

**Estimate:** ~12 tasks.

### 2b — Surfaces

**Scope:** Research section UI + Conflict diff view.

**Why grouped:** Both are *new surfaces*; both involve previewing/comparing content; could share file-rendering primitives (image, PDF, text-with-highlights). Both are SwiftUI-heavy with limited pure-logic units.

**Estimate:** ~14 tasks.

### 2c — Metadata + metrics

**Scope:** Inspector growth (tags, links, per-doc word target) + Word goals + Project Statistics window.

**Why grouped:** All *metadata + metrics*; share a common write path through `ProjectStore.updateInspector` and the manifest's `targets` block. Session tracking and Statistics window both need the same per-day word-count aggregation.

**Estimate:** ~18 tasks.

---

## Order

Recommended order: **2a → 2b → 2c**.

- **2a first** because it pays off DocumentStore immediately, is the most user-visible "depth" feature, and unlocks the file-system layout that 2b's research section will lean on.
- **2b second** because the conflict diff view is functionally needed (the disabled button is a visible loose end) and the research section UI is large enough to benefit from a clean slate after 2a's binder work.
- **2c last** because it's the most metadata-heavy and benefits from having the structural depth (drag-reorder, research) settled first.

---

## What this isn't

- Not a spec for any individual sub-milestone — those come from the brainstorm/spec cycle for each (2a, 2b, 2c).
- Not binding on master design ordering. The master spec's Phase 2 description is preserved in `docs/superpowers/specs/2026-05-07-maugham-master-design.md`; this note is a project-state-aware pragmatic decomposition.
- Not committing to merge timing. Each sub-milestone tags independently as `milestone-2a`, `milestone-2b`, `milestone-2c`. They can ship out of order if priorities change.
