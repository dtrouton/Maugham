# Stores — area guide

The persistence and coordination layer: the project session that owns an open project's stores; `ProjectStore` (the manifest: structure, research, statements, cast, trash and every binder verb); `DocumentStore` (the folder's file presenter, the registry of open `Document`s, the typed user-content mover, admission and the posture door); the inbox and its transcription; the small stores (recents, sessions, trash, debounce, staging); and the `.maugham/` layout. The one rule from CLAUDE.md: **move or delete user content only through `DocumentStore`'s typed mover (tripwire 14).** The area carries tripwires 14, 17, 19, 20, 21, 22, 24, 35, 38, 40, 41, 46, 49, 50, 51, 52 and 53. The why behind every rule below, and its history, is in `docs/history/stores.md`.

## Map

Every file in `Maugham/Stores/` appears once.

### The session and the two big stores
- `ProjectSession.swift` — an open project's stores and `claude` services, owned outside any view: `open(url:)`, `attachWindow`/`detachWindow`, `close()`; the sole assigner of the store's live canvas model (`CanvasLiveSeamTests`).
- `ProjectSessionRegistry.swift` — one `ProjectSession` per project, borrowed by every window (`acquire(_:as:)`, `release`, `shutdownAll()`).
- `ProjectStore.swift` — the façade's core types (`ProjectStoreError`, `StructureItemKind`), the `ProjectStore` class, `load`, word counts, `derivedCache`.
- `DocumentStore.swift` — the project-folder coordinator: the `NSFilePresenter` callbacks (`presenterDidChangeSubitem`), the `Document` registry, manifest IO and adoption hand-off, sessions and UI state, the typed mover (`relocate(plan:)`, `relocateUserContent`, `trash`), `coordinatedMove`/`coordinatedWrite`, `admit`, `invalidateTrust`, `reReadAfterExternalChange`. Tripwires 14, 40, 49, 50.
- `DocumentStore+Registry.swift` — `revoke(person:)`, `retire(device:)`, `claim(adopting:)`, `forgetPersonKey(person:)`, `settle`, `heldLines()`/`heldLinesByDevice()`, `highestOpIdApplied(fromPerson:)`, the silent-admission queue. Tripwires 41, 53.
- `DocumentStore+ClosedHeldLines.swift` — held lines in documents nobody has open (`closedProvenance`, `sweepClosedProvenance`).
- `DocumentStore+Posture.swift` — the Mac's posture door: `PostureBook`, `posture(forDocId:as:)`, `settledPosture(forDocId:as:)`, `posture(forPath:)`, `overrideYield(docId:)`. Tripwires 46, 51.
- `ProjectFolderPresenter.swift` — the `NSFilePresenter` that forwards callbacks to its delegate (`DocumentStore`).
- `MaughamSidecarPath.swift` — typed classification of a project-relative URL; the presenter dispatches on it. Tripwire 40.
- `ManifestEcho.swift` — content signature of the manifest bytes last known on disk (the adoption echo guard).
- `ManifestConflictArchive.swift` — the one spelling of `.maugham/conflicts/manifest-<ts>.json`.

### `ProjectStore` seams (one peer file per seam)
- `ProjectStore+Structure.swift` — structure CRUD, `moveStructureItem`, `tidyFilenames`, `duplicateStructureItem`, `mintOpenings(of:)`, `propagateWikiLinkRename`. Tripwires 14, 52.
- `ProjectStore+Trash.swift` — delete/restore, ⌘⌥Z (`armDeletion`, `TrashDeletion`), `emptyTrash`.
- `ProjectStore+Metadata.swift` — inspector metadata, pass states, targets, review passes, typography.
- `ProjectStore+Research.swift` — research CRUD, `deleteResearchItems(ids:)`, `trashResearchItemCore`, `renameResearchPath`. Tripwire 14.
- `ProjectStore+Citation.swift` — `updateCitation(researchId:_:)`, the one door citation details are written through (inspector and MCP), and `suggestedCitationKey`.
- `ProjectStore+ResearchMove.swift` — `moveResearchItems(ids:to:atIndex:)`, `ResearchMoveTarget`, `researchDedupedNotePair`. Tripwire 14.
- `ProjectStore+CollectionPieces.swift` — Collection loose pieces, `movePiece`/`renamePiece`, `promotePieceToProject` and its staging rollback. Tripwire 14.
- `ProjectStore+References.swift` — Collection project-references (Mac-local, ADR 0009): `resolveReference`, `relinkReference`.
- `ProjectStore+WikiLink.swift` — `[[…]]` title resolution (`WikiLinkProject` conformance).
- `ProjectStore+Search.swift` — project search and Replace (`performSearch`, `replaceMatch`, `replaceAll`, `replaceInManuscript`). Tripwire 52.
- `ProjectStore+Tasks.swift` — the `__project__` task stream and `appendProjectTaskOp`; cross-project task aggregation.
- `ProjectStore+Annotations.swift` — the project-wide annotation walk and open-note counts; an unreadable closed doc is skipped and its id returned in `unreadableDocIds` (RULING-54), so a count says unknown rather than a short number. Tripwire 49.
- `ProjectStore+Palette.swift` — palette cards, `paletteCoordinatedWrite(_:to:)`, `healPaletteRolesEagerly`, role healing.
- `ProjectStore+CanvasAssets.swift` — the canvas's asset well (`ingestCanvasAsset(image:)`/`(fileURL:)`).
- `ProjectStore+Statements.swift` — statements: lookup, `createStatement`, `withStatementDocument`, `mutateStatementText`, `appendToStatement`, `statementText(of:)`, the open registry and gate. Tripwires 20, 52.
- `ProjectStore+StatementAssets.swift` — a statement's asset well (`addImage(toStatement:scope:…)`).
- `ProjectStore+StatementAdoption.swift` — one-time adoption of legacy craft-intent notes (`adoptLegacyCraftIntentIfNeeded`).
- `ProjectStore+ProductionRoles.swift` — the cast: translator, reader, collator per language, and the designer.
- `ProjectStore+ManifestAdoption.swift` — `adoptExternalManifest`, `beginStructuralVerb()`/`endStructuralVerb()`.
- `ProjectStore+RemovedElsewhere.swift` — `refreshRemovedElsewhere()`, `restoreRemovedElsewhere(id:)`.
- `ResearchScope.swift` — where a new research item lands (typed seam, ADR 0010) and `pieceResearchPrefix`.

### Small stores and helpers
- `DebounceScheduler.swift` — cancel-and-restart task helper; the 750 ms autosave window.
- `RecentsStore.swift` — recently opened project folders (UserDefaults).
- `SessionLog.swift` — the session event log type (.maugham/sessions.json).
- `SessionTracker.swift` — the active writing session in memory (`shiftBaseline(by:)`, idle threshold).
- `UIState.swift` — per-project UI state (.maugham/ui-state.json), `AuthorReaderChoice`.
- `TrashStore.swift` — `<project>/.trash/` entries, `TrashSubject`, `sweep()`, `permanentlyDelete`.
- `LetGoRecord.swift` — per-device ids of pieces let go from Trash. Tripwires 17, 24.
- `SentCopyStore.swift` — a Word export's sent copies; `drafts(book:)` derives the draft count by scanning. Tripwires 17, 24.
- `RemovedElsewhere.swift` — the derivation of pieces that left the structure without going to Trash.
- `RenamePlan.swift` — a validated batch of path renames for `relocate(plan:)`.
- `DesignProposalStore.swift` — staged design proposals under `.maugham/design/`.
- `StatementProposalStore.swift` — staged brief and visual-language proposals.
- `TranslationRoundStore.swift` — the ring of translation rounds per language.
- `ProjectFactory.swift` — new projects on disk (Novel/Screenplay/Short Story seeds, and a Report in either prose shape, writing only `profile`; a profile on any other kind throws `profileNotOffered` before anything is written). Tripwire 52 (starter).
- `SampleProjectBuilder.swift` — materializes a bundled sample project.
- `ProjectSearchEngine.swift` — the walk behind project search.
- `ResearchKindInference.swift` — file extension → `ResearchItem.AssetKind`.
- `WikiLinkProject.swift` — the title-resolving protocol; `WikiLinkRewriter.swift` — rewrites `[[Title]]` in a body.
- `PersonKeyAccess.swift` — the one production construction of a `PersonKeyStore`. Tripwire 53.
- `ICloudShareMetadataReader.swift` — Mac alias for Core's `FileURLShareMetadataReader`.

### The inbox
- `InboxStore.swift` — the capture inbox (`.maugham/inbox/`): verified chained read, sealed appends, bylines, held-row counts, promote/send verbs; a counted caller of `createResearchNote(` (`TripwireGrepTests.test_filingAResearchNoteHasAKnownSetOfCallers`). Tripwires 17, 24.
- `InboxTranscriptionWorker.swift` — serial worker running an injected `Transcriber`; `WhisperKitTranscriber.swift` is production (Apple Silicon only).

### The `.maugham/` layout
Everything derived lives under `.maugham/` (two exceptions below), and each path has one owner.

| Path | Owner | What it is |
|---|---|---|
| `.maugham/ops/` | `OpLogStore` (OpLog/Core) | per-doc, per-device op logs and `.mzseg` segments |
| `.maugham/ops/__project__.jsonl` | `ProjectStore+Tasks` | the project-scope task stream; rotates into segments at the open sweep like any tail |
| `.maugham/checkpoints.<deviceSlug>.jsonl` | `CheckpointStore` (OpLog) | ⌘S checkpoints, per device; a FILE, never a directory, never the unsuffixed `checkpoints.jsonl` (a merge source, never written) |
| `.maugham/pending/` | `PendingBuffer` (OpLog) | per-device crash-recovery buffer (`<docId>.<slug>.pending.jsonl`), kept out of `ops/` so the op-log glob never matches it; safe to nuke |
| `.maugham/conflicts/` | `Document` (diverged/external `.md` backups) and `DocumentStore` (`manifest-<ts>.json` archives) | conflict backups |
| `.maugham/conflicts/quarantined-ops/` | `OpLogQuarantine` (OpLog) | set-aside op-log history: a moved unreadable file (`.file`, offered back by Retry) or a copy of a run of lines this device did not write (`.lines`, content-deduped, never returned: `ReturnOutcome.setAsideByProvenance`), each with a `<name>.quarantine.json` |
| `.maugham/conflicts/quarantine/` | `IntegrityQuarantine` (Core) | op-log lines that failed to decode, content-deduped |
| .maugham/sessions.json | `SessionLog`, written by `DocumentStore.appendSessionEvent` | session events |
| .maugham/ui-state.json | `UIState`, read and written by `DocumentStore` | window and pane state |
| `.maugham/scratch/` | `DocumentStore` (rename scratch) | transient; safe to nuke |
| `.maugham/let-go/let-go.<slug>.jsonl` | `LetGoRecord` (written by `TrashStore.permanentlyDelete`/`sweep`) | per device: ids this device emptied, deleted or swept from Trash |
| `.maugham/inbox/` | `InboxStore` | `inbox.<slug>.jsonl` per device, plus `text/`, `images/`, `audio/` |
| `.maugham/devices/`, `.maugham/people/` (`claims/`, `events/`) | `RegistryWriter` (Core) | the book's register (tripwire 40) |
| `.maugham/design/proposals/<proposalId>/` | `DesignProposalStore` | spec.md, `files/<path>`, proposal.json, then `scratch/` and `backup/` |
| `.maugham/statements/proposals/<key>.json` | `StatementProposalStore` | one pending proposal per key |
| `.maugham/exports/<book>/<export-id>/` | `SentCopyStore` | a Word export as sent: export.docx and sent.json; the id is `yyyyMMdd-HHmmss-<slug>`; out of the backup signature |
| `.maugham/translations/` | `TranslationStore` (Core); `rounds/<lang>.json` is `TranslationRoundStore`'s | translation records; the round ring |
| .maugham/canvas.json | `CanvasStore` (Canvas) | the canvas layout |
| .maugham/manifest.shadow.json (+ .sha256) | `ManifestShadow` (Core) | the manifest's safety copy: a corrupt or missing manifest is restored from it (not while iCloud is still downloading it) (#92) |
| `.maugham/publish/`, `.maugham/publications*` | Publish area | templates, config, build; the publication log and snapshots |
| `.maugham/diagnostics/`, `.maugham/derived/` | Compiler area (`DiagnosticsStore`, `DeclaredWorldStore`) | compiler output |
| `.maugham/bible.<deviceSlug>.json` | `BibleStore` (Compiler) | the bible ledger and graduated keys, per device |

Two things deliberately live elsewhere:
- **The Trash is `<project>/.trash/`** (`TrashStore.trashRoot`), not under `.maugham/`.
- **This device's key material** is in `DeviceState.directory` (`~/Library/Application Support/<BuildVariant.current.supportFolderName>/device/`): one key blob and token per `DeviceActor` (`device-key.blob`/`device-token` for the author, `device-key.<actor>.blob`/`device-token.<actor>` for the others) and one op-log-state.json. It must never sync: a copied token would make two machines one device id on one per-device file (tripwire 17), and the remembered chain heads are this device's private account. Under XCTest the path gains an `xctest-worker-<pid>` leaf, so parallel workers never share a key or a head.

## Rules

### Tripwires this area carries
- **14 — Move or delete a path the writer might be editing only through the typed mover** (`relocate(plan:)`, `relocateUserContent(affectedPaths:perform:)`, `trash(relativePath:using:…)`), never a raw `FileManager.moveItem`/`moveToTrash`: the 750 ms autosave recreates the file at the old path. `TripwireGrepTests.test_noRawMoveOfUserContentOutsideTypedMover` scans every `ProjectStore+*.swift` file; `test_userContentMoverTripwireFiresOnPlantedOffender` is its control.
- **17 — A file more than one device writes is partitioned per device** (`let-go.<slug>.jsonl`, `inbox.<slug>.jsonl`), read as the union of every device's file: iCloud cannot line-merge one shared JSONL. Op-log side: `OpLogStoreSegmentTests.test_legacyFile_neverSealed`.
- **19 — What the phone also reads is implemented once in MaughamCore** (`StatementLookup`, `StatementConvention`, `PaletteLookup`, `PaletteConvention`, `InboxConvention`, `RegistryPresence`'s claim rule, `PersonKeyStoreChoice`): two copies drift. `TripwirePhoneGrepTest`.
- **20 — A statement's prose is read from its op log, never its `.md`**: through `statementText(of:)`. Every file read in a production file carries `// adr-0018-ok: <reason>` saying what it reads (`TripwireGrepTests.test_noManuscriptFileReadsOutsideReconciler`).
- **21 — Post through `MaughamEvent`** (`postNotice`, `postDetailSegment(_:)`, `postAdmissionRequested`), never a raw `maugham.*` notification (`TripwireGrepTests.test_noRawMaughamPostsOrSubscriptionsOutsideWrapper`).
- **22 — A rename or move is followed by the editor's PATH-keyed reload** (`EditorHost.needsReload`), never an id-keyed one: prose only.
- **24 — Filenames take a `DeviceSlug`** (`LetGoRecord.fileURL(for:in:)`, the inbox manifest): enforced by the compiler.
- **35 — `trashedBy` is a display string, never an identity**: `DocumentStore.trashedByLabel` gives the register's label or the machine's name (`TripwireGrepTests.test_noHostnameIdentity`).
- **38 — Every `Document.load` here passes a `DeviceActor`** (`.author` for `mintOpenings`, Removed Elsewhere's restore and the statement dance), never a `device:` string (`TripwireGrepTests.test_noDeviceStringAtAProductionDocumentLoad`).
- **40 — `MaughamSidecarPath`'s `.registry` arm asks `RegistryWriter.directoryURL`** and never spells a registry folder (`TripwireGrepTests.test_registryRecordsAreWrittenThroughRegistryWriterOnly`).
- **41 — The registry verbs call `RegistryAdmission`/`RegistryPresence`**, never `RegistryWriter.write` (`TripwireGrepTests.test_theRegistrysWritersAreThreeFiles`).
- **46 — The posture door wraps `OpLogStore.localWritePermit`** and builds no permit of its own (`TripwireGrepTests.test_theWriteSidePermitQuestionHasOneFunction`).
- **49 — The unsigned snapshot is taken in one home**: `DocumentStore`'s `sweptUnsignedSnapshot` (the narrowing admission's price) and `ProjectStore+Annotations`' snapshot reads are the Stores entries in `TripwireGrepTests.test_theNarrowingPredicateAndTheSnapshotAreInThePermitLayerOnly`; never compute the snapshot elsewhere.
- **50 — The held-line and schema call sites are counted per type** (`TripwireGrepTests.countedLists`, `test_theP3bCountedListsAreExactlyTheNamedArrays`): `DocumentStore`'s `expectedStreams(`, `gateOldBuildsOut` and `currentSchemaVersion` assignments, and adoption's one schema stamp. Add a new call to the list deliberately; a schema number written anywhere else skips the raise-only rule.
- **51 — `DocumentStore+Posture.swift` is the Mac's one answer to what a window may offer** (`TripwireGrepTests.test_postureIsAskedOfThePermitInOnePlace`; allow-list `postureAskAllowed`).
- **52 — A manuscript writer outside the editor asks its posture first** (`replaceInManuscript`, the rename's wiki-link sweep, `mutateStatementText`): `TripwireGrepTests.test_everyGuardedDocumentMutatorIsClassified`, `test_everyManuscriptWriterOutsideTheEditorIsANamedSite` (population `manuscriptWriterCallSites`).
- **53 — `PersonKeyAccess.swift` is the one production construction of a `PersonKeyStore`** (`PersonKeyCensusTests`).

### Store shape
- **Model a new store after `RecentsStore`, `TrashStore` or `SessionLog`**: small, one responsibility. `ProjectStore` is large only because the project is the central aggregate.
- **A new project-scoped seam is a new `extension ProjectStore` in its own peer file**, never a new top-level store class.
- **A standalone sidecar store is a `@MainActor` struct over a bare `projectURL`** (`TrashStore`, `DesignProposalStore`, `PublicationSnapshotStore`), not a `ProjectStore` extension.
- **No shared "current text" field on `DocumentStore`**: text lives on `Document` (`displayText`; `lastDiskEcho.bytes` for the echo guard). Look a document up through the registry's `document(for:)`.
- **Test-only `wait*` helpers do not go in production code**: mark them `#if DEBUG` or move them to a test helper. `waitForStructuralVerbs` is production (`readManifest` uses it).
- **Apply an id prefix once, in the generator** (ADR 0008): `scene-scene-…` or `doc-doc-…` is a bug.
- **Use `DebounceScheduler` for autosave-like behaviour**; for a different cadence add a configured instance, never ad-hoc debouncing.
- **Only the owner writes a `.maugham/` path** (the table above). The OpLog area writing `.maugham/ops/` and the checkpoints file is the ownership exception.
- **A new top-level `.maugham/` directory needs a reason**, and is a lowercase noun, plural for a collection of records.
- **Read and write cloud-synced manuscript and project files through `NSFileCoordinator`** (`coordinatedMove`/`coordinatedWrite`): iCloud otherwise races you.
- **Scan a directory without `.skipsHiddenFiles`**; skip dotfiles by name (`DotfileScan.isDotfile`): something outside Maugham flags `.maugham/` files hidden (`TripwireGrepTests.test_noSkipsHiddenFilesInProductionScans`).
- **`Task { [weak self] … guard let self … await … }` holds the owner across every await after the guard.** Bind `self` in a scope that ends before the suspension, take what the await needs as values, and end the pass when the store is gone (the word-count pass's fix). Three live instances are left alone (`DebounceScheduler.schedule`, `ProjectStore+Search.performSearch`, `DocumentStore`'s idle-session timer around `appendSessionEvent`); there is no census.

### The typed user-content mover
**Typed user-content mover** — the three entry points, each on `DocumentStore`:

| Entry point | Use for |
|---|---|
| `relocate(plan:)` | a flat `RenamePlan` batch: rename, reorder, cross-group move (`renameStructureItem`, `moveStructureItem`, `moveResearchItem`, `moveResearchItems`) |
| `relocateUserContent(affectedPaths:perform:)` | a bespoke move: the Collection piece's two-phase temp-suffix folder swap (`movePiece`/`renamePiece`), a note plus its `<slug>_assets/` (`renameResearchPath`). Run each step in `perform` with `coordinatedMove`/`coordinatedWrite` |
| `trash(relativePath:using:…)` | soft-delete into `<project>/.trash/` (`deleteStructureItem`, `deleteResearchItem`, `deleteResearchItems`) |

- **User content means** a manuscript `.md`/`.fountain`, a Collection piece folder, or a research note or folder.
- **Each entry point closes, unregisters and flushes before any file call** (`closeFlushAndUnregister`: every open `Document` at an affected path, plus `flushPendingSave()` for the research-note debounce), so a caller cannot forget either half.
- **A bespoke move commits step by step, so choose every destination before the first step runs.**
- **A note and its `<slug>_assets/` dedup jointly through the one helper, `researchDedupedNotePair`**: the stem must be free for the note AND for `<stem>_assets` (an orphaned assets folder makes a leaf-only dedup collide). It takes an `isTaken` predicate; the batch mover also unions its in-flight claims. A note with no assets folder dedups on the leaf alone. Never write a second copy.
- **`moveResearchItems` builds ONE `RenamePlan` for the whole batch** (files, group folders with descendant path rewrites, each note's `<slug>_assets/`) and calls `relocate(plan:)` once. Validation (unknown ids, cycles, role-guarded cross-scope moves) runs before any file call and fails the whole batch. `.link` items move in the manifest only. The single-item `moveResearchItem` routes through the same plan builder, the one place that knows a note travels with its assets.
- **`deleteResearchItems(ids:)` is one validation pass, one `trashResearchItemCore` per id, one manifest save.** A `.link` takes `TrashStore.recordManifestOnlyTrash` (a meta.json, no file), so a pathless item never reaches the file mover.
- **A new mover of user content routes through one of the three entry points.** Raw moves are allowed only with an `// internal-move:` marker, and only for: `promotePieceToProject`'s staging moves; their inverse in `rollbackPromotionStaging`; the no-`DocumentStore` fallback branches (unit tests, and `ProjectStore.load`, which runs before `ProjectSession.open` sets `documentStore`). Empty-file scaffolding, .maugham-link.json and manifest writes, scratch writes and `executeCopy` (Duplicate) are out of scope.
- **The staging rollback stays raw**: the close and flush already ran, and `relocateUserContent` throws and would re-enter a `DocumentStore` the promotion has closed. A compensation must not throw over the error it compensates.
- **A failed promotion moves its staged files BACK from a record, never a re-derivation**: each staging helper returns its `PromotionStagedMove`, and `rollbackPromotionStaging` walks them in reverse (`research/` has no op log, so deleting the staging tree loses it). A failed move-back logs loudly and leaves the staging tree standing; one stranded path does not abort the rest; a tree already gone means the promotion completed. Its test seam, `afterStaging:`, cannot throw.
- **Palette card writes go through `paletteCoordinatedWrite(_:to:)`**, never a raw `.write(to:)`. The funnel's no-`DocumentStore` fallback is the one raw write, marked `// palette-coordinated-write: <reason>` (`TripwireGrepTests.test_noRawWriteInPaletteStore`).

### Manifest adoption and structural verbs
- **A manifest another device wrote is adopted, never merged.** `handleManifestChanged` passes the `ManifestEcho` guard, decodes through `decodeGuardingSchema` (a later build's manifest is archived, never adopted), and calls `ProjectStore.adoptExternalManifest`. Last writer wins.
- **The copy an adoption replaces is archived** to `.maugham/conflicts/manifest-<ts>.json` (nothing when the two agree), including an unsaved change of the window's own, which is logged.
- **A function that awaits before saving the manifest is a structural verb**: `beginStructuralVerb()`/`endStructuralVerb()`. A manifest arriving during one is HELD, not adopted. `StructuralVerbCensusTests` requires it of every production function that awaits before `saveManifest()`, a direct `writeManifest(`, or an unsaved mutation of `manifest`; exceptions are by file and function with a reason, a stale exception fails, and every caller of an allowed helper must itself be a verb. Its known limits are in the test's header.
- **The settle runs on the NEXT main-actor turn** (`scheduleStructuralSettle`), so a verb's rollback in its `catch` lands before any adoption. `DocumentStore.structuralVerbsSettled` then archives the held manifest if the verb saved after it, else adopts it.
- **`readManifest()` waits for verbs and held manifests to settle** (`waitForStructuralVerbs`) and takes on unannounced bytes before returning. Never call it from inside a verb.
- **A creation path that calls `writeManifest(` directly reads the starter before it writes anything** (`ProjectFactory`'s public callers): `StructuralVerbCensusTests` wants no await ahead of that write.
- Every manifest written to disk goes through `ProjectManifest.encodeForDisk`, which stamps the content floor so an older build refuses rather than strips v10 content; narrowing raises only to `narrowingSchemaVersion` (`TripwireGrepTests.test_manifestBytesForDiskComeFromOneFunction`).
- **A piece open here that another device moved or trashed leaves the registry and `stopRendering()` before it closes**, so its flush keeps the last keystrokes and never writes a phantom `.md` at the old path.
- **`Document.close()` is single-flight**: the adoption and `EditorHost`'s reload both close a moved piece.
- **A piece that left closes with a `MaughamEvent.postNotice`.** It says *moved to Trash by <who>* only when `TrashStore.list()` holds that id (`<who>` is the entry's `trashedBy`, or *another device* for an older entry with none); otherwise it says `DocumentStore.removedElsewhereNotice`. Absence from the structure is not trash.
- **A restored copy is its own book**: `BackupRestore.renewIdentity` gives it a new manifest id and shadow (#92). ⌘S and ⌘⇧S back up through `CheckpointFlashDecision.backUp` (#90).
- **The editor never binds a closed `Document`**: `EditorHost.needsReload` answers true for an `isClosed` one, so a piece returning at the same path reopens.

### Word counts and the session
- **Another person's words never enter this writer's session.** Every re-read of an OPEN piece's op log goes through `DocumentStore.reReadAfterExternalChange`, which moves the baseline by the difference; `excludeForeignWords` moves the baseline and live total together (`SessionTracker.shiftBaseline`).
- **`register(document:for:)` counts a piece as it opens**, so the first keystroke carries only what it typed; the load-time pass skips a piece that left the structure since it began.
- **A piece that left drops out of `projectWordCount` at once; one that arrived is counted by `ProjectStore.recountFromOpLogs` off the presenter callback** (one trust table per pass off the main actor, a yield between pieces, open pieces skipped, a removed one never revived).
- **`invalidateTrust` drops the `DerivedManuscriptCache`** (it keys on op-log mtimes, and a trust change moves no file) and recounts every closed piece.
- **`ProjectStore.derivedCache` fronts `DerivedManuscript` for CLOSED docs only**, keyed on each op-log file's `(url, mtime, size)`; open docs read the live `Document`. It is `ProjectStore`'s (the weak `documentStore` is not wired during `load`) and `@ObservationIgnored`.
- **Project-open word counts are async** (`beginWordCountPopulation`, held as `wordCountPopulationTask`): `projectWordCount` is briefly partial after open. Perf guards assert derive counts, never wall-clock.

### Project sessions
- **An open project's stores live in a `ProjectSession`, owned outside any view.** `open(url:)` loads the manifest, opens the `DocumentStore`, cross-links them, builds the bible and declared world and an unconfigured `AgentRoster`; `attachWindow` configures the roster and makes the window's canvas model live; `detachWindow` undoes exactly that.
- **`close()` is the one end, in one order**: the roster detaches first, then the `DocumentStore` flushes and drains.
- **`ProjectSession.open` is not idempotent** (it declares this Mac, sweeps and rotates seals, starts transcription, installs a presenter), so every window asks the one `ProjectSessionRegistry`: the first `acquire(_:as:)` opens, later ones borrow, the last `release` closes.
- **One open in flight per project**: concurrent acquires await one task their cancellation cannot reach; a failed open registers nothing; an acquire during the last close waits and opens fresh.
- **A `.window` borrow attaches its window (newest wins; releasing hands it to the newest live window or detaches every service); a `.reader` borrow (Statistics) holds only the stores.** MCP registration follows the window borrows.
- **App quit calls `shutdownAll()`**, which reaches every roster, so no `claude` outlives a reader-held project (`TranslatorEnvironmentTests.test_everyWindowEndingPathShutsEverySessionDown` and its planted controls).

### The presenter and sidecars
- **`presenterDidChangeSubitem` switches on `MaughamSidecarPath`**, so a new sidecar owner is a compile error to route; a path with no routing joins the no-op arm.
- **The `.opLog` arm has two halves**: an OPEN document gets `handleExternalLogChange()` (its merge posts `.maughamAnnotationsChanged` past its echo guard, never the callback, which fires on our own appends); a CLOSED document gets the post directly.
- **The `.registry` arm schedules a debounced `registryChanged`** (forget every trust table, re-read every open document) unless the change is an echo of this Mac's writes (`registryChangeIsAnEcho`).
- **The `.letGo` arm schedules a debounced `refreshRemovedElsewhere()`.**
- **`.maugham/translations/`, `.maugham/design/` and `.maugham/statements/proposals/` classify as `.unknownSidecar`** on purpose: derived working areas with no route.
- **`MaughamSidecarPath.trash` matches `.maugham/trash/`, which nothing writes**; the real Trash, `.trash/`, classifies as `.otherProjectFile`.

### Removed Elsewhere and the let-go record
- **Removed Elsewhere is derived, never stored.** A piece qualifies when it has an op log and is not a statement; no live row and no Trash entry accounts for it (a trashed group accounts for its children); no device let it go; and an archived `manifest-<ts>.json` held it (row, parent, place and date from the NEWEST such archive).
- **Keep the archive leg**: a chapter an earlier build emptied from Trash has no let-go record.
- **`TrashStore.permanentlyDelete` and `TrashStore.sweep` are the two doors every permanent deletion passes**, and each records the removed entry's ids (a group's children too) in this device's let-go file once the folder is gone. Op logs stay on disk.
- **A failed let-go write is logged, not thrown**: the deletion already happened.
- **The wording names what happened to the binder, not who did it** (*Left the binder when two devices' outlines crossed*): the archive cannot say which.
- **`refreshRemovedElsewhere()` reads files off-main, driven by `RemovedElsewhereRefresh`** (a `.task(id:)` keyed on structure ids and Trash entries), so no verb has to ask.
- **Restore (`restoreRemovedElsewhere(id:)`) is a structural verb**: the row returns under its SAME id at its old parent and index (manuscript root if the group is gone; a numbered path if its path is claimed), the manifest saves, then the `.md` is re-rendered through `Document.load` + `performAutosave`, never from the stale file (the load backs a stale file up as `-diverged-`; a missing file is not a divergence). Going through the load keeps every held or refused line as judged. It moves no file, is not on ⌘Z, and moves the session baseline (`excludeForeignWords`).
- **Known limits**: a piece dropped while every Mac holding it was closed left no archive and is not listed; a piece an earlier build emptied from Trash IS listed; a single-device book lists nothing.
- **Known limit**: two Macs restoring one piece at once can leave a stray `.md` with no row; cleaning it up would belong in the adoption, through the typed mover, and is not built.

### The trash
- **The Trash is `<project>/.trash/`**, swept of entries over 30 days at `ProjectStore.load`.
- **Every entry records a `TrashSubject`** (`manuscriptItem`, `researchItem`, `captureAsset`, `internalArtifact`); `moveToTrash` will not compile without one. It decides which tree a restore rewires; an old entry without one falls back to the shape sniff and is REFUSED if it matches neither tree.
- **`list()` is the writer's view; `entriesIncludingInternal()` is all of it**, used by disposal and `restoreTrashEntry`.
- **Neither hides an entry it cannot read** (RULING-7): a Maugham-named folder with a missing or undecodable meta.json is an `isUnreadable` entry titled `TrashEntry.unreadableTitle`; restore refuses naming the cause; disposal reaches it. A folder whose name Maugham did not write (RULING-9) and an empty folder get no row.
- **`mintEntryFolder` claims a folder name** (`withIntermediateDirectories: false`; a taken name takes the next number). **Keep the timestamp a PREFIX**: the sweep dates entries by parsing the name (RULING-39).
- **"Empty Trash" walks the directory** (`TrashStore.entryFolderIds()`, not cached `trashEntries`) and throws `trashNotEmptied` after re-listing. Never put a `try?` in that loop.
- **The restore destination is the caller's** (`restore(trashId:to:)`, RULING-41): `TrashStore` knows nothing about manifests.
- **⌘⌥Z is armed with one `TrashDeletion` per delete gesture** (`armDeletion`). A restore consumes its entries (`forgetTrashId`); a permanent delete does not, so the next ⌘⌥Z refuses with a reason.
- **`trashedBy` is recorded on every trash** (`DocumentStore.trashedByLabel`).
- **The Trash is claim-covered**: read `register/reconciliation/Trash.{claims,filings}.json` before changing delete or restore; changing pinned behaviour updates the claim and filing in the same commit.

### Statements
- **A statement is a `Statement` in `ProjectManifest.statements`** whose content is an ordinary `Document` at the project root (intent.md, `intent/<slug>.md`, visual-language.md, `editions/<lang>.md`).
- **Look a statement up by SCOPE in the manifest**: no path prefix, no filename convention in the read path. The pure halves are Core's (`StatementLookup.statement(in:kind:scope:)`, `StatementConvention.newPath(kind:scope:documentSlug:)`).
- **Absence is valid and free**: `statement(kind:scope:)` returns nil and mints, stamps and logs nothing (`read_craft_intent` promises this).
- **`createStatement` refuses rather than redirects**: a scope that is not a manuscript document throws `.structureMissing`; a `(kind, scope)` with no storage row throws `.statementHasNoStorage`.
- **`createStatement` refuses an unsafe path**: an edition brief whose tag fails `TranslationRecord.isValidLanguageTag` verbatim throws `.languageTagInvalid`; every path goes through `SafeRelativePath.resolve(_:under:)` (`.statementPathUnsafe`). Both throw before any directory or manifest row (`EditionBriefStatementTests`).
- **Creation never takes an occupied path** (`vacantStatementPath` steers to intent-2.md): registering over an untracked file would own the writer's bytes.
- **The slug is derived from the title once, at creation**; identity is the manifest `id`, and a statement's path moves through the typed mover.
- **`createStatement` is idempotent.**
- **`withStatementDocument(_:session:_:)` is the ONE statement open-and-mutate dance**: the live `Document` via `openStatementDocument(id:)`, then the open gate, a re-ask inside it, then a transient `Document.load`/mutate/awaited `close`. The lookup plus mutate does not suspend. A throwing closure writes nothing, and the transient `Document` closes on that path too.
- **Who takes `lockStatementOpen` is a census** (`TripwireGrepTests.test_theStatementOpenGateIsTakenByExactlyTheseMembers`, `statementOpenGateTakers`). The gate is per statement and covers the OPENING only; a writer queued behind the pane re-asks the registry inside it (`StatementOpenGateTests`).
- **Statements have their own open registry because they are in no `DocumentStore` one** (it would put them in `allOpenDocuments()`, which task aggregation iterates). The pane registers on bind and withdraws before every close (`noteStatementDocumentOpened(_:id:)`, `forgetStatementDocument(id:)`); `openStatementDocument(id:)` refuses a closed `Document`. Anything that writes into a statement asks it before loading its own.
- **`mutateStatementText(of:session:transform:)` hands the transform the current text**, so check and write are one string; it asks the posture first (tripwire 52).
- **`appendToStatement(_:to:session:)` appends to the end of the ESSAY, not the file** (`StatementEssay`): below a `## Rulings` section it would be invisible to the Intent pane.
- **The inspector's intent row (`IntentAffordanceRow`) is a pane swap that mints nothing**; its caption resolves through `StatementPane.effectiveScope`.
- **Name every write's destination by statement**, never by what the pane shows now: callers suspend.
- **`statementText(of:)` is the one reader of a statement's prose** (`read_craft_intent`, `read_visual_language`): the open pane's `Document` if any, else `derivedCache.displayText`.
- **A promoted Collection piece takes its intent with it**: `stagePromotedIntent` (`// internal-move: staging`), `writePromotedManifest` re-scopes it with a fresh `stmt-` id, `convertPromotedPieceToReference` prunes the Collection's entry. The entry point closes an open statement `Document` explicitly first. The op log stays behind; the new project re-bootstraps from the `.md`, so a derive-only read answers "" until something opens it.

### Statement and canvas asset wells
- **`ingestCanvasAsset(image:)`/`(fileURL:)` are the one pair that gives a canvas item a file**; every route is a caller. The Finder drop takes the file twin, the browser bitmap the image twin (`CanvasAssetIngest`, `CanvasExternalDrop`); never route one case through the other twin, which would leave half the pair with no caller. A research drag ingests nothing.
- **`canvas_assets/` is at the project root beside `canvas.md`, content not derived state**: deleting .maugham/canvas.json must never cost the photographs.
- **A well's name is derived and never spelled**: `ImagePasteHandler.wellURL(forNoteAt:in:)` builds `<slug>_assets` from the file's name and creates nothing. `TripwireGrepTests.test_theSharedImageSaverIsCalledFromTheSeamsThatOwnAWell` (the files that may call `ImagePasteHandler.saveAndReference*`) and `test_theCanvasAssetWellIsDerivedAndNeverSpelledInCode`.
- **The canvas pair returns a PROJECT-RELATIVE path** (`CanvasItemReference.owned(path:)`), resolved through `ProjectStore.resolveImageRef(_:relativeTo:)`: never absolute, `file://` or the Markdown ref.
- **Image writes into a well are uncoordinated** (new files, unique names, written once); manuscripts and card markdown still route through `DocumentStore`.
- **A statement's pictures go in its own well** (`addImage(toStatement:scope:image:)`/`(…fileURL:)`; `addImage(to:image:)` once found), never `canvas_assets/`.
- **The ingest validates before it mints**: a bad bitmap or refused file type leaves nothing.
- **A save failing after the mint is undone by `rollbackUnusedStatement`** (under the statement-open gate, taken unconditionally), which never removes a statement whose well holds anything: `statementWellHoldsAnything` is asked with the other refusals AND again just before `removeItem`, because `saveManifest` suspends.
- **It returns a `StatementPicture` (statement and ref) and never touches the statement's text**: the caller appends the ref through the op log. It opens no `Document` and takes no `lockStatementOpen`.

### Rename propagation
- **A rename moves the document's title AND the composed title of every statement scoped to it** (`ArtifactIndex.statementTitle`); the old title is composed from a closure answering the OLD name.
- **The renamed document is excluded from the document-title pair only**; the composed pairs still apply to it. A document with no scoped statements is skipped.
- **Manuscripts and statements receive ops**; statements go through `withStatementDocument`, never a second dance.
- **A research note gets a coordinated whole-file write behind one `flushPendingSave()`** (a raw write with no `DocumentStore`): without the flush a queued 750 ms note save lands after it with the stale body.
- **An empty derive is not "nothing to do"**: the manuscript loop falls through to `Document.load`; the statements loop does too when the statement's file has non-zero size (a `stat`, never a read).
- **Not covered**: an open `ResearchNoteEditor` can write its body back over the rewrite; the renamed document's own composed-title rewrite can be lost to its own path-keyed reload.

### Craft intent, palette and role identity
- **Palette cards and research notes are plain-edited** (no op log, no `¶id`), and absence is valid. Cards are research assets under `research/palette/`, parsed by Core's `PaletteCard`; the typed mover covers them.
- **Look up by role first, path second** (`ResearchItem.role`; Core's `PaletteConvention`/`PaletteLookup`). `ProjectStore.paletteFolderPath`/`paletteGroupTitle` alias the Core constants.
- **A path-identified lookup heals lazily** (`healRole`/`stampRole`, fire-and-forget, idempotent; no migration). Mac only: the phone reads `PaletteLookup` without healing.
- **Show the live title** (`paletteGroupDisplayTitle`), never the default.
- **Keep `ResearchRole.craftIntent`, `PaletteLookup.craftIntentItem` and the craft-intent arm of `healPaletteRolesEagerly`**: adoption, the palette heal, `Promotion.isCraftIntent` and the phone read them.

### Adoption of legacy craft intent
- **`adoptLegacyCraftIntentIfNeeded()` is gated on the on-disk schema `< 4`** (a fixed number, never `currentSchemaVersion`) and runs from `ProjectStore.load`.
- **The stamp is unconditional, including after a failure**: no resume, no retry.
- **Content arrives as a bootstrap op** through `Document.load`, never a bare file write.
- **Duplicates concatenate, oldest first** (`ResearchItem.addedAt`, ties on tree order).
- **Scope is read most-specific first**: a loose piece's research prefix; a `linkedResearchIds` record naming exactly one document; else the project.
- **Read every body before creating anything; trash the notes LAST** (`deleteResearchItems`). A scope adopts whole or not at all.
- **A note claimed by two documents falls to the project**, never a guess.
- **That trash takes the `// internal-move:` branch** because `documentStore` is not wired yet: safe for that branch's reason, not because a close or flush ran.
- **A note with no file or an empty body is not adopted and not touched**: a pathless item handed to `deleteResearchItems` leaves the manifest with no trash entry.
- **Failure never blocks the open**; scopes are isolated and failures logged.
- **`modified` shifts only when prose moved.** Tests cross a whole-second boundary first.
- **Keep the legacy-filename fallback** even though `load` never reaches it (`healPaletteRolesEagerly` runs first); it is tested by driving adoption directly.

### Production roles
- **Only a RUN may call `translatorRole(for:)`, `readerRole(for:)` or `collatorRole(for:)`**: each finds or MINTS and persists a row (`mintedLanguageRole`, `commitProductionRoles`). A status read uses the pure lookups (`EditionStatus.translatorName`/`readerName`/`collatorName`).
- **The designer is never minted**: `designerRole()` returns the stored row or `ProductionRole.presetDesigner` and writes nothing.
- **`renameProductionRole(id:to:)` is the one production entry point that mutates `productionRoles`.**
- **A language tag is refused if invalid once lowercased** (`.languageTagInvalid`, after `.productionRoleLanguageEmpty`), stored verbatim and matched case-insensitively (`ProductionRoleStoreTests`).
- **External MCP edits (`write_translation`, `write_publish_file`) carry no role signature**, so a signed annotation means the work came through the app loop.

### Staging stores
- **`DesignProposalStore.stage` takes `designerName:` from its caller** and never resolves `designerRole()`.
- **`stage` supersedes every pending proposal project-wide**, never an approved one.
- **`list()` reads newest-first and skips an unreadable folder** rather than throwing.
- **`Status` decodes with an `.unknown(String)` that re-encodes losslessly**: proposal.json is rewritten in place.
- **`.maugham/design/` is derived and deletable, except while a promotion stands**: that proposal's `backup/` is the only copy of the displaced templates, so `delete(id:)` throws `.promotionBackupStands(id:)` until `ProposalPromotion.revert` or `.finalize`. `backupDir(id:)` is spelled on the store.
- **`StatementProposalStore` never writes a statement**: the one write into an essay is `StatementProposalGate.adopt`, a writer's click. `stage` supersedes the slot and returns the proposal re-read from disk; `validate`/`glossaryLines` check a brief's `## Rulings` and refuse rulings in visual language. Craft intent has no key (`ProposableStatement` has no case).
- **The ring keeps the newest 10 rounds per language, and its next number outlives the ring**, so a trimmed round's number is never re-minted.
- **`TranslationRoundStore.append` mints the next number; `update(_:)` rewrites a round in place by its own number** and never mints. A round the ring aged out throws `UpdateError.roundGone(number:)` in words, never a silent re-append (which would give a settled round a new number). A missing or undecodable file reads as an empty ledger.
- **The round file is a whole-file rewrite, not per device**: one `TranslationPipeline` per project session (`AgentRoster.pipeline`) is its only writer on this Mac.

### Admission and the registry
- **`DocumentStore.admit(device:label:ownName:permit:)` is the one production path behind Admit**, three acts in order: `RegistryAdmission.admit` off the main actor (it throws its refusals); `invalidateTrust()` (every open `OpLogStore` AND the inbox); a re-read of every open document.
- **The other verbs call `settle`, which is admit's own acts in admit's order.** `forgetPersonKey` settles before rethrowing `PersonKeyForgetIncomplete`.
- **What an admission pays for is decided before it pays**: `permitThisAdmissionInstalls(asked:for:)` asks `RegistryAdmission.standingRecord`; only an act that installs a narrowing permit pays the snapshot (`sweptUnsignedSnapshot`) and the schema gate (`gateOldBuildsOut`). An unreadable registry throws.
- **`highestOpIdApplied(fromPerson:)` is computed from OPEN documents only.**
- **`heldLinesByDevice()` is `heldLines()`'s counts**, the union of open documents, the closed map and the inbox, so the surfaces cannot disagree. `heldLines()` also carries the stream slugs each holder was held in (`HeldLineUnion`): only the file it wrote in says which of a device's four writers a key is, and a key that is not a person's is never offered as one.
- **`Document.handleExternalLogChange` re-stamps `provenance` ABOVE its echo guard, and only when it differs**: a held line produces no op, so below the guard the pending count would stay at the open-time value; assigning only on change keeps an invalidation off every keystroke's echo.
- **`register(document:for:)` and the presenter's `.opLog` arm both call `announcePendingHistory`; it posts once per new stranger; the presenter path debounces 1 s, `register`'s does not.** Its predicate is provenance, never the registry. Whether there is anything to ask stays `AdmissionDecision.requests`' question, so no verified registry read lands on the keystroke path.
- **Closed documents' held lines** (`ClosedHeldLinesTests`): passes run at open, after every `invalidateTrust` (which bumps `closedTrustEpoch`), and per document through `pendingAnnounceScheduler`. They are chained (`closedSweepTask`), resolve one trust table off-main, skip open documents, and keep a throwing document's previous entry. Nothing lands if the epoch moved; a fresher entry wins; ids the manifest dropped go.
- **The union counts each docId once** (open provenance, else the closed map) and only ids the live manifest lists (`countedClosedProvenance(excludingOpen:)`). A close MOVES provenance into the map; an open drops the entry.
- **A landing posts `postAdmissionRequested` only when what it holds for a STRANGER changed.** `handleManifestChanged` prunes the closed map before adopting. `startedAPiece` stays open-documents-only, so a closed piece's piece question is put when it opens. The presenter's open arm collects every open document a burst touched (`pendingAnnounceDocIds`). Known limit: a chapter restored from Trash re-counts its stale entry until the next pass.
- **Order at open**: `declareThisMac` → `ensureRootIfEmpty` → `RegistryPresence.admitRecognised` (own `do`/`catch`) → `admitRemembered`, all before the seal sweep and any `Document.load`. Recognition runs first, so the remembered path never hands a person narrowed in this book the whole book, nor admits a device recognition declined. The key is looked up off the main actor (`PersonKey.findOrCreate(in:seedName:)`, seeded with `thisWritersName`).
- **The claim rule is Core's** (`RegistryPresence.claimIntent(forDevice:personKey:)`): a key gives `.set`, no key gives `.keep`, never `.remove`; `RegistryPresence.declareDevice` re-writes with `.keep` when the record refuses the claim.
- **`declareThisMac` never costs the open**: a claim problem is logged as a `.fault` and kept on `personClaimProblem`; a changed person key on `personKeyChanged` (#103).
- **Silent admissions (`admitRecognised()`, `admitRemembered()`, `open`'s passes) run in `serialisingSilentAdmission`**, so a device is admitted once. `AdmissionDecision.refreshedRequests` calls recognition only when a device record is waiting; otherwise the next open links.
- **Only a signed Release build reaches the keychain**: a test host with nothing injected gets an `InMemoryPersonKeyStore` that refuses to create. A suite that wants a key sets `PersonKeyAccess.storeForTesting` and clears it in `tearDown`.

### The posture door
- **A surface DRAWS with `posture(forDocId:as:)`; a door that ACTS asks `settledPosture(forDocId:as:)`.** Drawing is cached per epoch, never resolves a registry on the main actor, is provisional (last known → the open document's stamp → `Posture.settling`) and uncached while a refresh runs, fails closed only for a document never answered, and may show a verb the new permit refuses until the refresh lands; the acting door refuses it. `settledPosture` waits out a refresh, re-warms if the folder moved, and never answers provisionally.
- **A trust change or manifest adoption bumps the epoch, clears the cache and unpublishes the table.** The refresh warms every asked `(docId, actor)` into a staging dictionary off-main (`stagePostureCache`), then in ONE main-actor turn publishes the table and answers, re-stamps every open `Document` (manuscripts and `ProjectStore.liveStatementDocuments`) and bumps the epoch WITHOUT clearing (the first bump cleared; clearing here makes every redraw a miss) (`test_theRestampAndTheBumpAreOneTurn`, `DocumentStorePostureTests.test_theRedrawAfterATrustChangeIsAllHitsAndEveryHitIsFresh`). A folder that moves mid-warm abandons the warm and clears.
- **The builder reads class and starter from ONE `ManifestPlacement`** (`postureManifestPlacement`; `test_theBuilderReadsTheClassAndTheStarterFromTheSameManifest`).
- **`PostureBook.asked` is pruned at every adoption** (`prunePostureAsked`): a key stays while its document is in the adopted manifest (structure item or statement), open in this window, or is `__project__`.
- **A book with no register is always warm** and answers `Posture.author`.
- **Every door behind a host fails CLOSED**: `ProjectStore.documentStore` is weak and goes a frame early (`TreeStructureVerbs.none`, `TranslationAuthorVerbs.none`).
- **The owner yield**: where this device holds its root record, the author's posture on a piece (and its statement and translation) yields to that piece's writers (`PieceWriters`, over `TrustTable.myChain`), never to this device's own person or a whole-book co-author; a whole-book author that is not the root yields to nobody.
- **The starter yield**: every book author yields to the permit's `unsettledStarter` ahead of the owner yield, without waiting for `PieceWriters`. Acting doors honour it. It lifts at a trust change or at the external re-read that brings a book author's text.
- **Both yields end with `overrideYield(docId:)`** (Edit Anyway), for this window and session.
- **The manuscript writers outside the editor skip and name** a refused document (Replace All, the rename's link sweep). The rename's sweep is the one that still LOADS a starter-yielded piece; only the load can say *waiting*, it cannot mint there, and the write asks the door again.
- **`appendProjectTaskOp` is the one door for the `__project__` stream's task ops**; a refusal is a `postNotice` (`.settling` says *try again in a moment*), and a refused create or archive registers no ⌘Z. A refused ⌘Z inverse while `.settling` consumes that undo step. The census checks the door is asked before the mirror write (`TripwireGrepTests.test_everyProjectTaskOpPassesTheProjectStreamsDoor`, `projectTaskOpAppendSites`). Never allocate a real document with id `__project__`.
- **`posture(forPath:)` asks the open document and the live manifest first, then caches an unknown path's resolution per epoch**, a fabricated id only while `ManifestFileStamp` is unchanged, and never the `?? path` fallback (`test_aPieceCreatedAfterAMissResolvesToItsRealIdOnTheNextAsk`).

### Starters and openings
- **Every piece a creation site makes records `StructureItem.startedBy`** from `ProjectStore.thisMacAsAStarter` (`addStructureItem`, `duplicateStructureItem`, `addLoosePiece`, `addProjectReference`, the `ProjectFactory` seeds); a group records nothing (`TripwireGrepTests.test_everyStructureItemAProductionFileConstructsRecordsItsStarter`).
- **`writePromotedManifest` carries the piece's own starter; rename, move, tidy and Trash restore carry the stored item.**
- **A Duplicate mints its openings at creation** (`mintOpenings(of:)`: `Document.load` as `.author`, `performAutosave`, close); reference pieces are skipped and a refused load is logged.

### The inbox
- **Every inbox stream is read and written through `JSONLAppendStore<InboxEntry>` with `InboxStore.chainPolicy()`**, the same implementation as the op log's tails.
- **`refresh` reads verified** (`loadVerifiedStrict()`); an unvouched run is set aside under `InboxManifest.chainDocId` (`"inbox"`). A broken chain is not an unreadable file.
- **Every append is sealed on the spot** (`appendThrowing` then `appendSeal()`); a Mac with no key writes no seal.
- **`identity` is injectable** (`InboxStore(projectURL:deviceId:identity:…)`, default `.author`); tests pass a software signer. `deviceId` names the row and the manifest file; the identity is what the chain is verified against.
- **Bylines resolve once per `refresh`** off the same verified registry as the trust table (`TrustResolution.resolveVerified`). `Maugham/Views/InboxByline.swift` composes them; this Mac's captures and a book with no chain get none.
- **A byline names an admitted device by its label, a recorded but unadmitted one by its name plus *(not yet admitted)*, an unrecorded one by its four-character code.** A stranger's sealed rows are held and never become rows.
- **`pendingByDevice`/`pendingDeviceNames` count held rows** from the verified read, emptied when the registry refuses. `InboxPane.pendingNotice(counts:names:)` and People & Devices read the same two.
- **Inbox `writtenAt` is monotonic** (tripwire 17's clock-skew rule), stamped on every append.
- **Asset subdirectories come from `InboxConvention`** (`TripwireGrepTests.test_noRawInboxSubdirLiteralsInInboxStore`).
- **MCP may read and promote the inbox; it never adds or trashes.**
- **Read `register/reconciliation/Inbox.{claims,filings}.json` before changing inbox behaviour.**
- **The three promote siblings (`promoteToResearch`, `promoteToPaletteCard`, `sendToCanvas`) run every fallible write BEFORE the throwing `.promoted` flip and retire the original AFTER it**, so a failed flip leaves the original in place and a retry finds it (never a stuck `.new` with `assetMissing`).
- **A promoted original goes to the project Trash** (`trashPromotedAsset` → `ProjectStore.trashCaptureAsset`, a `captureAsset` entry), never `removeItem`; a failure there is logged, leaving a duplicate rather than a loss.
- **An empty text or untranscribed audio is `nothingToPromote`. An audio recording is never retired.**
- **`promote_inbox_entry`'s `palette_card_id`/`palette_subject` are mutually exclusive with `target_document_id`.**
- **`promoteToPaletteCard` appends into an existing card** (`.text`/`.audio` as a `PaletteCard.SensoryNote`, untagged when `sense` is unknown; `.image` through `addImage(toPaletteCard:fileURL:)`).
- **`sendToCanvas` asks `CanvasCapture.refuseUnlessWritable` first**, before the copy and the flip (`CanvasStore.SidecarRefused`); with a canvas open the live model answers.
- **`sendToCanvas` ingests, writes the canvas, flips, then retires.**
- **The retry converges**: the node id is `cap-<entryId>`, and the image arm asks `CanvasCapture.existingNode` (via `CanvasClaudeWrite.liveModel`) before `ingestCanvasAsset`.
- **There is no MCP write path onto the canvas from the inbox.**
- **`InboxTranscriptionWorker` is poked on every inbox change**, audio or not, because an `.m4a` and its manifest row arrive in either order.

## Recipes

### Add a `ProjectStore` seam
1. New file `Maugham/Stores/ProjectStore+<Seam>.swift` holding `extension ProjectStore`; stored state goes in `ProjectStore.swift` (an extension cannot store).
2. If the seam moves or deletes files, route them through `DocumentStore`'s typed mover. The file joins `test_noRawMoveOfUserContentOutsideTypedMover` automatically (every `ProjectStore+*.swift`).
3. If a verb awaits before saving the manifest, bracket it with `beginStructuralVerb()`/`endStructuralVerb()`, or add a reasoned exception in `MaughamTests/Stores/StructuralVerbCensusTests.swift`.
4. If it constructs a `StructureItem` piece, set `startedBy: thisMacAsAStarter`.
5. If it writes manuscript or statement text, ask the posture and add the call to `TripwireGrepTests.manuscriptWriterCallSites`.
6. `./gen.sh`, then add the file to this guide's Map.

Checks: `StructuralVerbCensusTests`, `TripwireGrepTests`.

### Add a project-scope sidecar under `.maugham/`
1. Write a standalone `@MainActor` struct in `Maugham/Stores/<Name>Store.swift` over a bare `projectURL`, spelling its directory in one function (`DesignProposalStore`'s `.maugham/design`, `LetGoRecord.directory(in:)`).
2. If more than one device writes it, partition per device: a `DeviceSlug` filename read as the union of every device's file, appended through `JSONLAppendStore` (`LetGoRecord.swift`). A single writer may rewrite the whole file (`TranslationRoundStore.swift`).
3. Every file read carries `// adr-0018-ok: <reason>`; a directory scan skips dotfiles with `DotfileScan.isDotfile`.
4. A record rewritten in place decodes with a lossless `.unknown` case (ADR 0015); a missing or undecodable file reads as empty, never throws.
5. If the sidecar changes often (UI-ish state, a per-action ledger), exclude it from the backup signature in `Packages/MaughamCore/Sources/MaughamCore/BackupSignature.swift`: its path in `excludedPrefixes`, or its stem in `excludedStems` for a per-device `<stem>.<slug>.jsonl` stream. Otherwise every write mints a backup generation.
6. Decide routing in `MaughamSidecarPath.swift`. Either let it fall to `.unknownSidecar`, or add a case. A new case goes to `classify`/`classifySidecar` (spelling the folder through your store, as `.letGo` does) and to `DocumentStore.presenterDidChangeSubitem`'s switch (a debounced refresh, or the no-op arm). Add a line for it in `MaughamTests/Integration/PresenterRoutingTests.swift`'s `test_sidecarPathParser_roundTripsAllCanonicalSubdirs`.
7. Add its row to this guide's `.maugham/` table.
8. `./gen.sh` after adding the file and its test.

Checks: `PresenterRoutingTests`, `TripwireGrepTests.test_noManuscriptFileReadsOutsideReconciler`, `test_noSkipsHiddenFilesInProductionScans`.

### Add a mover of user content
1. A flat rename set: build a `RenamePlan` (`RenamePlan.swift`) and call `documentStore.relocate(plan:)`.
2. Anything else: `documentStore.relocateUserContent(affectedPaths:perform:)`, choosing every destination before the first step, each step through `coordinatedMove`/`coordinatedWrite`.
3. A delete: `documentStore.trash(relativePath:using:…)` with its `TrashSubject`.
4. A note with assets: dedup through `researchDedupedNotePair`.

Checks: `TripwireGrepTests.test_noRawMoveOfUserContentOutsideTypedMover`, `DocumentStoreRelocateRollbackTests`.

### Add a statement writer
1. Go through `withStatementDocument` (or `mutateStatementText`/`appendToStatement`) in `ProjectStore+Statements.swift`; never `Document.load` a statement yourself.
2. Name the destination by statement id or `(kind, scope)`, never by the pane's current selection.
3. If it takes `lockStatementOpen`, add it to `TripwireGrepTests.statementOpenGateTakers`.

Checks: `StatementOpenGateTests`, `test_theStatementOpenGateIsTakenByExactlyTheseMembers`, `ManuscriptWriterPostureTests`.

## Pointers
- `docs/history/stores.md`: the old guide word for word, with every rule's why and the defects behind them.
- ADR 0006 (trash and undo, with the rulings amendment), ADR 0008 (id prefixes), ADR 0009 (Collection references), ADR 0010 (typed seams), ADR 0012 (per-device JSONL), ADR 0015 (schema evolution), ADR 0018 and 0019 (reads derive from the op log; clean `.md`), ADR 0021 (scoped events), ADR 0030 (the cast), ADR 0032 (the signed op log: admission, posture, Option A, the person key).
- `docs/tripwires.md` rows 14, 17, 19, 20, 21, 22, 24, 35, 38, 40, 41, 46, 49, 50, 51, 52, 53.
- `register/reconciliation/Trash.*`, `register/reconciliation/Inbox.*`.
- Neighbouring guides: `Maugham/OpLog/AREA.md` (the op log, `Document.load`, the person key), `Maugham/Views/AREA.md` (the panes), `Maugham/Canvas/AREA.md` (`CanvasCapture`), `Maugham/Compiler/AREA.md` (the designer loop, the pipeline), `MaughamPhone/AREA.md` (the phone's inbox writer).
- Cross-document search (⌘⌥F): `Maugham/Views/ProjectSearchView.swift`, `ProjectWindow.applyCloseFind`. `InboxPane` is ⌘⌥B.
- Not here: the editor (`Maugham/Editor/`), the op-log format (`Maugham/OpLog/`), UI (`Maugham/Views/`), MCP handlers (`Maugham/MCP/Tools/`), model types (`Maugham/Models/`, MaughamCore).
- Tests worth knowing: `MaughamTests/Stores/`, the top-level `*StoreTests.swift`, `PresenterRoutingTests` (classifier round-trip, own autosave not reingested, external `.md` edit discarded, MCP annotations on a live doc synthesize no `claude_archive` ops, unhandled sidecars route nowhere), `ManifestAdoptionTests`, `RemovedElsewhereTests`, `ClosedHeldLinesTests`, `DocumentStorePostureTests`, `StructuralVerbCensusTests`, `TrashStoreTests`, `ProjectSessionRegistryTests`.
