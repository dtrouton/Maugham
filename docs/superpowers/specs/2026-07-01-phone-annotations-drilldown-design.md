# Phone Annotations drill-down — project → chapter → notes

**Date:** 2026-07-01
**Surface:** `MaughamPhone/` (iOS companion)
**Status:** Design approved; ready for implementation plan

## Problem

The phone's Annotations tab (`AnnotationsListView`) shows **one flat cross-project
list** of Claude's still-open annotations, sectioned only into **Recent** /
**Other projects**. Each project section concatenates *every* open annotation
across *all* of that project's documents — there is no per-document breakdown and
no way to narrow to a single project or a single chapter/piece. On a real
manuscript with notes spread across many chapters, the list is an undifferentiated
scroll.

The writer wants to **triage by locus**: focus on one project, then one
chapter/piece, and see only its open notes.

## Key fact that makes this cheap

`StructureItem.id` **is** the op-log `docId` (confirmed on the Mac side:
`ProjectStore.swift:231` loads `forDocId: item.id`; `ProjectStore+Tasks.swift:138`
matches `openDocIds.contains(item.id)`). Annotations on the phone are already
tagged with their `docId` (`LoadedAnnotation.docId`). The phone already loads
`project.manifest.structure` (the binder tree) for the Read tab.

Therefore the phone can map any annotation's `docId` → its chapter/piece **title**
and its **position/parent-group** in the binder by walking the structure tree —
**with no new data plumbing, no MaughamCore change, and no cross-surface contract
touched.** This is a reshape of one phone view plus one pure helper.

## Interaction model (decided)

**Drill-down navigation** (not filter chips), three levels deep in a
`NavigationStack`:

```
Annotations (Projects)                 Novel                         Ch. 3 — The Arrival
▸ Novel            (12) ›      ACT I                          💬  "tighten this line..."
▸ Screenplay        (3) ›      ▸ Ch. 1 — Arrival     (5) ›    ✎  "POV slips here..."
                               ▸ Ch. 3 — The Letter  (2) ›
   tap Novel ↓                 ACT II                            tap a note ↓
                               ▸ Ch. 7 — Nightfall   (7) ›    → AnnotationDetailView (unchanged)
```

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

Why: the three drill-down levels must share **one** derived tree so that a resolve
deep in the stack updates every level's count on reload. Threading value snapshots
into pushed views would leave stale counts behind.

Published state (replaces `loaded: [ProjectAnnotations]`):

```swift
struct ProjectAnnotations: Identifiable {
    let id: ProjectId
    let projectName: String
    let projectURL: URL
    let chapters: [ChapterAnnotations]     // NEW: broken down by document
    var count: Int { chapters.reduce(0) { $0 + $1.annotations.count } }
}

struct ChapterAnnotations: Identifiable {
    let docId: String                      // == StructureItem.id
    let chapterTitle: String               // item.title, or fallback
    let groupTitle: String?                // immediate parent group's title (section header)
    let annotations: [LoadedAnnotation]
    var id: String { docId }
    var count: Int { annotations.count }
}
```

`LoadedAnnotation` (annotation + docId) is unchanged.

The store keeps today's off-render-path loading exactly: `reload()` walks every
project, faults op-logs in via `ensureDownloaded`, loads + derives open
annotations (reusing `AnnotationLoading.openAnnotations`), then **groups** them
(§2). It also keeps `refreshBanner()` and the Face-ID-gated `loadIfNeeded`.
Invoked only from `.task`, the unlock button, pull-to-refresh, and the
`resolveTick` reload — never from a row body (tripwire 4).

### 2. Grouping — a pure, table-tested function

New function in `AnnotationLoading` (the existing pure helper enum — no I/O, no
SwiftUI):

```swift
static func groupByChapter(
    _ annotations: [LoadedAnnotation],
    structure: [StructureItem],
    research: [ResearchItem]
) -> [ChapterAnnotations]
```

Behaviour:

- Walk `structure` (depth-first, binder order) building `docId → (title, parentGroupTitle)`.
  Reuse `TreeWalk`/`TreeNode` from MaughamCore (already used by `BinderView`).
- Fall back to the `research` tree for a docId not found in `structure` (research
  files can carry annotations; the phone enumerates *all* `.maugham/ops/` streams).
- **Unmapped docId** (stale manifest / orphan) → a `ChapterAnnotations` under an
  **"Other"** group with a short docId-derived title; **never dropped silently**
  (fail-visible, per the smoke-lessons ethos).
- Output order: **binder order** for mapped chapters; unmapped/"Other" last.
- Only chapters with ≥1 open annotation appear.

Kept pure so it is table-driven unit-testable: binder-order, group-header
assignment, research fallback, unmapped → Other, and the empty cases — with **no
filesystem**, per the AREA testability pattern.

### 3. Navigation — three levels

`AnnotationsListView` becomes the **root (Projects)** view over
`store.projects`:

- **Root — Projects.** Only projects with open notes. Keep today's **Recent /
  Other projects** sectioning. Row: `projectName (count) ›`. The Face ID unlock
  gate, the §3.13 **sync/needs-download/failed banner** with its inline action,
  and **pull-to-refresh** all stay here, unchanged. Empty state unchanged
  (tripwire 15: both frames).
- **Middle — `ProjectChaptersView`.** Pushed on project tap. Flat chapter rows in
  binder order, sectioned by `groupTitle` header. Row: `chapterTitle (count) ›`.
- **Leaf — `ChapterAnnotationsView`.** Pushed on chapter tap. Lists the chapter's
  annotations using the existing `AnnotationRow` **minus the now-redundant project
  name**. Each row is a `NavigationLink` to the **unchanged `AnnotationDetailView`**.
- **Single-document skip.** When a project has exactly **one** chapter with notes
  (every Screenplay; small projects), the project row pushes **straight to
  `ChapterAnnotationsView`** — no dead one-row middle level. Implemented by making
  the project row's navigation destination conditional on `chapters.count == 1`.

### 4. Resolve loop

`AnnotationDetailView` is **untouched**. Its `onResolved` closure still bumps a
`resolveTick`; the root's `.onChange(of: resolveTick)` calls `store.reload()`.
Because all levels read the store's tree, counts recompute everywhere: a chapter
that hits zero drops out of its project; a project that hits zero drops off the
root. **No live cross-device updates** (tripwire 5 unchanged — reflects remote
changes only on appear / pull-to-refresh / after a phone-side resolve).

### 5. Testing

- **Pure `groupByChapter`:** table-driven `AnnotationLoadingTests` cases —
  binder-order preservation, parent-group header assignment, nested-group
  immediate-parent, single-doc collapse input, research-tree fallback title,
  unmapped-docId → "Other", empty input. No filesystem.
- **Store load path** reuses the already-tested `AnnotationLoading.docIds` /
  `openAnnotations` primitives; no new I/O logic to test beyond grouping.
- **Views** are build-verified (UI/OS primitives can't run in a unit test — the
  AREA seam pattern). No new seam required; the store takes the same injected deps
  the view already held.

## Non-goals / out of scope

- No filter chips or search (drill-down is the model).
- No live cross-device refresh (tripwire 5).
- No change to `AnnotationDetailView`, `AnnotationWriter`, the op-log format, or
  any MaughamCore type. No cross-surface contract touched.
- No MaughamCore changes (grouping lives in the phone's `AnnotationLoading`; it
  consumes existing MaughamCore types `StructureItem` / `ResearchItem` /
  `TreeWalk`).

## Tripwires respected

- **4** — no per-row derivation; grouping happens once in the store, rows render
  pre-derived values.
- **5** — no `NSFilePresenter`; refresh only on appear / pull / resolve.
- **15** — root empty state keeps both `.frame` calls.
- **3** (iOS) — docId parsing still routes through
  `OpLogStore.docIds(...)` in MaughamCore; no local stricter predicate.
- **19** — nothing the Mac owns is reimplemented; grouping is phone-local UI over
  shared data.

## Files

- **New:** `MaughamPhone/Annotations/AnnotationsStore.swift` (`@Observable` load +
  grouped tree).
- **New:** `MaughamPhone/Annotations/ProjectChaptersView.swift`,
  `MaughamPhone/Annotations/ChapterAnnotationsView.swift` (drill-down levels).
- **Edit:** `MaughamPhone/Annotations/AnnotationLoading.swift` (add pure
  `groupByChapter` + supporting result types, or co-locate result types with the
  store — decide in the plan).
- **Edit:** `MaughamPhone/Annotations/AnnotationsListView.swift` (becomes the
  Projects root over the store; move load `@State` into the store).
- **Edit:** `MaughamPhone/MaughamPhoneApp.swift` (construct/inject the store, or
  let the view own it — decide in the plan; match how `ProjectsBrowser` is wired).
- **Edit:** `MaughamPhoneTests/` — new `groupByChapter` table tests.
```
