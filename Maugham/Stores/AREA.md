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
  - `ProjectStore+Tasks.swift` — project-scope pane-created tasks + cross-project task aggregation
- `DocumentStore.swift` — project-folder coordinator + Document registry. Owns the NSFilePresenter, manifest IO, session tracking, UI state, rename/copy/move orchestration, **and the typed user-content mover** (see below). Per-doc op-log, autosave, conflict-detection, and echo guard now live on `Document` (post-`milestone-document-first-class`); this file routes external presenter callbacks to the matching Document via the registry.
- `MaughamSidecarPath.swift` — typed classification of project-relative file URLs into manifest / opLog / checkpoints / sessions / uiState / conflictBackup / scratch / pending / trash / unknownSidecar / otherProjectFile / outsideProject. `presenterDidChangeSubitem` dispatches via a switch on this enum — adding a new sidecar owner is a compile-error workflow. See [ADR 0010](../../docs/adr/0010-typed-cross-area-seams.md).
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
| `.maugham/pending/` | `PendingBuffer` (OpLog area) | Device-partitioned crash-recovery buffer (`<docId>.<slug>.pending.jsonl`). Relocated out of `ops/` so it can't match the op-log glob (tripwire 17 / ADR 0012). Ephemeral; safe to nuke. |
| `.maugham/trash/` | `TrashStore` | 30-day soft-delete; sweep on app launch |
| `.maugham/ops/__project__.jsonl` | `ProjectStore+Tasks` | Reserved synthetic doc id for project-scope pane-created tasks (milestone-tasks). The op log is real but no manuscript backs it. **Do not allocate a real document with id `__project__`.** |

Don't invent new top-level subdirs without a reason. If you need a new one, the convention is: lowercase noun, plural if it's a collection of records.

## Typed user-content mover (tripwire 14, enforce-by-construction)

Moving or deleting a path the user might be editing (a manuscript `.md`/`.fountain`, a Collection piece folder, or a research note/folder) goes through **one** of three `DocumentStore` entry points — never a raw `FileManager.moveItem`/`moveToTrash`:

| Entry point | Use for |
|---|---|
| `relocate(plan:)` | A flat `RenamePlan` batch — binder rename / reorder / cross-group move (`renameStructureItem`, `moveStructureItem`, `moveResearchItem` cross-group). |
| `relocateUserContent(affectedPaths:perform:)` | A bespoke move that isn't a flat plan — the Collection piece's two-phase temp-suffix folder swap (`movePiece`/`renamePiece`), the research note + sibling `<slug>_assets/` rename (`renameResearchPath`). Run the FS surgery in `perform`, using `coordinatedMove`/`coordinatedWrite` for each step. |
| `trash(relativePath:using:…)` | Soft-delete into `.trash/` (`deleteStructureItem`, `deleteResearchItem`). |

Each runs the **close-before-FS-surgery** discipline INTERNALLY before any FS call: `document(for:)?.close() + unregister()` for every open Document at an affected path, **plus** `flushPendingSave()` for the path-keyed research-note debounce. This is what makes tripwire 14 structural rather than remembered — a caller cannot forget either half, which dissolves findings 1.3 (executeRenamePlan didn't flush) and 1.6 (movers closed but didn't flush). **This replaces the prose tripwire-14 description that used to live in CLAUDE.md** (the "Close-before-FS-surgery" note in `Views/AREA.md` now points here).

**Enforcement:** `MaughamTests/TripwireGrepTests.test_noRawMoveOfUserContentOutsideTypedMover` forbids raw `.moveItem(` / `.moveToTrash(` in the `ProjectStore+{Structure,CollectionPieces,Research,WikiLink}` seams. A sibling self-check (`…FiresOnPlantedOffender`) proves the grep catches a planted offender.

**The boundary (intentionally NOT routed):** internal, non-user-edited moves stay raw and are excluded from the grep via an explicit `// internal-move:` marker — the `promotePieceToProject` staging moves (into a temp `staging/` tree, which already closes+flushes upstream), and the no-`DocumentStore` fallback branches (load-only contexts like unit tests have no registry/scheduler, so the discipline is a provable no-op). Empty-file scaffolding (`Data().write`), `.maugham-link.json`/manifest writes, scratch tmp writes, and `executeCopy` (Duplicate) are derived/internal and out of scope. When you add a NEW mover of user-editable content, route it through one of the three entry points above — do not add a raw move with an `// internal-move:` marker unless it's genuinely one of these internal classes.

## Palette + craft-intent seams (2026-07-09)

Two new research-adjacent conventions, both plain-edited (no op log, no `¶id` anchors — same precedent as research notes) and both absence-is-valid: **palette cards** (`ProjectStore+Palette.swift`) are markdown research assets under a `research/palette/` group (kind/swatches/senses/images convention), parsed on load via `PaletteCard` (`Maugham/Models/PaletteCard.swift`); the typed user-content mover already covers them for free since they're ordinary research items. **Craft intent** (`ProjectStore+CraftIntent.swift`) is a single conventional `craft-intent.md` per scope — project-level for novel/screenplay/short-story, per-loose-piece (in that piece's own research folder) for collections — with no doc existing being a first-class, deliberate state, not a missing file to backfill.

## Derived-manuscript cache + async word counts (F5, 2026-07-01)

- **`ProjectStore.derivedCache` (`DerivedManuscriptCache`, MaughamCore)** fronts
  `DerivedManuscript` for **closed** docs, so the hot read-loops (cross-document
  search per debounced keystroke, project-open word counts, the
  link/reference/scenes tools, the wiki-rename pre-check) don't replay a doc's
  full op-log history on every call. Validity token = the doc's op-log file set
  with each file's `(url, mtime, size)`; a token match returns the cached derived
  state, else it derives and stores. **Open docs bypass the cache** and read the
  live `Document` (they're already the freshest source; ADR 0018 open-doc rule).
- **Owner is `ProjectStore`, not `DocumentStore`** — deliberately. Every adopter
  already holds a `ProjectStore`, and word-count population needs the cache
  *during / just after* `load`, when the weak `documentStore` back-ref isn't wired
  yet. It's content-keyed on op-log mtimes, so even the fresh (cold) `ProjectStore`
  the Statistics window loads derives correctly against its own instance.
  `@ObservationIgnored` — internal machinery, never an observed SwiftUI dependency.
- **Project-open word counts are now ASYNC** (`beginWordCountPopulation`, held as
  `wordCountPopulationTask` so tests can await it). They left the blocking `load`
  path: counts populate after the window appears, with a `Task.yield()` per doc,
  streaming in as they land. **Accepted trade-off:** `projectWordCount` is partial
  for an instant after open (transient live-counter skew) and self-corrects as the
  counts stream in. Perf guards assert derive-COUNTS (cache hits), not wall-clock,
  so CI can't flake.

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
- `MaughamTests/Integration/PresenterRoutingTests.swift` — cross-area integration tests for the `presenter → Document` routing seam. Asserts: typed-path classifier round-trips every canonical sidecar subdir; our own autosave doesn't reingest as `externalEdit`; an external `.md` edit is silently discarded (re-materialized to the op-log truth, not reingested) per ADR 0019; MCP `add_annotation` against a live doc doesn't synthesize spurious `claude_archive` ops; unhandled sidecar paths don't route to manuscripts.

## What's intentionally NOT here

- The text editor / NSTextView — `Maugham/Editor/`.
- The op log itself — `Maugham/OpLog/` (Stores writes *into* `.maugham/ops/` only via the OpLog stores; doesn't decide log format).
- UI for any of these (binder views, conflict diff sheet, trash UI) — `Maugham/Views/`.
- MCP tool handlers that read store state — `Maugham/MCP/Tools/`.
- Model types (ProjectType, Manifest, ItemRole, etc.) — `Maugham/Models/`.
