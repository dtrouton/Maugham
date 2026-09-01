# Stores — Area guide

The persistence and coordination layer: project structure, documents, recents, sessions, trash, debounce scheduling, and the `.maugham/` filesystem layout. Read this before editing in `Maugham/Stores/`. Also read the project root `CLAUDE.md` for cross-cutting invariants.

## What this area owns

- Project structure mutation and persistence (`ProjectStore`).
- Document load/save/conflict-resolution coordination with NSFileCoordinator/Presenter (`DocumentStore`).
- The `.maugham/` filesystem layout for everything derived.
- Small focused stores: recents, sessions, trash, debounce scheduling.
- Search across the binder (`ProjectSearchView`, mounted as an overlay of the left column).

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
  - `ProjectStore+Annotations.swift` — the project-wide annotation walk + open-note counts (M3 P2). Same cache shape as `+Tasks`, and the same lenient-but-never-silent rule: an unreadable closed doc is skipped and its id returned in `unreadableDocIds` (RULING-54), so a count surface says "unknown" rather than a number that is short.
  - `ProjectStore+CanvasAssets.swift` — the canvas's asset well (see below)
  - `ProjectStore+Statements.swift` — find-or-create a statement by scope (see below)
  - `ProjectStore+StatementAdoption.swift` — the one-time, on-open migration of legacy craft-intent notes (see below)
  - `ProjectStore+StatementAssets.swift` — a statement's own asset well (see below)
- `DocumentStore.swift` — project-folder coordinator + Document registry. Owns the NSFilePresenter, manifest IO, session tracking, UI state, rename/copy/move orchestration, **and the typed user-content mover** (see below). Per-doc op-log, autosave, conflict-detection, and echo guard now live on `Document` (post-`milestone-document-first-class`); this file routes external presenter callbacks to the matching Document via the registry.
- `MaughamSidecarPath.swift` — typed classification of project-relative file URLs into manifest / opLog / checkpoints / sessions / uiState / conflictBackup / scratch / pending / trash / unknownSidecar / otherProjectFile / outsideProject. `presenterDidChangeSubitem` dispatches via a switch on this enum — adding a new sidecar owner is a compile-error workflow. **The `.opLog` arm has two halves as of M3 P2 Task 9**: a document that is OPEN gets `handleExternalLogChange()` as before (and the MERGE posts `.maughamAnnotationsChanged` itself, past its echo guard — `NSFilePresenter` fires on our own appends, so posting from the callback would announce once per typing burst); a document that is NOT open gets the post directly, which is the cross-device gap this arm used to drop on the floor — a peer's note landing in a closed piece changed a count on the review board that nothing re-read until the project was reopened. See [ADR 0010](../../docs/adr/0010-typed-cross-area-seams.md).
- `DebounceScheduler.swift`, `RecentsStore.swift`, `SessionLog.swift`, `TrashStore.swift` — small focused stores, well-bounded. **Use these as the model** for new stores; don't model new things after `ProjectStore`'s size.
- Cross-document search (`⌘⌥F`) — see `ProjectSearchView` and `ProjectWindow.applyCloseFind`.
- ID-prefix helpers / generators — see ADR 0008.

## The `.maugham/` filesystem layout (canonical)

Everything derived lives under `.maugham/` in the project folder. Each subdirectory has one owner:

| Path | Owner | Purpose |
|---|---|---|
| `.maugham/ops/` | `OpLogStore` (in OpLog area) | Per-doc JSONL op logs |
| `.maugham/checkpoints.<deviceSlug>.jsonl` | `CheckpointStore` (OpLog area) | Project-scope checkpoints from ⌘S, partitioned per device (FM-1). A FILE, never a directory — and never the unsuffixed `checkpoints.jsonl`, which stays a merge source and is never written |
| `.maugham/conflicts/` | `DocumentStore` | Conflict backup copies |
| `.maugham/sessions/` | `SessionLog` | Per-session activity records |
| `.maugham/ui-state/` | `ProjectStore` (UI extension) | Window position, last-opened doc, cursor restore |
| `.maugham/scratch/` | Various | Transient writes; safe to nuke |
| `.maugham/pending/` | `PendingBuffer` (OpLog area) | Device-partitioned crash-recovery buffer (`<docId>.<slug>.pending.jsonl`). Relocated out of `ops/` so it can't match the op-log glob (tripwire 17 / ADR 0012). Ephemeral; safe to nuke. |
| `.maugham/trash/` | `TrashStore` | 30-day soft-delete; sweep on app launch |
| `.maugham/ops/__project__.jsonl` | `ProjectStore+Tasks` | Reserved synthetic doc id for project-scope pane-created tasks (milestone-tasks). The op log is real but no manuscript backs it. **Do not allocate a real document with id `__project__`.** |
| `.maugham/design/proposals/<proposalId>/` | `DesignProposalStore` | A staged design proposal (`spec.md`, `files/<relative path>`, `proposal.json`), plus `scratch/` and `backup/` once a sample has compiled or a promotion has run. Derived — deleting `.maugham/design/` costs nothing else on disk — **with one honest exception: while a promotion stands, that proposal's `backup/` is the only copy of the templates it displaced**, until `ProposalPromotion.revert` puts them back or `.finalize` lets them go. `delete(id:)` refuses over a standing backup for exactly that window |
| `.maugham/translations/rounds/<lang>.json` | `TranslationRoundStore` | The ring of the newest 10 `TranslationPipeline` rounds run against that language, oldest-first on disk, plus the next round number (which outlives the ring, so a trimmed-out round's number is never re-minted). Derived — losing it costs a round's report, never words, and a missing or undecodable file reads as an empty ledger rather than throwing. A **whole-file rewrite on every append**, by the one pipeline the desk allows to run at a time — unlike the op log's per-device partitioning (tripwire 17), there is no second writer here to race, so this file is not per-device. That single-pipeline gate is per *window*, not per project: two windows open on the same project would each allow their own pipeline to run, racing this whole-file rewrite (a recorded edge, not a fix). `.maugham/translations/` already classifies as `unknownSidecar` in `MaughamSidecarPath`, so no presenter route changed to add it. **Two writes, and only one of them mints**: `append` files a finished round and takes the next number, while `update(_:)` (translation pipeline P4) finds a round by ITS OWN number in that language's ledger and rewrites it in place — never minting, never moving a number — which is what the round report's verbs use to record a dismissal, an adoption or a skip. A round the ring has aged out is refused in words (`UpdateError.roundGone(number:)`, a `LocalizedError` with a non-empty sentence) rather than silently re-appended, because a re-append would hand a settled round a new number and a second life. See `Maugham/Compiler/AREA.md`'s "The pipeline — seven legs" section for the record's own shape |

Don't invent new top-level subdirs without a reason. If you need a new one, the convention is: lowercase noun, plural if it's a collection of records.

## Typed user-content mover (tripwire 14, enforce-by-construction)

Moving or deleting a path the user might be editing (a manuscript `.md`/`.fountain`, a Collection piece folder, or a research note/folder) goes through **one** of three `DocumentStore` entry points — never a raw `FileManager.moveItem`/`moveToTrash`:

| Entry point | Use for |
|---|---|
| `relocate(plan:)` | A flat `RenamePlan` batch — binder rename / reorder / cross-group move (`renameStructureItem`, `moveStructureItem`, `moveResearchItem` cross-group, `moveResearchItems` batch scope move). |
| `relocateUserContent(affectedPaths:perform:)` | A bespoke move that isn't a flat plan — the Collection piece's two-phase temp-suffix folder swap (`movePiece`/`renamePiece`), the research note + sibling `<slug>_assets/` rename (`renameResearchPath`). Run the FS surgery in `perform`, using `coordinatedMove`/`coordinatedWrite` for each step. **A bespoke move commits step by step, so every destination it will need must be chosen before the FIRST one runs** — see the joint dedup below. |
| `trash(relativePath:using:…)` | Soft-delete into `.trash/` (`deleteStructureItem`, `deleteResearchItem`, batch `deleteResearchItems`). |

**`moveResearchItems(ids:to:atIndex:)`** (`ProjectStore+ResearchMove.swift`, 2026-07-16) is a **fourth routed caller** of `relocate(plan:)`, not a new entry point — it builds one `RenamePlan` covering every step in the batch (file moves, group-folder moves with descendant manifest-path rewrites, and each moved note's sibling `<slug>_assets/` folder) and executes it through the same `documentStore.relocate(plan:)` single call, so tripwire 14's close-before-FS-surgery + debounce-flush discipline applies for free. `ResearchMoveTarget` (`.sharedRoot` / `.group(id)` / `.piece(id)`) is the typed destination (ADR 0010 pattern); validation happens entirely before any FS call (unknown ids, cycles, role-guarded cross-scope moves all fail the whole batch, moving nothing). `.link` items are manifest-path-only (no file, no plan step). The file is in the `TripwireGrepTests.test_noRawMoveOfUserContentOutsideTypedMover` census alongside the other research/structure seams. `deleteResearchItems(ids:)` (`ProjectStore+Research.swift`) is the equivalent batch soft-delete: one up-front validation pass, one `trashResearchItemCore` per id, one manifest save — built on the existing `trash` entry point, not a new one. (Its `item.kind != .link` guard, present since before this milestone, is what keeps a pathless link item from being handed to the file-mover, which would throw "no such file" — the batch path inherits the same guard. **As of RULING-45, 2026-08-09, that guard is a BRANCH rather than a skip**: a link takes `TrashStore.recordManifestOnlyTrash`, which writes a `meta.json` and no file, so delete means the same thing for a link as for a note and restore puts the row back.)

Each runs the **close-before-FS-surgery** discipline INTERNALLY before any FS call: `document(for:)?.close() + unregister()` for every open Document at an affected path, **plus** `flushPendingSave()` for the path-keyed research-note debounce. This is what makes tripwire 14 structural rather than remembered — a caller cannot forget either half, which dissolves findings 1.3 (executeRenamePlan didn't flush) and 1.6 (movers closed but didn't flush). **This replaces the prose tripwire-14 description that used to live in CLAUDE.md** (the "Close-before-FS-surgery" note in `Views/AREA.md` now points here).

**A note and its `<slug>_assets/` folder dedup JOINTLY, and both movers ask the one helper** (`researchDedupedNotePair`, `ProjectStore+ResearchMove.swift`; #31, 2026-08-09). The chosen stem must be free for the leaf **and** for `<stem>_assets` — an *orphaned* `<target-slug>_assets/` with no note beside it leaves the leaf looking vacant, which is the shape a leaf-only dedup walks into. The batch mover has done this since W2; `renameResearchPath` did not, and its two coordinated moves commit separately, so the note's `.md` landed at the new path and the assets move then threw with the manifest still naming the old one — manifest↔disk divergence from a rename that reported failure. The helper takes an `isTaken` predicate rather than a name set precisely because a name set would force the rename caller to pre-list the whole destination directory just to build one: both callers ask the filesystem for what's taken, and the batch mover additionally unions its own in-flight claims. **One implementation — a second copy is the drift W2 existed to kill.** A note with *no* assets folder still dedups on the leaf alone (both movers agree on that too): an unrelated `<slug>_assets` must not push an ordinary rename to `-2`.

**Enforcement:** `MaughamTests/TripwireGrepTests.test_noRawMoveOfUserContentOutsideTypedMover` forbids raw `.moveItem(` / `.moveToTrash(` in the `ProjectStore+{Structure,CollectionPieces,Research,WikiLink,ResearchMove}` seams. A sibling self-check (`…FiresOnPlantedOffender`) proves the grep catches a planted offender.

**Collection-pane parity note (2026-07-16):** `CollectionResearchPane` used to be a degraded fork of `ResearchView` — flat rendering (no nested groups), same-section-only reorder, single selection. It now shares `ResearchTree`'s `ResearchTreeNode`/`ResearchSelectionSync` (`Maugham/Views/ResearchTree.swift`) with `ResearchView`, so both surfaces render full nested trees, support drop-into-group, and drive `Set<String>` multiselect. The store-side counterpart of that parity work is this file: the pre-existing single-item cross-group `moveResearchItem` had a latent bug — its `RenamePlan` carried only the moved item's own path, silently orphaning a note's sibling `<slug>_assets/` folder (and breaking its image refs) on a cross-group move. `moveResearchItems`' plan builder is now the single place that knows a `.document`-kind note travels with its assets folder, and the pre-existing single-item mover was retrofitted to route through the same builder — so the fix lands for both the old one-at-a-time path and the new batch path.

**Palette writes are grep-enforced too, same shape.** `ProjectStore+Palette.swift` must route card writes through `paletteCoordinatedWrite(_:to:)`, never a raw `.write(to:)` — enforced by `TripwireGrepTests.test_noRawWriteInPaletteStore`. The funnel's own unit-test fallback (used when `documentStore == nil`) is the one allowed raw write; mark that line `// palette-coordinated-write: <reason>` so the grep can tell it apart from a reach-around.

**A failed promotion moves its staged files BACK** *(M1A Task 13)*. `promotePieceToProject` *moves* three things into its staging tree — the piece's main document, its whole `research/` folder and its intent statement — and its failure path used to be a bare `try? removeItem(at: stagingURL)`, so any throw at the manifest write, at `validatePromotedProject` or at the final replace deleted all three. **The blast radius is uneven, and that is what set the severity:** the document and the intent each leave their op log behind in the Collection, and `Document.load` reads a missing file as empty stored bytes with the log intact, so both re-materialise on next open — but `research/` has *no op log at all*, and its notes, images and assets went with nothing behind them. Each staging helper now returns the `PromotionStagedMove` it made, recorded as it lands, and `rollbackPromotionStaging` walks that list in reverse. A **record, not a re-derivation**: working out on the failure path what *should* have been staged writes the staging rules a second time in a place no successful promotion exercises, and the copy that drifts is the one holding `removeItem`. The compensation never throws over the writer's original error, but it is never silent either — a move-back that fails logs loudly and **leaves the staging tree standing**, because a directory recoverable by hand beats a correct-looking error and no files. One stranded path does not abort the others. When the tree is already gone, step 7 consumed it and the files are whole at the destination; nothing is chased there. The seam that makes any of this testable is an `internal` `afterStaging:` overload that **cannot throw** — a test can only arrange the world so a real step fails, never fabricate an error the code would not produce.

**The boundary (intentionally NOT routed):** internal, non-user-edited moves stay raw and are excluded from the grep via an explicit `// internal-move:` marker — the `promotePieceToProject` staging moves (into a temp `staging/` tree, which already closes+flushes upstream) **and their inverse in `rollbackPromotionStaging` (`// internal-move: staging rollback`), which is raw for two reasons rather than one: the same close+flush already ran, *and* `relocateUserContent` is `throws` and would re-enter a `DocumentStore` the promotion has already closed — a compensation must not throw over the error it is compensating for** — and the no-`DocumentStore` fallback branches (load-only contexts like unit tests have no registry/scheduler, so the discipline is a provable no-op). Empty-file scaffolding (`Data().write`), `.maugham-link.json`/manifest writes, scratch tmp writes, and `executeCopy` (Duplicate) are derived/internal and out of scope. When you add a NEW mover of user-editable content, route it through one of the three entry points above — do not add a raw move with an `// internal-move:` marker unless it's genuinely one of these internal classes.

## Palette + craft-intent seams (2026-07-09)

Two new research-adjacent conventions, both plain-edited (no op log, no `¶id` anchors — same precedent as research notes) and both absence-is-valid: **palette cards** (`ProjectStore+Palette.swift`) are markdown research assets under a `research/palette/` group (kind/swatches/senses/images convention), parsed on load via `PaletteCard` (now `Packages/MaughamCore/Sources/MaughamCore/PaletteCard.swift`, moved from Mac-only, tripwire 19); the typed user-content mover already covers them for free since they're ordinary research items. **Craft intent** used to be the second (`ProjectStore+CraftIntent.swift`, a conventional `craft-intent.md` per scope); **M1A Task 8 deleted that seam** — it is a `Statement` now, see below — and what survives it here is `ResearchRole.craftIntent` and the craft-intent arm of `healPaletteRolesEagerly`, whose only remaining reader is adoption.

## The canvas's asset well — `ProjectStore+CanvasAssets.swift` (1C-d, 2026-07-30)

`ingestCanvasAsset(image:)` / `ingestCanvasAsset(fileURL:)` are the **one pair** that gives a canvas item node a file of its own, and every 1C-d route — Finder drop, browser bitmap, inbox promotion — is a *caller* of it rather than a storage decision of its own. (A *research* drag ingests nothing: that item has a home already and the canvas holds only its position.)

**Both twins have exactly one production caller as of Task 11, and they are the two arms of one drop.** `ProjectWindow` hands `CanvasView` a `CanvasAssetIngest` holding both; `CanvasExternalDrop` routes a Finder drag (a file URL) to the file twin, which preserves the name and extension, and a browser drag (a rendered bitmap, no file URL) to the image twin. Re-rendering the Finder case through the image twin, or writing the browser case to a temp file to reuse the file twin, would each have left the other half of a built pair with no caller — this directory's signature defect, and the twin's own doc comment says the pair was built for both.

- **`canvas_assets/` sits at the PROJECT ROOT, beside `canvas.md`, and is content rather than derived state.** It is deliberately not under `.maugham/`: deleting `.maugham/canvas.json` costs the arrangement and must never cost the photographs. It is the one asset well whose owner is the canvas rather than a research note.
- **No naming, dedupe or timestamp scheme of its own.** The pair hands `ImagePasteHandler` the canvas's own `canvas.md`, and that saver's existing `<slug>_assets` derivation yields `canvas_assets/` for free. The well's name is therefore **derived and never spelled** in production code — move `canvas.md` and the well follows.
- **The pair returns a PROJECT-RELATIVE path**, which is what `CanvasItemReference.owned(path:)` requires. The saver returns a Markdown ref one step earlier; resolving it is `ProjectStore.resolveImageRef(_:relativeTo:)` — the palette's, shared rather than respelled (its label was generalised from `cardDirectory:` for this). An absolute path, a `file://` URL or the ref itself each renders nothing, keys the thumbnail cache on a string that differs between Macs, and breaks the moment the project is moved or synced.
- **Two tripwires, same shape as the palette's.** `TripwireGrepTests.test_theSharedImageSaverIsCalledFromTheSeamsThatOwnAWell` is a census of the files allowed to call `ImagePasteHandler.saveAndReference*` (count the set, not the prose); `…test_theCanvasAssetWellIsDerivedAndNeverSpelledInCode` catches the other reach-around, a hand-built `"canvas_assets"` path that never names the pair at all. Both have a planted-offender self-check.
- **The image write itself is uncoordinated**, matching the two existing wells: these are new files with minted unique names, written once and never re-edited, so there is no second writer for NSFileCoordinator to arbitrate. A *manuscript* or a card's markdown is a different case — those still route through `DocumentStore` (tripwire 7).

## A statement's asset well — `ProjectStore+StatementAssets.swift` (M1A Task 12, 2026-08-01)

`addImage(toStatement:scope:image:)` / `(…fileURL:)` are visual language's ingestion pair, and `addImage(to:image:)` is their synchronous sibling for a caller that has already found the statement. Umbrella §3.2 calls visual language *mixed — images, references and prose*, and a mood board you cannot put a picture into is the wrong shape for the one artifact whose subject is how the book looks.

- **A seam of its own rather than a caller of the canvas's or the palette's.** A statement is a file of its own, so its pictures go beside it; routing them into `canvas_assets/` would file them next to a document they have nothing to do with, and would tie them to a sidecar the writer may delete. It is an entry in the saver census, and the census comment says which well.
- **The name is derived, never spelled, and there is exactly ONE derivation.** `ImagePasteHandler.wellURL(forNoteAt:in:)` builds `<slug>_assets` from the file's own name, so a `Statement.path` of `visual-language.md` yields `visual-language_assets/` with no literal anywhere. It creates nothing — `destination` calls it and then creates — so a reader asking *whether* a well holds anything cannot bring one into being by asking.
- **The ingest pair leaves nothing behind on failure, in either order it can fail (issue #29, S6).** Both twins encode/validate *before* they mint, so a bad bitmap or a refused file type refuses before there is a statement at all; a save that fails *after* the mint — the disk's own refusal — is undone by `rollbackUnusedStatement`, taking the same statement-open gate unconditionally. **And the rollback never takes a statement away from a photograph** (issue #35): the drop writes into the well *before* it takes the gate to append its ref, so a mint racing it would find no words, no bytes and a known row and remove the row out from under a picture already on disk — `statementWellHoldsAnything` is therefore asked beside the other refusals *and* again immediately before `removeItem`, since `saveManifest` is a suspension point and the well is a directory other processes write into.
- **Find-or-create, because the well cannot be known before the file exists.** `vacantStatementPath` steers around an occupied `visual-language.md`, so the path is `createStatement`'s answer rather than a constant. `createStatement` is idempotent, so a pane minting on the same turn gets the same statement.
- **The file-URL twin validates BEFORE it mints.** A refused `.txt` must not be what declares the writer's visual language to exist — so the guard is asked here as well as inside the saver, and a refusal leaves nothing behind at all.
- **It returns a `StatementPicture` — the statement AND the ref — and never touches the statement's text.** The pair travels together because an async ingest can finish on a different scope than it started on (the writer drops a picture on Visual Language and presses `⌘⌥N` while the file is copied); a caller holding only the ref would have to ask "which document is this for?" of whatever the pane shows *now*. Putting it in is the caller's next act, through the op log — writing the `.md` would be discarded on the next re-materialize.
- **It opens no `Document` and takes no `lockStatementOpen` of its own** — that gate is over the *opening*, and this only writes a file beside one. `withStatementDocument` is where the gate is taken (the seam below; `mutateStatementText` is one of its callers).

## The statement seam — `ProjectStore+Statements.swift` (M1A, 2026-07-31)

**Finding the `Document` to write into is `withStatementDocument(_:session:_:)`'s, and it is the ONE statement open-and-mutate dance** *(origin's S2 extraction + the second draft's discipline, merged 2026-08-09)*: the live `Document` first through `openStatementDocument(id:)`, then the open gate, a re-ask of the registry inside it, then a transient `Document.load`/mutate/awaited-`close`; the lookup-plus-mutate does not suspend, so a pane cannot close its `Document` between them. Its closure may THROW, and **a throw writes nothing** — on the transient arm the just-loaded `Document` is closed on the refusing path too. **It is the seam that takes `lockStatementOpen`**; who takes the gate is a census — `TripwireGrepTests.statementOpenGateTakers` — not a sentence here.

**`mutateStatementText(of:session:transform:)` is its whole-text wrapper**, handed the text the write is about to be made from, so a caller whose act depends on what is currently there (revoking a ruling that must still be present) decides and edits over one string, with no window between the check and the write (`RulingPerformer` passes its own transform through it). **`appendToStatement(_:to:session:)` keeps the paragraph verb** — a blank line, then the arriving words — for the promotion and picture-ingest callers, and **its "end" is the end of the ESSAY, not of the file** *(declared-world Task 6)*: once an intent statement has a `## Rulings` section, a whole-file append lands below the list, where `RulingsSection.parse` does not read it and the Intent pane cannot show it — safe on disk, invisible in the surface that owns it. `StatementEssay` is the split; byte-identical for a statement with no section, and for visual language always. `withStatementDocument`'s other caller is `propagateWikiLinkRename`'s statements loop — why the dance was extracted at all: a rename that opened its own `Document` on a statement the pane has open would be written back out by the writer's next burst. Every destination is named by **statement**, never by "whatever the pane is showing": callers suspend, and the writer can change panes in that window with a keystroke.

A **statement** — the writer's intent, or the book's visual language — is a `Statement` entry in `ProjectManifest.statements` whose content is an ordinary `Document` living **in the open at the project root** (`intent.md`, `intent/<slug>.md`, `visual-language.md`; spec §2.2). It is the artifact that replaces craft intent. **Canvas promotion moved onto it in Task 7 and the last readers moved in Task 8**, which deleted `ProjectStore+CraftIntent.swift`: `read_craft_intent` answers off `statement(kind:scope:)`, and both inspectors' "Open Craft Intent" / "Add craft intent…" pair became one `IntentAffordanceRow` that posts `.maughamSetDetailSegment` and creates nothing.

- **Lookup is by SCOPE, in the manifest — there is no path prefix and no filename convention in the read path.** That is the point, not an implementation detail. `craftIntentItem(forPieceId:)` looked its doc up through `ResearchScope.pieceResearchPrefix`, which opens `guard piece.pieceKind == .loose`, so a **novel chapter's** intent was created into shared `research/` where the lookup never looked and the next create minted a second copy of the writer's prose. There is no prefix here, so there is nothing to be nil. `PromotionPerformer.performCraftIntent` carried a comment block describing that defect from the inside and **Task 7 deleted it with the defect** — a comment explaining a bug that no longer exists is worse than no comment — along with `intentPiece`'s `.pieceFolder`-only narrowing, which was the same defect wearing a rule's clothes.
- **The shared half is `MaughamCore`'s** (tripwire 19): `StatementLookup.statement(in:kind:scope:)` is pure — no stamping, no side effects, `PaletteLookup`'s shape — and `StatementConvention.newPath(kind:scope:documentSlug:)` is the §2.2 storage table's one spelling. The Mac wraps them with creation; the phone reads them.
- **Absence is valid and free.** `ProjectStore.statement(kind:scope:)` returns nil having minted nothing, stamped nothing and logged nothing — unlike `craftIntentItem`, which lazily healed a legacy identity on read. A statement's identity IS its manifest entry, so there is nothing to heal. `read_craft_intent`'s shipped description already promises Claude that absence is "a valid, deliberate state"; the store must not contradict its own MCP surface.
- **`createStatement(kind:scope:)` refuses rather than redirects.** A scope naming something that is not a manuscript document in this project throws `.structureMissing`; a `(kind, scope)` pair with no row in the table (visual language at document scope, an ADR-0015 `.unknown` from a newer build) throws `.statementHasNoStorage`. A chapter's intent quietly written into the book's file is the same class of loss as a second file nobody reads.
- **And it refuses the PATH it is about to mint, at the choke point rather than at each caller** *(issue #43, F-F, 2026-08-27)*. An edition brief whose tag fails `TranslationRecord.isValidLanguageTag` **verbatim** throws `.languageTagInvalid` — stricter than `translatorRole(for:)`, which tests the tag lowercased, because this one is spelling the filename `editions/<lang>.md`: `editions/EN.md` is a brief that `read_edition_brief`, the translator briefing and the desk all look for in lowercase and never find, and `editions/../../x.md` is not in the project at all. Then, for **every** kind, the path goes through `SafeRelativePath.resolve(_:under:)` (`.statementPathUnsafe`) instead of a bare `appendingPathComponent`. On the `intent/<slug>.md` arm that is belt-and-braces and known to be: `Slugifier.slug` keeps only `[a-z0-9-]` and falls back to `untitled`, so a document titled `../../evil` cannot escape today — the gate is there for the kind added later, or the slug rule that forgets. Both throw before the directory is created and before the manifest row is appended, so a refusal leaves nothing on disk (`EditionBriefStatementTests`' §(e), which snapshots the whole tree rather than just `editions/` — a path that escapes lands where a narrow assertion would not look).
- **Creation never takes an occupied path.** Two documents may share a title, so their slugs collide — and an **untracked file** may already sit at the candidate path. Since the manifest is the only authority on a statement's identity, registering one over an untracked file would point `resolveDocId` at it, bootstrap the statement from its bytes and then own it: `createStatement` steers to `intent-2.md` instead. (A test plants the offender; with the steer removed, the writer's file is emptied by the empty scaffolding write.)
- **The slug is derived from the document's title once, at creation, and never re-derived.** Identity is the manifest `id` (tripwire 22), so a rename moves the title and leaves the path. A statement's path moves through the typed `DocumentStore` mover like any other user-editable content (tripwire 14).

- **There is a registry of OPEN statement `Document`s, and it exists because a statement is deliberately in no other one** *(Task 7)*. `StatementEditorHost` does not register its `Document` with `DocumentStore` — that would put it in `allOpenDocuments()`, which the project Tasks aggregation iterates (spec §8) — so `DocumentStore.document(forDocId:)` cannot find an open statement, and anything else wanting to write into one opens a **second** live `Document` on the same path, each with its own `PendingBuffer` writing the same file. Whichever writes last decides the sequence, so the other side's paragraph is written back out, silently, two keystrokes later. `noteStatementDocumentOpened(_:id:)` / `forgetStatementDocument(id:)` / `openStatementDocument(id:)` are the seam: the pane registers on bind and withdraws before every close, and the reader refuses a **closed** `Document` (the entry is weak, and `.onDisappear` closes without releasing — `setFullText` on a husk is a logged no-op, which is the writer's words going nowhere). Its one consumer today is `PromotionPerformer`, which asks before it loads anything of its own; the same rule binds the next one.

- **`statementText(of:)` is the ONE spelling of ADR 0018's two branches for a statement** *(Task 9)*. Every reader of a statement's prose goes through it — `read_craft_intent` and `read_visual_language` today — because a statement is a `Document` with an op log and the file beside it is derived output that lags whenever an op lands out of band (tripwire 20). It takes the open pane's `Document` via `openStatementDocument(id:)` when there is one, which is fresher by up to one debounce window, and `derivedCache.displayText` otherwise; the reason it is one method rather than a copy per tool is `CanvasClaudeWrite.readScene`'s: two readers must not come to different conclusions about which text is real.

- **And a second seam covers the window in which one is being OPENED** *(Task 7, fix round 1)*. The registry above answers for a `Document` that is already open; `Document.load` is `async` and constructs a fresh instance per call, so between "the registry says nobody has this" and "I have registered mine" a second opener asks the same question and gets the same answer — and the two hold live `Document`s on one path. `lockStatementOpen(_:)` / `unlockStatementOpen(_:)` is a per-statement gate over the OPENING only: the pane holds it across its load and its registration, a transient writer across its whole load-write-close, and because the pane releases as soon as the registry can answer for it, a writer that queued behind one **re-asks the registry inside the gate** and takes the live-`Document` path instead of loading at all. Per statement rather than per project, so one open never blocks another (`StatementOpenGateTests`, which holds each opener to the gate separately — a gate one side ignores is not a gate).

- **The inspector's affordance is a PANE SWAP and mints nothing** *(Task 8)*. `IntentAffordanceRow` (`Maugham/Views/`) is one view shared by `InspectorView` and `PieceInspector`, because the old pair was two copies kept in step by hand. There is deliberately no "Add" button: the pane's own rule is that absence is valid and an empty scope shows an empty editor that mints on the first keystroke (§4.3), so an inspector-side create would be the nag the pane does not have — and it would also mint into a scope the pane may not be showing. The row resolves its caption through **`StatementPane.effectiveScope`**, not a second resolution: the pane's scope follows the binder selection, so with a chapter selected the button lands on the *chapter's* intent, and a caption derived any other way would describe a statement the writer is not about to see. It goes through `MaughamEvent.postDetailSegment(_:)` — the one spelling of that post, shared with the View menu (tripwire 21).

- **A promoted Collection piece takes its intent with it** *(Task 8)*. Before M1A a loose piece's intent was a research note under `pieces/<n>-<slug>/research/`, which `writePromotedManifest`'s prefix rewrite carried for free; a statement lives at `intent/<slug>.md` at the Collection's ROOT, which no research prefix matches, and the new manifest takes `statements: []` by default — so the writer's intent would have silently stayed behind in a project whose piece is now a reference. `stagePromotedIntent` moves the file into the staging tree at the same project-relative path (`// internal-move: staging`, the main document's own class), `writePromotedManifest` re-points its scope at the new document's id and mints it a fresh `stmt-` id, and `convertPromotedPieceToReference` prunes the Collection's entry beside the research prune. **Its op log stays behind and its words do not** — the new project has no `.maugham/` at all and re-bootstraps from the rendered `.md`, exactly as the piece's own manuscript does; a derive-only read of a freshly promoted project therefore answers "" for every document in it until something opens one. The Intent pane can be showing that statement while the promotion runs, and a statement is in no `DocumentStore` registry, so the entry point withdraws its registration and closes that `Document` explicitly — which is also what renders the `.md` being staged.

## Rename propagation — `propagateWikiLinkRename` (`ProjectStore+Structure.swift`, S2 complete 2026-08-09)

Renaming a document moves every `[[…]]` that named it. **Three loops, one pairs list, and the pairs are the part that is easy to get wrong.**

- **A rename moves more than one title.** The document's own, and the **composed title** of every statement scoped to it — `ArtifactIndex.statementTitle` names a statement after its document (M1A), so `[[Craft Intent · Alpha]]` stops resolving the instant `Alpha` becomes `Omega`. The manifest is already renamed when this runs, so the "before" title is composed with a closure answering the OLD name rather than read back out of `structure`.
- **The renamed document is excluded from the DOCUMENT-title pair only, and that asymmetry is deliberate.** Its own `[[Alpha]]` self-references are left to the resolver's case-insensitive title match on the next render — an argument about the document's own name, which says nothing about the name of a statement about it. A `[[Craft Intent · Alpha]]` written in the very chapter that intent is for resolves to nothing at all after the rename, so the composed pairs apply to it too. With no statements scoped to it the document is skipped outright rather than loaded to be told there is nothing to do.
- **Three destinations, two write disciplines.** Manuscript documents and statements are `Document`s, so the rewrite arrives as **ops** (tripwire 20) — the statements loop is a caller of `withStatementDocument`, never a second open dance. A **research note is not op-logged**, so its rewrite is a plain coordinated whole-file write behind one `flushPendingSave()`, or a raw write in a no-`DocumentStore` context (`PromotionPerformer.write`'s shape). The flush is load-bearing: a `ResearchNoteEditor` save queued on the 750 ms debounce would otherwise land *after* this write and put the stale body back. Research notes are in scope because canvas promotion writes `[[…]]` into a note and never into a manuscript (1C-c2), so a rename orphaned exactly the links the writer had just made.
- **An empty derive is not "nothing to do".** The manuscript loop has always fallen through to `Document.load` on an empty pre-check because an un-bootstrapped doc materialises to `""`; the statements loop does the same, gated on the statement's file having **non-zero size** — a `stat`, never a read, because reading the file to decide would be the manuscript-as-truth read ADR 0018 forbids, and the content still arrives through `Document.load`'s bootstrap inside the dance. The state is real: a freshly promoted project's intent has its prose in the `.md` and no `.maugham/` at all (`stagePromotedIntent`, above).
- **Not covered, on the record:** an open `ResearchNoteEditor` has no registry equivalent to `openStatementDocument(id:)`, so a note being edited at the moment of a rename can write its in-memory body back over the rewrite. Statements and manuscripts are both covered against this; research notes are not.
- **Not covered, on the record (2026-08-09):** the **renamed document itself** is visited by the composed-title pairs (the bullet above's asymmetry), and its editor's own rename-reload — `EditorHost`'s path-keyed reload, tripwire 22 — can be mid-flight when the transient rewrite lands, in which case the composed-title rewrite in that one body is lost. That is the pre-branch behaviour, not a regression; reaching it needs the renamed document open *and* self-referencing its own intent's composed title.

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

## Production roles — `ProjectStore+ProductionRoles.swift` (2026-08-19)

**Cast is translator(s) + designer.** The roles carry an identity (a preset name, customizable) and a brief (a preset doctrine, customizable). Stored on the project manifest (`ProjectManifest.productionRoles`), alongside the `reviewPasses` entries, in the same manifest file at the project root. Roles live in an array, keyed by id (role-typed `String`), and accessed through `ProjectStore.translatorRole(for:)` / `.designerRole()` — but the two are NOT symmetric. A translator is minted lazily: `translatorRole(for:)` looks the tag up in the stored list, and only on a miss mints, appends and persists a new row (`ProjectStore+ProductionRoles.swift`'s `translatorRole(for:)`, backed by `commitProductionRoles`) — a genuine write hiding behind what reads like a getter. The designer is **never minted**. `designerRole()` is a pure read: it answers the stored designer row if the writer has renamed or briefed one, else `ProductionRole.presetDesigner`, and writes nothing either way — every project has a designer from the moment it exists, so there is nothing to retroactively create. The preset only reaches disk through the writer's own rename (`renameProductionRole(id:to:)`), which is the one production entry point that mutates `productionRoles` for either role kind. Both return a `ProductionRole` that resolves through `effectiveName` / `effectiveBrief` to the raw field or a preset when absent — the `ReviewPass` shape carried forward to the publish department. External-MCP edits through `write_translation` / `write_publish_file` do not carry a role signature, so a signed annotation means the work came through the app loop (the straight-means-Claude transposition). The read-vs-write split is spelled out in `ProjectStore+ProductionRoles.swift`'s own doc comment (top of file); the lazy mint, the designer's never-mint, and the rename entry point are pinned by `MaughamTests/ProductionRoleStoreTests.swift` (`test_mintingATranslatorTwiceReturnsTheSameRole`, `test_theDesignerAnswersWithoutTouchingTheManifest`, `test_theStoredDesignerWinsOverThePreset`, and the rename suite). **A tag that is not a language tag once lowercased is refused here too** *(issue #43, F-F, 2026-08-27)*: `.languageTagInvalid`, on top of the older `.productionRoleLanguageEmpty` for a blank one, which runs first and keeps its own round-trip reason. **Tested lowercased, stored verbatim, matched case-insensitively** — the three are one posture, so `ES` and `es-MX` still mint exactly as they always have (`test_theTagsCaseDoesNotMintASecondTranslator`, `test_aRegionalTagIsItsOwnTranslator`, both untouched by the gate) and only `../evil`-shaped input is turned away. This is deliberately *weaker* than the edition-brief gate one section up: a role is normalised on read (`EditionStatus.storedTranslatorLanguages`) and matched case-insensitively (`storedTranslator(for:)`), so case costs nothing here, while a filename cannot be re-spelled after the fact. Every shipped caller already lowercases and validates upstream (`DepartmentPaneHost.addLanguage`, `DepartmentCastSheet`), which is the point of moving it here — the next caller inherits the refusal instead of having to remember the rule.

## `DesignProposalStore` — staging under `.maugham/design/` (publish department P3, 2026-08-20)

`Maugham/Stores/DesignProposalStore.swift` is a standalone `@MainActor` struct
over `.maugham/design/proposals/<proposalId>/` — `TrashStore`'s and
`PublicationSnapshotStore`'s shape (a bare `projectURL` and no other state),
**not** a `ProjectStore` extension, the model this file's own tripwire 3
points new small stores at. It stages what `Maugham/Compiler/DesignerReport
.swift` parses out of a designer round: `stage(report:round:designerName:)`
writes `spec.md`, one file under `files/` per proposed path, and
`proposal.json`; `list()` reads newest-first, tolerant of an unreadable
folder (`TrashStore.list()`'s own precedent — skipped, not thrown); `load(id
:)`, `updateStatus(id:_:)`, `reject(id:note:)`, `delete(id:)`, and
`sampleResult(id:)`/`recordSampleResult(id:_:)` for
`Maugham/Publish/SampleCompiler.swift`'s compile outcome. Read
`Maugham/Compiler/AREA.md`'s "The designer" section for the loop this feeds;
this entry is about the store's own shape.

**`stage` takes `designerName:` as a caller-supplied parameter, never
resolving `designerRole()` itself** — the store has no `ProjectStore`
reference to resolve it from, and identity is resolved once, upstream, by
whichever orchestrator caller is doing the run (`DesignerOrchestrator`'s
`StageContext.designerName`), the same precedent `TranslatorOrchestrator
.IngestContext` set: a layer that only records identity never re-resolves it.

**Supersession is project-wide, not partitioned by language or document.**
`stage` supersedes every still-`pending` proposal in the store on every call
— never an `approved` one — because the spec gives Design exactly one desk
row and one pending-proposal badge per project (unlike the translator, whose
desk gets a row per language). If a future milestone needs per-language
design proposals to coexist, this needs a scope parameter added; it does not
have one today.

**Status decoding follows `PassState`'s tolerance, not `SynthesisSource`'s**
(ADR-0015 pattern either way): `Status` carries an `.unknown(String)` case
that re-encodes losslessly, load-bearing specifically because
`updateStatus`/`recordSampleResult`/`reject` **rewrite `proposal.json` in
place** (this is not an append-only op log) — touching one field on a
proposal a newer build wrote must not clobber its status down to a generic
literal it no longer recognises.

**Everything under `.maugham/design/` is derived and safely deletable** — a
proposal is a working document about bytes the writer has not yet approved,
never the bytes themselves once approved (those land in the live
`.maugham/publish/` tree, `ProposalPromotion`'s job, in
`Maugham/Publish/`). Deleting the whole directory costs nothing else on
disk, the same contract `TrashStore`'s and `CanvasStore`'s directories carry.

**…with one window in which that is not true, and `delete(id:)` guards it.**
Once a promotion stands, the promoted proposal's `backup/` holds the ONLY
copy of the live templates it displaced: not the proposal (which holds the
new ones), not the live tree (which now has the new ones), nowhere else on
disk. Deleting the folder then is not discarding a design round the writer
turned down — it destroys their originals while the new design is still
shipping. So `delete` throws `.promotionBackupStands(id:)` while `backup/`
exists, and the two ways out of that window are the promotion's own verbs:
`ProposalPromotion.revert` (put the originals back) or `.finalize` (keep the
new design and let them go, deliberately, by name). `backupDir(id:)` is
spelled on this store rather than in the promotion that writes it, because
the store owns the proposal directory's layout and `delete` has to know.

## Role identity — `ResearchItem.role` (2026-07-11)

Path/filename matching (`research/palette`, `craft-intent.md`) was fragile: renaming either through an ordinary Research affordance detached the wall/inspector/MCP from the item (no data loss, but the next add minted a duplicate). `ResearchItem.role: ResearchRole?` (MaughamCore) is the durable fix — an additive-optional field (`paletteGroup`/`craftIntent`/`.unknown` sentinel for forward-tolerance, ADR-0015 pattern; absent → nil; no manifest schema bump).

- **Lookups go role-first, path-second.** `PaletteConvention`/`PaletteLookup` (MaughamCore) hold the canonical constants (`folderPath`, `groupTitle`, `craftIntentFileName`, `craftIntentTitle`) and the shared role-first-then-path lookup functions; `ProjectStore.paletteGroup()` wraps the palette half, and `ProjectStore.paletteFolderPath`/`paletteGroupTitle` are thin aliases onto `PaletteConvention`, not independent literals. **The craft-intent half of this no longer has a Mac wrapper** — M1A Task 8 deleted `ProjectStore.craftIntentItem(forPieceId:)` and the `craftIntentFileName`/`craftIntentTitle` aliases with the seam they served. The MaughamCore constants and `PaletteLookup.craftIntentItem` stay, because adoption (`ProjectStore+StatementAdoption.swift`), the palette heal, `Promotion.isCraftIntent` and the **phone** all still read them.
- **Lazy healing, no migration.** A lookup that falls back to path identity stamps the role on that item and saves the manifest (`ProjectStore.healRole`/`stampRole`, fire-and-forget `Task`, idempotent) — the item is role-identified from then on, so renaming the palette group through any Research affordance no longer detaches it. Mac-only: the phone never writes the manifest, so it consumes `PaletteLookup` read-only with no healing. **The craft-intent doc's lazy heal is gone**: it lived inside `craftIntentItem(forPieceId:)`, which M1A Task 8 deleted, and nothing on the Mac performs that lookup any more. What survives is the EAGER load-time heal (`healPaletteRolesEagerly`), and it survives for adoption alone — see the adoption section above.
- **Live title everywhere.** `ProjectStore.paletteGroupDisplayTitle` reads the group's actual (possibly renamed) title with no side effect, so the wall header/sidebar always show what the writer renamed it to, not the frozen default.

## Promote-into-card seam (2026-07-11)

`InboxStore.promoteToPaletteCard(_:projectStore:cardId:)` is the palette sibling of `promoteToResearch` — same `.new`→`.promoted` status handling, same non-destructive copy-then-delete-original contract for assets, but it appends INTO an existing card rather than minting a research item: `.text`/`.audio` become a `PaletteCard.SensoryNote` (tagged when `InboxEntry.sense` maps to a known `PaletteCard.Sense`, untagged — never thrown — otherwise), `.image` copies into the card's `<slug>_assets/` well via `ProjectStore.addImage(toPaletteCard:fileURL:)`. The manifest only flips to `.promoted` after every mutating step succeeds, so a failure (e.g. an audio capture with no transcript yet) leaves the entry `.new` for retry rather than half-promoted. `Views/PalettePickerSheet.swift` drives the UI: card list pre-sorts a `paletteSubject` case-insensitive title match to the top and offers a "New Card…" row when the subject matches nothing (`InboxPane`'s direct "Promote to Palette: “card title”" menu item skips the sheet entirely when the subject already matches exactly one card). MCP `promote_inbox_entry` (`Maugham/MCP/Tools/InboxTools.swift`) exposes the same seam via `palette_card_id`/`palette_subject`, mutually exclusive with `target_document_id`.

## Inbox → canvas seam (1C-d Task 12, 2026-07-31, spec §8A.4)

`InboxStore.sendToCanvas(_:projectStore:placement:)` is the **third sibling** beside `promoteToResearch` and `promoteToPaletteCard`. `.text`/`.audio` become a canvas **scrap** carrying the inline text or the transcript (trimmed at the ends and *not* flattened — a `SensoryNote` is one line of prose and a scrap is not); `.image` becomes an **owned** item node, ingested into `canvas_assets/` through the one pair in `ProjectStore+CanvasAssets.swift`. An empty text capture and an untranscribed voice memo are both refused with `nothingToPromote`, exactly as the palette sibling refuses them: a blank card plus a `.promoted` entry is the capture lost. **A third refusal, `CanvasStore.SidecarRefused`, is raised BEFORE the copy and BEFORE the flip** (issue #33) and only on the sidecar route: `CanvasCapture.refuseUnlessWritable` is the function's first statement, because a `.maugham/canvas.json` this build cannot read (a newer schema, or damaged bytes) loads as an EMPTY scene, and writing one card into that saves it over every region, line, position, mark and binding the other build put there. Asked at the top rather than left to `CanvasCapture.send` so the picture is never ingested first — a copy in the well that no node references is enumerated by nothing and invisible for ever. The entry stays `.new`, so the capture is retryable once Maugham is updated, and the refusal reaches the writer through `InboxPane`'s existing "Couldn't promote" alert (`SidecarRefused` is a `LocalizedError` naming the project). With a canvas open there is nothing to ask: the live model is this build's own.

**The ordering is the palette sibling's, chosen rather than inherited** — and worth stating because **the two existing siblings disagree**: `promoteToResearch` removes the source asset *before* its flip, while `promoteToPaletteCard` copies, flips, and removes last. §8A.4's sentence ("flip to `.promoted` only after every mutating step has succeeded") is the palette one's, so: ingest, write the canvas, flip, remove. A flip that fails leaves the inbox original in place, where the other order would strand the entry `.new` with its asset gone and every retry hitting `assetMissing` for ever.

**The retry converges — on the card and on the file** (S7, issue #29). `CanvasCapture` derives the capture's node id from the entry (`cap-<entryId>`, RULING-8/M8-IN-004), so a second send lands on the same card; the image arm now asks that same question through `CanvasCapture.existingNode` **before** `ingestCanvasAsset`, and repeats only the flip and the removal. Ordering alone made the earlier duplicate *recoverable in principle and invisible in practice*: a copy in `canvas_assets/` that no node references is listed by no surface and swept by nothing. The query is read-only and calls `CanvasClaudeWrite.liveModel` rather than re-deciding which canvas is real — a second spelling could read a detached model's stale scene while the write went to the sidecar, which is the double-copy back again. **An audio capture's recording is never removed** (the palette sibling's behaviour too): what went to the canvas is the transcript, and the recording is the only copy of the writer's voice.

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

6. **Don't write directly to `.maugham/` subdirs from outside this area.** Each subdir has one owner; route through it. (The OpLog area writes to `.maugham/ops/` and `.maugham/checkpoints.<deviceSlug>.jsonl` — that's the one exception, by ownership.)

7. **NSFileCoordinator/Presenter is required for any cloud-synced file.** Don't read or write manuscript / project files without it; iCloud will race you and conflict-bomb the user.

8. **Adding a new `extension ProjectStore`** for a new seam is the established pattern (Collection-Pieces does this). Don't introduce a new top-level store class for something that's logically project-scoped.

## The trash after the rulings (2026-08-09)

`TrashStore` + `ProjectStore+Trash` were reworked to seven of Denver's rulings; the full list with
its reasoning is the amendment section of [ADR 0006](../../docs/adr/0006-trash-and-undo.md). The
four things to know before editing in here:

- **Every trash entry records a `TrashSubject`** in its `meta.json` — `manuscriptItem`,
  `researchItem`, `captureAsset` or `internalArtifact` — and `moveToTrash` will not compile
  without one. It is what decides which tree a restore rewires (sniffing the metadata's shape was
  the bug: a `ResearchItem` decodes cleanly as a `StructureItem`), and what keeps Maugham's own
  safety copies out of the writer's pane. Additive-optional on disk; an entry written before the
  field falls back to the old sniff and is REFUSED if it matches neither tree.
- **`list()` is the writer's view and `entriesIncludingInternal()` is the whole of it.** The
  disposal verbs and `restoreTrashEntry` use the second; the pane uses the first. **Neither hides
  an entry it cannot read** (RULING-7): a folder Maugham wrote whose `meta.json` is missing or
  undecodable comes back as an `isUnreadable` entry titled `TrashEntry.unreadableTitle`, restore
  refuses naming that as the cause, and disposal reaches it as normal. Two shapes still skip, each
  for its own reason — a folder whose NAME Maugham did not write is not Maugham's entry (RULING-9),
  and a folder holding *nothing* gets no row, because "contents preserved" over an empty folder is
  the same misrepresentation pointing the other way.
- **An entry folder name is claimed, not assumed.** `mintEntryFolder` creates with
  `withIntermediateDirectories: false` so the create IS the claim; a taken name takes the next
  number. **Keep the timestamp a PREFIX** — the sweep dates entries by parsing the folder name
  (RULING-39), so an id scheme that buried or dropped the stamp (a ULID, a bare UUID) would take
  that away with nothing failing.
- **"Empty Trash" walks the DIRECTORY and reports what it could not destroy** (RULING-7).
  `emptyTrash` uses `TrashStore.entryFolderIds()`, not the cached `trashEntries` — an entry written
  straight through the store (MCP `set_piece_style`) is in no cache — and throws
  `trashNotEmptied` after re-listing, so the pane and the message agree. Don't put a `try?` back in
  that loop: `TrashView`'s catch was dead code for as long as one was there.
- **The destination of a restore is the CALLER's decision**, passed as `restore(trashId:to:)`.
  `TrashStore` knows nothing about manifests, and only `ProjectStore` knows where the row is
  going to sit — which is the whole of RULING-41.
- **⌘⌥Z is armed with a `TrashDeletion`, one per delete gesture** (`armDeletion`). A restore
  consumes its entries (`forgetTrashId`); a permanent delete deliberately does NOT, so the next
  ⌘⌥Z refuses with a reason instead of doing nothing.

## What to read before editing

- **Trash is claim-covered**: `TrashStore` + `ProjectStore+Trash` have 51 test-pinned behavioural
  claims and verdicts in `register/reconciliation/Trash.{claims,filings}.json`. Read the filings
  before changing delete/restore behaviour — a `VIOLATES` row is a known defect with a ruling
  behind it, a `COMPLIES` row is ruled-correct behaviour, and changing pinned behaviour means
  updating the claim + filing in the same commit (CLAUDE.md, "Behavioural claims + rulings").
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
