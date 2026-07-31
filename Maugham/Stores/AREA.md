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
  - `ProjectStore+CanvasAssets.swift` — the canvas's asset well (see below)
  - `ProjectStore+Statements.swift` — find-or-create a statement by scope (see below)
  - `ProjectStore+StatementAdoption.swift` — the one-time, on-open migration of legacy craft-intent notes (see below)
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
| `relocate(plan:)` | A flat `RenamePlan` batch — binder rename / reorder / cross-group move (`renameStructureItem`, `moveStructureItem`, `moveResearchItem` cross-group, `moveResearchItems` batch scope move). |
| `relocateUserContent(affectedPaths:perform:)` | A bespoke move that isn't a flat plan — the Collection piece's two-phase temp-suffix folder swap (`movePiece`/`renamePiece`), the research note + sibling `<slug>_assets/` rename (`renameResearchPath`). Run the FS surgery in `perform`, using `coordinatedMove`/`coordinatedWrite` for each step. |
| `trash(relativePath:using:…)` | Soft-delete into `.trash/` (`deleteStructureItem`, `deleteResearchItem`, batch `deleteResearchItems`). |

**`moveResearchItems(ids:to:atIndex:)`** (`ProjectStore+ResearchMove.swift`, 2026-07-16) is a **fourth routed caller** of `relocate(plan:)`, not a new entry point — it builds one `RenamePlan` covering every step in the batch (file moves, group-folder moves with descendant manifest-path rewrites, and each moved note's sibling `<slug>_assets/` folder) and executes it through the same `documentStore.relocate(plan:)` single call, so tripwire 14's close-before-FS-surgery + debounce-flush discipline applies for free. `ResearchMoveTarget` (`.sharedRoot` / `.group(id)` / `.piece(id)`) is the typed destination (ADR 0010 pattern); validation happens entirely before any FS call (unknown ids, cycles, role-guarded cross-scope moves all fail the whole batch, moving nothing). `.link` items are manifest-path-only (no file, no plan step). The file is in the `TripwireGrepTests.test_noRawMoveOfUserContentOutsideTypedMover` census alongside the other research/structure seams. `deleteResearchItems(ids:)` (`ProjectStore+Research.swift`) is the equivalent batch soft-delete: one up-front validation pass, one `trashResearchItemCore` per id, one manifest save — built on the existing `trash` entry point, not a new one. (Its `item.kind != .link` guard, present since before this milestone, is what keeps a pathless link item from being handed to the file-mover, which would throw "no such file" — the batch path inherits the same guard.)

Each runs the **close-before-FS-surgery** discipline INTERNALLY before any FS call: `document(for:)?.close() + unregister()` for every open Document at an affected path, **plus** `flushPendingSave()` for the path-keyed research-note debounce. This is what makes tripwire 14 structural rather than remembered — a caller cannot forget either half, which dissolves findings 1.3 (executeRenamePlan didn't flush) and 1.6 (movers closed but didn't flush). **This replaces the prose tripwire-14 description that used to live in CLAUDE.md** (the "Close-before-FS-surgery" note in `Views/AREA.md` now points here).

**Enforcement:** `MaughamTests/TripwireGrepTests.test_noRawMoveOfUserContentOutsideTypedMover` forbids raw `.moveItem(` / `.moveToTrash(` in the `ProjectStore+{Structure,CollectionPieces,Research,WikiLink,ResearchMove}` seams. A sibling self-check (`…FiresOnPlantedOffender`) proves the grep catches a planted offender.

**Collection-pane parity note (2026-07-16):** `CollectionResearchPane` used to be a degraded fork of `ResearchView` — flat rendering (no nested groups), same-section-only reorder, single selection. It now shares `ResearchTree`'s `ResearchTreeNode`/`ResearchSelectionSync` (`Maugham/Views/ResearchTree.swift`) with `ResearchView`, so both surfaces render full nested trees, support drop-into-group, and drive `Set<String>` multiselect. The store-side counterpart of that parity work is this file: the pre-existing single-item cross-group `moveResearchItem` had a latent bug — its `RenamePlan` carried only the moved item's own path, silently orphaning a note's sibling `<slug>_assets/` folder (and breaking its image refs) on a cross-group move. `moveResearchItems`' plan builder is now the single place that knows a `.document`-kind note travels with its assets folder, and the pre-existing single-item mover was retrofitted to route through the same builder — so the fix lands for both the old one-at-a-time path and the new batch path.

**Palette writes are grep-enforced too, same shape.** `ProjectStore+Palette.swift` must route card writes through `paletteCoordinatedWrite(_:to:)`, never a raw `.write(to:)` — enforced by `TripwireGrepTests.test_noRawWriteInPaletteStore`. The funnel's own unit-test fallback (used when `documentStore == nil`) is the one allowed raw write; mark that line `// palette-coordinated-write: <reason>` so the grep can tell it apart from a reach-around.

**The boundary (intentionally NOT routed):** internal, non-user-edited moves stay raw and are excluded from the grep via an explicit `// internal-move:` marker — the `promotePieceToProject` staging moves (into a temp `staging/` tree, which already closes+flushes upstream), and the no-`DocumentStore` fallback branches (load-only contexts like unit tests have no registry/scheduler, so the discipline is a provable no-op). Empty-file scaffolding (`Data().write`), `.maugham-link.json`/manifest writes, scratch tmp writes, and `executeCopy` (Duplicate) are derived/internal and out of scope. When you add a NEW mover of user-editable content, route it through one of the three entry points above — do not add a raw move with an `// internal-move:` marker unless it's genuinely one of these internal classes.

## Palette + craft-intent seams (2026-07-09)

Two new research-adjacent conventions, both plain-edited (no op log, no `¶id` anchors — same precedent as research notes) and both absence-is-valid: **palette cards** (`ProjectStore+Palette.swift`) are markdown research assets under a `research/palette/` group (kind/swatches/senses/images convention), parsed on load via `PaletteCard` (now `Packages/MaughamCore/Sources/MaughamCore/PaletteCard.swift`, moved from Mac-only, tripwire 19); the typed user-content mover already covers them for free since they're ordinary research items. **Craft intent** (`ProjectStore+CraftIntent.swift`) is a single conventional `craft-intent.md` per scope — project-level for novel/screenplay/short-story, per-loose-piece (in that piece's own research folder) for collections — with no doc existing being a first-class, deliberate state, not a missing file to backfill.

## The canvas's asset well — `ProjectStore+CanvasAssets.swift` (1C-d, 2026-07-30)

`ingestCanvasAsset(image:)` / `ingestCanvasAsset(fileURL:)` are the **one pair** that gives a canvas item node a file of its own, and every 1C-d route — Finder drop, browser bitmap, inbox promotion — is a *caller* of it rather than a storage decision of its own. (A *research* drag ingests nothing: that item has a home already and the canvas holds only its position.)

**Both twins have exactly one production caller as of Task 11, and they are the two arms of one drop.** `ProjectWindow` hands `CanvasView` a `CanvasAssetIngest` holding both; `CanvasExternalDrop` routes a Finder drag (a file URL) to the file twin, which preserves the name and extension, and a browser drag (a rendered bitmap, no file URL) to the image twin. Re-rendering the Finder case through the image twin, or writing the browser case to a temp file to reuse the file twin, would each have left the other half of a built pair with no caller — this directory's signature defect, and the twin's own doc comment says the pair was built for both.

- **`canvas_assets/` sits at the PROJECT ROOT, beside `canvas.md`, and is content rather than derived state.** It is deliberately not under `.maugham/`: deleting `.maugham/canvas.json` costs the arrangement and must never cost the photographs. It is the one asset well whose owner is the canvas rather than a research note.
- **No naming, dedupe or timestamp scheme of its own.** The pair hands `ImagePasteHandler` the canvas's own `canvas.md`, and that saver's existing `<slug>_assets` derivation yields `canvas_assets/` for free. The well's name is therefore **derived and never spelled** in production code — move `canvas.md` and the well follows.
- **The pair returns a PROJECT-RELATIVE path**, which is what `CanvasItemReference.owned(path:)` requires. The saver returns a Markdown ref one step earlier; resolving it is `ProjectStore.resolveImageRef(_:relativeTo:)` — the palette's, shared rather than respelled (its label was generalised from `cardDirectory:` for this). An absolute path, a `file://` URL or the ref itself each renders nothing, keys the thumbnail cache on a string that differs between Macs, and breaks the moment the project is moved or synced.
- **Two tripwires, same shape as the palette's.** `TripwireGrepTests.test_theSharedImageSaverIsCalledFromTheSeamsThatOwnAWell` is a census of the files allowed to call `ImagePasteHandler.saveAndReference*` (count the set, not the prose); `…test_theCanvasAssetWellIsDerivedAndNeverSpelledInCode` catches the other reach-around, a hand-built `"canvas_assets"` path that never names the pair at all. Both have a planted-offender self-check.
- **The image write itself is uncoordinated**, matching the two existing wells: these are new files with minted unique names, written once and never re-edited, so there is no second writer for NSFileCoordinator to arbitrate. A *manuscript* or a card's markdown is a different case — those still route through `DocumentStore` (tripwire 7).

## The statement seam — `ProjectStore+Statements.swift` (M1A, 2026-07-31)

A **statement** — the writer's intent, or the book's visual language — is a `Statement` entry in `ProjectManifest.statements` whose content is an ordinary `Document` living **in the open at the project root** (`intent.md`, `intent/<slug>.md`, `visual-language.md`; spec §2.2). It is the artifact that replaces craft intent; `ProjectStore+CraftIntent.swift` is still present and still has consumers until Task 7 moves them.

- **Lookup is by SCOPE, in the manifest — there is no path prefix and no filename convention in the read path.** That is the point, not an implementation detail. `craftIntentItem(forPieceId:)` looked its doc up through `ResearchScope.pieceResearchPrefix`, which opens `guard piece.pieceKind == .loose`, so a **novel chapter's** intent was created into shared `research/` where the lookup never looked and the next create minted a second copy of the writer's prose. `PromotionPerformer.performCraftIntent` carries a comment block describing that from the inside. There is no prefix here, so there is nothing to be nil.
- **The shared half is `MaughamCore`'s** (tripwire 19): `StatementLookup.statement(in:kind:scope:)` is pure — no stamping, no side effects, `PaletteLookup`'s shape — and `StatementConvention.newPath(kind:scope:documentSlug:)` is the §2.2 storage table's one spelling. The Mac wraps them with creation; the phone reads them.
- **Absence is valid and free.** `ProjectStore.statement(kind:scope:)` returns nil having minted nothing, stamped nothing and logged nothing — unlike `craftIntentItem`, which lazily healed a legacy identity on read. A statement's identity IS its manifest entry, so there is nothing to heal. `read_craft_intent`'s shipped description already promises Claude that absence is "a valid, deliberate state"; the store must not contradict its own MCP surface.
- **`createStatement(kind:scope:)` refuses rather than redirects.** A scope naming something that is not a manuscript document in this project throws `.structureMissing`; a `(kind, scope)` pair with no row in the table (visual language at document scope, an ADR-0015 `.unknown` from a newer build) throws `.statementHasNoStorage`. A chapter's intent quietly written into the book's file is the same class of loss as a second file nobody reads.
- **Creation never takes an occupied path.** Two documents may share a title, so their slugs collide — and an **untracked file** may already sit at the candidate path. Since the manifest is the only authority on a statement's identity, registering one over an untracked file would point `resolveDocId` at it, bootstrap the statement from its bytes and then own it: `createStatement` steers to `intent-2.md` instead. (A test plants the offender; with the steer removed, the writer's file is emptied by the empty scaffolding write.)
- **The slug is derived from the document's title once, at creation, and never re-derived.** Identity is the manifest `id` (tripwire 22), so a rename moves the title and leaves the path. A statement's path moves through the typed `DocumentStore` mover like any other user-editable content (tripwire 14).

## Adoption — `ProjectStore+StatementAdoption.swift` (M1A, 2026-07-31, spec §5)

`adoptLegacyCraftIntentIfNeeded()` runs from `ProjectStore.load`, once per project, and moves a writer's existing craft-intent research notes into their intent `Statement`. It is the one seam in the milestone that touches prose the writer already wrote, and every ruling in it is biased toward not destroying a word of it.

- **The gate is the ON-DISK schema version** — `< 4`, stamped to `ProjectManifest.currentSchemaVersion` afterwards. Gating on "has no `statements` section" would re-scan, forever, every writer who legitimately has no intent (absence is a valid, deliberate state). The `4` is a fixed number and deliberately *not* `currentSchemaVersion`: a future bump to 5 must not re-run adoption across every schema-4 project.
- **The stamp is UNCONDITIONAL, including after a failure**, and that is the reading of "once". A manifest carrying a `statements` section while still declaring schema 3 is §2.5's exact hazard: an older build reads it happily and re-saves it *without* the section, orphaning the statement files it points at. An un-adopted note costs nothing by comparison — it is still in the research tree, still the writer's. **There is no resume; there is no retry.**
- **The content arrives as a BOOTSTRAP OP**, via `Document.load`'s `needsBootstrap` branch — the sanctioned import read, and the surface `Bootstrap.run` must be reached through. Writing the file and stopping would look identical on screen and leave adopted intent with no history at all.
- **Duplicates concatenate, oldest first** (`ResearchItem.addedAt`, ties on tree order), separated by a blank line. The §3 defect has been minting second copies for as long as it has shipped, so a writer can hold two notes for one scope with no way to tell which is "the" one — concatenating is recoverable, choosing is not.
- **Scope is read off the manifest, most specific evidence first:** a Collection loose piece's research prefix; then **a `linkedResearchIds` record naming exactly one document**; then the project. **The middle tier is the headline case, not an edge** — §3's defect is a *novel's*, whose chapter intent routes through `.sharedPlusLink` into shared `research/` and *writes a link on the way*. Without it, a writer with intent on ten chapters opens the new pane to one headingless blob with the records that said whose was whose trashed alongside. A note claimed by two documents falls to the project: that ambiguity is real, and guessing would file intent under a heading the manifest never claimed.
- **The step order is the safety property.** Every body is read *before* anything is created, so a note this build cannot read costs nothing but its own adoption; the notes are **trashed last** (`deleteResearchItems`), so nothing leaves the research tree until its words are durably elsewhere. **A scope is adopted whole or not at all**: an unreadable body fails its scope rather than being shrugged off as an empty one, or an undownloaded iCloud file would be silently adopted as nothing and then trashed.
- **That trash does NOT run the typed mover's discipline at adoption time, and does not need to.** `documentStore` is wired by `ProjectWindow` only *after* `ProjectStore.load` returns, so `trashResearchItemCore` takes its `// internal-move:` branch (`trashStore.moveToTrash` directly). Safe for that branch's own stated reason — no registry to race, no open Document, no debounced save — and **not** because the close/flush ran. Don't reason about this window as though it did.
- **A note with no file, or with an empty body, is not adopted and not touched.** There is no prose in either, and a pathless item handed to `deleteResearchItems` is dropped from the manifest with **no trash entry** — a silent, unrecoverable removal in the one seam that must never make one.
- **Failure never blocks the open.** The entry point does not throw; scopes are isolated from each other and a failure is logged. Losing access to a manuscript because an intent note was odd is far worse than un-adopted intent.
- **`modified` shifts only when prose actually moved.** The schema stamp alone leaves it alone — the project-id backfill's reasoning, *"backfilling an identifier is not a content edit"* — so opening a shelf of old projects once does not reshuffle the wall. Adoption of real prose does shift it, because moving the writer's words between files genuinely changes the project. Both directions are pinned, and the tests must cross a whole-second boundary first or neither assertion can fail (`modified` round-trips through whole-second ISO8601).
- **Detection is role-first with the legacy filename as a fallback, and the fallback is unreachable through `load` today** — `healPaletteRolesEagerly` runs immediately before adoption and stamps exactly the notes it would catch (verified: a planted role-only detection passed the whole suite through the load path). It is kept, and tested by driving adoption directly, because after Task 7 adoption is the last reader of `ResearchRole.craftIntent` and that half of the palette heal becomes the kind of thing a tidying pass removes.

## Role identity — `ResearchItem.role` (2026-07-11)

Path/filename matching (`research/palette`, `craft-intent.md`) was fragile: renaming either through an ordinary Research affordance detached the wall/inspector/MCP from the item (no data loss, but the next add minted a duplicate). `ResearchItem.role: ResearchRole?` (MaughamCore) is the durable fix — an additive-optional field (`paletteGroup`/`craftIntent`/`.unknown` sentinel for forward-tolerance, ADR-0015 pattern; absent → nil; no manifest schema bump).

- **Lookups go role-first, path-second.** `PaletteConvention`/`PaletteLookup` (MaughamCore) hold the canonical constants (`folderPath`, `groupTitle`, `craftIntentFileName`, `craftIntentTitle`) and the shared role-first-then-path lookup functions; `ProjectStore.paletteGroup()`/`craftIntentItem(forPieceId:)` wrap them. `ProjectStore.paletteFolderPath`/`paletteGroupTitle`/`craftIntentFileName`/`craftIntentTitle` are now thin aliases onto `PaletteConvention`, not independent literals.
- **Lazy healing, no migration.** A lookup that falls back to path/filename identity stamps the role on that item and saves the manifest (`ProjectStore.healRole`/`stampRole`, fire-and-forget `Task`, idempotent) — the item is role-identified from then on. Renaming the palette group or a craft-intent doc through any Research affordance no longer detaches it. Mac-only: the phone never writes the manifest, so it consumes `PaletteLookup` read-only with no healing.
- **Live title everywhere.** `ProjectStore.paletteGroupDisplayTitle` reads the group's actual (possibly renamed) title with no side effect, so the wall header/sidebar always show what the writer renamed it to, not the frozen default.

## Promote-into-card seam (2026-07-11)

`InboxStore.promoteToPaletteCard(_:projectStore:cardId:)` is the palette sibling of `promoteToResearch` — same `.new`→`.promoted` status handling, same non-destructive copy-then-delete-original contract for assets, but it appends INTO an existing card rather than minting a research item: `.text`/`.audio` become a `PaletteCard.SensoryNote` (tagged when `InboxEntry.sense` maps to a known `PaletteCard.Sense`, untagged — never thrown — otherwise), `.image` copies into the card's `<slug>_assets/` well via `ProjectStore.addImage(toPaletteCard:fileURL:)`. The manifest only flips to `.promoted` after every mutating step succeeds, so a failure (e.g. an audio capture with no transcript yet) leaves the entry `.new` for retry rather than half-promoted. `Views/PalettePickerSheet.swift` drives the UI: card list pre-sorts a `paletteSubject` case-insensitive title match to the top and offers a "New Card…" row when the subject matches nothing (`InboxPane`'s direct "Promote to Palette: “card title”" menu item skips the sheet entirely when the subject already matches exactly one card). MCP `promote_inbox_entry` (`Maugham/MCP/Tools/InboxTools.swift`) exposes the same seam via `palette_card_id`/`palette_subject`, mutually exclusive with `target_document_id`.

## Inbox → canvas seam (1C-d Task 12, 2026-07-31, spec §8A.4)

`InboxStore.sendToCanvas(_:projectStore:placement:)` is the **third sibling** beside `promoteToResearch` and `promoteToPaletteCard`. `.text`/`.audio` become a canvas **scrap** carrying the inline text or the transcript (trimmed at the ends and *not* flattened — a `SensoryNote` is one line of prose and a scrap is not); `.image` becomes an **owned** item node, ingested into `canvas_assets/` through the one pair in `ProjectStore+CanvasAssets.swift`. An empty text capture and an untranscribed voice memo are both refused with `nothingToPromote`, exactly as the palette sibling refuses them: a blank card plus a `.promoted` entry is the capture lost.

**The ordering is the palette sibling's, chosen rather than inherited** — and worth stating because **the two existing siblings disagree**: `promoteToResearch` removes the source asset *before* its flip, while `promoteToPaletteCard` copies, flips, and removes last. §8A.4's sentence ("flip to `.promoted` only after every mutating step has succeeded") is the palette one's, so: ingest, write the canvas, flip, remove. A flip that fails leaves the inbox original in place and a retry re-copies — a recoverable duplicate — where the other order would strand the entry `.new` with its asset gone and every retry hitting `assetMissing` for ever. **An audio capture's recording is never removed** (the palette sibling's behaviour too): what went to the canvas is the transcript, and the recording is the only copy of the writer's voice.

The canvas half is `Maugham/Canvas/CanvasCapture.swift` — read `Maugham/Canvas/AREA.md`, "A capture sent from the Inbox", for the two routes, the prefixed drag payload and why the command's card is loose. **There is no MCP write path for this route and the asymmetry is deliberate** (§8A.4): Claude's way onto the canvas is §8A.2, whose source must already be a research item because `read_document` is the catalogue's only image reader. `promote_inbox_entry` is unchanged.

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
