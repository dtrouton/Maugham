# Stores — Area guide

The persistence and coordination layer: project structure, documents, recents, sessions, trash, debounce scheduling, and the `.maugham/` filesystem layout. Read this before editing in `Maugham/Stores/`. Also read the project root `CLAUDE.md` for cross-cutting invariants.

## What this area owns

- Project structure mutation and persistence (`ProjectStore`).
- Document load/save/conflict-resolution coordination with NSFileCoordinator/Presenter (`DocumentStore`).
- The `.maugham/` filesystem layout for everything derived.
- Small focused stores: recents, sessions, trash, debounce scheduling.
- Search across the binder (`BinderSegment.find`).

## Layout

- `ProjectStore.swift` itself is small (~170 lines, holds the core types and the main `ProjectStore` class declaration). The seams are in **peer files** (one file per seam — emulate this pattern when you add a new one):
  - `ProjectStore+Structure.swift` — Structure CRUD
  - `ProjectStore+Trash.swift` — Trash + undo
  - `ProjectStore+Metadata.swift` — Inspector metadata
  - `ProjectStore+Research.swift` — Research item CRUD
  - `ProjectStore+CollectionPieces.swift` — Collection loose pieces
  - `ProjectStore+References.swift` — Collection project-references (Mac-local)
  - `ProjectStore+WikiLink.swift` — `[[…]]` resolution and rename propagation
  - `ProjectStore+Search.swift` — search across the binder
- `DocumentStore.swift` — project-folder coordinator + Document registry. Owns the NSFilePresenter, manifest IO, session tracking, UI state, rename/copy/move orchestration. Per-doc op-log, autosave, conflict-detection, and echo guard now live on `Document` (post-`milestone-document-first-class`); this file routes external presenter callbacks to the matching Document via the registry.
- `MaughamSidecarPath.swift` — typed classification of project-relative file URLs into manifest / opLog / checkpoints / sessions / uiState / conflictBackup / scratch / trash / unknownSidecar / otherProjectFile / outsideProject. `presenterDidChangeSubitem` dispatches via a switch on this enum — adding a new sidecar owner is a compile-error workflow. See [ADR 0010](../../docs/adr/0010-typed-cross-area-seams.md).
- `DebounceScheduler.swift`, `RecentsStore.swift`, `SessionLog.swift`, `TrashStore.swift` — small focused stores, well-bounded. **Use these as the model** for new stores; don't model new things after `ProjectStore`'s size.
- `BinderSegment` files — search across documents (`⌘⌥F`) plus the regular binder slicing.
- ID-prefix helpers / generators — see ADR 0008.

## The `.maugham/` filesystem layout (canonical)

Everything derived lives under `.maugham/` in the project folder. Each subdirectory has one owner:

| Path | Owner | Purpose |
|---|---|---|
| `.maugham/ops/` | `OpLogStore` (in OpLog area) | Per-doc JSONL op logs |
| `.maugham/checkpoints/` | `CheckpointStore` (OpLog area) | Project-scope checkpoints from ⌘S |
| `.maugham/conflicts/` | `DocumentStore` | Conflict backup copies |
| `.maugham/sessions/` | `SessionLog` | Per-session activity records |
| `.maugham/ui-state/` | `ProjectStore` (UI extension) | Window position, last-opened doc, cursor restore |
| `.maugham/scratch/` | Various | Transient writes; safe to nuke |
| `.maugham/trash/` | `TrashStore` | 30-day soft-delete; sweep on app launch |

Don't invent new top-level subdirs without a reason. If you need a new one, the convention is: lowercase noun, plural if it's a collection of records.

## Tripwires

1. **Don't reintroduce a shared "current text" field on `DocumentStore`.** The historical `currentDocumentText: String` was overloaded between conflict detection (stored-form) and op-log context (display-form) — that field is gone post-`milestone-document-first-class`. Document text now lives only on `Document` itself: `displayText` (public, observed) and `lastDiskEcho.bytes` (private, echo-guard only, see `Maugham/OpLog/EchoState.swift`). If you find yourself wanting a "DocumentStore-side current text" again, you're probably about to recreate the bug; route via the registry's `document(for:)` lookup instead.

2. **`wait*` helpers in `DocumentStore` are test-only living in production code.** Don't call them from production paths; don't add new ones without marking them `#if DEBUG` or moving them to a test helper.

3. **Don't model a new store after `ProjectStore`.** The `ProjectStore` + eight peer extension files together are large because the project is the central polymorphic aggregate; that complexity is justified there and not elsewhere. Model after `RecentsStore` / `TrashStore` / `SessionLog` — small, focused, one responsibility.

4. **Don't double-prefix IDs.** ID prefixes are canonical after ADR 0008. If you see `scene-scene-…` or `doc-doc-…`, that's a bug. The prefix is applied once, by the generator.

5. **Don't bypass `DebounceScheduler` for autosave-like behavior.** The 750ms window is calibrated; ad-hoc debouncing leads to thrash. If you need a different cadence, add a configured instance, don't reinvent.

6. **Don't write directly to `.maugham/` subdirs from outside this area.** Each subdir has one owner; route through it. (The OpLog area writes to `.maugham/ops/` and `.maugham/checkpoints/` — that's the one exception, by ownership.)

7. **NSFileCoordinator/Presenter is required for any cloud-synced file.** Don't read or write manuscript / project files without it; iCloud will race you and conflict-bomb the user.

8. **Adding a new `extension ProjectStore`** for a new seam is the established pattern (Collection-Pieces does this). Don't introduce a new top-level store class for something that's logically project-scoped.

## What to read before editing

- For project structure / binder mutations: start with `ProjectStore.swift` and find the relevant extension.
- For document lifecycle / autosave / conflict: `DocumentStore.swift` + ADR 0001 (autosave) and ADR 0007 if it exists for conflict (check `docs/adr/`).
- For new small store: read `RecentsStore.swift` or `TrashStore.swift` as the model.
- For the op-log boundary (where `DocumentStore` bolts onto the op log): `Maugham/OpLog/AREA.md`.
- For ID prefix rules: `docs/adr/0008-*.md`.

## Tests worth knowing about

- `MaughamTests/StoreTests/` — unit tests per store.
- `MaughamTests/Integration/PresenterRoutingTests.swift` — cross-area integration tests for the `presenter → Document` routing seam. Asserts: typed-path classifier round-trips every canonical sidecar subdir; our own autosave doesn't reingest as `externalEdit`; `resolveConflictKeepMine`'s autosave doesn't reingest; MCP `add_annotation` against a live doc doesn't synthesize spurious `claude_archive` ops; unhandled sidecar paths don't route to manuscripts.

## What's intentionally NOT here

- The text editor / NSTextView — `Maugham/Editor/`.
- The op log itself — `Maugham/OpLog/` (Stores writes *into* `.maugham/ops/` only via the OpLog stores; doesn't decide log format).
- UI for any of these (binder views, conflict diff sheet, trash UI) — `Maugham/Views/`.
- MCP tool handlers that read store state — `Maugham/MCP/Tools/`.
- Model types (ProjectType, Manifest, ItemRole, etc.) — `Maugham/Models/`.
