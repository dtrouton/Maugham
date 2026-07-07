# Scoped Research — unify piece/chapter research associations

**Date:** 2026-07-07
**Status:** Approved (brainstorm 2026-07-07)

## Problem

Maugham has three places a writer associates research with what they're writing, and they don't see each other:

1. **Explicit references (Model A).** `StructureItem.linkedResearchIds: [String]?` (`Packages/MaughamCore/Sources/MaughamCore/StructureItem.swift:38`) — an ID array on the manuscript piece, persisted in the manifest. Surfaced by the right pane's Research mode (`LinkedResearchPane`), created by drag from the binder or `ResearchLinkPickerSheet`. Store API: `linkResearch` / `unlinkResearch` / `linkedResearchIds(forDocumentId:)` / `resolveResearchLinks` (`Maugham/Stores/ProjectStore+Structure.swift:667-717`). MCP: `link_research`, `unlink_research`, `list_all_links`.
2. **Physical containment (Model B, Collections only).** A research item "belongs to" a piece because its `ResearchItem.path` lives under `pieces/<NN>-<slug>/research/` (`ProjectStore+CollectionPieces.swift:448-549`). Surfaced by `CollectionResearchPane`'s Shared vs per-piece sections. No link record exists — the folder location *is* the association. MCP is blind to it.
3. **Wiki-links** — read-time computed edges, out of scope here and unchanged.

The clunk: add a piece-scoped research note in a collection (Model B), open the right pane's Research mode, and it isn't there — `LinkedResearchPane` reads only `linkedResearchIds`, so the writer must re-link from the full research picker something the folder structure already declared. The same "lands in shared, re-file manually" friction exists for inbox promotion (`InboxStore.promoteToResearch` hardcodes `parentId: nil`, `Maugham/Stores/InboxStore.swift:196-220`), and novel chapters have no one-step "create a note for this chapter" flow at all.

**Why containment must stay:** `promotePieceToProject` moves the whole piece `research/` folder into the new standalone project and rewrites paths (`ProjectStore+CollectionPieces.swift:299-341`). Cross-collection references work the same way. Containment is what makes a piece portable with zero manifest surgery on link IDs. It is the strongest association the writer can express; the fix is to make the other surfaces *read* it, not to replace it.

**Prior art.** Scrivener's Document Bookmarks vs Project Bookmarks is exactly the document-scoped vs shared split (and Scrivener shares our wart: binder-nested research doesn't auto-appear as a Document Bookmark). Ulysses attaches research to the sheet and it's simply *there* when the sheet opens. Obsidian computes the backlinks pane — nobody re-declares an association the structure already expresses. This design is "Scrivener's two scopes with the wart fixed."

## Design

### 1. Data model — no changes

- Containment stays the association mechanism for collection pieces (portability under promotion / cross-collection referencing).
- `linkedResearchIds` stays the explicit many-to-many mechanism (any piece ↔ any shared research item).
- No new manifest fields. No migration (per project policy: none anyway).
- Wiki-links untouched.

### 2. New store-level concept: research creation scope

A typed enum following the ADR 0010 typed-seam pattern:

```swift
enum ResearchScope {
    case shared
    case document(id: String)   // a StructureItem id — collection piece or chapter
}
```

One routing implementation in `ProjectStore` (e.g. `createResearchNote(scope:title:)`, `addResearchAsset(scope:fromURL:)`, `addResearchLink(scope:...)`):

| Scope | Collection piece (`pieceKind == .loose`) | Multi-doc document (novel chapter) | Single-doc project types (short story, screenplay) | `.shared` |
|---|---|---|---|---|
| Behavior | Write into `pieces/<slug>/research/` (delegates to existing `addPieceResearchNote`/`Asset`/`Link`) | Create in shared research, then append the new item's ID to that document's `linkedResearchIds` | Create in shared research, no link — §3's derivation already surfaces all research as the document's | Today's `addResearchTextNote(parentId: nil, …)` etc., unchanged |

All creation surfaces call this routing instead of hand-rolling destination logic: the binder (`CollectionResearchPane`, already scope-aware — refactor to call through), the right pane (new, §3), and inbox promotion (§4).

### 3. Right pane (`LinkedResearchPane`) becomes scope-aware

- **New derived "Piece Research" section**, shown above the existing "Linked Research" section:
  - Collection piece active → items whose `path` has the piece's `pieces/<folder>/research/` prefix (same rule as `CollectionResearchPane.pieceItems()`).
  - Single-doc project types (short story, screenplay) → *all* project research is the document's research.
  - Novel/multi-doc → no derived section; chapters associate via `linkedResearchIds` only.
- Derived items are not unlinkable from the pane (there's no link to remove); moving them to shared remains a binder operation.
- **Creation affordances** in the pane header: **New Note**, **Add File…**, **Add Link…** — matching the binder's creation menu, routed through the active document's scope (§2). Created items appear immediately in the appropriate section.
- `ResearchLinkPickerSheet` excludes items already in the derived section (linking to something already owned is redundant) and leads with shared items.
- Preview behavior, drag-to-link, and per-row unlink for the "Linked Research" section are unchanged.

### 4. Inbox promotion gets a destination

`InboxPane` context menu (`InboxPane.swift:177`):

- **"Promote to Research"** — shared, unchanged (default).
- **"Promote to Research for *[Active Document Title]*"** — one click, targets the currently active manuscript document; hidden when no manuscript document is active.
- **"Promote to Research for…"** — opens a searchable document picker (pattern: `ResearchLinkPickerSheet`) listing chapters/pieces.

`InboxStore.promoteToResearch` gains a `scope: ResearchScope` parameter (default `.shared`) and routes through §2. Terminal `.promoted` status handling, error alert, and the duplicate-asset-on-failure guarantee are unchanged. Image/audio promotion to a collection-piece scope moves the asset into the piece's `research/` folder.

### 5. MCP parity

- `promote_inbox_entry` gains optional `target_document_id` (validated: unknown ID fails loudly, per catalog policy).
- `list_all_links` emits containment as a new edge type `piece_research` (piece → research item), ending MCP's blindness to Model B. `linked_research` and `wiki` edges unchanged.
- `link_research` / `unlink_research` unchanged.
- Reference output (`ReferenceTools.swift:149` area) includes piece-owned research alongside linked research.
- Known blast radius: schema changes touch the tools-list tests (≥3 broke last time a tool was added — onboarding milestone lesson).

### 6. Promotion follow-through (free)

A piece promoted to a standalone project already carries its research files with rewritten `research/…` paths. Rule §3's single-doc derivation means the promoted project's right pane shows that research automatically — no re-linking step after promotion.

## Error handling

- Scope routing for a document ID that doesn't exist or isn't a valid target (e.g. a Collection reference piece, `pieceKind != .loose` where containment is required): fail loudly (typed error), never silently fall back to shared.
- Orphan `linkedResearchIds` continue to be filtered on read (`resolveResearchLinks`), unchanged.
- Inbox promote failure semantics unchanged (worst case: duplicate asset, never data loss).

## Testing

- **Scope routing unit tests** per project type × creation kind (note/asset/link): collection piece → path under piece folder; novel chapter → shared item + `linkedResearchIds` appended; single-doc → shared item, no link appended; `.shared` → today's behavior. Invalid target → typed error.
- **Derivation agreement**: the right pane's derived section and `CollectionResearchPane.pieceItems()` use one shared predicate (extract it; test both surfaces against it).
- **Picker exclusion**: an item in the derived section never appears in `ResearchLinkPickerSheet`'s list for that document.
- **Inbox**: `promoteToResearch(scope:)` per kind × scope; MCP `promote_inbox_entry` with/without `target_document_id`, including unknown-ID failure.
- **MCP**: `list_all_links` emits `piece_research` edges for a collection fixture; tools-list tests updated.
- **Promotion regression**: existing `promotePieceToProject` tests extended to assert carried research satisfies the single-doc derivation rule (paths rewritten to `research/…`).
- Manual smoke: collection piece → add piece note in binder → right pane shows it without linking; right-pane New Note on a novel chapter → appears linked; phone capture → promote to active piece → lands in piece folder.

## Out of scope

- Research→research linking (unchanged: right pane shows empty state when a research note is the active doc).
- Per-chapter `research/` folders for novels — rejected: the portability rationale (promotion, cross-collection referencing) doesn't apply to chapters; containment would complicate the on-disk layout for no benefit.
- Wiki-link mechanism changes.
- Moving items between scopes from the right pane (stays a binder operation).
- Auto-linking on creation (writing `linkedResearchIds` for containment-owned items) — rejected: duplicates truth, drifts on file moves and promotion.
