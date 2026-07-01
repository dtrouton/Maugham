# Phone Annotations drill-down + show-resolved

**Date:** 2026-07-01
**Surface:** `MaughamPhone/` (iOS companion)
**Status:** Design approved; ready for implementation plan
**Scope:** (1) project → chapter → notes drill-down; (2) global Open/All
show-resolved. **Undo/reopen is explicitly deferred** to its own milestone
(§ Deferred).

## Problem

The phone's Annotations tab (`AnnotationsListView`) shows **one flat cross-project
list** of Claude's still-open annotations, sectioned only into **Recent** /
**Other projects**. Each project section concatenates *every* open annotation
across *all* of that project's documents — no per-document breakdown, and no way
to narrow to a single project or chapter/piece. On a real manuscript with notes
spread across many chapters, the list is an undifferentiated scroll.

Two wants:

1. **Triage by locus** — focus on one project, then one chapter/piece, and see
   only its open notes.
2. **Review what was handled** — the list is `.open`-only today; a resolved note
   silently leaves and can't be re-surfaced from the phone. A read-only
   show-resolved view lets the writer review accepted/rejected/archived notes.

## Key fact that makes this cheap

`StructureItem.id` **is** the op-log `docId` (confirmed on the Mac side:
`ProjectStore.swift:231` loads `forDocId: item.id`; `ProjectStore+Tasks.swift:138`
matches `openDocIds.contains(item.id)`). Annotations on the phone are already
tagged with their `docId` (`LoadedAnnotation.docId`). The phone already loads
`project.manifest.structure` (the binder tree) for the Read tab.

Therefore the phone can map any annotation's `docId` → its chapter/piece **title**
and its **position/parent-group** in the binder by walking the structure tree —
**with no new data plumbing, no MaughamCore change, and no cross-surface contract
touched.** Both features in scope are a reshape of one phone view plus one pure
helper. (The deferred undo/reopen is the *only* part that would touch MaughamCore
— see § Deferred.)

## Interaction model (decided)

**Drill-down navigation** (not filter chips), three levels deep in a
`NavigationStack`, with a global **Open / All** segmented control at the root:

```
Annotations   [ Open | All ]           Novel                         Ch. 3 — The Arrival
▸ Novel            (12) ›       ACT I                          OPEN
▸ Screenplay        (3) ›       ▸ Ch. 1 — Arrival     (5) ›     💬  "tighten this line..."
                                ▸ Ch. 3 — The Letter  (2) ›     ✎  "POV slips here..."
   tap Novel ↓                  ACT II
                                ▸ Ch. 7 — Nightfall   (7) ›    RESOLVED   (only in All mode)
                                                                ✓ accepted · "typo fix"
                                                                ✗ rejected · "kept as-is"
```

- **Open** (default): only open notes drive the drill-down — today's triage
  behavior. Projects/chapters with zero open notes don't appear.
- **All**: projects/chapters that have **any** notes appear, including
  fully-triaged ones (all resolved), so the writer can review anything handled.
  Counts stay **open-count primary**; resolved shown as a muted secondary. The
  leaf shows an **OPEN** section then a dimmed **RESOLVED** section with
  accepted/rejected/archived status chips + `resolvedAt`.

At the **middle level**, chapters are a **flat list in binder order**, each with a
count, **sectioned under their immediate parent-group's title** as a header
(ungrouped chapters go under no header). Empty groups vanish.

## Design

### 1. `AnnotationsStore` — one observable source of truth

Extract the load/derive logic currently living as `@State` inside
`AnnotationsListView` into a new **`@Observable @MainActor final class
AnnotationsStore`**, mirroring `ProjectsBrowser`'s shape (plain `@Observable`,
injected deps — the AREA testability pattern; **not** `@AppStorage`).

Injected dependencies: `ProjectsBrowser`, `DownloadCoordinator`, `RecentsTracker`.

Why: the three drill-down levels must share **one** derived tree so a resolve deep
in the stack updates every level's count on reload, and so the Open/All toggle
re-filters a single already-loaded set without re-reading disk.

The store loads **all** annotation statuses (drops the current
`.filter { $0.status == .open }` at load) so `All` mode needs no second read; the
open/resolved split is a pure partition of the loaded set.

Published state (replaces `loaded: [ProjectAnnotations]`):

```swift
struct ProjectAnnotations: Identifiable {
    let id: ProjectId
    let projectName: String
    let projectURL: URL
    let chapters: [ChapterAnnotations]     // broken down by document; all statuses
    var openCount: Int      { chapters.reduce(0) { $0 + $1.openCount } }
    var resolvedCount: Int  { chapters.reduce(0) { $0 + $1.resolvedCount } }
}

struct ChapterAnnotations: Identifiable {
    let docId: String                      // == StructureItem.id
    let chapterTitle: String               // item.title, or fallback
    let groupTitle: String?                // immediate parent group's title (section header)
    let open: [LoadedAnnotation]
    let resolved: [LoadedAnnotation]       // accepted / rejected / archived, for All mode
    var id: String { docId }
    var openCount: Int { open.count }
    var resolvedCount: Int { resolved.count }
}
```

`LoadedAnnotation` (annotation + docId) is unchanged; its `annotation.status`
carries the open/resolved distinction and, for resolved, the concrete
accepted/rejected/archived state (`annotation.status` + `resolvedAt` +
`userResponse`, all already derived by `AnnotationDeriver`).

The store keeps today's off-render-path loading: `reload()` walks every project,
faults op-logs in via `ensureDownloaded`, loads + derives (reusing
`AnnotationLoading`), then **groups** (§2). It keeps `refreshBanner()` and the
Face-ID-gated `loadIfNeeded`. Invoked only from `.task`, the unlock button,
pull-to-refresh, and the `resolveTick` reload — never from a row body
(tripwire 4). The Open/All `mode` is view state; the store exposes a pure filter
helper so each level renders the right subset without reloading.

### 2. Grouping — a pure, table-tested function

New function in `AnnotationLoading` (the existing pure helper enum — no I/O, no
SwiftUI):

```swift
static func groupByChapter(
    _ annotations: [LoadedAnnotation],       // ALL statuses
    structure: [StructureItem],
    research: [ResearchItem]
) -> [ChapterAnnotations]
```

Behaviour:

- Walk `structure` (depth-first, binder order) building
  `docId → (title, parentGroupTitle)`. Reuse `TreeWalk`/`TreeNode` from
  MaughamCore (already used by `BinderView`).
- Fall back to the `research` tree for a docId not found in `structure` (research
  files can carry annotations; the phone enumerates *all* `.maugham/ops/` streams).
- **Unmapped docId** (stale manifest / orphan) → a `ChapterAnnotations` under an
  **"Other"** group with a short docId-derived title; **never dropped silently**
  (fail-visible, per the smoke-lessons ethos).
- Within each chapter, partition into `open` (`.status == .open`) and `resolved`
  (accepted/rejected/archived); both preserve `AnnotationDeriver`'s
  newest-first order.
- Output order: **binder order** for mapped chapters; unmapped/"Other" last.
- A chapter is emitted if it has **any** notes (open or resolved). The **view**
  hides zero-open chapters in `Open` mode (pure filter), so grouping stays
  mode-agnostic and fully testable.

Kept pure so it is table-driven unit-testable: binder-order, group-header
assignment, research fallback, unmapped → Other, open/resolved partition, empty
cases — **no filesystem**, per the AREA testability pattern.

### 3. Navigation — three levels + Open/All

`AnnotationsListView` becomes the **root (Projects)** view over `store.projects`,
filtered by the current `mode`:

- **Root — Projects.** A **`Picker(.segmented)` Open / All** in the nav bar (or a
  toolbar). `Open`: projects with ≥1 open note. `All`: projects with any note.
  Row: `projectName (openCount) ›`, with a muted `+N resolved` when in `All` and
  `resolvedCount > 0`. Keep today's **Recent / Other projects** sectioning. The
  Face ID unlock gate, the §3.13 **sync/needs-download/failed banner** with its
  inline action, and **pull-to-refresh** all stay here, unchanged. Empty state
  unchanged (tripwire 15: both frames); its copy adapts to `mode`
  ("No open annotations" vs "No annotations").
- **Middle — `ProjectChaptersView`.** Pushed on project tap. Flat chapter rows in
  binder order, sectioned by `groupTitle` header, filtered by `mode`. Row:
  `chapterTitle (openCount) ›` + muted `+N resolved` in `All`.
- **Leaf — `ChapterAnnotationsView`.** Pushed on chapter tap. In `Open` mode:
  just the open notes. In `All` mode: an **OPEN** section then a dimmed
  **RESOLVED** section — each resolved row shows a status chip
  (accepted ✓ / rejected ✗ / archived 🗄, from `AnnotationKind`/status) +
  `resolvedAt`, and is **non-actionable** (read-only review; taps still open the
  detail). Uses the existing `AnnotationRow` **minus the now-redundant project
  name**; resolved rows add the chip + dimming.
- **Single-document skip.** When a project has exactly **one** chapter *visible in
  the current mode*, the project row pushes **straight to
  `ChapterAnnotationsView`** — no dead one-row middle level. (Recomputed per mode,
  since `All` can reveal a second chapter.)

`AnnotationDetailView` opened from a **resolved** row is view-only in this
milestone — its Accept/Reject/Archive already hide when the annotation is not
`.open` (Race-2 guard, spec §5.3), so a resolved note simply shows its recorded
outcome. **No reopen affordance ships here** (§ Deferred).

### 4. Resolve loop

`AnnotationDetailView` is **untouched**. Its `onResolved` closure still bumps a
`resolveTick`; the root's `.onChange(of: resolveTick)` calls `store.reload()`.
Because all levels read the store's tree, counts recompute everywhere: a chapter's
open-count drops (and it leaves `Open` mode when it hits zero); the note moves
from `open` to `resolved` and is visible again in `All`. **No live cross-device
updates** (tripwire 5 — reflects remote changes only on appear / pull-to-refresh /
after a phone-side resolve).

### 5. Testing

- **Pure `groupByChapter`:** table-driven `AnnotationLoadingTests` — binder-order,
  parent-group header, nested-group immediate-parent, single-doc input,
  research-tree fallback title, unmapped-docId → "Other", open/resolved partition,
  status-chip source, empty input. No filesystem.
- **Mode filter helper:** pure — `Open` hides zero-open chapters/projects; `All`
  keeps any-note ones; counts correct. Table-tested.
- **Store load path** reuses the already-tested `AnnotationLoading.docIds` /
  `openAnnotations` primitives (the latter generalized to all-statuses, or a new
  `allAnnotations` sibling — decide in the plan); no new I/O logic beyond grouping.
- **Views** build-verified (UI/OS primitives can't unit-test — the AREA seam
  pattern). No new seam required; the store takes the deps the view already held.

## Deferred — undo / reopen (its own milestone)

The plan's Phase H backlog paired show-resolved with **undo/revert**. Analysis
shows undo is **not** a phone-local affordance: annotation status is a pure
function of the latest lifecycle op's kind, and no op maps back to `.open`
(`AnnotationDeriver.resolution` recognizes only claudeAccept/Reject/Archive). Undo
therefore requires:

- a **new `claudeReopen` OpKind** in MaughamCore →
- a **`ProjectManifest.currentSchemaVersion` bump** (OpKind schema contract, ADR
  0015), which has a **two-pipeline wrinkle**: once a new Mac rewrites a manifest
  at the bumped version, an **old phone rejects that project** via
  `decodeGuardingSchema` until updated (Mac and phone release independently);
- an **`AnnotationDeriver` change** (`isLifecycleKind` + `resolution` → `.open`) —
  a **cross-surface contract** touch, verified on the Mac too;
- a UX decision: reopening an **accepted suggestedChange re-surfaces the note but
  does not revert the materialized manuscript text** (a lifecycle-only reopen
  carries no `ParagraphChange`). "Undo" means re-triage, not un-edit — must be
  designed on purpose, not ridden in.

Deferred so the schema bump and the reopen-≠-revert semantics get a deliberate
milestone. Show-resolved (read-only) ships now and stands alone.

## Non-goals / out of scope

- No filter chips or search (drill-down + Open/All is the model).
- **No undo/reopen** (deferred above). Resolved rows are read-only review.
- No live cross-device refresh (tripwire 5).
- No change to `AnnotationDetailView`, `AnnotationWriter`, the op-log format, or
  any MaughamCore type. No cross-surface contract touched **in this milestone**.

## Tripwires respected

- **4** — no per-row derivation; grouping happens once in the store, rows render
  pre-derived values.
- **5** — no `NSFilePresenter`; refresh only on appear / pull / resolve.
- **15** — root empty state keeps both `.frame` calls.
- **3** (iOS) — docId parsing still routes through `OpLogStore.docIds(...)` in
  MaughamCore; no local stricter predicate.
- **19** — nothing the Mac owns is reimplemented; grouping + Open/All are
  phone-local UI over shared data.

## Files

- **New:** `MaughamPhone/Annotations/AnnotationsStore.swift` (`@Observable`
  all-status load + grouped tree + pure mode filter).
- **New:** `MaughamPhone/Annotations/ProjectChaptersView.swift`,
  `MaughamPhone/Annotations/ChapterAnnotationsView.swift` (drill-down levels;
  the leaf renders OPEN + optional RESOLVED sections).
- **Edit:** `MaughamPhone/Annotations/AnnotationLoading.swift` (add pure
  `groupByChapter` + the mode filter + result types, or co-locate result types
  with the store — decide in the plan; generalize `openAnnotations` to all
  statuses or add `allAnnotations`).
- **Edit:** `MaughamPhone/Annotations/AnnotationsListView.swift` (becomes the
  Projects root over the store; adds the Open/All segmented control; move load
  `@State` into the store).
- **Edit:** `MaughamPhone/MaughamPhoneApp.swift` (construct/inject the store, or
  let the view own it — match how `ProjectsBrowser` is wired; decide in the plan).
- **Edit:** `MaughamPhoneTests/` — `groupByChapter` + mode-filter table tests.
```
