# OpLog — Area guide

This is the **cleanest** area in the codebase per the 2026-05-19 audit. Don't refactor structurally. Read this before touching anything in `Maugham/OpLog/`. Also read the project root `CLAUDE.md` for cross-cutting invariants.

## What this area owns

The manuscript op log: append-only event stream of paragraph-level mutations, paragraph-keyed LWW conflict resolution, project-scope checkpoints with partial restore, cross-Mac log merge, and the inline `<!-- ¶id -->` HTML-comment anchors that join op records to rendered markdown.

**This is the source of truth for manuscripts.** `.md` files on disk are the **clean** derived render — standard Markdown/Fountain with NO `¶id`/`t-` anchors (ADR 0019); the anchors live only in the op log + the in-memory representation. Writers read the clean file; Claude reads via MCP / the op log (ADR 0018), not by parsing the on-disk `.md`. The op log is what survives merges and history.

## Layout

- `OpLogStore.swift` and `CheckpointStore.swift` — wrappers over `JSONLAppendStore<T>` that keep hot-path (op log, every typing burst) and cold-path (checkpoints, ⌘S) concurrency profiles explicit; `JSONLAppendStore` is the shared persistence primitive. **Both partition per device** — a writer appends only to its own `<stem>.<deviceSlug>.jsonl` and readers glob-merge every sibling, the legacy unsuffixed file included (ADR 0012; `PartitionedJSONLFile` in MaughamCore holds the checkpoint/publication template, `OpLogStore` its own). Checkpoints were left out of ADR 0012's scope and were fixed by FM-1; `formal/OpLogSync.tla`'s `_cpshared`/`_cppartitioned` pair is the proof that partitioning is the fix rather than a tidy-up.
- `JSONLAppendStore.swift` — generic append + read + tail for any JSONL-typed store. Extend here if you need new shared persistence semantics. **It is chained when it holds a `ChainPolicy` and plain when it does not** (signed op log P1): the op log and the inbox pass one; publications and checkpoints do not, and keep the append they have always had. Project-scope TASK ops are not an exception — they are `Op`s appended through `OpLogStore` into `__project__.jsonl`, so they are chained like any other op.
- `DeviceActor.swift` (MaughamCore) — the closed enum of who, on this device, wrote an op: `author`, `assistant`, `translator`, `maugham`. The raw value is both the device-id prefix and the key-file suffix, so a fifth actor is a spec amendment and a new file on disk rather than a case added in passing; nothing switches over it with a `default`.
- `LocalIdentities.swift` (MaughamCore) — this device's four writers in one value: `subscript(actor:)` (exhaustive, so a fifth case is a compile error), `all` in `DeviceActor.allCases` order, `fingerprints` (the keys this device holds, which `TrustTable.resolve` reads to answer `.mine` — it ENUMERATES and mints nothing), and `identity(forDeviceId:)`, which matches on the WHOLE id and never a prefix — another Mac's author carries `author-` too. `current` is computed over `DeviceIdentity.identity(for:)`'s per-actor memoization, so nothing is minted until it is asked for; the phone, which is the author alone, must reach `DeviceIdentity.author` directly rather than through here.
- `DeviceIdentity.swift` / `DeviceState.swift` (MaughamCore) — one enclave key **per actor**, each persisted by the app as a plain blob under Application Support (`device-key.blob`/`device-token` for the author, `device-key.<actor>.blob`/`device-token.<actor>` for the other three), and the id/fingerprint/slug derived from it. `DeviceIdentity.author` is the writer's; `DeviceIdentity.identity(for:)` is any of the four. `DeviceIdentity+Testing.swift` holds the test-only software signer, and is the one allow-list entry of `TripwireGrepTests.test_noSoftwarePrivateKeyInProduction`.
- `OpLogChain.swift` (MaughamCore) — the wire format (`prev` as the first key; the seal line) and the pure verifier that classifies every line. No I/O, no clock, no policy about who is trusted: the `trusted` closure and the remembered head are parameters. `Hex` lives here too, shared with the segment container and the fingerprint.
- `OpLogDeviceState.swift` (MaughamCore) — what this device remembers: the chain head it last wrote into each file, the digests of segments it has already verified, and (P3a Task 9) where OTHER devices' streams stood. Also `ChainPolicy`, the value a chained `JSONLAppendStore` carries.
- `ForeignStreamWatch.swift` (MaughamCore) — P3a Task 9's half of that memory: the collector a load carries so a truncated foreign stream is noticed. See *A foreign stream that got shorter* below.
- `RegistryRecord.swift` / `RegistryCanonical.swift` / `RegistryWriter.swift` / `RegistryWriter+Restore.swift` / `RegistryReader.swift` (MaughamCore) — the book's register of who may write in it: the record shapes (count `RegistryDirectory`'s cases — `PermitEvent` joined them in P3a), the bytes a signature is made over, the one writer (and the restore door beside it), and the reader that verifies a record's filename, signature, signer and own author actor before it counts as one, and lists what fails.
- `Permit.swift` / `PermitEvent.swift` / `PermitMark.swift` / `PermitTimeline.swift` / `DocumentClass.swift` / `PermitPartition.swift` / `AnnotationOwnership.swift` / `LocalWritePermit.swift` / `OpLogPermitContext.swift` (MaughamCore) — P3a's permit layer: what a person may write, the event that changes it, the chain positions an event is marked at, the timeline the check reads, which kind of stream a file is, the line-by-line partition, the same-person rule for annotation amendments, and the write-side answer. See *The permit* below.
- `RegistryCache.swift` (MaughamCore) — this device's memory of the last verified registry, and the root it joined. Restores a record something deleted or tampered with, byte-faithfully, and reports it.
- `TrustTable.swift` / `TrustResolution.swift` (MaughamCore) — `TrustVerdict`'s six answers to *who is this seal's key to me*, as a pure function of the registry (`TrustTable`) and the impure half that reads the folder, reconciles the cache and records the join (`TrustResolution`). `keyless(mine:)` is P1's behaviour exactly.
- `RegistryPresence.swift` (MaughamCore) — what a device says about itself at open, and the first Mac's root. `Maugham/Stores/DocumentStore.swift` calls it; the phone's `PhoneDeviceRecord` is its other caller; and `OpLogStore.append`/`TranslationStore.appendBatch` ask its `declareActor` before a key minted after the open signs its first line (F6).
- `ISO8601Fast.swift` (MaughamCore) — the byte-level parser for the two ISO-8601 spellings the app writes (no fraction, or exactly three digits), tried before `ISO8601DateFormatter` on the op log's decode path. Equivalence by construction rather than by replicating Foundation's undocumented truncation: every other shape falls through to the formatter chain untouched. See "Where the time goes" item 4.
- `OpLogProvenance.swift` (MaughamCore) — `FileProvenance` per file and `OpLogProvenance` over a document, the load's own account of what its history is made of. What `HistoryPane`'s unsigned-history sentence reads.
- `Bootstrap.swift` — mints `¶id` anchors on first-open of a document. **Must be called from any production load path *that may write the piece*.** Wired into `Document.load` since `milestone-document-first-class` (2026-05-19); `BootstrapWiringTests` enforces the contract. Any new manuscript-load path must route through `Document.load`. The qualifier is P3a Task 8's — see *The load seam* below.
- `Document+Waiting.swift` — P3a Task 8's half of the load: `DocumentLoadError.waitingForPiece`, the document-class resolution the permit check asks for (a manifest that will not read answers `.piece(docId)`, the WIDENING direction, and never a refusal), and the root's label for the sentence. See *The load seam* below.
- `EchoState.swift` — typed snapshot of "bytes we just wrote to disk." The `init` is `private`; the only construction paths are the three named factories (`initialLoad`, `afterWrite`, `afterIngest`), which is a compile-checked invariant. The echo guard in `Document.handleExternalDiskChange` reads `lastDiskEcho.bytes` to suppress presenter callbacks that arrive in response to our own writes. See [ADR 0010](../../docs/adr/0010-typed-cross-area-seams.md).
- `SweepReason.swift` — typed pending orphan-annotation sweep carrying the *observed* removed-paragraph-id set. Replaces an earlier bool flag. Sweep archives only annotations on `reason.removed` — never "anything missing from sequence." See [ADR 0010](../../docs/adr/0010-typed-cross-area-seams.md). **The sweep also REPORTS (RULING-32):** each successful archive bumps `Document._sweptSinceLastReport`, and `flushBurstNow` spends that running total on one quiet sentence at the burst boundary — the writing pause. Batched across every sweep the burst contained, silent during it, never a prompt.
- `ParagraphID.swift` — paragraph IDs are 4 chars from a restricted alphabet (`0123456789abcdefghjkmnpqrstvwxyz`, no `iloux` to dodge ambiguity). `mint()` produces them; `parseComment()` only accepts strings matching `[alphabet]{4}`. The 4-char rule is enforced **at the .md round-trip boundary** — `recordChange(paragraphId:)` and other in-memory APIs accept any string, so OpLog unit tests legitimately use short IDs like `"a"`/`"b"`. If your test crosses the .md ↔ op log boundary (Bootstrap, RenderFilter against parsed comments), use 4-char alphabet-restricted IDs or `ParagraphID.mint()`.
- `TaskAnchorID.swift` — task anchors are 6 chars from the same restricted alphabet. `mint()` and `parseComment()` mirror `ParagraphID`, but the comment format is `<!--t-XXXXXX-->` (vs the paragraph-anchor `<!-- ¶XXXX -->`). Use `TaskAnchorID.mint()` (not literal strings) in tests that cross the .md boundary. See [ADR 0011](../../docs/adr/0011-tasks-first-class-with-inline-anchors.md) for why anchors are 6 chars (birthday-collision safety to ~30K tasks per doc).
- `RenderFilter.swift` — derives the rendered .md from the op log. **Lives at `Maugham/Editor/RenderFilter.swift`** (it's consumed by the editor's display path; conceptually owned by this area). Three matching tiers for the "which historical paragraph does this orphan line belong to" question.
- `ShingleMatcher.swift` — k-shingle Jaccard matcher used by RenderFilter.
- **External `.md` edits are discarded, not ingested.** There is no reconciler that maps external `.md` edits back into the op log — the hard invariant is that Maugham is the only editing surface. `Document.handleExternalDiskChange` (live edits) and the `Document.load` divergence check (while-closed edits) both **snapshot the external bytes forensically under `.maugham/conflicts/` and re-materialize the op-log truth over them** (ADR 0019). The old `Reconciler.classify` (MaughamCore) was the last vestige of the ingest design; it went unused after ADR 0019's addendum #1 and was deleted in the 2026-07-01 op-log-spine-hardening branch.
- `PendingBuffer.swift` — in-memory buffer between live typing and op-log appends (debounce window). **ADR 0019:** the buffer carries the live `sequence` (durable on disk), so crash recovery is op-log-domain — the recovered burst restores its ordering without consulting the `.md`. On-disk shape is `{ basis?, changes, sequence }`. **Ordering-only edits (F1, 2026-07-01):** a pure delete/reorder records no `changes`, so `flushBurstNow` emits a **sequence-only `typing_burst`** (empty `changes`, explicit `sequence`) when the buffer is empty but ordering **changed since load** — gated on `_orderingChangedSinceLoad` (inits FALSE, flips true only at genuine delete/reorder/insert sites), NOT on `_orderingDirty` (which inits TRUE to anchor the first keyframe). Gating on `_orderingDirty` was the Phase-1 ship-blocker: it made every untouched open/close append a junk `{changes: [], sequence}` op, turning transient loads (MCP reads, task reads, wiki-rename, search-replace, binder nav) into op-log writers whose newest-ULID sequence could revert a peer's not-yet-synced delete. **Clean close leaves NO pending file (Issue 2a, 2026-07-01):** after a successful burst flush `close()` clears the pending file, so the trailing autosave's zero-value `{seq, []}` mirror can't linger as a stale ordering assertion; on a FAILED burst flush the pending file is kept (it is the recovery source). Scope: in-app doc closes only — **app quit never runs `close()`** (the `willTerminate` path flushes autosave synchronously; an async close can't outlive the process), so a quit leaves a basis-stamped `{seq, [], basis}` file behind by design; the basis guard below is what keeps it harmless (smoke-verified 2026-07-02). On load, `Document.load`'s recovery fold fires for an empty-changes pending file only when its `sequence` **differs** from the op-log-derived sequence AND the pending file's **`basis` is current** (Issue 2b) — `basis` is the newest opId the writer had folded when the sequence was stamped; if peer ops have merged in since (basis != the log's newest opId), the pending order is stale and the empty-changes fold is skipped (a non-empty-changes fold still recovers the text but with `sequence: nil`). The Deriver honors an empty-changes `typing_burst`'s sequence; its junk-skip stays `.bootstrap`-kind-only.
- **`Document.close()` husks the instance (zombie-window teardown, 2026-07-02).** At the END of a successful `close()` — strictly AFTER the burst flush, trailing autosave, `pending.clear`, and seal, so disk truth is durable — the O(doc) in-memory state is dropped (`paragraphs`, `sequence`, `displayText`, `_opLogMirror`, annotation/task caches, `lastDiskEcho` bytes). Reason: a closed `Document`'s SwiftUI `@State` box (`StoredLocation<Optional<Document>>` in EditorHost) can stay retained by a dead scene graph SwiftUI never dismantles on window close, and we can't nil another view's `@State` — husking makes the stranded instance weightless (mirror of `EditorCoordinator.detach()`). An `isClosed` flag (set first, `guard`ed at the top of `close()` for double-close idempotency) gates every mutation entry point (`setFullText`/`setParagraph`/`insert`/`delete`/`reorder` → no-op + `documentLog.error`; `performAutosave` → bail, **data-safety-critical** so a stray scheduler tail can't write an empty `materialize()` over the manuscript; `handleExternal*` → bail so a stray presenter callback can't resurrect the husk). `opLog()` still returns disk truth (it falls back to `opStore.load` once the mirror is husked). A `Document` is abandoned by contract after `close()`; no production reader touches it (see the scene-storage spike note's husk section). Regression net: `DocumentDoubleCloseTests`.
- **Clean-`.md` load contract (ADR 0019, hardened 2026-07-01).** Load + crash recovery are op-log-domain: the bootstrap signal is op-log-*emptiness* (`!logExists`), not the `.md`'s anchors; content + order come from `Deriver.deriveWithSequenceFallback` (first-appearance synthesis for legacy sequence-less logs). The `.md` reads left in `Document.load` are (1) the import-bootstrap read for a brand-new / imported plain file with an empty op log (the sanctioned mint read), (2) the echo-guard comparison seed (`EchoState.initialLoad`), and (3) the **divergence-snapshot reference** — see below. `Document.reconcile` is now `reconcile(derived:)`: it takes the derived state (no `parsed:` argument, no `.md`-anchor rescue branches — those were deleted once F2 closed the empty-log hole at Bootstrap) and does **orphan-drop only** (a paragraph present in the map but absent from `sequence` is trimmed). See [ADR 0019](../../docs/adr/0019-clean-md-on-disk.md) and its addendum #2.
- `OpKind.swift` — the closed set of operation types. Adding a new one touches every store and the renderer.
- `RewindCursor.swift` — typed scrub state (`.now` vs `.atOp(opId, at)`) consumed by `Deriver.derive(ops:upTo:)` and `RewindWindow`.
- `RewindRestoreResult.swift` — return value of `Document.restoreToOp`.
- `SynthesisSource.swift` — typed cause of synthesized ops. **Read the enum, not a list here** — this line spelled four cases out and was stale by two (`undo_rewind`, then `reject_convergence`) before anyone noticed, because no test guards a prose list. Adding a case is a schema decision: see the type's own SCHEMA CONTRACT note and bump `ProjectManifest.currentSchemaVersion` with it.
- **The Document's one writer-facing channel.** `Document.notifyWriter(_:)` posts a project-scoped `.maughamDocumentNotice` carrying a finished sentence, which `RewindModifier` renders in the toast it already owns. Three CLASSES of occasion reach it — count the call sites, not this sentence: the **rewind undo's** drift decline (RULING-7, `Document+RewindUndo.swift`, one site because one restore is one act); the **annotation undos'** drift declines (RULING-22, `Document+Annotations.swift`, however many verbs — today the edit, the textless accept, the stet and the triage mark); and the **sweep's** batched summary (RULING-32, `flushBurstNow`). All of them previously reached `documentLog` and nobody else; the declines themselves are correct and unchanged — what the channel adds is the other audience. **The coalescing rule: the toast slot holds ONE sentence, so anything that can happen N times per writer action must arrive as one sentence carrying N.** The sweep spends `_sweptSinceLastReport` at the burst boundary; the annotation undos go through `Document.declineUndo(_:)` — never `notifyWriter` directly — which counts per `UndoDecline` verb and spends one sentence a main-actor hop after the last of the batch's undo closures, because `NSUndoManager.groupsByEvent` folds a bulk action's per-note registrations into a single ⌘Z (#41 A1). A verb's singular and plural sentences live on adjacent lines in `UndoDecline` so they cannot drift apart. Post through `MaughamEvent.postNotice`, never by hand (ADR 0021, tripwire 21).
- **The Document's second channel: "my notes changed"** (M3 P2 Task 9). `Document.announceAnnotationsChanged()` posts a project-scoped `.maughamAnnotationsChanged` carrying the doc id, for the surfaces that CANNOT hold this document — the review board's open-notes column and the queue in project scope, both of which count notes in pieces nobody has opened. `annotationsVersion` already serves everyone who holds it; this is the other audience. **Called from the APPEND sites, never from `invalidateAnnotationsCache`** (whose callers include the burst flush — every receiver walks the whole project, so announcing from there would put that walk on the keystroke path), and from `handleExternalLogChange` only when the merge actually brought FOREIGN annotation ops in: `NSFilePresenter` fires on our own appends, and that echo guard is the reason `DocumentStore`'s presenter arm posts for closed documents only. The census over the append sites is `AnnotationChangeEventTests.test_everyAppendSiteInTheFileAnnounces` — it checks the LIST against the file's own `opStore.append(` calls, so a sixth append site cannot pass by omission.
- **The recovery ladder's read-only rung (spec `2026-08-12-manuscript-recovery-design.md` §4, RULING-54, M9-OL-013/014).** `Document.load(recovery: .readOnlyPartial)` (`Document+Load.swift`) is a second, opt-in-only door reached after the strict load has already refused: it derives from whichever op-log files DID read, names the ones that didn't (`Document.readOnlyRecovery: ReadOnlyRecoveryState?`), mints no anchors, folds no pending file, and writes NOTHING — not an op, not a checkpoint, not a seal, not a quarantine record. `DocumentRecoveryError` (`.nothingUnreadable`, `.noOpLog`) is this door's OWN refusal, distinct from `OpLogStore.ReadError`: the recovery door is only ever the right one when the strict load already said no. The no-writes guarantee is held by a **census**, not a comment — `ReadOnlyRecoveryTests.test_everyOpLogWriterConsultsTheWritabilityChokePoint` scans every `Document*.swift` function that reaches `opStore.append(`/`pending.recordChange(` and fails if it doesn't consult the writability choke point (`rejectMutationIfNotWritable`/`requireWritable`, or their read-only-recovery-specific siblings) first — a mutation entry point added later can't quietly skip it. `RecoveryCause.swift` classifies the refusal that sends a caller to this door: a dataless iCloud stub, an unreadable file, or an unlistable ops directory — see `Maugham/Views/AREA.md` for the pane that offers it. A read-only-recovery `Document` is deliberately never handed to `documentStore.register` — it stays invisible to the registry MCP's tools resolve through (census-pinned in `EditorHost.swift`, `ReadOnlyRecoveryTests.test_editorHostRefusalWiring_census`).
- **The recovery ladder's rung 3 — quarantine-and-continue, and the return merge (spec §5, M9-OL-015/016, register `RULING-54`).** `OpLogQuarantine` and `RecoveredHistory` (both `Packages/MaughamCore/Sources/MaughamCore/`) are the typed verbs the app-layer `EditorHost.quarantineAndContinue`/`retryFullLoad` call. `OpLogQuarantine.quarantine(fileURL:docId:reason:in:)` is tripwire 14's typed mover for this case — a coordinated, byte-identical move (never opens the bytes) into `.maugham/conflicts/quarantined-ops/`, with a `QuarantineRecord` sidecar (`docId`, original filename, when, the read error) written beside it — **written FIRST, before the bytes move**, so a failed record write moves nothing rather than stranding moved bytes with nothing to offer them back, and a failed move deletes the record-of-nothing it wrote; the same-millisecond disambiguation counts an existing sidecar as a collision too, so a returned record's forensic account is never overwritten; a dataless iCloud stub is refused (`QuarantineError.datalessStub`) rather than moved, so this verb never fights rung 2's own download. `OpLogQuarantine.attemptReturn` is the return: a STRICT read of the quarantined bytes (any failure, or a line that fails to decode, leaves the record `.held`) followed by a load of the CURRENT log via `OpLogStore` (a throw there also answers `.stillUnreadable` — merging against a partial live picture would be dishonest) — only then does it check the destination: present means sync already delivered the file back while it was set aside, so the archive stays put and the record flips `.superseded`; absent means a coordinated move-back and `.returned`. **Never overwrites an existing destination file**, and `.returned` is terminal — the auto-return sweep and the pane's Retry can race over one record, and the loser's rewrite declines rather than stamping `.superseded` over the winner's `.returned`. A sidecar rewrite that fails AFTER a successful move-back self-heals at READ time (`records(forDocId:in:)` reconciles a stale `.held` record against a returned file it can see on disk) rather than stranding the writer. `RecoveredHistory.report(currentOps:returnedOps:mergeHappened:)` is the pure accounting behind the writer-facing report, and **`mergeHappened` is the caller's fact rather than the function's guess**: every paragraph in the RETURNED file's own derivation is either in the sequence the writer will actually see or an orphan — that sequence being `union(current, returned)` when the file MOVED and the CURRENT log ALONE on the `.supersededBySync` branch, where nothing moves and the archive is in no readable log. Each branch has its own 200-trial property test (`RecoveredHistoryTests.test_property_everyReturnedParagraphIsAccountedFor`, a strict opId partition; `test_property_noMerge_everyReturnedParagraphIsAccountedForAgainstCurrent`, deliberately overlapping op sets) rather than being trusted to inspection. Computing the no-move branch against the hypothetical merge is the C1 the whole-branch review caught: an archive holding the keyframe that would have WON reported zero orphans and the writer was told nothing was missing. A sweep over several records says one thing through `RecoveredHistoryReport.aggregate`; nothing at a surface hand-builds a report (`HistoryPaneQuarantineNoticeTests` censuses both). `EditorHost.loadDocumentIfNeeded` runs the return opportunistically on every normal document open (guarded off a read-only recovery bind); `HistoryPane`'s Retry runs it explicitly. See `Maugham/Views/AREA.md` for the writer-facing surfaces (the standing notice, the orphan sheet, the set-aside offer on both the pane and the banner).

## Task anchors — first-class inline identity

Task anchors (`<!--t-XXXXXX-->`) join paragraph anchors as the second instance of the "first-class inline identity" pattern. See [ADR 0011](../../docs/adr/0011-tasks-first-class-with-inline-anchors.md) for the architectural decision and the general rule: *use anchors for any manuscript-derived data item whose lifecycle (priority, status, parent) must survive text restructuring.*

Key machinery:
- `Document.rebuildTasksCache` calls `TaskDeriver.derive` and receives `mintedAnchors` as a side-channel. It injects the new anchors into `paragraphs[paragraphId]` so the autosave path writes them back to disk. Re-entrancy is guarded via `_isRebuildingTasks`.
- `Document.archiveTask(id:)` does **two things**: emits a `.taskArchive` op AND mutates the manuscript text (splice rules per spec §2.7). Auto-archive on manual line delete is emitted from `setFullText` Pass 3 of the V2 alignment.
- `Document.setFullText` now accepts optional `preEditCursor` / `postEditCursor` for V2 cursor-bias cross-paragraph alignment. Legacy callers pass nil and get per-paragraph-only alignment (no regression to existing code paths).
- `RenderFilter.stripComments` strips `<!--t-…-->` markers before display; `RenderFilter.restoreTaskAnchors(prior:displayed:)` re-injects them after each edit. The round-trip property `restoreTaskAnchors(prior, stripComments(prior)) == prior` is property-tested in `RenderFilterTaskAnchorTests`.

## Invariants

These hold by construction. If you find code that violates one, treat it as a bug.

- **Op log is append-only.** No mutation, no deletion. Checkpoints capture state; they don't truncate history. Sealing (ADR 0016) is a storage-layout change to a single-writer file; the logical log is untouched — the merged, opId-deduped set is identical before and after a seal.
- **`¶id` anchors are 4-char.** No exceptions. Tests that use 1-char IDs are wrong and silently bypass validation.
- **Task anchors are 6-char.** Same alphabet as paragraph anchors. `<!--t-XXXXXX-->` only — no uppercase, no other prefix.
- **Paragraph-keyed LWW, by opId.** Concurrent writes to the same paragraph resolve by **opId order** (ULIDs give a deterministic total order), not by line position. Cross-Mac merges depend on this. See the merge/derive contract below for the exact rule.
- **`Bootstrap.run` is idempotent.** Calling it twice on the same document is safe (it skips paragraphs that already have anchors).
- **`.md` on disk is derived.** A reader can always rebuild it from `op-log.jsonl` + the renderer. Don't introduce any state that lives *only* in .md and not in the op log.
- **Checkpoints can do partial restore.** Restore-this-document, not restore-everything.
- **A checkpoint never carries a non-document where a document goes.** The window's subject is not a document id — it may name a group, or (since the binder's project row) the project — and ⌘S is handed it raw. `CheckpointCapture.documentSubject(of:in:)` is the **one** answer to *"is this a manuscript document?"* here, and its `nil` is honoured everywhere a document id would otherwise go — no `.checkpoint` breadcrumb op (a stream named after a group parses as a real doc id everywhere downstream — `DocumentStore` seals it, the phone downloads it), no parenthetical on the auto-label, no `activeDoc` on the record, and no `.document(…)` seed in `PartialRestorePicker`. **The label and the record are one decision** — `CheckpointSubjectRecordTests.test_theLabelAndTheRecordCannotDisagree` goes red on a half-fix in either direction. On the read side, a *recorded* `activeDoc` is not trusted either: rows already on disk hold the sentinel and group ids (tripwire 11, no migration), and a document recorded honestly can since have been deleted — so the same membership test runs against the project's census. `Checkpoint.activeDoc` is optional in memory and always present on the wire (`""` for `nil`), because an older build decodes it non-optionally and would quarantine the whole row.

## Merge / derive resolution contract

Two devices with **identical logs must derive identical text**, regardless of load
order. This is plain merge correctness (not concurrency-conflict resolution), and
it is now enforced:

- **`OpLogStore.mergeSortedDedup` is opId-ordered, content-deterministic, and
  load-order-independent.** It sorts on a TOTAL order `(opId, canonicalEncoding)`
  — where `canonicalEncoding` is the op's stable `.sortedKeys`+ISO8601-fractional
  JSON — then first-wins dedupes by opId. Production feeds it from
  `contentsOfDirectory` enumeration, whose order is not guaranteed; the total
  order makes the survivor of a same-opId collision a function of content alone,
  so file-enumeration order can't change the result. `load` + `loadSyncMerged`
  both go through it.
- **`Deriver.derive` sorts its input by the SAME `(opId, canonicalEncoding)`
  order itself** before folding — order-independent by construction, no unenforced
  "caller must sort" precondition. `deriveWithSequenceFallback` does the same.
  (`derive(ops:upTo:)` in `Deriver+Rewind.swift` is intentionally the exception:
  "state as of a cursor" is a timeline prefix, so it respects the caller's
  already-opId-sorted order and must NOT re-sort.)
- **A same-opId collision whose payloads DIVERGE is a corruption signal**, not a
  normal case — ULIDs don't collide, so a divergent same-opId pair means a
  replay / hand-recovery / duplicated op. We pick a deterministic survivor (merge
  stays correct); surfacing it (e.g. `IntegrityQuarantine`) is worth doing later
  but the pure merge fn lacks the `projectURL`/stamp to do so — don't entangle it.
- **`Op.at` is DISPLAY-ONLY.** It is NOT consulted for resolution (resolution is
  by opId). Don't introduce wall-clock comparisons into the merge/derive path.
- **`sequence: nil` on a typing burst means "ordering unchanged-by-construction"
  — not legacy-only — from M1 (ADR 0016) on.** `flushBurstNow` attaches
  `sequence` only when ordering changed since the last sequence-bearing burst,
  at the keyframe floor (`Document.sequenceKeyframeInterval`), or on the first
  burst after load. The deriver carries the last explicit sequence forward, so
  state-at-cursor ordering is exact at every rewind cursor (pinned by
  `SequenceKeyframingTests.test_keyframedLog_derivesIdenticalToFullCapture`).
  A text-only burst can no longer stamp a stale sequence over a concurrent
  remote reorder (pinned by `…test_concurrentReorder_survivesTextOnlyBurstMerge`).
- **First-bootstrap-wins (F3, 2026-07-01).** A doc bootstraps exactly once; the
  Deriver honors only the FIRST `.bootstrap` op (ULID order). For any later one
  (an iCloud partial-sync re-mint — device B re-minting every `¶id` because it saw
  the clean `.md` before `.maugham/ops/` synced) it **skips the SEQUENCE** (the
  re-mint must not win ordering) but **KEEPS the changes** (Minor 4, 2026-07-01,
  in both `derive` and `deriveWithSequenceFallback`, logged). Keeping the text
  means a subsequent burst carrying an explicit sequence of the re-minted ids
  renders full content instead of a near-empty doc. This makes the re-mint inert
  once the real log merges in, instead of the real log reading all original ids as
  removed and mass-archiving every paragraph-anchored annotation. **Residual risk
  (known limitation):** with no post-re-mint edit the kept re-mint texts are orphan
  paragraphs (ids not in the surviving sequence) that `Document.reconcile` drops;
  WITH a post-re-mint edit the doc degrades to content-preserved-under-new-ids (an
  annotation archive) rather than the near-empty render the old drop-changes
  behavior produced. **Clock-skew winner inversion (accepted):** first-vs-later is
  by opId (ULID), whose high bits are wall-clock; a device whose clock lags can
  mint a re-mint bootstrap that sorts BEFORE the original, inverting which wins.
  Single-editor by ethos makes concurrent bootstraps near-zero-risk, so this is
  accepted, not gated. A true fix needs a bootstrap tombstone that syncs ahead of
  `ops/`, and no such channel exists. See ADR 0019 addendum #2.
- **Deferred to the collaboration milestone:** a skew-proof logical clock and
  same-paragraph **conflict surfacing** (two devices genuinely editing the same
  paragraph concurrently). Single-editor by ethos today, so skew-induced LWW loss
  is near-zero risk and not gated here. The audit's 0.2 (skew LWW) + the
  `prior`-snapshot divergence-detection idea are the starting point for that work
  (see `docs/superpowers/notes/2026-06-07-codebase-audit.md`). Tests:
  `CrossMacMergeTests`, `OpLogStorePartitioningTests`, `DeriverTests`,
  `CrossDeviceIntegrationTests` (case 1 = determinism; case 4 = the deferred skew
  scenario, `XCTSkip`-marked).

## Chained and sealed (signed op log P1, [ADR 0032](../../docs/adr/0032-the-signed-op-log.md))

Every line this device writes to an op log or an inbox manifest is chained to
the one before it, and every span it wrote is sealed by a key that never leaves
the enclave. The point is provenance, never a lock: a load classifies each line
and applies what it can account for, and **verification never refuses to open a
book**.

**The wire format.** An op line is the existing `.sortedKeys` JSON object with
`"prev":"<64 hex>"` inserted textually as the FIRST key —
`OpLogChain.chainedLine(elementJSON:prev:)`, and never a field on `Op` or
`InboxEntry`, so an op re-appended elsewhere cannot carry a stale prev and every
existing decoder ignores the key. The line hash is SHA-256 over the line's bytes
**without** the trailing newline. `OpLogChain.genesis` (the hash of no bytes) is
the `prev` of the first line written into an empty file, accepted only where
nothing precedes it; a first line with no `prev` at all is **legacy**, and legacy
is a prefix and never a suffix. A **seal line** is a line of its own kind,
`{"seal":{"at","head","key","pub","sig"}}` with sorted keys, carrying a signature
over the chain head plus the public key that verifies it — self-contained, so P2
adds a trust decision without a format change. **`OpLogChain` is the ONLY place a
seal line is recognised**: `isSealLine` is its private prefix constant's one
door, and `JSONLAppendStore.parse` (the one parser every reader shares) is its
one caller. A second recogniser somewhere else is a second opinion about what a
seal is.

**The new units live in MaughamCore** — see the Layout list above for the whole
set. `DeviceIdentity.swift` is this
device's key and its name; `OpLogChain.swift` is the format and the pure verifier
(plus `Hex`, shared with the segment container and the fingerprint so they cannot
disagree about what a digest looks like); `OpLogDeviceState.swift` is what this
device remembers, and carries `ChainPolicy`, the value a `JSONLAppendStore` holds when it
is chained and holds nil when it is not (publications and **checkpoints** keep
the plain append they have always had; project-scope task ops are NOT an
exception — they are `Op`s appended through `OpLogStore`, so they are chained
like any other op).

**Identity is the key's fingerprint, not the host name.** `DeviceIdentity.load`
mints a `SecureEnclave.P256.Signing.PrivateKey` and persists its
`dataRepresentation` as a plain file under
`~/Library/Application Support/<BuildVariant.current.supportFolderName>/device/`
— no keychain item, no entitlement, and the blob is useless off this machine.
`deviceId` is `<actor>-<16-hex prefix of the fingerprint>` — the author's
carries its prefix too, so a per-device file reads as itself,
`<doc>.author-<16hex>-<8hex>.jsonl` — `slug` is
`DeviceSlug.make(from: deviceId)` (tripwire 24 unchanged — only what `make` is
handed changed), and `MacDeviceID`/`PhoneDeviceID` are deleted. **Unsigned is a
state, not a failure**: with no enclave the device persists 32 random bytes,
takes its fingerprint from those, writes chained lines that nothing seals, and
reports nothing wrong. This Mac's pre-milestone files (hostname slug) and the
phone's (`phone:<uuid>`) are another device's files from here on: read as
unsigned history, never appended to, never sealed.

**The remembered head is the fact only this device has.** The chain catches a
line naming the wrong `prev`; it does not catch one naming the RIGHT one, which
is what an agent that reads the file and hashes its last line writes.
`OpLogDeviceState` keys the head it last wrote on
`<SHA-256 of the project root path>/<filename>` in `op-log-state.json`, beside
the key material. Two orderings are load-bearing. The head is **remembered
before the line is written** — a crash between the two leaves a head no line
hashes to, which is the adopt case, where the other order would leave the
device's own last op quarantined as a stranger's. And the whole append (read the
tail, verify, set aside, rewrite the kept prefix, chain, remember, write) is
**inside ONE coordinated write** — never a nested coordination, which would
deadlock on the write already held.

**`OpLogChain.resolveAbsentHead` is the ONE place that decides what a missing
remembered head means, and all three readers-or-writers call it** — the op log's
`classifyTail`, the chained append, and the verified read. It adopts on the
crash window and only there: the walk never broke, every seal in the file is
ours, and the file's own head is the one this device remembered LAST time
(`OpLogDeviceState.previousHead`, shifted in by `remember`). Anything else — a
file truncated back to a seal with correctly-chained lines written onto it,
which the chain rules alone cannot fault — quarantines every line after the last
seal this device TRUSTS and does not update the state. A device with no key has
no trusted seal to anchor on, so its file is left exactly as the walk found it
rather than quarantined whole; its tail is unsigned history by definition. Keying
on the project PATH means a moved project forgets entirely: nothing adopted,
nothing quarantined, which is the safe direction.

**The state file belongs to one identity.** `op-log-state.json` carries the
fingerprint of the device that wrote it and starts empty (rewriting the file)
under any other — the heads have no device in their key, and Application Support
is what Migration Assistant copies while the enclave blob it copies will not
load. No migration: an older file reads as a mismatch, which is the empty case.

**A device chains only its OWN files, and there are four of them (P1b).**
`OpLogStore.append` asks `LocalIdentities.identity(forDeviceId: op.device)` which
of this device's actors wrote the op — `author`, `assistant`, `translator`,
`maugham` — attaches a `ChainPolicy` carrying THAT actor's key, and takes the
plain append when the answer is nil, logging at `.notice`. The match is on the
whole id and never a prefix: another Mac's author carries `author-` too.
Signing and trusting have stopped having the same answer — a line is signed by
one actor, while every read judges by *all four*, because the assistant's seal
over the assistant's own file is this device's own word and a narrower set would
file the writer's own MCP history as another device's unsigned history. **P2a
retired the set that used to say so.** `ChainPolicy.trustedFingerprints` is gone
and `ChainPolicy.trust` is a `@Sendable (String) -> TrustVerdict` in its place,
because a set can only answer *mine* or *nobody* and admission put four more
answers between them; the four local keys are now one arm of `TrustTable`
(`.mine`), and the closure's default — `{ $0 == identity.fingerprint ? .mine :
.noChain }` — is P1's shape for a caller holding one identity and meaning it.
See *People and admission* below. `DeviceSlug.make` is deterministic, so every op
carrying a SENTINEL rather than a device id lands in a file every Mac derives the
same name for — the single exception to ADR 0012's one-writer premise, which is
precisely what licenses the chained append's truncating rewrite. **P1b Task 3
emptied that exception on this surface**: `Document.load` now names a
`DeviceActor` and derives the id from that actor's key, so `"wiki-rename"`
(`ProjectStore+Structure`), `"find-replace"` (`ProjectStore+Search`) and `"mcp"`
(`TaskReadTools`, `AnnotationToolHelpers`) are gone as device strings, and the
task rebalance signs as `maugham` with `TaskDeriver.rebalanceSentinel` surviving
only as the SESSION marker every reader of a rebalance now matches on. The
unchained arm remains, and it is not dead: another Mac's ops arrive through sync
carrying an id this device holds no key for, and that is exactly the case it
describes. **If a sentinel returns, the list is a grep and never a sentence** —
`TripwireGrepTests.test_noDeviceStringAtAProductionDocumentLoad` is what keeps
one out of a `Document.load`. The rule also keeps `linesSinceSeal` honest: the
counter only ever sees a line this device chained, so the file it counts and the
file its seal closes are the same file.

**An annotation op's actor follows its AUTHOR's source kind, not the Document it
arrived through** (Denver's ruling, 2026-09-08: *"the mcp is on the device but a
different identity — we know that is an AI"*). `Document.addAnnotation` stamps
`deviceFor(author:)` rather than the Document's own `device`: an author whose
`sourceKind` is not `.human` is the ASSISTANT's, read off `Document.loadIdentities`
so the id naming the file and the key signing it come from one answer. A CLOSED
document already had this by construction, since `AnnotationToolHelpers`
transient-loads it as `.assistant`; an OPEN one did not, because the tool writes
through the live `Document` the editor loaded as `.author` — and Denver's smoke of
this slice caught `add_comment` on an open chapter landing in the author's file
under the author's key. Claude's note was signed as the writer's. The same rule
covers the compiler's ingest and the two translation environments, which reach
`addAnnotation` with a `.claude` author. `session` is NOT redirected — a sitting
can have two writers in it — and neither is anything else: human-authored
creation (`addReviewerAnnotation`) and every disposition op
(accept/reject/stet/triage/edit/withdraw) keep this Document's own device,
because those are the writer's acts however the note arrived. Pinned by
`ActorLoadTests.test_anAIAuthoredNoteIsTheAssistantsEvenThroughTheWritersOwnDocument`.

**Sealing is per actor, and the decisions are made by a COUNTER and by the
Document's own actor — never by a scan.** `sealChain(docId:)` seals the files
this store has appended to since their last seal, read off its in-memory
`linesSinceSeal` counters. It is not a nicety: `appendSeal` opens an
`NSFileCoordinator` writing coordination, reads the whole file and runs a full
`OpLogChain.verify` over it BEFORE it can discover there is nothing to sign, so a
walk over four actors at the burst boundary was three extra coordinated
acquisitions, three extra whole-file reads and three extra verifies on the
writer's keystroke path. The interval trigger inside `append` seals the file just
appended to, under that file's own actor.

The open-time sweep has no counters — it is a fresh store — so it uses the other
door, `sealChain(docId:actor:)`, and asks for the **author's** tail alone, which
is P1's shape and the crash-window leftover it exists for; another actor's
leftover is sealed by that actor's own next write, by its own cadence and its own
close.

`sealTailIfNeeded` still takes a SLUG, and its two callers differ on purpose.
`Document.close()` rotates the tail of the actor that Document was LOADED as and
no other — rotation DELETES the tail it seals, and every MCP annotation or task
call is a Document loaded as the assistant, so a fan-out there would delete the
file the writer's own open Document is appending to. `DocumentStore`'s open-time
sweep is the one place every local actor rotates, so a long MCP session's
assistant tail still becomes a `.mzseg` at the same 512 KB threshold the writer's
does; it is safe there because it runs before the first `Document.load`, so no
live appender exists to race the read→delete gap. The scope rule survives both:
never the legacy unsuffixed file, never another device's — a document loaded
under a device string naming no local actor rotates nothing at all. `__project__`
is no longer outside it: since 2026-09-09 the open sweep names the project
stream by hand, last, and rotates it at the same threshold (it is not in
`docIds(inOpsDirectoryFilenames:)`, which answers MANUSCRIPT ids), and that
sweep is its only boundary because it has no close.
The sidecar's signer follows the slug: the segment signature carries the key
of the actor whose slug the segment is named for, and a slug naming no local
actor gets no sidecar at all. Pinned by
`SegmentSealTriggerTests.test_close_rotatesOnlyTheActorThisDocumentWasLoadedAs`,
`test_anAssistantLoadedDocumentsCloseNeverRotatesTheAuthorsTail`,
`test_openMaintenanceRotatesEveryLocalActorsOversizedTail` and
`test_openMaintenanceReadsOnlyTheAuthorsFile`, plus `ActorSigningTests`'
verify-counting pins in MaughamCore.

**A torn LAST line is `tornTail`, not a break.** Bytes that do not close as a
JSON object, with nothing after them, are a write that stopped mid-line: excluded
from the walk, never quarantined, the head unmoved, and handed to the element
decoder so they appear in `diagnostics.skipped` as a torn line always has. An
incomplete line with something after it still breaks the chain — the write
finished, so the damage is not a tear.

**Quarantine is a `.lines` record that never returns.** A quarantined line is
never applied and never deleted: `OpLogQuarantine.setAsideLines` copies the bytes
to `.maugham/conflicts/quarantined-ops/<file>.<hash>.<stamp>.lines` with a
`kind: .lines` record beside it, **content-deduped** so the same foreign line
found on ten consecutive opens is one record rather than ten. Nothing moves — the
file itself is fine and the caller has already rewritten it without those lines.
`attemptReturn` answers `.setAsideByProvenance` and touches nothing, so this is
the ONE new refusal in the tree; the sweep that offers `.file` records back
filters `.lines` out. The reason is DERIVED from the break
(`JSONLAppendStore.quarantineReason`), so no caller can file the same event under
different words: *written by something that is not Maugham* for a line after the
remembered head or an unchained line after the chain began, *the history's chain
is broken* for everything else.

**Every reader classifies before it applies** (signed op log P1). `OpLogStore.classify`
is the one rule, and both readers call it: `loadFileDiagnosed` (coordinated,
behind `loadDiagnosed`/`loadDiagnosedPartial`) and `loadSyncMerged`. Quarantined
lines are omitted from the ops by both; only the coordinated reader writes
anything — the `OpLogQuarantine.setAsideLines` record, an adopted head, a
remembered segment digest, each best-effort so a forensic write can never cost
the writer their manuscript. `loadDiagnosed` answers a third member,
`OpLogProvenance`, counting every line of every file as legacy / verified /
unsealed / unsigned-history / quarantined. **A record is the load path's alone**:
a caller taking the nil `identity`/`state` defaults (`ProjectIntegrity.check`)
classifies with no key and no remembered head, so its reading of a file is
strictly weaker than the load's — it cannot see an `afterRememberedHead` break at
all — and it therefore writes nothing. A check reports; the load records. **The
two are not interchangeable and must not be read as one another**: because the
check classifies keylessly, it can hand back opIds the load will not apply, so
`ProjectIntegrity`'s dangling-pointer check can pass over ops a document never
sees. Never treat a clean check as a statement about what the load will do.
**Seal lines never reach an element
decoder**: the filter is in `JSONLAppendStore.parse`, the one parser every
reader shares, so a seal is never reported as a torn line.

**What the Mac does with all of it** (signed op log P1, Task 6). **Sealing is
one verb, `OpLogStore.sealChain(docId:)`, and its cadence is a set of call
sites — count them, don't read a number here.** On the Mac they are: every
`OpLogStore.chainSealInterval` (100) appends, from `OpLogStore.append` itself;
after every burst that actually appended (`Document.flushBurstNow` — a burst IS
"typing followed by idle"); at `Document.close()`; and over every doc this Mac
has written at project open (`DocumentStore`, through the counter-free
`sealChain(docId:actor:)` and the author alone). **`__project__` reaches the first
of those through `ProjectStore._projectOpLogStore`, the ONE store the project
task stream appends through for the store's lifetime** — a fresh store per
append reset the interval counter every time, so the project stream was the one
op log nothing ever sealed. The two verbs remain different acts:
`sealChain` SIGNS a run of lines in place and never refused the project stream,
while `sealTailIfNeeded` REWRITES the tail into an immutable segment and did
refuse it until 2026-09-09. That refusal is gone: the project stream rotates at
the same 512 KB as every other tail, at the open sweep, so it has a ceiling like
every other tail. The residue worth knowing: open is its ONLY boundary, so a
session appending past 512 KB of task ops — some 2,500 of them — carries the
excess until the next open. The inbox and the phone do not
use this verb at all — they call `JSONLAppendStore.appendSeal()` directly after
**every** append (`InboxStore.appendThrowing`, `InboxCaptureWriter`,
`AnnotationWriter`), because a capture or a lifecycle decision is rare and one
signature each costs nothing. Every one of them is best-effort and
LOGGED rather than swallowed — `sealChain` already answers false without
throwing on a device with no key and on a file with nothing new, so a throw is
a real failure and never a reason to lose the burst that has already landed.
**At close and at open the chain seal runs BEFORE `sealTailIfNeeded`**, so a
rotated `.mzseg` ends on a seal line and its whole span is verified inside the
container; the other order rotates an unsealed span away where nothing can ever
sign it. That ordering is load-bearing only for ops that arrive OUTSIDE the
burst path — an annotation, a task op, a checkpoint breadcrumb — because a burst
seals itself; `SegmentSealTriggerTests.test_close_sealsTheChainBeforeRotatingTheTail`
therefore ends its tail on a breadcrumb, and a version of it that ended on a
burst passed under BOTH orders. **`Document.provenance`** is the load's own
account of what the history is made of, stamped by both doors (the strict load
and the read-only recovery load) and posted by neither: a notice from a
windowless load is dropped by the liveness guard, exactly the pending stamp's
reasoning. `EditorHost` reads the stamp and folds it into the ONE
`.maughamQuarantineRecordsChanged` post it already makes
(`EditorHost.quarantineRecordsChanged(setAsideAtLoad:outcomes:)`), whose sweep
now takes `.file` records only — a `.lines` record is not a file waiting to come
back. `HistoryPane` says the two things a writer can act on knowing and no
others: `unsignedHistoryNotice` (legacy history, foreign-signed history, or ONE
sentence carrying both — the coalescing rule) and `setAsideChangesNotice`,
neither with a Retry, because neither is something the writer can undo. **"Another
device" in that sentence never means this Mac's assistant, translator or
Maugham** (P1b): trust on the read side is all four local fingerprints, so
Claude's annotation file and the pipeline's translation file are this device's
own signed word, and a narrower trusted set would have the writer told their own
MCP history came from somewhere else. **The INBOX has
its own half of that sentence** — `InboxPane.setAsideNotice(changeCount:)`, drawn
beside the unreadable-manifests notice — because the inbox's `.lines` records are
filed under the manifest stream's own id (`InboxManifest.chainDocId`) and
`HistoryPane` only ever asks for a DOCUMENT's, so they were written and shown to
nobody. **Both panes count through `OpLogQuarantine.setAsideChanges`, one
implementation, and what it counts is neither records nor lines but CHANGES**
(the P2 smoke's finds 6 and 7). Op lines only — a seal is the signature that
closes a span, held back with the lines it settles and counted nowhere, which is
the rule `OpLogChain.pendingByDevice` already applies to the PENDING half, so the
two halves cannot put different numbers in front of one noun. Deduplicated by the
line's own identity (`op_id`, else an inbox row's `id`, else a digest of the
bytes), because the same op reaches the archive twice whenever a span is set
aside and then split differently on a later load — the smoke's own `[op1, seal1]`
followed by `[op1]` and `[seal1, op2, seal2]`: three records, six lines, TWO
changes. And minus what the stream is already carrying: both call sites pass an
`applied` set — History the document's own op ids, the Inbox
`InboxStore.appliedManifestIDs` — so a re-admission stops the sentence claiming
history the writer now has, while the disclosure goes on listing every record,
because the evidence is permanent and the sentence is not. **History's sentence
says WHICH reason** (the final wave's I3, `HistoryPane.setAsideChangesByReason`
asking that one enumeration ONCE over every record and grouping by reason — once
per reason would not see a change held under two of them — and
`setAsideChangesNotice(byReason:)` giving each group a clause): P1 had one cause
and said it unconditionally, and four of P2b's six describe lines Maugham wrote
on the writer's other machine, so a revoked Mac's history was reported to them
as *written by something that is not Maugham*. The words are
`JSONLAppendStore.quarantineReason`'s, which the records already carry, and a
change found in two records takes the reason of the first record that held it.
`InboxPane.setAsideNotice(changeCount:)` is the same shape and has NOT been given
the same treatment — its sentence still says *by something that is not Maugham*
over every reason, which is the same defect one stream over. **And the sentence is ACKNOWLEDGED, per device per
record** (P2a, D2, `SetAsideAcknowledgement.swift`): what P1 shipped summed every
record forever, so one foreign line found once was a standing accusation the
writer could only silence by deleting the forensics it was about. An
**Acknowledge** button beside each notice records the ARCHIVE FILENAMES in this
device's `UIState.acknowledgedSetAsideRecords` (through
`DocumentStore.acknowledgeSetAsideRecords`, which unions), the sentence counts
only what `SetAsideAcknowledgement.unacknowledged` returns, and a record filed
tomorrow brings it back counting only itself. **Both panes call that one
predicate and neither restates the filter** — a census in
`SetAsideAcknowledgementTests` holds the field to four files: `UIState`, the
store's verb, and the two panes that hand it to the predicate. **Nothing under
`.maugham/conflicts/` is touched**: the History pane's `Set-aside records`
disclosure (`SetAsideRecordsDisclosure`, its own view at the foot of
`HistoryPane.swift`) lists every record whether acknowledged or not, because what
the writer put down is the sentence, not the evidence. **That list declares an
ideal width of its own and truncates each row in the middle** — an archive name
is 99 unbreakable characters, three of them ask for 559 pt through
`fittingSize`, and on the macOS 27 SDK a pane's demand is what a fixed column
becomes rather than a hint (`DetailColumnWidthTests`' fixed-width cases all read
528 against the 300/320/360 they pin). Denver's whole window went blank on that
chevron; the blanking would not reproduce in a mounted three-column split, so the
demand is measured and the causal step is not — see that view's own doc comment.
**And the Inbox's recount follows every refresh** (`InboxStore.refreshes`, the id
its `.task(id:)` keys on): a promote, a trash, a sync or an admission moves both
the records and `appliedManifestIDs`, and counting once beside the pane's first
`refresh()` left the sentence frozen at its first reading. Per DEVICE because UI
state is this machine's — acknowledging here says nothing about the phone. **`unsealed`
lines are never mentioned**: the live tail is always partly unsealed, so naming
it would be a permanent notice about nothing. **The production load door names an ACTOR:**
`Document.load(url:actor:session:presenter:)` takes a `DeviceActor` and derives
the device string from that actor's key, so the writer's editor loads
`.author`, MCP loads `.assistant` (`AnnotationToolHelpers.withAnnotationDocument`,
`TaskReadTools`), and `write_translation` loads `.translator`. The
`device: String` overloads survive as **`internal`, test-only** — hundreds of
test call sites predate the actors — and
`TripwireGrepTests.test_noDeviceStringAtAProductionDocumentLoad` (with a planted
offender) is what keeps a literal out of production, because a hand-built string
names no key and appends unchained. The device identities and chain
memory a load hands its `OpLogStore` come from `Document.makeLoadOpStore`, the
one construction, with `Document.localIdentitiesForTesting` (all FOUR writers,
since a load's `actor:` argument derives its device string from the same value)
and `Document.deviceStateForTesting` as its test seam — a machine with no Secure
Enclave (CI's runner) is genuinely unsigned, so a seal assertion has to inject a
signer or it is asserting the runner rather than the code. **`Bootstrap.run`
takes that store rather than building one** (P1b Task 3): the bootstrap op is a
document's first line, and a store of `Bootstrap`'s own would sign it with
`LocalIdentities.current` while the load chained everything after it with
something else, leaving the opening op unchained and legacy forever.

## People and admission (P2, [ADR 0032](../../docs/adr/0032-the-signed-op-log.md) §8)

> **P2 ships whole: the first tag that carries P2a carries P2b.** Until the
> admission sheet exists, a
> Mac that has rooted itself holds every phone op as pending with no way to
> admit it. `ensureRootIfEmpty` writes this Mac a root at the first open of
> every existing project, so B3's escape hatch closes for all of them, and the
> phone's P1b-signed spans classify `.stranger` → `.pending` → held: every phone
> annotation out of the Annotations pane, every phone capture out of the Inbox,
> History's *waiting for admission* line beside an Admit… button drawn disabled.
> Nothing is lost and admission re-reads, but the writer's own phone history is
> invisible for the length of such a build. **A smoke of a P2a-only dev build on
> a real project WILL show this.** It would also have looked arbitrary, because
> a stranger's ROTATED `.mzseg` segment fell through `classifySegment` to the
> keyless walk and applied as unsigned history while the live tail was held —
> **fixed in P2b** (see the P2b subsection below), so rotated history is now
> held exactly as a tail is.

P1 could tell this device's own hand from everything else. P2a puts the rest of
the range in: a book has a **registry** of who may write in it, and a seal made
by a key that registry admits is this book's word even though it is not this
device's. The state that did not exist before is **pending** — a stranger's
sealed span is HELD, neither applied nor quarantined, until somebody admits the
device that wrote it. Nothing here refuses to open a manuscript; the writer's
own words are never what is held.

**The records.** `RegistryRecord.swift` (MaughamCore) holds `DeviceRecord`,
`PersonRecord` and `ClaimRecord`, plus `DeviceKind` and `RegistryDirectory`.
Under labels-only a **person IS a device's author key**, which is why a device
record must name its own author actor (`actors["author"] == device`) and a
reader that finds otherwise lists it malformed: admitting a device admits every
actor its record lists, and an author entry naming another key would have a
reader trust an actor the signature never claimed. `RegistryCanonical` is the
bytes a signature is made over and their digest — `.sortedKeys` plus the store's
own date encoding, so field order cannot change what was signed.

**One writer, one reader.** `RegistryWriter.write(_:signedBy:in:presenter:)` is
the ONE production door, and the one place `.maugham/devices`,
`.maugham/people` and `.maugham/people/claims` are spelled. It refuses an
identity that is not the one the record names
(`RegistryWriteError.wrongSigner`) and refuses a device with no key
(`DeviceIdentityError.unsigned`), both before anything is created, so a refusing
path leaves no directory behind; `writeUnchecked` is `internal` and exists for
the tests that must plant a record the reader has to refuse.
`RegistryWriter+Restore.swift` is the second door and writes already-signed
bytes without signing anything — the cache's restore, deliberately dumb, so the
reader keeps the only opinion about what a record is. `RegistryReader.load`
verifies, in order: the filename is the fingerprint the record carries, a
signature is present, it holds together over the canonical bytes
(`OpLogChain.credentialsVerify`, the seal's own verifier), the signer is the key
the record's shape expects, and — for a device record — its `actors["author"]`
is its own `device`. Read `MalformedRecord.Reason`, not this sentence. People are read in **two passes**,
because a non-root person record is only a record if a ROOT signed it and which
fingerprints are roots is not known until every self-signed record has verified
— otherwise anyone who can write the folder admits themselves with a second key.
**Malformed is listed, never read**: one bad file costs its own record and
nothing else. A record that is PRESENT and unreadable is different and throws —
`OpLogStore.ReadError.unreadableFile(kind: .registry)`, the third `FileKind`
beside `.history` and `.translation`, with a refusal sentence of its own,
because a permissions error or a half-downloaded iCloud file would otherwise
un-admit a device by accident (RULING-54).

**The cache** (`RegistryCache`) is this device's own memory of the last verified
registry, in `registry-cache.json` beside `op-log-state.json`, keyed by the same
project-root hash (`OpLogDeviceState.scopeHash(ofRoot:)`) and pruned by the same
two-clause rule (`OpLogDeviceState.rootIsGone(atPath:)` — a deleted project
loses its memory, a project on an unmounted volume keeps it). It stores each
record's own FILE bytes, carried out of the read as `Registry.sourceBytes`, so a
restore is byte-faithful and this build cannot re-encode a record into something
its own signature no longer covers. `reconcile(folder:cached:in:)` restores only
refs the folder has no FILE for — a present record, verified or not, is left
exactly where it is — and reports what it put back. Where the folder has a file,
**the folder wins under the same key and only under the same key**: a device
re-signing its own record to add an actor key is not a removal, but a record
signed by a key other than the one that signed the remembered copy is a record
changing HANDS, and it is listed `malformed(.signerChanged(expected:found:))`
with the remembered record standing (the same-authority rule, P2b Task 1). A
registry deleted WHOLESALE is restored record by record, which is the case spec
§2.4 says must be loud rather than a silent reversion to P1 trust.

**The table** (`TrustTable`, `TrustVerdict`) is who a seal's key is to this
device — count `TrustVerdict`'s own cases, not this sentence: `.mine`,
`.admitted(person:)`, `.stranger(device:)`,
`.revoked(person:highestOpIdSeen:)`, `.retired(device:retiredAt:)`,
`.otherRoot(root:)`, `.noChain`. It is a
pure function of a `Registry`, this device's `LocalIdentities` and the root it
has joined — no I/O, no clock — and `verdict(forSealKey:)` is O(1) because
`resolve` precomputes its lookups. `.mine` is answered before the chain, so a
device with no registry at all still knows its own hand. The impure half is
`TrustResolution`: it reads the folder, reconciles it against the cache,
resolves the table and records the join. **`TrustResolution.keyless(mine:)` is
P1's behaviour exactly** — this device's keys answer `.mine`, every other key
answers `.noChain` — which is why the whole P1 suite passes unchanged.

**The root order, and the rule that a device never switches chains.** `myRoot`
resolves in the arms below, and the order is load-bearing — they are numbered
because `TrustTable`'s own comments cite them by number (*arm 3 of `myRoot`*),
so the numbering is a name and not a count:

1. the root this device already **joined** (`RegistryCache.joinedRoot`,
   write-once — B1);
2. this device's **own self-signed root record**, if the registry holds one;
3. a **foreign root whose chain names one of my keys** —
   `TrustTable.admittingRoots.first`, sorted, so the answer is deterministic;
4. `nil`, which is `.noChain`.

Arm 2 outranks arm 3 because a self-signed root record for my key is the one
statement in the registry that nobody but this device could have written, while
an admission naming me is merely somebody's assertion. **A device that has its
own root record NEVER joins another** (`TrustTable.ownRootRecord` is what is
asked, because B1's rule is about the RECORD and not about which arm of the
order happened to win): a foreign root that names it is recorded as a **claimant**
(`RegistryCache.recordClaimant`) and its spans read `.otherRoot`. Every foreign
root beyond the joined one is a claimant too. Without this, any Mac that can
write the folder writes itself a root plus an admission of you and takes over a
book you created.

**A span answers to its file's verdict, sealed or not** (P3a Task 11, audit
PR #65's F1 + F2; a defect in released v0.39.0/v0.40.0 that P3a's first ten
tasks did not close). Trust used to be consulted at `case .seal` and nowhere
else, so a chained op line with a good `prev` was `.unsealed`, not held back,
and applied: everything a SIGNED foreign device had written since its last seal
— up to `chainSealInterval − 1` ops, or its whole file before its first one —
entered the book whatever the register said about it. A stranger's text was in
the manuscript unadmitted, a revoked device's post-revocation tail leaked, and
`PermitPartition.attributableKeys` skipped exactly those spans, so the permit
never judged them either. Every P2 fixture sealed before it asserted, which is
why it shipped green.

The rule is in `OpLogChain.verify`, at end-of-walk, because that is where the
trust closure is and where every seal has been seen — and `OpLogChain` stays
ignorant of device records, because **the file's key** comes to it in three
arms, the second of which is a closure the caller supplies: the key of the LAST
seal in the file that parsed and chain-verified **whatever its verdict** (a file
is one device's writing, ADR 0012, so a stranger's seal names the file exactly
as this device's own does); else — **or where that seal's key is one the
register cannot attribute to anybody** — whatever the caller can name for the
filename's slug (`PermitMark.keyNaming(_:in:)` → `TrustTable.key(forDeviceSlug:)`,
the ONE slug → key join, which `label(forDeviceSlug:)` is now written over);
else **unchanged** — and that third arm IS the unsigned door, decision B3 left
open on purpose for the unsigned device and pre-signing legacy history, Denver's
to rule when P3b is planned. **Arm 1 falls through rather than winning
outright** (fix round 1) because one seal under a throwaway key would otherwise
buy the whole unsealed remainder a gentler answer — a revoked device's tail
merely HELD, and offered to the writer for admission under a code that is not
that device's, while the file's own name still carries its slug.
*Unattributable* is `TrustVerdict.isUnattributable`: `.noChain`, which only a
reader with no root of its own ever sees, or `.stranger` **with no device**,
which is what a rooted book — every book since P2a — actually answers for a key
no record mentions. The fall-through cannot WIDEN, and structurally rather than
by a guard: an unattributable verdict settles to nil or `.pending` and arm 2 is
taken only when it answers a state at all, so a filename naming an admitted
device answers nil and arm 1's hold stands (`OpLogChainTests
.test_anUnattributableVerdictCanOnlyHoldOrLeaveASpanAlone` is what goes red if
an arm changes). The span an unattributable seal COVERS is untouched — `case
.seal` settles it and this rule never looks at it. What the span then becomes is
`TrustVerdict.settlingAnUnsealedSpan`, `settling`'s sibling; read its arms, not
this sentence. Two of them cannot be `settling`'s: `.mine`/`.admitted` leave the
span `.unsealed` rather than calling it `.verified` (nothing signed these bytes,
and **this device's own unsealed tail is never held or refused** — typing
appends unsealed lines all day, and the chained WRITE's own `.mine`-only closure
would otherwise refuse to seal the file it is appending to), and `.retired`
keeps rather than refuses, because its answer turns on a seal's moment and there
is no seal: refusing would set aside the last tail of every device that ever
retired, under a sentence that is false about it. `PermitPartition`'s
`attributableKeys` gained the same filename fallback for a file holding no seal
at all, which is *never seal once* — the bypass its trailing-span rule already
closes one word along. And `OpLogChain.readmitting` now puts a re-admitted line
back into **the state it would have had if nothing had refused it** —
`.verified` where a seal covers it, `.unsealed` where none ever did
(`Line.coveredByASeal`, a fact the walk has in hand and nothing downstream can
re-derive, since *covered by a seal* is not *has a seal after it*) — because
calling unsigned bytes verified on the way back in is the same misstatement the
`.mine` arm exists to avoid on the way out.

**The third line state.** `Line.State.pending(device: String)` joined `legacy`,
`verified`, `unsealed`, `unsignedHistory`, `quarantined` and `tornTail` — read
the enum, not this sentence — and the mapping
from verdict to state lives in exactly one switch,
`TrustVerdict.settling(sealKey:sealedAt:)`: `.mine`/`.admitted` verify and apply;
`.stranger` is **pending** — not applied, not quarantined, and **no `.lines`
record**, because nothing is wrong with it and it may be admitted five minutes
from now; `.revoked` and `.otherRoot` quarantine, in their own words (*written
after this device's access was withdrawn* / *written under another claimant's
copy of this book*), derived in the walk as every quarantine reason is;
`.retired` quarantines **by date** — that is what the `sealedAt` argument is
for, and it is the seal's own moment: a span sealed before the device said it
had stopped stays verified, and one sealed at or after it is set aside as
*written after this device was retired* (spec §5, P2b Task 7). `.mine`
outranks retirement, so a Mac that retired itself still reads its own history as
its own word — a table that answered otherwise would have the chained write's
truncating rewrite set aside the file this device wrote — and revocation
outranks it too, because that is the root refusing rather than the machine
stopping politely.
`.noChain` is unsigned history, applied, which **is** P1 (decision B3).

**A revocation keeps what this Mac had already applied** (find 5, ruled
2026-09-18; it used to refuse the whole span and merely file it under two
different sentences). The walk still sees seals and chains, never opIds, so it
refuses the span under one cause; `RevocationSplit.partition` then cuts that set
against `TrustTable.highestOpIdSeen(forPerson:)`, the mark the ROOT recorded
when it revoked somebody, and `OpLogChain.readmitting` re-settles the kept lines
`.verified`. **The cut happens BEFORE the parse** — in both `classifyTail` and
`classifySegment`'s fallback walk, through one function
(`OpLogStore.readmittingWhatWasAlreadyApplied`), because a revocation must cost
a rotated segment exactly what it costs a live tail. An op at or below the mark
stays in the book; one above it is set aside as *written after this device's
access was withdrawn*, and that is now the only sentence a revocation has.

**Nothing is newly trusted, and that is the argument.** The mark is this Mac's
own record of how far it had got with that device, not the device's word about
itself, so a line at or below it is one this Mac had already applied while they
were admitted. Re-admitting it is the revocation declining to reach backwards
into work the writer has read and redrafted, not a revoked key being believed.
**A seal travels with the op immediately before it in file order** (it carries
no opId, and the span it closes ends at the line above it); a line with no op
before it stays refused, which is the strict side. `Verification.head` does not
move: it is what the next chained append builds on, and a re-admitted line is
not a suffix.

**The writer chooses how much comes back** (`RevocationScope`). The default is
above; *Revoke and Set Aside Everything* records no mark, which is how a reader
has always been told that nothing of theirs was ever already here, so the whole
history leaves the book until they are re-admitted. `DocumentStore.revoke`
computes the mark over EVERY op-log file in the project (plus the open documents
from memory) — over the open documents alone it was nil for a writer with no
chapter open, and nil means keep nothing. History tells the two apart from the
record itself (`TrustEvent.Kind.revokedEntirely`). The *may be late sync, or may
be backdated* half is gone with its cause: those lines are applied, and the
distinction returns in P3 with a real Apply and a durable per-span exception
behind it. A
refused span does not break the chain — a verdict is about whose word a span is,
not about whether the bytes follow from each other — so a later span from an
admitted key still applies and held-back lines are no longer necessarily a
suffix. `FileProvenance.pending` / `.pendingByDevice` count what is held, keyed
by **device** rather than by key, because two actor keys of one Mac are one
device waiting; `OpLogProvenance` sums them across files.

**A revocation takes the words out of a chapter that is OPEN** (Denver's
re-smoke, 2026-09-19). Every verb before it only ever ADDED — a peer's op
syncing in, an admission letting a held span through — so
`Document.handleExternalLogChange`'s echo guard asked *is there anything new*
and returned when there was not, which is exactly what a revocation produces:
the registry narrows, the next classification refuses lines it used to keep, and
`loadDiagnosed` comes back SHORTER. The record was written and the `.lines`
record filed in the same second while the revoked device's paragraph stayed in
the draft until the project was closed and reopened. The guard now also asks
whether ops have LEFT; nothing else changed, because everything past it was
already a rebuild from the loaded ops (`deriveWithSequenceFallback` +
`reconcile`, then `_opLogMirror = ops`) rather than a merge into what is held.
Retirement and a registry Restore narrow trust the same way and arrive down the
same path. The writer's un-bursted words are safe because the flush at the top
of that function turns them into real ops BEFORE the reload; a chapter the
revoked device never wrote in takes the early return and is not disturbed at
all. **Only the harsh scope ever removes anything from an open chapter**: under
the gentle one the mark is the highest opId this Mac applies from that device,
so everything on screen is at or below it by construction.

**The write path did not learn pending.** `JSONLAppendStore.chainedAppend` still
judges by `.mine` alone: ADR 0012 gives each file one writer, and the truncating
rewrite is licensed by exactly that, so a stranger's line in MY file is a
quarantine and never a hold.

**Every device declares itself** (`RegistryPresence`). `ensureDeviceRecord`
names `.author` — a write path, and naming an actor is the writer's act — and
then only ENUMERATES (`LocalIdentities.existingActors`), so declaring oneself
mints no other key; it writes when there is no record, or when the record on
disk disagrees about the name, the kind or the actor set, carrying `madeAt`
over, and leaves a retired record alone. `ensureRootIfEmpty` writes the first
root and refuses on three conditions in their own right: the registry already
names somebody, this device has not written its own record yet (the root's label
comes from it), or this device is not a `.mac`. **A malformed-only registry is
not an empty book** — no root is written beside a tampered one. On the Mac both
run in `DocumentStore.open`, after the presenter is wired and before the seal
sweep; on the phone `PhoneDeviceRecord.ensure` runs at the first write inside
the writers' existing main-actor hop, because the phone has no open. An unsigned
device writes nothing and says so once per process.

**A key named AFTER the open reaches the record before its first line does**
(P3b smoke find F6). `LocalIdentities` is lazy, so the assistant's key is minted
by the first MCP write of a session, the translator's by the pipeline's first
run, Maugham's by the first rebalance — all after `DocumentStore.open` declared
this device. Until the fix those lines were signed by a key the record did not
name, and every other Mac held them as a stranger's until this one relaunched.
`RegistryPresence.declareActor` re-signs the record by editing the FILE's
object (`RegistryWriter.resign`, rename's door), changing `actors` alone — so a
later build's fields and any actor this build has no word for survive, and the
name is still decided only at open. The two write paths that sign as a
non-author actor — `OpLogStore.append` and `TranslationStore.appendBatch` —
reach it through `declareActorOnce` BEFORE the line is written, on their own
(main) actor and only when `declarationIsDue` — a check that reads no record —
says so (a detached hop was measured to reorder what `append`'s callers observe
and was withdrawn). A store ASKS once per actor until it learns the registry
changed — `invalidateTrust()` (which `DocumentStore` sends every open document
on a registry arrival and after its own registry writes) or its own
`trust()`/`trustOnThisActor()` re-resolving over a new signature both make it
forget, so an open document's store asks again (whole-branch review M2; before
that the store memoised the actor before the due check and never re-asked for
its life). Across stores there is one ATTEMPT per registry state (the memo holds
the registry's `TrustResolution.signature` after the last attempt, per project
and actor key, for the process's life), so a registry that REFUSES costs one
verified read and one write attempt, not one per line. The author's typing path
is untouched: an author line asks nothing, one enum compare. It never declares a device the book has no record of, never names the
author (the author is the device, declared at open, and the keystroke path pays
nothing), never mints a key it only enumerated, leaves a retired record alone,
and never costs a line: a refusal is logged and the line goes on, held elsewhere
until the registry changes or the next open catches the record up. The phone
signs as the author only, so it never reaches the re-signing.

**And a record that arrives AFTER its line re-judges it** (P3b review,
Important #1). *Before the line* is ordering on the writing Mac's disk only —
iCloud may still deliver the line first. The receiving Mac's presenter routes
every registry folder as `MaughamSidecarPath.registry` (folders asked of
`RegistryWriter.directoryURL`, tripwire 40), and `DocumentStore.registryChanged`
— debounced, off the typing path — takes `admit`'s third act: forget every
table, re-read every open document, post the admission-settled event. It does
NOT fire for this Mac's own writes: `invalidateTrust` (which every registry
verb here calls) records the register as settled, and a change touching nothing
but this device's own DEVICE record — F6's mid-session re-sign — is an echo
(`DocumentStore.registryChangeIsAnEcho`; this Mac's keys read as its own
whatever that record says). Pinned by `RegistryArrivalTests`.

**Stated limit.** The open's own `ensureDeviceRecord` still writes a fresh `DeviceRecord`
rather than re-signing the file's object, so a later build's fields on this
device's record are dropped at open (tripwire 42's rule honoured by the
mid-session door only).

**What History says.** `HistoryPane.pendingNotice` is the one line in that pane
with a control — *14 notes from iPhone are waiting for admission* — and its
**Admit…** button is LIVE as of P2b (it posts a forced
`.maughamAdmissionRequested` rather than presenting anything, because a pane is
a column and the sheet is the window's). `joinedChainNotice` is the quiet line
under it: *This Mac is on Denver's MacBook's chain* — a standing FACT, re-worded
from P2a's *joined*, which is something that happened on a day and is now a
dated entry in the Project section below (Denver's ruling C). Absent when this
Mac is its own root. Both read names from the registry directly, because the
table carries none.

**Two tripwires, both censuses** — see items 10 and 11 below.

### Admission, revocation and the claim — what P2b built (2026-09-11)

**Three files write a registry record, and the census is why.**
`RegistryPresence.swift` (a device signing its own record, and the first root),
`RegistryAdmission.swift` (admit, revoke, retire, claim) and
`RegistryCache.swift` (the restore, which writes already-signed bytes and forms
no opinion). `RegistryWriter` refuses a signer that is not the record's own key
and a device with no key, but the AUTHORITY rules are not inside it — who may
revoke is `RegistryAdmission`'s, declaring oneself is `RegistryPresence`'s — so
a fourth caller would reach the signature without reaching the rule.
`TripwireGrepTests.test_theRegistrysWritersAreThreeFiles` is the census, with
`TripwirePhoneGrepTest.test_thePhoneWritesNoRegistryRecord` as the phone's twin
allow-listing nobody at all, and planted offenders on both sides. The second
census is `RegistryCanonicalCensusTests`: `RegistryCanonical` alone decides what
a signature covers (no other registry/trust source may name `JSONEncoder(`,
`JSONSerialization` or `SHA256`; `RegistryCache.swift` and `AdmissionMemory.swift`
are allowed the encoder for their own persisted stores and nothing more), and
the set of files naming `digestHex(` is exactly the writer, the reader and
`RegistryCanonical`.

**The digest is lossless and frozen.** `canonicalBytes(ofJSON:)` takes the
FILE's bytes — parse, remove `"sig"` by name, re-serialize `.sortedKeys` +
`.withoutEscapingSlashes` — so a field this build has no property for is part of
what was signed on both sides. A re-sign (revoke, retire, a later adoption
joining an existing claim) goes through `RegistryCanonical.resigned(fileBytes:editing:signing:)`,
which edits the FILE's object rather than a decoded copy, and refuses an edit
that moves `fingerprint` or the expected signer — a re-sign may change facts and
never identity.

**A record changes hands only under the same key** (the same-authority rule, in
`reconcile`, described above with the cache). Its non-obvious half: refusing the
displacing copy would also hide the claim it represents, so where the refused
record is about THIS device the displacing key is recorded as a claimant.

**`RegistryAdmission` is the four verbs.** `admit` writes the person record
signed by my root, refusing `.notARoot`, `.alreadyAdmittedElsewhere(root:)` and
`.recordUnreadable(fingerprint:)` — all three refusals of AUTHORITY, decided
against the reconciled registry (`TrustResolution.verifiedRegistry`) and never a
raw folder read, or an admission would launder a takeover and drop the restore
promise. It is idempotent to the BYTE (a re-signature is a new file for iCloud
to carry and a new signature for every peer to check), keeps `admittedAt` across
a rename, and **clears a revocation** when the admitting root re-admits — the
one way back. `revoke` and `retire` re-sign through the door above and refuse in
their own right (`notAdmitted`, `cannotRevokeARoot`, `notThatDevice`). `claim`
writes this device's self-signed root record FIRST and then the `ClaimRecord`,
because the reader refuses a claim whose `newRoot` is nobody's root here.

**`RegistryPresence.admitRemembered` is the silent admission at open** (B2):
where this device is a root, every device record with no person record whose
fingerprint `AdmissionMemory` remembers is admitted under the remembered label
and the device's own current name. One folder read however many it admits; a
device already admitted under another root is skipped rather than thrown on.

**`AdmissionMemory`** (`admission-memory.json`, beside `registry-cache.json`) is
device-local, identity-scoped like the cache, and has **no project key at all**
— what the writer decided a machine is called is a fact about their decision,
not about a folder. `labelledAt` moves only when the label actually changes,
which is what keeps History's *remembered from Playlist* true.

**The table gained a verdict whose answer depends on a DATE, and adoption.** `.retired(device:retiredAt:)`
is the one verdict whose answer depends on WHEN a seal was made — hence
`settling(sealKey:sealedAt:)` — and `.mine` outranks it, so a Mac that retired
itself still reads its own history as its own word. `TrustTable.adoptedRoots`
is adoption, transitively: `myChain` is my root's chain unioned with each
adopted root's, so a root I adopted is mine, while `myRoot` and the claimant
list do not move (B1). `TrustTable.rootSource` is **DELETED** — it had no
production reader, and `DeviceStanding` derives the this-Mac / joined / adopted
marker from `myRoot` plus the registry.

**A revoked span is cut on the mark, and the cut is made per LINE.** The rule
is written out once, above — see *A revocation keeps what this Mac had already
applied*. The two facts that belong beside `TrustTable` rather than beside the
walk: `highestOpIdSeen(forPerson:)` is what the root recorded when it revoked
somebody, and `RevocationSplit.partition` asks it **per line, of that line's own
person**, because a candidate is decided by `OpLogChain.Line.refusal` — the
reason THAT line was refused — and never by `Verification.quarantineCause`,
which is one cause for a whole file and is the first one the walk met. A splice
after a revoked seal wears the revocation's name at the file level; reading it
there put forged text back into a manuscript on the strength of an op id its own
forger chose (find-5 review, the Critical). The inbox's own chained stream has
no revoked-span cut: its reader passes no table.

**A stranger's rotated history is held like its tail.** `classifySegment`'s
fallback walk used to be keyless, so an unsettled `.mzseg`'s inner seals all
answered `.noChain` and applied as unsigned history — rotation, which is
maintenance a device performs on itself, silently admitted it. It now passes the
same `TrustVerdict` closure `classifyTail` does; with no table the keyless walk
stands, which is P1 exactly. **This is a P1 behaviour change** and is visible on
an existing book: history applied before the upgrade reads pending afterwards,
until the device is admitted (`PendingLoadTests.test_aStrangersRotatedSegmentIsHeldJustAsItsTailIs`).

### Three hygiene facts P2b's final wave settled (Task 10)

**`OpLogChain.pendingByDevice` counts OP lines only.** A seal is held back with
the span it closes, and it is counted nowhere. Every reader of this number puts
a noun after it — *3 captures waiting*, *14 notes from iPhone* — and a seal is
neither a capture nor a note, so two ops under one seal reading *3* was three
surfaces telling the writer they have something they have not got. The LINE
tallies (`FileProvenance.pending`, `pendingLines`) still count the seal, because
it is a line and it is held; the two answer different questions and both are
pinned (`PendingLoadTests.test_heldSealsAreNotCountedAsThingsTheWriterIsWaitingFor`).
**`OpLogProvenance.pendingOpLines` is the sum every noun-bearing sentence reads**
(the final wave's I1): it is `pendingByDevice`'s own total, so History's *N notes
waiting* banner and the admission sheet's request are the same number by
construction. History printed `pendingLines` until then and said *3 notes* about
a device the sheet described as holding 2, and a pending span that is nothing but
a seal now draws no sentence at all rather than *1 note from another device*.

**`RegistryCache` keeps a dated restore list**, bounded at
`RegistryCache.restoreLimit` (50) per project and written by `reconcile` on what
it actually put back. A restoration leaves NO trace in the folder afterwards —
the file is back and looks exactly as it did before somebody deleted it — so
this is the only place the fact survives, and dating it at read time would stamp
a week-old deletion with the moment a pane was opened. Two surfaces read the one
list: `TrustEvents.derive` dates its `.recordRestored` from it, and
`PeopleAndDevicesModel` marks the row (*put back 9 Sep*). A record deleted twice
is two events and one row mark, because a timeline is what happened and a row is
what holds.

**`RegistryCache.shared` is lazy about the enclave.** `TrustResolution` reaches
for it on the way past every project it opens, and the identity behind it is
this device's author fingerprint — asking for which MINTS an enclave key if
there is not one (`LocalIdentities`' lazy rule: naming an actor is the writer's
act). Most projects have no registry and never will, so the file is read on the
first real question and the identity is resolved only where the answer turns on
it: a file that decoded, or a write (`persistLocked` stamps it, which is exactly
when this device has to say whose memory this is). **A project with no registry
and no cache file resolves no identity at all**, pinned through a counting seam
in `RegistryCacheTests.test_aProjectWithNoRegistryNeverReachesForTheEnclave`.
The public `init(fileURL:identity:)` is unchanged for a caller that already
holds the fingerprint.

## The permit — what a person may write (P3a, [ADR 0032](../../docs/adr/0032-the-signed-op-log.md)'s P3a addendum)

P2 answered *is this key somebody this book admits?* P3a answers **admitted to
write WHAT**, and answers it where lines are read. **No surface** in P3a —
P3b gave the permit its controls and P3c plan 1 the Mac's posture (below); the
phone's is P3c plan 2's. It is **behaviour-neutral for every existing book**: no permit events ⇒
every admitted person is an author of the whole book from the start ⇒ the P2
suite passes untouched.

### The values, and what each one is for

- `Permit.swift` — `Permit` (`.reviewer`, `.author(.book)`, `.author(.pieces)`,
  `.unjudgeable(raw:)`), `Permit.parse` (the one parse, from the three wire
  strings), and **`Permit.allows` — THE table**. Its switch over `OpKind`
  (`Permit.group(of:)`) has no `default:`: a kind a later build adds fails to
  compile there until somebody decides who may sign it. Manuscript text is
  **asked of `Deriver.appliesToManuscript`** and never restated, because a
  second copy of that list would drift and a prose-moving kind missing from
  this copy would be waved through on the reviewer row. Answers are
  `Allowed.yes` / `.no(RefusedWhat)` / **`.cannotJudge`**, and the third is not
  a failure: an unrecognised role, scope, event kind or op kind holds lines
  PENDING and never sets them aside, because an older Mac must not quarantine
  what a newer one would apply.
- `PermitEvent.swift` — the fourth registry record. Count `PermitEvent.Kind`'s
  cases, not a number here; `.unknown(String)` is the tolerated later-build
  one.
- `PermitMark.swift` — the mark value and `judge(streamKey:…)`, plus
  `PermitMark.stream(of:)` / `streamKey(of:)`, **the one URL → stream parse**
  (`<docId>`, `translation:<docId>.<lang>.<slug>`, `inbox:<slug>`), and
  `PermitMark.keyNaming(_:in:)`, the one slug → key join.
- `PermitTimeline.swift` — a person's events in order as `(permit, mark)`
  entries, `current`, `permits(forFile:…)` and `permit(ofLineAt:…)`.
- `DocumentClass.swift` — which kind of stream a file is, resolved from the
  manifest; `.unplaceable(String)` is the statement whose scope this build does
  not know.
- `PermitPartition.swift` — the pure partition, `RevocationSplit`'s sibling.
- `AnnotationOwnership.swift` — the one same-person rule for amendments.
- `LocalWritePermit.swift` + `OpLogStore.localWritePermit(as:documentClass:)` —
  the write side; see *The load seam* below.
- `OpLogPermitContext.swift` — `PermitContext`/`PermitJudge`, what a read path
  hands the partition, plus `PermitMemo` and `AmendmentPermits`.

### The mark, and the two alternatives that were rejected

A mark says *from when*. It is **not** an opId: a ULID's timestamp is chosen by
its own writer, so a demoted author could stamp new text with an old id and
slip under it. And it is **not** this device's own memory: fix the first that
way and a fresh Mac with no memory applies what the root's Mac refused, which
is silent, permanent divergence.

A mark is **chain positions in the shared bytes**, per STREAM: the digest of
every whole segment the root had read and judged, and the `lineHash` of the
last line it had. Keyed by stream, never by filename, because a rotation moves
the marked line from the tail into a `.mzseg` without touching the chain.

**SEEN, not applied.** A mark selects which permit judges a line; it does not
bless the line. *Last applied* would let refused text at the end of what the
root read fall after a promotion's mark and be applied under the new permit —
the pardon spec §5 forbids — and would re-judge a segment's honestly-applied
lines under a demotion because one refused line kept the segment out of the
mark. *Seen* excludes only a torn tail and what a broken chain quarantined.
**A revocation is the one act whose mark means APPLIED**, so the store answers
two questions — `OpLogStore.seenPositions` (permit events) and
`OpLogStore.appliedPositions` (revocation) — and
`DocumentStore.permitMark(forPerson:seen:)` chooses between them.

**What governs the lines before a person's FIRST event turns on that event's
kind** (`PermitTimeline.opening(before:)`, five arms — read them): an
`admitted`/`silentlyAdmitted` event's permit governs both sides of its mark
(nothing precedes an admission, and a stranger's held text would otherwise fall
to the book-author default the moment she is let in as a reviewer); a
`roleChanged`/`scopeChanged`/`readmitted` event first means a P2 admission, so
the opening stays book author and **a demotion never reaches back**; an unknown
kind first leaves the opening unjudgeable. This is why a re-admission must mint
`.readmitted` and never `.admitted`.

### Where the check runs

After `RevocationSplit` and before the parse, line by line. The order is the
only one in which both answers survive: a revocation is a verdict about a whole
KEY cut on a mark, a permit is about one LINE judged against the history its
signer had at that line. A refusal is `QuarantineCause.notPermitted` (person,
rung, what was refused, whether it fell after a mark); a line this build cannot
judge is `.pending`, held with no `.lines` record, because nothing is wrong
with it.

**The call sites are a named list, and the list is in the census, not here**:
`TripwireGrepTests.partitionCallSites` holds them with the reason for each —
`OpLogStore.partitioningByPermit` (the op-log door: live tail, settled segment,
fallback walk), `OpLogStore.verificationForPositions` (the mark SWEEP, which
must judge a file exactly as the load does or the two cut it in different
places), `TranslationStore.loadMerged`, and
`JSONLAppendStore.loadVerifiedStrict` (the inbox manifest and the annotation
log).

**Annotation amendments are judged AS OF THE LINE.** Judged by the signer's
current permit instead, a demotion would revert an author's honest edit of a
reviewer's note and a promotion would pardon an ignored withdrawal. The
partition carries the governing permit out per amendment op (`AmendmentPermits`
— empty for every book that has no events) and `AnnotationOwnership` honours
the amendment under the permit in force at that line.

**Cost is bought back structurally, not by a flag.** A registerless book judges
nothing (`judgesAnything`); a book author's author key skips the per-line
decode (`Permit.allowsEverything`); a stream whose every line is one kind,
written by an actor the table allows that kind under a book author, is answered
whole (`PermitPartition.answersWholeFile`); the document class travels as a
CLOSURE inside the `PermitJudge` so no manifest is read where nothing is judged.
Measured 2026-09-20, ordinary book, quiet machine: the two main-actor project
walks over 30 documents moved 59.5 → 59.6 ms and 63.3 → 63.4 ms against `main`,
and one `Document.load` of a 1,001-op document 24.9 → 26.0 ms.

**Every one of those exits turns on NARROWING, not on events** (final fix wave,
W1 — `TrustTable.hasNarrowingPermits`). P3a's own verbs write events: `admit`
files one for every device the writer lets in, and the silent admission at
project open files another. Every event P3a can write carries the book-author
permit, so gating the exits on *are there events* made the first admitted phone
turn a book into *judge everything* for a reason that has nothing to do with
permits — and took the annotation ownership rule with it, which stopped
honouring an UNSIGNED Mac's edits and withdrawals from that day on. The
question is asked of the permits: *has anybody in this book ever been anything
but an author of the whole book*, over every entry of every timeline, with an
unreadable role word counting as narrowing. The ACTOR rows are not part of that
and bind in every book, evented or not.

**And the narrowed book is measured too** (final fix wave, W5 — it was P3a's
one unmeasured path). Same machine, same day, one fixture, both shapes; the
absolute numbers are not comparable with the ordinary-book row above because
the fixture is a different one, but the two columns here are comparable with
each other, which is the question.

| measure (medians of 7) | admissions-only | one reviewer |
|---|---|---|
| annotations walk, 30 documents | 157.8 ms | 157.4 ms |
| aggregation walk, 30 documents | 153.3 ms | 163.8 ms |
| `Document.load`, 1,001 ops | 23.8 ms | 39.2 ms |
| `TranslationStore.loadMerged`, 40 records | 0.82 ms | 0.89 ms |

An admissions-only book pays nothing — it takes every exit, which is exactly
what W1 restored. The moment ONE person is a reviewer the book starts judging,
and the cost lands where the work is: **+15 ms on a document open**, +65 %, the
per-line decode plus the class resolution over 1,001 ops. The walks and the
translation read barely move, because those streams are still one kind each and
the aggregation's +7 % is inside its own spread. It is paid once per open
rather than per keystroke, and it is the price of the rung existing at all.

**Re-measured by P3b (2026-09-23), on a fixture that is KEPT.** That probe was
thrown away; `MaughamTests/Performance/NarrowedBookCostTests.swift` is
env-gated like `OpLogGrowthBaselineTests` and ATTACHES its table to the
xcresult (the host is sandboxed and `xcodebuild`'s log does not carry a test's
stdout), so the number can be re-taken. Same four measures, medians of 7, a
real novel project with 300 bursts in the measured piece, quiet machine, two
agreeing runs:

| measure | admissions-only | one reviewer | + a 400-line unsigned stream |
|---|---|---|---|
| annotations walk | 9.05 ms | 9.73 ms | 17.25 ms |
| aggregation walk | 8.95 ms | 9.64 ms | 17.00 ms |
| `Document.load` | 10.38 ms | 13.47 ms | 24.20 ms |
| `TranslationStore.loadMerged` | 3.44 ms | 4.23 ms | 4.22 ms |

One reviewer costs about +3 ms here; the stream the photograph is ABOUT is the
bigger half, +11 ms more, because every load walks and judges it. Taken
together a narrowed book costs **about one 16 ms frame** per document open —
which is the figure ADR 0032 gives, and the wording both documents now use.
(The sentence here used to say *two frames*, reading the larger fixture's
+15.5 ms as if it were the whole cost.)

### Possession, and a contested actor key

A device record LISTS the fingerprints of its four actor keys, and **nothing
proves possession of a listed key** — the actors map is a claim inside a signed
record, and only the author slot is self-proving (the record is signed by it).
`Registry.actorKeyOwners` is the one resolution, asked at all three join sites:
the author slot is proven and wins; a non-author key with exactly ONE claimant
is that device's whatever its standing; **a non-author key two or more records
claim is NOBODY's, forever**. Standing plays no part — awarding a disputed key
to the only standing claimant let a revoked owner's later lines read as the
standing liar's, which is the same defect from the other side.

The residual, named: an admitted device can hold another person's NON-author
actor lines pending indefinitely by listing that key, and revocation no longer
cures it. Availability only, never words, never the author key; the cure is
per-actor possession proofs in the device record — a format change, filed under
the roadmap's *Signed structure*.

### The acts, and why each one refuses rather than shortens

`RegistryAdmission` stays the only authority that writes (tripwire 13).
`changePermit` is its fifth verb; events are written from it and nowhere else,
and `RegistryCache` restores them byte-faithfully like any other record.

Four verbs compute a mark — admit, `changePermit`, revoke, retire — and a mark
that does not NAME a stream judges that stream wholly new. So a short sweep is
not a small inaccuracy: it turns a lost or evicted file into a demotion that
reaches back through all of it, or a *keep what was applied* revocation that
sets aside words this Mac had already shown the writer. **All four refuse and
write nothing** — no event, no record — when they cannot list an existing
directory (`ReadError.unlistableStreamDirectory`), cannot read a present stream
file, meet an old-style `.icloud` placeholder standing in for one
(`OpLogStore.nameBehindICloudPlaceholder`, sweep-only and the subject's streams
only), or cannot name a stream this device REMEMBERS having read
(`ReadError.streamMissingFromSweep`). The silent admission at project open is
the one exception: it skips this time rather than blocking the open. The
refusal is the existing `historyUnreadable` sentence, which now names its ACT
(`RegistryAdmissionError.Act` — four words for four verbs), because a writer
who pressed *make Sam a reviewer* should not be told a revocation was refused.

**A permit is about a PERSON and P2b merges devices under one LABEL**, so
`RegistryAdmission.records(sharingLabelWith:in:)` +
`DocumentStore.changePermit(everyRecordOf:to:)` is the label-wide verb: every
record's sweep pre-flighted before any write, each record its own mark and
event, revoked siblings skipped (a `roleChanged` after a revocation would draw
a History row about a machine already shut out), retired ones included.
`PermitChangePartlyApplied` is what a failure mid-run reports. **Nothing
presses it in P3a** — it exists for P3b's pane.

## The load seam (P3a Task 8, spec §4.6)

P2 asked of a key *is this somebody this book admits?* P3 asks *admitted to
write WHAT* — and the load has to ask it of ITSELF, before its first line
exists, because `Document.load` writes before it reads.

**What the load emits is the writer's own hand, whoever opened the file.**
Five emissions are the load path's or a derivation's rather than the caller's:
`Bootstrap`'s opening op, the two pending-recovery folds, the task anchors
`rebuildTasksCache` splices back into the paragraphs, and the `taskCreate`
beside each. None is the act of whoever opened the document, and every one is a
kind the table refuses to `assistant` and `translator` — so under MCP they were
lines the permit partition would set aside on the next read, with `bootstrap`
the worst of them (a document whose opening op leaves the book derives EMPTY,
and the first autosave writes that empty render over the manuscript). They are
now the AUTHOR's: `Document.authorEmissionDevice(loadedAs:)` redirects where
the load named one of this device's OTHER actors and leaves a `device:` string
naming no local key exactly as it was. `OpLogStore.append` derives the file and
the signer from `op.device`, so such a line is chained into the author's file
and sealed under the author's key with nothing else to change — and
`sealChain(docId:)` seals it at the close of the very Document that wrote it,
because its counters are keyed on the file APPENDED to and not on the
Document's own actor. Rotation is unchanged and stays the Document's own actor
(`sealTailIfNeeded`): a transient MCP Document must never rotate the tail the
writer's open Document is appending to.

**And not at all where this device may not write the piece.**
`OpLogStore.localWritePermit` is the ONE question — this device's own
`TrustTable.myTimeline.current`, narrowed by actor, against the stream's
`DocumentClass` — and `LocalWritePermit` is the answer, resolved once per load
and stamped on the `Document` so a derivation can ask it without a registry
read of its own. Three properties are load-bearing:

- **It never throws.** A present-but-unreadable registry record refuses a READ
  (RULING-54) and must not newly refuse a LOAD. **The fallback is two-deep, and
  the order is the point.** First the registry this device REMEMBERS
  (`TrustResolution.remembered` — `RegistryCache`'s byte-faithful copy, the
  same pure `TrustTable.resolve` a reconciled folder gets, recording no join
  and no claimant because a memory read taken over a hiccup must decide
  nothing); `keyless` only when there is nothing remembered either. Falling
  straight to `keyless` was the shape fix round 1 caught: it answers *author of
  the whole book* about everybody, so a REVIEWER's Mac meeting one
  half-downloaded record would bootstrap and mint anchors that every other
  device then sets aside. Keyless is right for a device that has verified
  nothing here — that is P1 exactly — and wrong for one that has.
- **It never suspends.** `trustOnThisActor` resolves here rather than off this
  actor, because `Document.load`'s suspension points are part of its contract
  — `ProjectStore.withStatementDocument`'s own comment is about a pane binding
  mid-load, and a bare `await Task.yield()` before the bootstrap fails
  `PromotionPerformerTests.test_promotingWhileTheIntentPaneIsOpen…` with no
  other change. It stores the table under the signature `trust()` compares, so
  the read that follows finds it warm.
- **A book with no register pays nothing** — no folder read, no verify, no
  manifest decode. `TrustResolution.hasAnythingToResolve` is
  `verifiedRegistry`'s own first question in its own spelling, and it asks
  about the MEMORY as well as the folder, because a register deleted wholesale
  is restored from that memory.

What the refusal does, in each of its three places:

| | |
|---|---|
| **bootstrap** | Asked of `LocalWritePermit.mayMintOpening` (P3c plan 2, Option A): in a book where somebody is narrowed, a piece whose manifest records a starter (`StructureItem.startedBy`, written by every creation site through `ProjectStore.thisMacAsAStarter` and by nothing else) is minted on THAT Mac alone — the root's included (OA-2), so the root waits for a piece a collaborator started rather than putting a root-signed opening in front of her words; a piece with no recorded starter, a starter that no longer STANDS here (revoked, retired, or unknown to the register — `TrustTable.starterIsStanding`, Ruling L (b)), and every un-narrowed book, keep today's rule. A creation that yields a piece WITH content (Duplicate, a duplicated group's children) mints its opening at creation on the starter's Mac through this same load (`ProjectStore.mintOpenings`, Ruling L (a)); an empty new piece needs none. The error names the STARTER where this Mac did not start the piece (`Document.starterLabelForWaiting`), the root otherwise, and never this Mac's own root label. `DocumentLoadError.waitingForPiece(docId:from:)` — mint nothing, read not a word of the `.md` as truth (tripwire 20). `EditorHost` draws it as its own calm state rather than an error (no notice, no recovery ladder) on the ONE widened load-outcome `@State` (tripwire 6), and re-attempts when the piece's ops change — the presenter already routes a closed document's op-log change through `MaughamSidecarPath`. |
| **the pending file** | Not folded, and **not read**: a buffer with something in it is one the next `close()` turns into a `typingBurst`, so reading it and merely declining to append would move the loss one hop. `PendingBuffer.fileNameIfOnDisk` names it without opening it. **`Document.mayWriteThePendingFile` is ONE expression at FOUR sites** — `performAutosave`'s mirror, `flushBurstNow`'s clear, `close()`'s failed-flush re-persist and `close()`'s clean clear — because the file has exactly one writer's worth of rules and four copies of them would drift. The burst's clear is the sharp one (fix round 1's C1): a burst's EMISSION is deliberately not permit-guarded, but its `clear()` UNLINKS the file, so one keystroke would have undone the promise the load had just made in a notice; `PendingBuffer.clearInMemoryOnly` is the same reset minus the unlink, and the writer's new words go where they always go, into the op log. `close()`'s failed-flush arm is the one place the rule costs something — this Document's un-bursted keystrokes stay in memory — and that is the right way round: they are words this device may not write at all, and the file holds words a load under a wider permit CAN fold. The writer is told through `PendingRecoveryFailure`, whose `cause` distinguishes RULING-54's *we could not read it* from *we touched nothing*. |
| **task anchors** | No mint and no `taskCreate` — a READ must not write where this device may not write — and the rebalance is guarded on its own key's row (`.maugham` signs `taskPriorityChange` only where the person may sign a task there at all). Tasks still derive and still show; the anchors are re-minted by whichever read happens after the permit widens. |

A keyless book, a P2-era book, the root and a book author reach `.unrestricted`
and behave exactly as they did — except, since Option A, that in a NARROWED
book they too wait for a piece whose recorded starter is another Mac (the
pane then names no root on the root's own Mac: `Document.rootLabel` answers
nil where this Mac holds its own root record). `DocumentWaitingTests` holds both halves;
`BootstrapWiringTests`' four tests are untouched.

**Two automations of that same hand were missed and are now in the rule**
(final fix wave, W4): `sweepOrphanedAnnotations`, which archives a note whose
paragraph a merge took away, and `repairRejectedButSplicedAnnotations`, which
puts a paragraph back when a reject beat an accept across a merge. Nobody does
either — the app does — so both sign with `authorEmissionDevice` and are not
made at all where `localWritePermit` disallows the kind
(`appendLifecycleOp(automation:)`, the one flag that carries both halves). On a
reviewer's Mac with somebody else's piece open the repair would otherwise have
been her machine signing text and dispositions the table refuses, filed in her
name, with her live document diverging until she reloaded. Declining costs
nothing: the piece's own author makes the same repair the next time she opens
it, and a disagreement standing visibly is what the repair already does when a
paragraph has drifted.

**P3c Task 5 widened that guard from the automations to every caller.** Every
disposition mutator — accept, revert, reject, stet, archive, triage, reopen —
asks the stamp first (`requireDispositionPermitted`, or the same check inside
`appendLifecycleOp`) and throws `Document.PostureRefusal` before it writes
anything; the automations keep `AutomationNotPermitted`, which their two
callers catch by type. The surfaces hide these verbs by the posture, so the
door is what stops a stale row, a margin card drawn before a demotion, or a ⌘Z
registered while this Mac could still write. An undo or redo refused this way
says so (`refusingLoudly` → `UndoDecline.notPermitted`) rather than falling
silent. Annotation creation and the writer's own note's edit and withdraw are
not doors here: they are the reviewer row. **A reopen is judged by what it
undoes** (ruling P, P3c plan 2). The table files `annotationReopen` with edit
and withdraw (`.ownAnnotation`), because the partition sees only the kind, and
`AnnotationDeriver` judges it twice through ONE Core policy
(`AnnotationAmendments`): in the withdraw pass by ownership against the
WITHDRAWAL it undoes (`AnnotationOwnership.mayAmend` handed the withdraw op —
controller Ruling D: author rights, or the same writer as the one who deleted
it, so she undoes her own Delete and the root's Delete of her note stays the
root's; `withdrawalStates` is the one walk behind `derive`, `deriveWithdrawn`
and `isWithdrawn`), in the lifecycle fold as a disposition
(`AnnotationOwnership.mayDispose` — author rights alone, never the same-person
arm, so her own note the root archived stays archived). The Mac's door branches
the same way: `reopenAnnotation` asks `requireRestoreHonoured` (the deriver's
own walk over the mirror plus the reopen) where it undoes a withdrawal and
`requireDispositionPermitted` otherwise, which probes a reopen as a stet
(`dispositionProbe`) — asked about itself, a reopen would answer the reviewer
row. The Deleted view's Restore follows who DELETED the note
(`WithdrawnAnnotation.withdrawnBy`, `AnnotationRowVerbs.restoresDeleted`).
**Every reader of the raw mirror asks the same judgement**: a reopen the
deriver does not honour now reaches `_opLogMirror`, so the withdrawn check in
`reopenAnnotation` is the judged `isWithdrawn`, and the reject/splice repair,
the rewind's return journey and `RewindImpact.preview` walk
`AnnotationDeriver.isHonouredLifecycleOp` rather than the bare lifecycle kinds.
The stated cost (RP-1): a reviewer's reopen of somebody else's archive is no
longer set aside as a `.lines` record; it passes the partition and is simply
not honoured, so History records nothing.

**The stamp is LIVE, not a load-time snapshot** (P3c plan 1, Task 2).
`Document.localWritePermit` is `internal private(set)`, and its one setter is
`stamp(localWritePermit:)`: the load calls it, and so does the posture door's
refresh (`DocumentStore+Posture.swift`) for every open document — the
manuscript registry's AND every open statement editor's (whole-branch fix wave
I1; a statement's `Document` is in no `DocumentStore` registry) — after every
trust change and manifest adoption, from the same builder, over the table the
refresh just warmed — in the same main-actor turn as the publication of the
staged drawing answers and the epoch bump that re-renders the editor
(controller ruling AG; fix wave Minor 1), so the stamp, the drawn answer and
the editor's lock never disagree for a turn. So every door on this page — the disposition
guard, `mayWriteThePendingFile`, the task door below — reads the permit as the
last landed refresh left it: once a demotion's refresh lands her next burst is
not signed, and a promotion gives the keyboard back, with no reopen. Until it
lands the stamp is the old one; the ADR's P3c limits state that window. **The re-stamp keeps the
stamp's own actor** (controller ruling J): the load stamps the AUTHOR's permit
whoever opened the file, because what it emits on its own account is the
author's (tripwire 38), so re-stamping as the loading actor would change what
the stamp means.

**Task ops have a door too** (P3c Task 8, `Document+Tasks.swift`).
`appendTaskOpInternal` refuses any op whose kind the stamp refuses, and
`archiveTask` refuses up front when either its op or — for an inline task —
its text splice is refused, so an op is never refused while its splice lands.
Both decline an undo out loud (`UndoDecline.taskNotPermitted`). The load's own
anchors and the rebalance were already gated on the same question. The
PROJECT stream's task verbs (`ProjectStore.createProjectPaneTask`/
`archiveProjectTask`) have no door — surface-only, a stated limit in ADR 0032's
P3c addendum.

**Every manuscript writer outside the editor has a door** (P3c whole-branch fix
wave, C1). A burst's EMISSION is deliberately not permit-guarded — the
editor's membrane is in front of the keystroke — so every other path that
reaches `setFullText` or a restore asks first. **A restore**
(`restoreToOpUndoable`, `restoreToOp`, `applyRestore`) refuses in
`requireRestorePermitted` before its undo-stack clear, before the burst flush
and before any op, throwing `PostureRefusal`; a registered ⌘Z/⇧⌘Z it refuses is
said (`UndoDecline.restoreNotPermitted`; the inline-archive undo's restore says
`taskNotPermitted`). **Project Replace, the rename's wiki-link sweep and every
statement write** ask the loaded Document's stamp (`Document.mayWriteItsText`)
beside the store's settled posture — see `Maugham/Stores/AREA.md`. The
population is a grep: `TripwireGrepTests.manuscriptWriterCallSites` counts
every production call of the writing spellings by file, each entry naming its
gate or why it needs none.

**`author_collaborator_id` is decoded and never written** (P3c Task 4, spec §8,
claim M5-AN-012). Attribution is the signing device through the registry, so
the WF1 collaborator id on a reviewer's note is read from old logs
(`AnnotationDeriver`) and nothing writes it: `addReviewerAnnotation` and its
edit/withdraw siblings lost `authorId:`, and `AnnotationInverse.editRevertOp`
lost its pass-through. See tripwire 23 below.

**And what RELEASED builds wrote is judged as the author's, permanently**
(final fix wave, W3(a)). The attribution rule above fixes what this build
writes; v0.37–v0.40 signed the same emissions with whichever actor opened the
document, so books exist holding `assistant-…` / `translator-…` files whose
lines are `bootstrap` and the anchor `taskCreate` — kinds the actor rows
refuse, and a refused `bootstrap` is a document whose OPENING op is gone,
deriving empty under the first autosave. `Permit.isALoadEmission` names those
two kinds and `Permit.actorJudging` answers which actor judges a line; the
partition asks both. It widens the ACTOR and never the permit, so a reviewer's
device's assistant-signed bootstrap is still refused under her own permit, with
the sentence her own hand's line would get. It is NOT gated on
`hasNarrowingPermits`, because a grandfather switched off by the first reviewer
P3b creates is the same defect arriving later. **The three other load emissions
are not covered and that is a stated stop**: both pending-recovery folds and
the anchor splice are `typingBurst`, and an assistant-signed ordinary burst
stays refused, which is the constitution's sentence about MCP and the
manuscript. **P3b Task 3 gave those three a `synthesisSource` of their own**
(`.pendingRecovery`, `.anchorSplice`) and deliberately left the rule where it
was: the label only reaches lines written after it ships, and a field the
assistant writes is a field the assistant can write. It is provenance — what
`LoadBurstCensus` reads and what History can say — and it reaches no table,
because `PermitPartition.writtenOp` decodes a KIND and nothing else. A disk census over every
project this Mac can reach (23 projects, 194 tails, 5 `.mzseg` segments, 11,064
lines) found no such line: the only non-author actor lines anywhere were
`claude_comment` and `claude_query`, which are the reviewer row.

## A foreign stream that got shorter (P3a Task 9, spec §4.7)

P1's remembered head is about this device's OWN files, and it catches an agent
appending a correctly chained line to one of them. It says nothing about
anybody else's: another Mac's history can be cut back to a seal and every rule
the chain has still holds, because the bytes that remain follow from each other
perfectly. So `OpLogDeviceState` gained a second memory —
`foreignStreams`, one `ForeignStreamMemory` per FOREIGN stream under the same
project-root hash the heads use — and `ForeignStreamWatch` is what fills it.

**It is keyed by STREAM and never by filename**, because a rotation copies the
live tail into a `.mzseg` and deletes the tail: the remembered line moves from
one filename to another while staying in the same stream, and a filename-keyed
memory reads that maintenance as a truncation. The key is
`PermitMark.stream(of:)`'s, the one parse. The key alone is not enough — a
segment its own signature settled is never walked (`classifySegment`'s fast
path counts its lines rather than splitting them), so after a rotation the
remembered line sits in a file the load has no lines for — which is why the
memory also carries **the digest of every segment this device took in whole**:
a tail that no longer holds the remembered line while the stream has taken in a
digest it had not seen has rotated. Both halves are per stream, and
`ForeignHeadTests`' *remember, rotate, read ⇒ no finding* pin goes red under a
filename key.

**A stream is remembered only once it has ANSWERED** (fix round 1's Important).
A file can be present, readable and yield nothing this device can point at — a
zero-byte `.jsonl` that synced ahead of its contents, or one whose first line
somebody corrupted so every line after it is `chainBroke` and none was ever
*seen*. `positions` names no such stream in a mark, so remembering it would make
`expectedStreams` demand a name the sweep can never produce, and every verb of
the root's would refuse for ever over a file sitting there perfectly readable,
with nothing the writer could do short of deleting `op-log-state.json`. The
ENTRY's existence is therefore the fact *this device has applied something of
theirs*. Once it exists it is kept: a stream that answered and has stopped
answering is the truncation case, and is supposed to refuse.

**It is kept, and it GROWS** (P3b Task 10's note). There is no per-stream
ageing and no cap: an entry leaves only when its PROJECT does
(`OpLogDeviceState.prune`, which drops every memory whose root is gone), and
`ForeignStreamMemory.segmentDigests` is a set that only gains members as that
stream rotates. The bound is *every foreign stream of every project this Mac
has open, times its segments* — small for a book with two Macs in it, and
worth knowing before somebody puts a hundred collaborators in one. **What P3b
added is an ESCAPE, not a prune**: an acknowledged loss stops being EXPECTED
(`OpLogDeviceState.acknowledgedLosses`), which is about what a sweep demands
and not about what the memory holds.

**The two notions
of *answered* are one value** — `FileClassification.wholeSegmentDigest`, which
both this memory and `positions`' `segments` list are built from, because a
disagreement between them is that same bug in another coat.

**The digests do a second job.** A digest this device remembers that no segment
of the stream carries any more is a **whole sealed span that went missing** —
`StreamTruncation.Loss.segment`, its own finding with its own sentence, because
the history's copy is gone even though every line already applied stays applied.
A `.mzseg` that is PRESENT and cannot be settled (evicted, corrupt, signed by a
key this device cannot stand behind) is not a deletion: while one is in the
stream no digest is reported missing at all, so under-counting can never read as
somebody removing one.

**Nothing is refused and nothing is set aside.** The surviving lines stay
applied — that is the spec's own clause — so this is a REPORT: an
`OpLogDeviceState.StreamTruncation`, read back through
`OpLogStore.truncatedStreams(in:state:trust:)`, which names the device the way
every other finding does (`TrustTable.label(forDeviceSlug:)` → the root's label,
else the four-character code) and carries the writer's sentence for which loss
it was. `IntegrityReport.truncatedStreams` carries it; it makes a report
**unhealthy** and deliberately does **not** block a backup, because the
surviving words are exactly what a backup is for. P3b's dated History entry
reads the same values.

**A finding is a fact that holds NOW, and it is dated once.** A stream with a
standing loss keeps the position it lost — it does not move its memory on —
because a memory that moved would find what it now remembers on the very next
load and clear a finding about history that is still gone. So the loss is
re-derived every load and `settleForeign` keeps the day it was first noticed
(same `loss`, same `lost` ⇒ no rewrite). When the bytes come BACK — iCloud
finishes, a file is restored — the finding is cleared and the project stops
being unhealthy, rather than being unhealthy for ever over something that is no
longer true.

**The PHONE runs it too** (final fix wave, M1 — correcting Task 9's review,
which said it ran neither half). `OpLogStore.load` goes through
`loadDiagnosed`, which builds the watch unconditionally, so a phone that reads
a chapter records what it saw and rewrites `op-log-state.json` like any other
device. That is harmless and is left alone rather than switched off: the memory
is the same derived bookkeeping there as here, it costs one state rewrite per
changed stream, and the phone benefits from the same truncation detection. What
the phone does NOT do is the SECOND job below — it writes no registry record
and runs no marking verb (tripwires 40/41), so nothing on it ever asks
`expectedStreams` a question.

**Where it is filled, and where it deliberately is not.** The STRICT load fills
it — `loadDiagnosed` carries one watch for the whole document and settles once,
so a chapter spread over four foreign files costs one rewrite of the state file
and an unchanged stream costs none. `TranslationStore.loadMerged` carries its
own (a sidecar never rotates, so each file is its whole stream) and
`JSONLAppendStore.loadVerifiedStrict` uses the one-file door
(`ForeignStreamWatch.note`, which refuses an `ops` stream on purpose). Three
paths do not: `loadSyncMerged` writes nothing at all, by design and still;
`loadDiagnosedPartial` is the read-only recovery rung, whose whole purpose is to
answer over the files that DID read, so a stream whose tail it could not open
looks exactly like a short one; and `ProjectIntegrity.check` classifies
keylessly and only REPORTS what a load recorded.

**Downgrading loses it, and that is fine — with one consequence worth naming**
(final fix wave, M2). An older build decodes this state file, ignores the keys
it has no property for, and rewrites the file without them; coming back up
finds the foreign memory empty and starts again from the next load. It is
derived bookkeeping — the same stance `heads` takes on a moved project — so the
cost is one load's worth of detection, never a word. The consequence is that
the SWEEP GUARD below goes quiet with it: a Mac that has been down to an older
build and back expects nothing of any stream until it has loaded each one
again, so for that window a verb that marks cannot tell an absent stream from
one that never existed and will not refuse over it. It is the pre-P3a
behaviour, arrived at honestly, and it heals on the next load of each
document — but it is a window, and it is here rather than in a comment because
it is invisible from either side.

**Its second job is a REGISTRY verb's, not a load's** (Task 7's
`expectedStreams` hook, supplied here). A mark that does not NAME a stream
judges that stream wholly new, so a stream that is merely ABSENT at sweep
time — iCloud has moved it, a sync is halfway through — would make a demotion
reach back through every line of it and a *keep what was applied* revocation set
aside words this Mac had already put in front of the writer. Nothing inside the
sweep can tell absent from never-existed; this memory can.

**And it is asked about CONTENTS, not names** (final fix wave, W2). Checking
that each remembered key came back in the mark catches a stream that has
vanished and nothing else, which leaves the case the shipped Revoke button
walks into: Sam's Mac rotates, and the tail DELETION reaches this disk before
the new segment does. The key is there — a fresh tail exists — so the sweep
passed with a position that had forgotten a whole segment; the root pressed
Revoke (*keep what was applied*), the segment arrived, and every line in it
judged NEW and was set aside. So `positions` takes the memories themselves and
asks `ForeignStreamWatch.loss` of what it found — the LOAD's own predicate,
rotation tolerance and all, called rather than restated, so the two cannot
disagree about whether a rotation is maintenance or a truncation. A stream that
legitimately grew is not refused; a stream whose name never came back answers
an empty `Found`, which the same predicate reads as the head being gone, so
both conditions are one call. The same rule reaches the EVENT: `writeEvent`'s
carry-forward unions segment digests per key (keeping an older line only where
the new sweep found none), because per-key-only was the identical defect one
field lower down.

`DocumentStore.expectedStreams(ofDeviceIds:in:state:)` is the one builder, and
its two call sites are `DocumentStore.permitMark(forPerson:seen:)` (which serves
`changePermit`, `admit` and `revoke`) and `DocumentStore.rememberedAdmissionMark`
(the silent admission). The verb then refuses with its existing
`historyUnreadable` sentence, naming the stream, and writes nothing — no event,
no record. **A stream this Mac has never read is not expected**, which is honest
late sync and ruling 1's answer. **And `retire` is unchanged, by ruling**: its
subject is this device, whose streams live in `heads` and never here, so it
expects nothing; its mark installs no `PermitTimeline` entry and no revocation
cut reads it, and a retirement that could be refused would leave a writer unable
to stand a machine down at all.

**Known limits, stated rather than hidden.** The LINE half is watched on the
live tail, so a stream whose tail is empty is watched by its digests alone until
it has a line again. A stream this device had remembered under the round-0 build
carries a segment COUNT this one has no property for, so it reads as *no digests
known* and is watched by its head alone until the next load learns them
(tripwire 11: no migration, just tolerate). The memory is bounded by (documents
× devices × actors) per live project and prunes on `rootIsGone`, the same clause
and the same pass as the heads.

**The digest list GROWS, and only the root prunes it.** One entry per whole
segment this device has taken in from that stream, and a stream gains a segment
every time its writer's tail rotates — so the list is monotonic for the life of
the book and is only ever dropped wholesale, with the stream, when its root goes
(`rootIsGone`). The arithmetic, stated so nobody has to re-derive it: a 64-hex
digest plus JSON quoting is ~70 bytes, a 30-chapter book on three devices with
two live actors each is ~180 streams, and a heavy year is a few rotations per
stream per chapter — tens to a low hundreds of kilobytes of
`op-log-state.json` over years. That is derived, device-local bookkeeping a
downgrade throws away for free, so the size is a fact to know rather than a
thing to fix; if it ever stops being one, the honest cure is a cap plus *older
than the oldest mark anything still reads*, not a silent trim.

## The unsigned door, and scope's lifecycle (P3b, [ADR 0032](../../docs/adr/0032-the-signed-op-log.md)'s P3b addendum)

P3a enforced the permit; P3b gives it a way to be GIVEN and SEEN, and closes
the four things the P3a build left open. Nothing here changes what a line
MEANS.

**`UnsignedSnapshot` — the photograph.** A file this register can name no key
for used to be applied UNJUDGED, which is P1's design and the ladder's one open
door. Refusing such lines would withdraw a whole enclave-less Mac's history the
day the root first makes anybody a reviewer, so the FIRST NARROWING event (not
the first permit event — an admission changes nothing about who may write what)
carries a mark over every unattributable stream instead. At or before it:
exactly P1, words applied and note amendments honoured. After it: PENDING —
held, never set aside, never pardonable by an admission, with §7.4's *Send to
Inbox* as its one way in. Narrowing is sticky, so there is no un-narrowing
direction, and where two roots have both narrowed **the earliest narrowing by
DATE governs** (`at` is a signed field, so every device reads the same number
out of the same bytes; the event id is only the tie-break).

**`HeldLines` — three reasons, one storage state.** P2 had exactly one reason
to hold a line, so *held* and *waiting for admission* were the same fact. There
are three now — a stranger's key, an admitted person's permit-pending line
(this BUILD cannot judge it, or she opened a piece nobody has claimed: §4.5,
recorded at the walk through `AmendmentPermits.recordStartedAPiece`), and an
unsigned stream — and they are told apart HERE, once, by the string the walk
held them under. `unsigned:<stream>` is a shape no fingerprint and no device id
can be, which is what makes the classification total rather than a guess.

**`HeldLines.Waiting` — what a held line IS** (P3b smoke find F2). Every
surface put *notes* after a held count, so Kit's paragraph of prose was *1 note
waiting* on the admission sheet and on History's §4.5 banner. The load now
counts, beside `pendingByDevice` and from the same classified lines,
`FileProvenance.pendingWaitingByDevice`: prose by distinct PARAGRAPH (a
paragraph typed in three bursts is one), the annotation layer as notes,
everything else (tasks, bookmarks, a later build's kinds) as changes, and the
first held paragraph's last words, task anchors stripped, as a peek. The kinds
are ASKED of `Permit.group(of:)`, the one exhaustive switch over `OpKind`
(which asks `Deriver.appliesToManuscript` for prose — tripwire 44), and each
held op line is decoded once. `HeldLines.sentence(_:notes:what:)` says the phrase where it has
one and the old count where it has none (the capture stream holds no ops).

**`OpLogDeviceState.acknowledgeLoss` — the escape.** A remembered stream that
is legitimately gone made `revoke`, `changePermit` and `admit` refuse for ever.
History draws what the book is missing — a stream found shorter than it was, or
one the folder holds no file of at all — and **Acknowledge** stops it being
expected. Every sweep takes the same escape through one function,
`expectedStreams`, the snapshot's sweep included; the acknowledgement is
device-local and changes no mark, only which Mac can write one.

**The schema gate.** The first narrowing raises `ProjectManifest.schemaVersion`
to 9 BEFORE the event is written (gate → event → record), so a v0.40 Mac cannot
open a narrowed book — which it would otherwise do by applying a reviewer's
refused text and re-asserting it under its own book-author key. The write door
is raise-only against what is on DISK, inside the coordinated write, and a P3
build that meets a narrowed book stamped lower HEALS it at open. A book made on
this build starts at 9.

**Settling a piece — *Theirs* re-judges BY REASON** (P3b smoke find F9;
Denver's ruling of 2026-09-23, replacing the positional cut). Answering §4.5's
question (*the piece is theirs*) writes an ordinary `scopeChanged` event — the
ordinary seen mark, the piece added — carrying `PermitEvent.settled`, the
pieces it answered (omitted while nil, so every other event's bytes are
unchanged). `PermitTimeline` reads it: every EARLIER entry of that person is
judged by `Entry.judging` — its permit read as having held the settled piece
(`Permit.settling`, which widens only an author-of-some-pieces list) — while
`Entry.permit` stays what the event installed, for History and `current`. So a
line of hers in that piece refused ONLY because the piece was not hers is
re-judged under the granted permit wherever it sits: before her held span,
after it, in a segment that arrives late. Every other refusal stays set aside
wherever it sits — the actor rows (the assistant never writes the manuscript),
a reviewer's rung, a verdict (a revocation, a broken chain: those are refused
before the partition runs), another person's line (the answer is on HER
timeline). A line held for a reason that is not §4.5's — a kind this build
cannot read — stays held, because `.cannotJudge` is the table's answer under
every permit. An entry AFTER the answer is not widened, so a piece taken away
again is taken away from that event's mark on; and `settled` over a permit that
does not author the piece settles nothing (`Entry.settles`, which History reads
too). The partition asks `entry.judging` and nothing else — one judgment, the
load and every sweep alike. The mark being the ordinary one, the answer takes
the ordinary loss check: a segment this Mac APPLIED that is missing now refuses
it (`streamMissingFromSweep`); one it never applied is honest late sync and is
judged by reason when it arrives. *Another person's line* means one another
person SIGNED — her own accepts, rejects and archives of other people's notes in
the piece, refused only for scope, come in too. **After a deliberate removal**
(Q1, ruled 2026-09-24) the question is still put and *Theirs* still brings it
all in, but the partition records that the piece was TAKEN from her
(`PermitTimeline.wasTakenFromThem` → `AmendmentPermits
.whoKeptWritingInATakenPiece` → `Document.keptWritingInATakenPiece`), so the
sheet, People & Devices' waiting row, History's banner and History's entry for
the answer all say she kept writing in it after it was taken. The positional machinery that preceded this
(`markLine`, the settling cut, `settlingOrder`) is gone.

## Sealed segments (ADR 0016, M2)

When a device's own live tail `<docId>.<slug>.jsonl` exceeds
`OpLogStore.segmentSealThreshold`, `Document.close()` / project-open
maintenance rotate it into an immutable, LZFSE-compressed, SHA-256-checksummed
`<docId>.<slug>.seg<NNNN>.mzseg` (container: `OpLogSegment`, MaughamCore).
Readers see one merged `[Op]` exactly as before — recognition lives ONLY in
`OpLogStore.opLogFileURLs` / `docId(fromOpLogFilename:)` / `loadFileDiagnosed`
/ `loadSyncMerged` (single-source helpers; grep tripwires on both targets).
Scope: never the legacy unsuffixed file, never another device's tail, never
inbox/pending, never mid-typing, Mac-only in v1. `__project__` was on that list
until 2026-09-09 and is not any more — it rotates at the same threshold, at the
project-open sweep alone (it has no close). Crash window
between segment-write and tail-delete is safe by construction
(`mergeSortedDedup` collapses the duplicates; the next seal converges).
A checksum failure quarantines + marks the doc unhealthy (backups pause) while
salvageable ops still derive. Non-Mac-editor tails (phone annotation writes,
MCP) never seal and that is accepted: they carry only rare, tiny lifecycle ops
and cannot realistically reach the threshold. Tests: `OpLogSegmentTests`,
`OpLogStoreSegmentTests`, `SegmentSealTriggerTests`, `SegmentIntegrityTests`.

**Each segment is signed beside itself** (signed op log P1): minting one also
writes `<name>.mzseg.sig`, a `SegmentSignature` over the 32 digest bytes the
container already carries — one P256 signature per segment rather than one per
line, so verification is a single check however long the history is. The name
comes from `OpLogStore.segmentSignatureURL(for:)` and nothing else; the `.sig`
suffix is what keeps `opLogFileURLs` (which matches `.jsonl` and `.mzseg`
endings) from ever listing it as history. Writing it is **best-effort** — a
device with no key signs nothing, a failed write is logged — because the seal is
maintenance and a segment with no signature is unsigned history, which is
honest. On the read side a segment reaches
exactly one of **three** outcomes, in this order. **Cached** —
`OpLogDeviceState.isVerified(segmentDigest:)` already holds this digest: the
chain walk is skipped entirely, every line counts `verified`, and nothing is
read but the container itself. **Trusted sidecar** — the `.sig` beside it names
this digest under a key that verifies and that this device stands behind: the
walk is skipped the same way and the digest is remembered (`markVerified`), so
the next load takes the first outcome. *Stands behind* was `identity.fingerprint`
under P1 and is `TrustVerdict.isOurWord(sealedAt:)` since P2a — `.mine` or
`.admitted`, and a RETIRED device's own word for a signature it made before it
stopped (P2b Task 7; the question takes the signature's own `at`, and there is
no undated form of it to reach for) —
so an admitted device's segment now settles as verified where P1 walked it
keylessly. A settled segment's lines count as
**verified** whatever they were before rotation, legacy included: the device
signed those exact bytes, which is the whole claim a seal makes. The
consequence is that a document's "written before this book was signed" sentence
DISAPPEARS once its legacy tail has been rotated into a signed segment —
nothing was rewritten, the sentence simply became false. **The fallback walk** — a foreign signature, no
signature at all, or a segment minted before this milestone: every line is
walked with no remembered head, counted by the
state the walk gives it, and a break still quarantines.
**That walk goes through the TABLE since P2b Task 10, and this is a P1
behaviour change** (ADR 0032 §6). It used to be keyless — `trusted: { _ in
false }`, so every seal inside answered `.noChain` and its span was applied as
unsigned history — which made a device's ROTATED history a different thing from
its live tail: a stranger's `.jsonl` was held and the same stranger's `.mzseg`
was applied unread, so rotation, which is maintenance a device performs on
itself, silently admitted it. Now a stranger's inner seals hold their spans
`pending` exactly as its tail's do, a revoked key's are refused, and this
device's own inner seals settle `verified` rather than being filed under
somebody else's unsigned history. With no table there is still nothing to ask
and the keyless walk stands, which is P1 exactly. Pinned both ways by
`PendingLoadTests.test_aStrangersRotatedSegmentIsHeldJustAsItsTailIs` and
`test_thisDevicesOwnInnerSealsSettleVerifiedInAWalkedSegment`. Only a container that
itself verified may be keyed on, since the stored digest is the one a tamperer
would leave alone.

**Where the time goes.** The load is `JSONDecoder`, and the chain is a rounding
error on it. Measured on 50,000 chained lines (42 MB) in release on a quiet
machine, best of three runs, at `4543b1a4`: the walk over the live tail costs
**33.9 ms** and seven sidecar reads plus signature checks **0.8 ms**, against
**421.5 ms** of parse-only control and a **514.6 ms** cold verified load. Before
the 2026-09-09 performance step those same four readings were 48.9 / 1.7 /
5832.0 / 5934.2 ms — the end-to-end columns fell by about 91% because the DATE parse
changed, not because verification got cheaper. The walk's own 48.9 → 33.9 ms is
Task 1's `prev` fast path, the only change on that path — with one clause of
honesty about its size: Task 1's own report read 41.0 ms on a **single** run, so
the remaining ~7 ms is best-of-three against one run rather than a second cause.
**The budget is Denver's
restatement of 2026-09-09 and it holds**: the chain's own cost read by the
fixture, under **20 ms** on a realistic tail (≤ 512 KB, some 600 lines) and
under **100 ms** on the fixture's 8×-oversized 6,250-line tail. The second
figure is measured (33.9 ms); the first is DERIVED — a real tail is a tenth of
the fixture's, so ≈ 3.4 ms — because the fixture only ever walks its own tail.
Full tables in `docs/superpowers/notes/2026-09-09-perf-step-measurements.md`.

**P2a added a term those numbers do not contain: a registry read on every
project open.** Every project this Mac opens now HAS a registry, because
`RegistryPresence` writes this device's record at `DocumentStore.open` — so
`TrustResolution`'s three-`fileExists` short-circuit, which used to spare the
ordinary case any cost at all, now fires only for projects last opened before
P2a. What replaces it is `TrustResolution.signature(of:)` — every record's name
and modification time across the three directories, three listings and a stat
apiece, nothing opened and no signature verified — which `OpLogStore.trust()`
and `InboxStore.trust()` compare before reusing the table they already hold. So
a folder read plus a P256 verify per record is paid once per store, and again
only when the registry has actually changed; the resolve itself runs off the
main actor. The unmeasured case is a book with many devices in it, where the
verify is per record rather than per store.

What keeps the cost where it is, and must not be undone:

1. **`Hex` (`OpLogChain.swift`) is table-driven**, because the obvious
   `String(format: "%02x")` spelling cost 107 ms of a 109 ms `lineHash` total on
   that fixture.
2. **The settled-segment branch COUNTS lines rather than splitting them**,
   because `split(separator:)` over a five-megabyte segment allocates a slice per
   line to answer a question that is a number.
3. **`prev(ofLine:)` reads the fixed prefix by bytes.** A chained line begins
   exactly `{"prev":"<64 hex>"`, and the fast path checks that prefix and all 64
   hex bytes before answering, so it can never differ from the textual reader,
   which still handles every other shape. The shape that must not come back is
   per-byte `Data` accumulation into a `String` — that was ~11 ms per 6,000
   lines, the largest per-line cost on the walk.
4. **No date decode allocates a formatter.** `ISO8601Fast` hand-parses the two
   shapes this app writes — `YYYY-MM-DDTHH:MM:SSZ` and the same with exactly
   three fraction digits — with days-from-civil arithmetic, and the unchanged
   `ISO8601DateFormatter` and epoch fallbacks sit behind it. The shape that must
   not come back is a formatter allocated per date. **And the fast path takes
   ONLY those two shapes on purpose**: the formatter TRUNCATES fractions past
   three digits, so a fast path that accepted 1–9 digits would answer
   differently from the reader it replaces. Offsets, other fraction lengths and
   epoch strings all fall through. The ENCODING side
   (`JSONLAppendStore.dateEncoding`) is byte-untouched, because every remembered
   chain head is a hash over encoded bytes.
5. **The head is persisted BEFORE the batch is written, and those persists are
   not coalesced.** The 2026-09-09 step considered batching them and refused:
   the crash window is the whole point of the ordering (ADR 0032 §3). A crash
   between remember and write leaves a head no line hashes to, which the load
   adopts; a crash the other way leaves the writer's own last op sitting after
   the remembered head, which is the quarantine case. Deferring the persist
   would turn a crash into a set-aside of the writer's own words. It is already
   one persist per BATCH, not one per line.

## External-edit discard + forensic snapshots (ADR 0019, hardened 2026-07-01)

External `.md` edits are never honored — they're discarded and the op-log truth
is re-materialized over them. Two entry points detect an external edit; both
snapshot the bytes forensically first (nothing is ingested):

- **Live edit while open** — `Document.handleExternalDiskChange` (the
  NSFilePresenter callback body): echo-guards, no-ops if the disk already matches
  our clean render, else snapshots (kind `discarded`) + re-materializes.
- **Edit while Maugham was CLOSED (F4)** — the addendum-#1 discard net covered
  only live events, so a file edited while closed was silently overwritten by the
  first autosave with no backup. `Document.load` now compares
  `stripAnchors(storedBytes)` to `stripAnchors(materialize(derived))` (display
  forms, so an unmigrated still-anchored file doesn't false-positive) and, on a
  mismatch, writes a snapshot (kind `diverged`) **before** anything can overwrite
  it — deduped against the newest existing backup for the doc (byte-equality) so
  repeated open/close of an unchanged divergent file doesn't accumulate copies.

Snapshot mechanics (`Document+ExternalChange.swift`):

- **Backup path roots via `resolveProjectURL`** (walk up to the manifest), so a
  Collection piece's backups land under the project root, not
  `pieces/.maugham/conflicts/` where nothing looks (F8).
- **Filename `<stem>-<docId>-<kind>-<stamp>.<ext>`** — the `docId` prevents two
  same-stem Collection pieces (`pieces/01/scene.md`, `pieces/02/scene.md`) from
  cross-pruning each other. `MaughamSidecarPath` classifies on the
  `.maugham/conflicts/` prefix, not the filename, so the naming change is
  path-routing-transparent. (Old-format backups from before this linger unpruned
  — accepted under no-migration.)
- **Retention: newest 20 per docId**, pruned on every write (F7 — the dir was
  previously uncapped and grew a backup on every ping-pong bounce).
- **Ping-pong damping (F7).** When op-log sync lags the `.md`, the discard handler
  could bounce rewrites indefinitely. It now counts **distinct-byte** discards per
  session; after `Document.discardDampThreshold` (3) it stops auto-rewriting
  (still snapshots, op log stays authoritative in memory) and logs once. A local
  edit resets the counter, re-arming rewriting.

## RenderFilter's three matching tiers (subtle)

When the renderer encounters a paragraph in the .md that doesn't have a `¶id` anchor (e.g., external edit), it tries to attach it to a known op-log paragraph in three tiers:

1. **Exact text match** — text == known paragraph.
2. **Word-shingle overlap ≥ 0.6** — `ShingleMatcher.bestMatch` (k=4-word shingles; picks the single highest-scoring candidate). Semantically the strongest tier.
3. **Character bigram overlap ≥ 0.6 *with a second-best margin*** — added late in T16 as a fallback for very-short paragraphs (< k words on either side) where word-shingles collapse to whole-string equality. **This third tier lives in `RenderFilter`, not `ShingleMatcher`** (it calls `ShingleMatcher.bigramOverlap` but owns the reuse policy). The bigram tier is a *fallback*, reached only when tier 2 misses — it never overrides a tier-2 match.

**Resolution contract (enforced, not hand-waved):**
- **Tier precedence (tier-2-vs-tier-3 disagreement).** The tiers run in order; tier 2 wins whenever it clears 0.6, so a higher tier-3 bigram score can never steal an id from a paragraph tier 2 already paired. This blocks the near-duplicate-substring false positive (e.g. survivor `"the cat sat on the mat"` vs candidates `"…the rug"` (shingle 0.667) and `"the mat"` (bigram 1.0) → reattaches to `"…the rug"`, the substring keeps its own id). Pinned by `RenderFilterTests.test_restoreComments_tier2WordShingleWins_overTier3BigramFalsePositive`.
- **Bigram margin-over-second-best** (`RenderFilter.bigramReuseThreshold = 0.6`, `bigramReuseMargin = 0.1`). The bigram tier reuses the best candidate's id ONLY when `best ≥ 0.6` AND `best − secondBest ≥ 0.1`. On a zero-/sub-margin tie among 2+ candidates the match is *ambiguous* (the survivor could be inheriting a DELETED sibling's id — e.g. dialogue `"Yes."`/`"Yes?"` both tying a survivor `"Yes!"` at 0.667) → mint fresh. A **single** high-overlap candidate has no competitor, so it is reused (a lightly-edited short paragraph keeps its id — the common minor-edit case `"First."` → `"First, edited."`). A delete-and-retype is byte-identical to an in-place edit from `restoreComments`' vantage, so single-candidate id-retention is the deliberate safe default. Pinned by `CrossDeviceIntegrationTests.test_case3a_singleCandidateMinorEdit_keepsItsId` (single-candidate keeps id) + `…test_case3b_nearDuplicateTie_reusesIdWithNoMargin` (ambiguous tie mints fresh).

Failure modes:
- All three tiers miss → orphan paragraph (logged, surfaced in the audit).
- Tier 2 matches the wrong paragraph (false positive on near-duplicate scenes) → silent corruption. The bigram tier no longer compounds this: tier 2's precedence + tier 3's margin rule together mint fresh on ambiguity rather than steal an id.

## Tripwires

0. **Manuscript content/sequence/anchors derive ONLY from the op log — never read the `.md`/`.fountain` as truth.** Open doc → use the live `Document`; closed doc → use `DerivedManuscript` (or `DerivedManuscriptCache` for hot loops). The sanctioned raw `.md` reads in this area all live in `Document+Load.swift` and are comparison/bootstrap references, never truth: the import-bootstrap mint read, the echo-guard seed (`EchoState.initialLoad`), and the divergence-snapshot reference. **The tripwire is now whole-tree and annotation-based (ADR 0018 addendum, 2026-07-01):** `TripwireGrepTests.test_noManuscriptFileReadsOutsideReconciler` scans ALL production `.swift` under `Maugham/`, `Packages/MaughamCore/Sources/`, and `MaughamPhone/` (phone twin: `TripwirePhoneGrepTest`) for a widened file-read pattern set; every hit must carry a `// adr-0018-ok: <reason>`. Op-log/inbox/pending JSONL reads are annotated `ok` — the op log IS the truth; the guard is about the derived `.md`.

1. **Don't collapse the OpLogStore / CheckpointStore wrappers into bare `JSONLAppendStore<T>` calls at every callsite.** The two thin wrappers exist precisely to keep the hot-path (op log: every typing burst) vs cold-path (checkpoint: ⌘S / project-close) concurrency profiles explicit at the type level. If you need new shared persistence semantics, extend `JSONLAppendStore<T>` and let both wrappers benefit; don't push the difference into call sites.

2. **Use 4-char alphabet-restricted paragraph IDs in any test that crosses the .md boundary.** In-memory tests of `PendingBuffer`, `Deriver`, `Op` serialization, `CrossMacMerge` etc. don't cross the boundary and short IDs (`"a"`) are fine. Tests exercising Bootstrap or RenderFilter-against-parsed-anchors need 4-char IDs from the alphabet, otherwise `parseComment` won't recognize them and the test will silently exercise only half the round-trip.

3. **Don't add a new `OpKind` without checking all consumers.** Adding a case touches `OpLogStore` (serialization), `RenderFilter` (rendering), the `Deriver` (folding), and probably `MCP/Tools/` (if the new op is annotation-visible). Audit before adding.

4. **Don't change paragraph-ID minting in `Bootstrap`** without thinking about existing on-disk op logs. New IDs in existing docs would orphan all prior op records.

5. **Don't bypass `PendingBuffer`** to write directly to the op log on every keystroke. The debounce is load-bearing for I/O cost; bypassing it will hit disk hundreds of times per second.

6. **No identity from the host name, and no hand-built device id.** `DeviceIdentity.author.deviceId` (and, for the other three actors, `LocalIdentities.current[<actor>].deviceId`) is the one answer on both surfaces; two Macs can share a name and then share a per-device op-log file, which is how a writer's lines go missing (tripwire 17). `TripwireGrepTests.test_noHostnameIdentity` and `test_noHandBuiltDeviceIdOutsideDeviceIdentity` (plus the phone's twin) are the census, each with a planted-offender self-check.

7. **No software private key in production.** The device key is the enclave's — `SecureEnclave.P256.Signing.PrivateKey` — because a software key copies off the machine with the file that holds it, and a signature made with one proves nothing about which device wrote the op. `DeviceIdentity+Testing.swift` is the sole allow-list entry of `TripwireGrepTests.test_noSoftwarePrivateKeyInProduction`; a test that needs a *verified* line injects that signer.

8. **A seal line is recognised in `OpLogChain` only.** `isSealLine` is the one door onto the `{"seal":` prefix, and `JSONLAppendStore.parse` — the one parser every reader shares (tails, decompressed segments, the inbox) — is its one caller. A second recogniser is a second opinion about what a seal is, and the failure is silent: a reader that hands a seal to an element decoder reports a healthy file as damaged.

9. **A production `Document.load` names an actor, never a device string — and the actor it names is the CALLER's, never the load's.** `Document.load(url:actor:session:presenter:)` is the production door; the `device: String` overloads are `internal` and test-only. A literal names no key, so `OpLogStore.append` takes the plain unchained path and the op is signed by nobody — which is exactly what happened to everything Claude wrote through MCP (`"mcp"`), both automations of the writer's hand (`"wiki-rename"`, `"find-replace"`) and the task rebalance (`"rebalance"`) under P1. **What the LOAD itself emits is the `.author` actor's whatever actor opened the file** (P3a Task 8, `Document.authorEmissionDevice(loadedAs:)`) — see *The load seam* below. `TripwireGrepTests.test_noDeviceStringAtAProductionDocumentLoad` is the census; `test_theDocumentLoadActorCensusFiresOnAPlantedOffender` is its control. CLAUDE.md tripwire 38.

10. **Every trust closure is built from a `TrustTable`.** The walk takes a `TrustVerdict`; the Bool `trusted:` overload is P1's shape and can only say *mine* or *nobody*, and the middle of that range is the whole of P2a — an admitted device's sealed span applied as this device's own, or a stranger's applied as unsigned history instead of HELD. Both failures are silent: the words land in the manuscript and nothing goes red. Three keyless sites survive, each allow-listed by file AND spelling in `TripwireGrepTests.trustClosureAllowedSpellings` — two `trusted: { _ in false }` in `OpLogStore.swift`, both of them the *no table was given* arm (the keyless reader `ProjectIntegrity.check` passes none; and the same arm of an unsettled segment's fallback walk, which since P2b Task 10 goes through the table whenever there IS one) and `trusted: { chain.trust($0) == .mine }` in `JSONLAppendStore.swift` (the chained write, which must not widen past this device's own hand). `ChainPolicy.trustedFingerprints` is gone. Census: `TripwireGrepTests.test_everyTrustClosureIsBuiltFromTheTrustTable` + `test_theAdmissionCensusesFireOnPlantedOffenders`; phone twin `TripwirePhoneGrepTest.test_noTrustDecisionOrRegistryWriteOnThePhone`. CLAUDE.md tripwire 39.

11. **Registry records are written through `RegistryWriter` only.** Every record is signed, and a record written any other way is one no reader can vouch for — the reader's honest answer to it is *malformed*, which is a device silently un-admitted and its whole history left pending. One writer is what makes the signer check a door rather than call-site discipline, and one place spelling the three directory paths is what stops a second opinion about where a record lives. `RegistryWriter.swift`, `RegistryWriter+Restore.swift` and `RegistryReader.swift` are the allow-list; everything else asks `RegistryWriter.directoryURL`, which is a read. Census: `TripwireGrepTests.test_registryRecordsAreWrittenThroughRegistryWriterOnly` + the same planted-offender control; phone twin as above. CLAUDE.md tripwire 40.

12. **One canonicalization, and it takes BYTES.** `RegistryCanonical.canonicalBytes(ofJSON:)` is the only place that decides what a registry record's signature was made over: parse the JSON object, remove `"sig"` by name, re-serialize with `.sortedKeys` and `.withoutEscapingSlashes`, SHA-256 the result. The writer canonicalizes the record it just encoded; the reader canonicalizes the FILE it just read, never a re-encode of what it decoded — because `JSONDecoder` drops a member this build has no property for, and hashing this build's vocabulary of a record written by a later one refuses an honest record. That failure is permanent and silent in the worst direction: the first device to upgrade un-admits itself everywhere an older copy reads the folder. `RegistryWriter.swift`, `RegistryWriter+Restore.swift`, `RegistryReader.swift` and `RegistryRecord.swift` may not name `JSONEncoder(`, `JSONSerialization` or `SHA256` at all — they ask. Census: `RegistryCanonicalCensusTests` (in MaughamCore's own package tests) with its converse and its planted offender. The escaping choice is frozen: a slash is written as itself, on both sides of the write.

13. **The registry's writers are three files.** Tripwire 11 says every record goes through `RegistryWriter`; this is the other half, and it is the half that matters for admission. The authority rules do not live inside `write` — *only the root that admitted them may revoke them* is `RegistryAdmission`'s, *a device signs its own record* is `RegistryPresence`'s — so a call from anywhere else reaches the signing without reaching the rule, and what it produces is a perfectly valid record nobody was entitled to write. `RegistryPresence.swift`, `RegistryAdmission.swift` and `RegistryCache.swift` (`restore` alone) are the callers; **the phone has none**, because admission is a Mac act and a phone that could sign a person record could admit itself. Census: `TripwireGrepTests.test_theRegistrysWritersAreThreeFiles` + `test_theRegistryWriterAndAvailabilityCensusesFireOnPlantedOffenders`; phone twin `TripwirePhoneGrepTest.test_thePhoneWritesNoRegistryRecord` + its own planted offender. (P2b Task 10.)

14. **No not-yet flag is left standing in production.** P2a drew several controls it could not yet wire and gated each on a constant — `admitIsAvailable` was the pattern. P2b wired them, and a gate that is now a constant `true` feeding a `.disabled(!…)` is worse than no gate: it draws as conditionally live, cannot be anything but live, and the next writer of the file has to prove it is dead before touching it. A `static let|var <name>IsAvailable = true|false` declaration is the shape; a system API's `isAvailable` READ (`SecureEnclave.isAvailable`) is a fact about the machine and passes. Census: `TripwireGrepTests.test_noAvailabilityFlagIsLeftStandingInProduction` with the same planted-offender control. (P2b Task 10.)


15. **Which of the four writers a key is has TWO sources, and the second can only ever narrow** (P3a Task 5). A device record is what says what a key is FOR, and where one exists it decides (`TrustTable.actor(forSealKey:)`). But a person record and a device record are separate files that sync separately, and a book can hold the first without the second — `RegistryAdmission.admit` writes a person record and nothing else — so a reader that answered *nobody* there would hold every line that person ever wrote PENDING, and one that answered `.author` there would be worse: a stranger's held span is keyed on `device ?? sealKey`, so before the device record arrives the writer can be asked about — and admit — somebody's ASSISTANT fingerprint, and calling that key `.author` applies assistant-signed manuscript text into the book. So where **no device record owns the key** the actor is read off the op log's own naming: `DeviceIdentity.actor(ofDeviceId:signingWith:)` takes the stream's slug (or an op's `device`), and believes its actor word only where the hex run that follows it really is a prefix of the sealing key. It is a CLAIM, used only to NARROW — an honest assistant's file is named `assistant-…`, and a client lying about it gains nothing it could not have by signing with its author key instead. Three cases stay nil (⇒ pending, never set aside): a device record that owns the key but calls it an actor word this build cannot read (a later build's fifth writer, which must not be guessed at), a stream with no device slug (the legacy unsuffixed file, whose lines are unsigned history and are not judged anyway), and an id whose fingerprint run is not this key's. **Note the slug is TRUNCATED at 24 readable characters**, so `author-<16 hex>` survives whole while `assistant-…` and `translator-…` keep only 13–14 hex characters — which is why the match is a prefix test with a floor rather than a fixed sixteen. Pinned in `PermitLoadTests` (all three cases) and `DeviceIdentityTests`.

16. **The role check reads the TIMELINE, never `PersonRecord.role`** (P3a). The field says what somebody may write TODAY; what judges a line is the permit its signer held WHEN THEY WROTE IT. Read the field instead and a demotion reaches back through every chapter the person wrote as an author, while a promotion pardons text the book had already refused — both silently, both with nothing red. `PermitTimeline` is built once, in `TrustResolution.verifiedRegistry`'s one read, and reaches the walk on the verdict. Census: `TripwireGrepTests.test_theRoleCheckReadsTheTimelineAndNotTheRecordsField` + `test_thePermitCensusesFireOnPlantedOffenders`; the allow-list is file AND spelling and names the writer (`RegistryAdmission`), the parse (`Permit`), the malformed reason (`RegistryReader`) and the display (`PeopleAndDevicesModel`). CLAUDE.md tripwire 43.

17. **`Permit.allows` is the one table, and `Deriver.appliesToManuscript` the one classifier of which ops become words** (P3a). The table's switch over `OpKind` has no `default:`, so a kind a later build adds cannot ship until somebody decides who may sign it — a second switch anywhere else takes that gate away, keeps compiling, and waves the new kind through or refuses it depending on which copy the reader reached. Restating the manuscript list is the sharper half: the copy that is missing a prose-moving kind lets a reviewer sign it. Census: `TripwireGrepTests.test_thePermissionTableIsSpelledInThePermitLayerOnly` + `test_theManuscriptClassifierHasOneNamedSetOfCallers` (its callers are an array — read it, not a number). CLAUDE.md tripwire 44.

18. **The partition's call sites are a named list, and a missing one is worse than a new one** (P3a). Every read path that applies somebody else's lines runs `PermitPartition.partition` before the parse. A site that disappears is a path applying unjudged text; a site that appears is a second opinion about where the judging happens, and the two disagree the first time one is changed. Census: `TripwireGrepTests.test_thePartitionsCallSitesAreExactlyTheNamedList`, whose `partitionCallSites` array carries each site with its reason. CLAUDE.md tripwire 45.

19. **The write-side question has ONE function, and a rung is compared only in the permit layer** (P3a Task 8). `OpLogStore.localWritePermit(as:documentClass:)` is the one answer to *may this device's actor write here* — it never throws, never suspends, and falls back to this Mac's REMEMBERED register before keyless, because keyless says *author of the whole book* about everybody and a reviewer's Mac meeting one half-downloaded record would otherwise bootstrap. A hand-built `LocalWritePermit` is `.unrestricted` by another name. And a surface that decides by testing a permit against `.reviewer` instead of asking the table is P3c's Posture done wrong: the two drift the first time a rung is added, and the surface is the copy that does not compile-error. Censuses: `TripwireGrepTests.test_theWriteSidePermitQuestionHasOneFunction` + `test_aPermitRungIsComparedOnlyInThePermitLayer`. CLAUDE.md tripwires 46, 47.

20. **Which lines the LOAD emitted is decided once, and the rule is permanent** (final fix wave, W3(a)). `Permit.isALoadEmission` names the two kinds — `bootstrap` and the anchor `taskCreate` — and `Permit.actorJudging` answers which actor judges a line; the partition asks both and restates neither. Released builds v0.37–v0.40 signed those emissions with whichever actor opened the document, and a refused `bootstrap` is a document whose opening op is gone. The rule widens the ACTOR and never the permit, so a reviewer's device's assistant-signed bootstrap is still refused under her own permit; and it is NOT gated on `hasNarrowingPermits`, because a grandfather the first reviewer switches off is the same defect later. **The stop, stated**: the three `typingBurst` load emissions are not covered — an assistant-signed ordinary burst stays refused, which is the constitution's sentence about MCP and the manuscript. They DO carry a `synthesisSource` since P3b Task 3 (`.pendingRecovery`, `.anchorSplice`) and the rule was deliberately not widened to read it: the label only reaches lines written after it ships, and a field the assistant writes is a field the assistant can write. Census: `TripwireGrepTests.test_theLoadEmissionRuleIsSpelledInThePermitLayerOnly` + the shared planted-offender control. CLAUDE.md tripwire 48.

21. **The unsigned door's decisions each have ONE home** (P3b). The narrowing predicate (`PermitTimeline.narrows`) and `UnsignedSnapshot` are spelled in the permit layer only; whether a file is unattributable AT ALL is decided in `OpLogChain` (the `unattributable:` label); the three `HeldLines.Holder` arms are BUILT in `HeldLines`; `AdmissionDecision.HeldKeyStanding` is the one *why is this held key not offered*; `Permit.permit(offering:)` is walked through by `PermitControl` alone; and `RegistryPresence` names no rung, because the admission that shows no sheet may only install the whole book. Every one fails silently and in the direction that moves words — a second answer to *is this book narrowed* holds a line here and applies it there, and a second opinion about *unattributable* keeps a file out of the photograph altogether. Censuses: `TripwireGrepTests.test_theNarrowingPredicateAndTheSnapshotAreInThePermitLayerOnly`, `test_whetherAFileIsUnattributableIsDecidedInOpLogChainOnly`, `test_theThreeHoldersAreBuiltInHeldLinesOnly`, `test_theHolderStandingClassifierIsOneFile`, `test_aSurfaceBuildsAPermitInOnePlace`, `test_theSilentAdmissionNarrowsNobody`, sharing `test_theP3bCensusesFireOnPlantedOffenders`. CLAUDE.md tripwire 49.

22. **Six P3b call-site lists are ARRAYS, not numbers in prose** (P3b). `expectedStreams`, `acknowledgedLosses`, `absentStreams`, `gateOldBuildsOut`, the `currentSchemaVersion` assignments and the held-line door's one caller live in `TripwireGrepTests.countedLists` with a count per file. A builder of `expecting:` somewhere else is a sweep that does not take the acknowledgement, so a loss the writer has already put down refuses a marking verb for ever; a narrowing verb that stopped calling the gate lets a v0.40 Mac into a narrowed book. Census: `test_theP3bCountedListsAreExactlyTheNamedArrays`. CLAUDE.md tripwire 50.

23. **`author_collaborator_id` is decoded and never written** (P3c Task 4). Only `Op.swift` names the `authorCollaboratorId:` label — the field, its init parameter and its decode; a read carries no colon. A second writer is a second attribution beside the signature, one nothing verifies. `TripwireGrepTests.test_theCollaboratorIdIsDecodedAndNeverWritten` + `test_theCollaboratorIdCensusFiresOnAPlantedOffender`, over `Maugham/`, `MaughamPhone/` and Core sources.

- **Cross-surface contracts:** if you touch op-log/inbox filenames, ids, formats, or Fountain rendering, you may be in shared phone↔Mac territory — the reach-around tripwires will tell you. Registry: `docs/superpowers/notes/cross-surface-contracts.md`.

## Behavioural claims

`Document+Rewind` (+`Document+RewindUndo`, `Deriver+Rewind`) is claim-covered:
`register/reconciliation/Rewind.{claims,filings}.json` — test-pinned facts and their verdicts
against the ruling set (count the `_summary`, not this sentence). **Read the filings before changing rewind behaviour**: a `VIOLATES` row is a
known defect with a ruling behind it, a `COMPLIES` row is behaviour a ruling protects, and changing
pinned behaviour means updating the claim + filing in the same commit (CLAUDE.md, "Behavioural
claims + rulings").

## Tests worth knowing about

- `MaughamTests/OpLog/` — unit tests for each store + the matchers.
- `MaughamTests/OpLog/BootstrapWiringTests.swift` — asserts every production manuscript-load path (`Document.load` and `withAnnotationDocument`) runs Bootstrap on an unanchored .md. Touch this whenever you add a new manuscript-load entry point.
- `MaughamTests/Integration/PresenterRoutingTests.swift` — asserts the echo-guard contracts hold (autosave + keep-mine round-trips don't reingest) and that `SweepReason` keeps MCP annotation writes against a live doc from triggering spurious archives.
- `MaughamTests/OpLog/DeriverUpToTests.swift` — `derive(ops:upTo:)` semantics.
- `MaughamTests/Integration/RewindFlowTests.swift` — end-to-end `Document.restoreToOp`.
- `MaughamTests/Integration/SynthesisSourceMigrationTests.swift` — string raw value on disk decodes into the enum.
- `MaughamTests/OpLog/AnnotationConvergenceTests.swift` — RULING-33's Swift half. Status derives from the latest LIFECYCLE op; text from a fold of every op's `changes`; nothing made them agree, so a reject beating an already-spliced accept settled `rejected` with the suggestion still in the manuscript, permanently. The post-merge repair appends a `claudeReject` carrying the INVERSE — one op that is both the newest lifecycle op and the newest payload — which is why `Deriver.appliesToManuscript` admits `.claudeReject` (writer-issued rejects still carry nothing) and why the manifest schema went 4→5. **The formal half is `formal/AnnotationRace.tla`'s `Fixed_NoRejectedButSpliced` config**, green over 7,709 states with its red partner one constant away.
- `MaughamTests/OpLog/DocumentNoticeTests.swift` — the writer-facing channel above, all three occasions plus the controls that keep a *successful* undo quiet.

Known thin coverage (file an issue before relying on these areas for novel behavior):

- `RenderFilter`'s tier-2-vs-tier-3 resolution IS now covered: `RenderFilterTests.test_restoreComments_tier2WordShingleWins_overTier3BigramFalsePositive` (precedence) + `CrossDeviceIntegrationTests.test_case3a/3b` (bigram margin rule). See the resolution contract above.

## What's intentionally NOT here

- The editor (NSTextView, tokenization, styling) — `Maugham/Editor/`.
- Document load coordination, autosave timing, conflict UI — `Maugham/Stores/DocumentStore.swift`.
- Project-folder filesystem layout (`.maugham/ops/` etc.) — owned conceptually by Stores; this area writes *into* `.maugham/ops/` but doesn't decide the layout.
- Annotation layer (paragraph-anchored comments from Claude/MCP) — `Maugham/MCP/` + a Stores extension.
