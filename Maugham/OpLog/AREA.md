# OpLog — Area guide

This is the **cleanest** area in the codebase per the 2026-05-19 audit. Don't refactor structurally. Read this before touching anything in `Maugham/OpLog/`. Also read the project root `CLAUDE.md` for cross-cutting invariants.

## What this area owns

The manuscript op log: append-only event stream of paragraph-level mutations, paragraph-keyed LWW conflict resolution, project-scope checkpoints with partial restore, cross-Mac log merge, and the inline `<!-- ¶id -->` HTML-comment anchors that join op records to rendered markdown.

**This is the source of truth for manuscripts.** `.md` files on disk are the **clean** derived render — standard Markdown/Fountain with NO `¶id`/`t-` anchors (ADR 0019); the anchors live only in the op log + the in-memory representation. Writers read the clean file; Claude reads via MCP / the op log (ADR 0018), not by parsing the on-disk `.md`. The op log is what survives merges and history.

## Layout

- `OpLogStore.swift` and `CheckpointStore.swift` — wrappers over `JSONLAppendStore<T>` that keep hot-path (op log, every typing burst) and cold-path (checkpoints, ⌘S) concurrency profiles explicit; `JSONLAppendStore` is the shared persistence primitive. **Both partition per device** — a writer appends only to its own `<stem>.<deviceSlug>.jsonl` and readers glob-merge every sibling, the legacy unsuffixed file included (ADR 0012; `PartitionedJSONLFile` in MaughamCore holds the checkpoint/publication template, `OpLogStore` its own). Checkpoints were left out of ADR 0012's scope and were fixed by FM-1; `formal/OpLogSync.tla`'s `_cpshared`/`_cppartitioned` pair is the proof that partitioning is the fix rather than a tidy-up.
- `JSONLAppendStore.swift` — generic append + read + tail for any JSONL-typed store. Extend here if you need new shared persistence semantics. **It is chained when it holds a `ChainPolicy` and plain when it does not** (signed op log P1): the op log and the inbox pass one; publications and checkpoints do not, and keep the append they have always had. Project-scope TASK ops are not an exception — they are `Op`s appended through `OpLogStore` into `__project__.jsonl`, so they are chained like any other op.
- `DeviceActor.swift` (MaughamCore) — the closed enum of who, on this device, wrote an op: `author`, `assistant`, `translator`, `maugham`. The raw value is both the device-id prefix and the key-file suffix, so a fifth actor is a spec amendment and a new file on disk rather than a case added in passing; nothing switches over it with a `default`.
- `LocalIdentities.swift` (MaughamCore) — this device's four writers in one value: `subscript(actor:)` (exhaustive, so a fifth case is a compile error), `all` in `DeviceActor.allCases` order, `fingerprints` (what *trusted* means on read), and `identity(forDeviceId:)`, which matches on the WHOLE id and never a prefix — another Mac's author carries `author-` too. `current` is computed over `DeviceIdentity.identity(for:)`'s per-actor memoization, so nothing is minted until it is asked for; the phone, which is the author alone, must reach `DeviceIdentity.author` directly rather than through here.
- `DeviceIdentity.swift` / `DeviceState.swift` (MaughamCore) — one enclave key **per actor**, each persisted by the app as a plain blob under Application Support (`device-key.blob`/`device-token` for the author, `device-key.<actor>.blob`/`device-token.<actor>` for the other three), and the id/fingerprint/slug derived from it. `DeviceIdentity.author` is the writer's; `DeviceIdentity.identity(for:)` is any of the four. `DeviceIdentity+Testing.swift` holds the test-only software signer, and is the one allow-list entry of `TripwireGrepTests.test_noSoftwarePrivateKeyInProduction`.
- `OpLogChain.swift` (MaughamCore) — the wire format (`prev` as the first key; the seal line) and the pure verifier that classifies every line. No I/O, no clock, no policy about who is trusted: the `trusted` closure and the remembered head are parameters. `Hex` lives here too, shared with the segment container and the fingerprint.
- `OpLogDeviceState.swift` (MaughamCore) — what this device remembers: the chain head it last wrote into each file, and the digests of segments it has already verified. Also `ChainPolicy`, the value a chained `JSONLAppendStore` carries.
- `OpLogProvenance.swift` (MaughamCore) — `FileProvenance` per file and `OpLogProvenance` over a document, the load's own account of what its history is made of. What `HistoryPane`'s unsigned-history sentence reads.
- `Bootstrap.swift` — mints `¶id` anchors on first-open of a document. **Must be called from any production load path.** Wired into `Document.load` since `milestone-document-first-class` (2026-05-19); `BootstrapWiringTests` enforces the contract. Any new manuscript-load path must route through `Document.load`.
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
one actor, while `ChainPolicy.trustedFingerprints` (and every `trusted:` closure
on the read side) is *all four*, because the assistant's seal over the
assistant's own file is this device's own word and a narrower set would file the
writer's own MCP history as another device's unsigned history. `DeviceSlug.make` is deterministic, so every op
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
sweep is its only boundary because it has no close. The sidecar's signer follows the slug: the segment signature carries the key
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
op log nothing ever sealed. `sealChain` never refused it; `sealTailIfNeeded`
did until 2026-09-09, and that refusal was about segment ROTATION, a different
act. It refuses nothing now: the project stream rotates at the same 512 KB as
every other tail, at the open sweep, so it has a ceiling like every other tail.
The residue worth knowing: open is its ONLY boundary, so a session appending
past 512 KB of task ops — some 2,500 of them — carries the excess until the
next open. The inbox and the phone do not
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
sentence carrying both — the coalescing rule) and `setAsideLinesNotice`, neither
with a Retry, because neither is something the writer can undo. **"Another
device" in that sentence never means this Mac's assistant, translator or
Maugham** (P1b): trust on the read side is all four local fingerprints, so
Claude's annotation file and the pipeline's translation file are this device's
own signed word, and a narrower trusted set would have the writer told their own
MCP history came from somewhere else. **The INBOX has
its own half of that sentence** — `InboxPane.setAsideNotice(lineCount:)`, drawn
beside the unreadable-manifests notice — because the inbox's `.lines` records are
filed under the manifest stream's own id (`InboxManifest.chainDocId`) and
`HistoryPane` only ever asks for a DOCUMENT's, so they were written and shown to
nobody. Both panes count through `OpLogQuarantine.setAsideLineCount`, one
implementation, because one record can hold a run of lines and the writer's
question is how many CHANGES. **`unsealed`
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
this digest under a key equal to `identity.fingerprint` and verifies: the walk
is skipped the same way and the digest is remembered (`markVerified`), so the
next load takes the first outcome. A settled segment's lines count as
**verified** whatever they were before rotation, legacy included: the device
signed those exact bytes, which is the whole claim a seal makes. The
consequence is that a document's "written before this book was signed" sentence
DISAPPEARS once its legacy tail has been rotated into a signed segment —
nothing was rewritten, the sentence simply became false. **Keyless walk** — a foreign signature, no
signature at all, or a segment minted before this milestone: every line is
walked with `trusted: { _ in false }` and no remembered head, counted by the
state the walk gives it, and a break still quarantines. Only a container that
itself verified may be keyed on, since the stored digest is the one a tamperer
would leave alone.

**Where the time goes.** The load is `JSONDecoder`, and the chain is a rounding
error on it. Measured on 50,000 chained lines (42 MB) in release on a quiet
machine, best of three runs, at `4543b1a4`: the walk over the live tail costs
**33.9 ms** and seven sidecar reads plus signature checks **0.8 ms**, against
**421.5 ms** of parse-only control and a **514.6 ms** cold verified load. Before
the 2026-09-09 performance step those same four readings were 48.9 / 1.7 /
5832.0 / 5934.2 ms — the end-to-end columns fell by about 91% because the DATE parse
changed, not because verification got cheaper. **The budget is Denver's
restatement of 2026-09-09 and it holds**: the chain's own cost read by the
fixture, under **20 ms** on a realistic tail (≤ 512 KB, some 600 lines) and
under **100 ms** on the fixture's 8×-oversized 6,250-line tail. The second
figure is measured (33.9 ms); the first is DERIVED — a real tail is a tenth of
the fixture's, so ≈ 3.4 ms — because the fixture only ever walks its own tail.
Full tables in `docs/superpowers/notes/2026-09-09-perf-step-measurements.md`.

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

9. **A production `Document.load` names an actor, never a device string.** `Document.load(url:actor:session:presenter:)` is the production door; the `device: String` overloads are `internal` and test-only. A literal names no key, so `OpLogStore.append` takes the plain unchained path and the op is signed by nobody — which is exactly what happened to everything Claude wrote through MCP (`"mcp"`), both automations of the writer's hand (`"wiki-rename"`, `"find-replace"`) and the task rebalance (`"rebalance"`) under P1. `TripwireGrepTests.test_noDeviceStringAtAProductionDocumentLoad` is the census; `test_theDocumentLoadActorCensusFiresOnAPlantedOffender` is its control. CLAUDE.md tripwire 38.

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
