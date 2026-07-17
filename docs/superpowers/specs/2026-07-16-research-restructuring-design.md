# Research Restructuring — scope moves, collection-pane parity, multiselect

**Date:** 2026-07-16
**Status:** Implemented (branch `feat/research-restructuring-2026-07-16`, 2026-07-16)

## Problem

Reorganising research in a collection is blocked three ways:

1. **No scope moves.** Research scope is purely path-derived — an item is piece
   research iff its `path` starts with `pieces/<NN>-<slug>/research/`
   (`ProjectStore.pieceResearchPrefix`, `Maugham/Stores/ResearchScope.swift:120`).
   Nothing moves an item between collection level (shared) and a piece: the
   scoped-research design (2026-07-07) deferred it ("stays a binder operation")
   and the binder never got it. `CollectionResearchPane.handleResearchReorder`
   silently ignores cross-section drags (`CollectionResearchPane.swift:305`).
2. **Groups in collections are decorative.** `CollectionResearchPane` renders
   only top-level items, flat — no `DisclosureGroup`, no children — and its
   drop handler only does same-section sibling reorder with `toParentId: nil`.
   Drop-into-group is unhandled, and there are no in-group creation context
   items. A group can be created but never filled through the UI; if an item
   did land in one, the pane would not render it. `ResearchView` (all other
   project types) has full tree rendering and drop-into-group
   (`ResearchView.swift:74-167`) — the collection pane is a degraded fork.
3. **No multiselect.** Both research surfaces use single-selection
   (`List(selection: $selectedResearchId)`, `String?`), so a reorganisation
   session is one item at a time.

**Latent bug found during investigation:** `moveResearchItem`'s cross-group
branch (`ProjectStore+Research.swift:308-338`) builds a `RenamePlan` with only
the item's own path. `renameResearchPath` (title rename) carefully moves a
note's sibling `<slug>_assets/` folder; the cross-group move does not — moving
a note with embedded images into another group orphans its assets folder and
breaks the image refs. The fix rides this milestone.

## Decisions (brainstorm Q&A)

- **Surfaces:** drag between sections, context-menu "Move to…", and an MCP tool
  — all three.
- **Groups are movable across scopes**, not just leaf items.
- **Link cleanup both ways:** moving into piece X drops X's now-redundant
  explicit link; moving out of piece X auto-creates an explicit link X→item so
  the right-pane association survives.
  (Amended 2026-07-17 after user smoke: scope moves no longer touch
  linkedResearchIds — manual links stay dormant while contained and resurface
  on move-out; containment-only associations sever.)
- **Multiselect drives full batch operations** (move, delete), not move-only.
- **Approach A** (scope-aware extension of the existing typed-mover seam) over
  B (overload `toParentId` with piece ids — stringly, conflates id namespaces,
  anti-ADR-0010) and C (restructure the manifest so pieces are real group
  nodes — huge blast radius across promotion portability, phone reads, and
  every path-prefix filter, for the same behavior).

## Design

### 1. Store — one batch, scope-aware move API

New in the `ResearchScope.swift` seam (ADR 0010 typed-seam pattern):

```swift
enum ResearchMoveTarget: Equatable {
    case sharedRoot            // top level of research/
    case group(String)         // into an existing research group, wherever it lives
    case piece(String)         // top level of a loose piece's research/ folder
}

func moveResearchItems(
    ids: [String], to target: ResearchMoveTarget, atIndex: Int? = nil
) async throws
```

- **Validate everything up front; move nothing on failure.** Unknown ids,
  group-into-own-descendant cycles, invalid piece targets (via existing
  `researchRouting` — reference pieces and unknown docs already throw), role
  guards. One invalid id fails the whole batch with a typed error.
- **Selected-descendant collapsing:** if a selected item sits inside a selected
  group, the group's move carries it; the redundant id is dropped from the
  batch, not double-moved.
- **One `RenamePlan`** containing every step — files, group folders (with
  descendant manifest-path rewrites, reusing the existing rewrite walk), and
  `_assets/` sibling folders for notes — executed by a single
  `documentStore.relocate(plan:)`, then one manifest rewrite + `saveManifest()`.
  Tripwire 14 (close-before-FS-surgery + debounce flush) comes free from the
  typed mover.
- **`.link` items** have synthetic `.link` paths with no file on disk:
  manifest path rewrite only, no plan step.
- **`_assets` handling** (also fixes the latent bug): the plan builder becomes
  the single place that knows a `.document`-kind note travels with its sibling
  `<slug>_assets/` folder. The existing single-item cross-group move
  (`moveResearchItem`) routes through the same builder. If arrival dedup
  changes the note's leaf slug, the assets folder is renamed to match and the
  note's `./<slug>_assets/` refs are rewritten (same logic `renameResearchPath`
  already has for renames).
- **Link cleanup both ways, same manifest save:** into piece X → remove the
  moved ids from X's `linkedResearchIds`; out of piece X → append the moved
  ids to X's `linkedResearchIds`. Piece→piece = remove from source piece's
  links if present, drop from destination's (containment covers it).
  (Amended 2026-07-17 after user smoke: scope moves no longer touch
  linkedResearchIds — manual links stay dormant while contained and resurface
  on move-out; containment-only associations sever. Phase 5 and the C2
  sourceScopes capture were removed.)
- **Role guards:** items with `role == .paletteGroup` or `.craftIntent` refuse
  cross-scope moves (typed error; UI hides the affordance). Palette *cards*
  are ordinary items — moving one out of the palette group is allowed and
  simply leaves the wall, as today. Same-scope reorders of role items are
  unaffected.
- `deleteResearchItems(ids: [String])` — batch soft-delete, one manifest save,
  built on the existing `trash` entry point.

### 2. Collection pane parity

Extract `ResearchView`'s tree rendering into a shared component (recursive
`DisclosureGroup` nodes, drop-position handling, group context-menu creation
items) and adopt it in `CollectionResearchPane`:

- Both the Shared section and piece sections render **nested trees**; groups
  work inside pieces.
- **Drop-into-group** works (`.middle` position on a group row), matching
  `ResearchView`.
- **Cross-section drops are scope moves** via the new API: drag from Shared
  into a piece section (or back, or piece→piece). Drop on a section header or
  empty area targets that section's root; top/bottom on a row in another
  section moves to that section at that position.
- Group rows in collections gain "New Note / New Group / Add File… /
  Add Link…" in-group context items (parity with `ResearchView`).
- Section assignment stays path-derived (`scopeFor` / `pieceResearchPrefix`) —
  only top-level manifest items are section roots; descendants render through
  the tree.

### 3. Multiselect + batch operations (both surfaces)

- `List(selection:)` becomes `Set<String>` on `ResearchView` and
  `CollectionResearchPane`. The existing single-id binding that drives the
  preview panes is **derived** (selection count == 1 → that id, else nil), so
  preview plumbing and its callers don't change.
- **Drag:** dragging a row that's part of the current selection moves the
  whole selection (standard Mac behavior). The drop payload stays the single
  dragged id; the handler expands it to the selected set when the dragged id
  is a member, and calls the batch API once, preserving current visual order.
- **Context menu on a selection:** "Move to ▸" submenu — Shared, each group
  (nested paths flattened as "World / Maps"), each loose piece (collections
  only) — plus batch **Delete**. Rename and Duplicate stay single-item and
  hide when the selection is multiple. Role-guarded items (palette group,
  craft intent) don't get cross-scope targets in the submenu.

### 4. MCP

One new tool, `move_research_item` (47→48), in the catalog per
`MCPToolCatalog.all` convention:

- Args: `research_ids` (array — reorganisation sessions are batch by nature),
  plus exactly one of `target: "shared"` / `target_group_id` /
  `target_document_id`. Mutual-exclusion and unknown ids fail loudly per
  catalog policy.
- `list_all_links` needs no change: `piece_research` edges are path-derived
  and update automatically after a move.
- Known blast radius: tools-list tests (≥3 broke last time a tool was added —
  onboarding-milestone lesson).

### 5. Out of scope / accepted

- **Undo:** research structure ops aren't op-log backed; moves stay
  non-undoable, consistent with every existing research mutation.
- **Phone:** no research UI; manifest path changes are invisible to it, and
  the role guard keeps the palette group where `PaletteLookup` expects it.
- **True FS atomicity for batches:** the plan executes steps sequentially; a
  mid-batch I/O failure can leave earlier steps applied. Mitigated by
  validating the full batch up front (the failure class left is disk-level
  I/O, same exposure as today's single moves).
- Wiki-links unchanged (title-addressed; moves don't change titles).

## Error handling

- Typed errors for: unknown id, non-group `target_group_id`, cycle, reference
  piece target, role-guarded cross-scope move, missing `DocumentStore`.
  Never a silent fallback to shared (scoped-research precedent).
- Name collisions on arrival: dedup via existing `researchDedupedFilename`;
  assets folder follows the deduped slug with in-note ref rewrite.
- Orphan `linkedResearchIds` continue to be filtered on read (unchanged).

## Testing

- **Store:** target × item-shape matrix — note+assets (incl. collision-dedup
  ref rewrite), group with descendants (manifest path rewrites), link item
  (manifest-only), plain asset; role-guard errors; cycle; unknown id; batch
  up-front validation (one bad id moves nothing); descendant collapsing; link
  cleanup in both directions; piece→piece.
- **Regression:** the `_assets` orphan bug pinned on the existing single-item
  cross-group move.
- **Panes:** section-assignment/derivation agreement (existing predicate);
  selection-set → preview-id derivation; drag-expansion of a selection.
- **MCP:** happy paths per target kind, fail-loudly cases, tools-list tests
  updated.
- **Manual smoke:** collection → create group → drag note in → disclosure
  renders → multiselect three items → Move to piece → files land under
  `pieces/<NN>-<slug>/research/` and the right pane shows them → move one
  back → explicit link appears in Linked Research.
