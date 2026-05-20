# Stores — Area guide

The persistence and coordination layer: project structure, documents, recents, sessions, trash, debounce scheduling, and the `.maugham/` filesystem layout. Read this before editing in `Maugham/Stores/`. Also read the project root `CLAUDE.md` for cross-cutting invariants.

## What this area owns

- Project structure mutation and persistence (`ProjectStore`).
- Document load/save/conflict-resolution coordination with NSFileCoordinator/Presenter (`DocumentStore`).
- The `.maugham/` filesystem layout for everything derived.
- Small focused stores: recents, sessions, trash, debounce scheduling.
- Search across the binder (`BinderSegment.find`).

## Layout

- `ProjectStore.swift` — ~2760 lines. The big one. Natural seams already split out via `extension`:
  - Structure CRUD (root file)
  - Trash (separate extension or section)
  - Inspector (metadata)
  - Research
  - Collection-Pieces (extension — **emulate this pattern** when you need a new seam)
  - WikiLink (`[[…]]` resolution and rename propagation)
- `DocumentStore.swift` — document lifecycle. NSFileCoordinator/Presenter for cloud sync. 750ms autosave debounce. Conflict resolution flow. Bolted-on op-log integration that's bug-bearing (see tripwire #1).
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

1. **`DocumentStore.currentDocumentText` is overloaded.** It serves *both* conflict detection (which wants the stored-on-disk form) *and* op-log context (which wants the display form). This is a bug-bearing seam — code that "obviously needs the current text" might be reading the wrong form. When editing here, decide explicitly which form you need and consider adding a separate accessor.

2. **`wait*` helpers in `DocumentStore` are test-only living in production code.** Don't call them from production paths; don't add new ones without marking them `#if DEBUG` or moving them to a test helper.

3. **Don't model a new store after `ProjectStore`.** It's 2760 lines because the project is the central polymorphic aggregate; that complexity is justified there and not elsewhere. Model after `RecentsStore` / `TrashStore` / `SessionLog` — small, focused, one responsibility.

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
- **Missing high-value coverage:** the `currentDocumentText` form-confusion seam (tripwire #1) has no regression test that would catch a caller using the wrong form. Adding one would prevent a class of future bugs.

## What's intentionally NOT here

- The text editor / NSTextView — `Maugham/Editor/`.
- The op log itself — `Maugham/OpLog/` (Stores writes *into* `.maugham/ops/` only via the OpLog stores; doesn't decide log format).
- UI for any of these (binder views, conflict diff sheet, trash UI) — `Maugham/Views/`.
- MCP tool handlers that read store state — `Maugham/MCP/Tools/`.
- Model types (ProjectType, Manifest, ItemRole, etc.) — `Maugham/Models/`.
