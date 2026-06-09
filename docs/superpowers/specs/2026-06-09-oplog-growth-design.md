# Op-Log Growth — Design (ADR 0016 executable spec)

- **Date:** 2026-06-09
- **Status:** Design approved; pre-implementation
- **Decision record:** [ADR 0016](../../adr/0016-op-log-growth-without-compaction.md) — compaction/truncation rejected; this spec is the implementation contract for its three mechanisms.
- **Supersedes:** the roadmap's withdrawn "Op-log compaction" item.

## 1. Motivation (summary — full reasoning in ADR 0016)

Op-log growth is three separable costs, none of which requires deleting history:

1. **Disk bytes** — dominated by redundancy, not history: `Document.flushBurstNow`
   (`Document.swift:584-591`) attaches the **full `sequence` array to every burst
   op unconditionally**. Per-chapter novel docs: ~1–2 KB each. Single-file
   screenplay (~every line a paragraph): tens of KB of identical ordering data
   per burst. Paragraph `prior`/`next` text is the history we want and is
   bounded by typing speed.
2. **iCloud sync churn** — every append re-uploads the entire ever-growing
   per-device JSONL.
3. **Derive/load time** — `Deriver.derive` replays all ops on every
   `Document.load` and every `handleExternalLogChange` delivery.

Mechanisms: **(1) sequence keyframing** (stop writing redundant bytes),
**(2) sealed compressed segments** (storage layout + sync + checksums),
**(3) derived-state cache** (load time). Phased; each independently shippable;
measurement first.

## 2. Non-goals

- **No truncation, ever, under this spec.** The logical op log remains the
  complete, append-only, opId-ordered set of all ops. Rewind to op #1 keeps
  working on every project.
- **Not the live-tail framing fix.** Audit finding 0.6's remaining case (a torn
  append that still parses as valid JSON) is a separate punch-list item;
  segments retire the bulk of the exposure via checksums but the active tail
  keeps today's format.
- **Not skew-aware LWW / conflict surfacing** — collaboration milestone.
- **Out of scope for sealing (v1):** the `__project__` checkpoint/task stream,
  inbox JSONL, and pending buffers. Manuscript doc op logs only — they are
  where the growth is.
- **No migration** (tripwire 11). Legacy logs load unchanged forever; new
  behavior applies to new writes only.

## 3. Phase 0 — Measure first (gate for everything after M1)

A committed fixture + measurement harness, shared with the roadmap's
performance pass.

- **Fixture generator** (test-support code, not checked-in data): synthesizes
  (a) a 100k-word / ~5,000-paragraph novel project (30 docs) and (b) a
  110-page single-file screenplay project, each with a simulated drafting
  history (N sessions × bursts at the 30s/90s cadence, realistic edit
  locality) producing genuine op logs through the production `Document` API —
  not hand-built `[Op]` arrays.
- **Metrics captured** (XCTest `measure` + a printed table the milestone doc
  records as baseline): total op-log bytes; bytes attributable to `sequence`
  (re-encode each op with `sequence = nil`, diff); `Document.load` wall time;
  `Deriver.derive` time at full log; bytes rewritten per burst append (sync-churn
  proxy = tail file size at each append).
- **Budgets** (confirm/adjust against baseline at Phase 0 exit): `sequence`
  share of new-write bytes < 5% after M1; a heavy drafting month per doc
  < ~1 MB on disk after M2; `Document.load` at fixture scale < 150 ms after M3
  (M3 ships only if this is violated without it).

## 4. Phase 1 / M1 — Sequence keyframing

### 4.1 Emission rule

`flushBurstNow` attaches `sequence` to the burst op **iff** any of:

1. **`orderingDirty`** — the doc's paragraph ordering changed since the last
   flushed burst (see 4.2);
2. **keyframe floor** — ≥ `sequenceKeyframeInterval` (constant, default **50**)
   consecutive burst ops have been emitted by this Document without an explicit
   `sequence`;
3. **first burst after load** of this Document instance (cheap robustness:
   every session contributes at least one ordering anchor).

Otherwise the burst carries `sequence: nil`. No other emit site changes:
`Bootstrap.run` always carries `sequence` (`Bootstrap.swift:54`) — load-bearing,
see 4.4; `reorder(sequence:)` (`Document.swift:566`) by definition carries it;
annotation/task/rewind ops already carry `nil`.

### 4.2 `orderingDirty` tracking

A `private var _orderingDirty: Bool` on `Document` (alongside `_pendingSweep` —
same lifecycle shape, per-instance, not persisted):

- Set in `setFullText` when `sequenceChanged` (the existing flag,
  `Document.swift:398`) is true; set by `insertParagraph`/`deleteParagraph`
  (`Document.swift:531-550`) and any other in-place `sequence` mutator.
- Cleared in `flushBurstNow` after a successful append of a sequence-bearing
  op (on append *failure* it stays set — the durable pending-buffer re-flush
  path from M1.1 must not lose the ordering signal).
- The crash-recovery op minted in `Document.load` (`Document+Load.swift:226-230`)
  keeps capturing `sequence` from the parsed `.md` unconditionally — it is a
  recovery op; correctness over bytes.

`PendingBuffer` is unchanged (it buffers `ParagraphChange`s; ordering is
Document state).

### 4.3 Why the deriver needs no change

`Deriver.derive` already treats `sequence: nil` as "carry forward the last
explicit sequence" (`Deriver.swift:62-78`). The rewind prefix variant
(`Deriver+Rewind.swift`) folds prefixes of the opId-ordered timeline: any
prefix of a keyframed log contains the bootstrap op (which carries `sequence`),
and every ordering *change* carries `sequence` by rule 1 — so state-at-cursor
ordering is exact at every cursor, not approximated.
`deriveWithSequenceFallback`'s first-appearance synthesis remains a
legacy-logs-only path (logs that predate the always-capture fix).

### 4.4 The empty-sequence recovery signal is preserved

`Document.load` uses "derived sequence is empty" as the trigger for its
on-disk-`.md` legacy recovery (`Document+Load.swift:23-47`). Under keyframing a
fresh log's op #1 is still a sequence-bearing bootstrap op, so a keyframed log
can never present empty-sequence-with-nonempty-paragraphs. No change to the
recovery branch; a regression test pins it (4.6 T5).

### 4.5 Cross-device behavior note (improvement, must be pinned)

Today every burst stamps a full — possibly stale — `sequence`; a text-only
burst on device A whose opId sorts after device B's concurrent reorder
**reverts B's reorder** at merge. Under keyframing A's text-only burst carries
`nil` and B's reorder survives. This is strictly closer to intent; T4 pins it
so nobody "fixes" it back.

### 4.6 Tests (M1)

| # | Test | Asserts |
|---|---|---|
| T1 | `SequenceKeyframingTests.test_textOnlyBurst_omitsSequence` | typing without reorder → burst op `sequence == nil` |
| T2 | `…test_orderingChange_capturesSequence` | paragraph add / delete / split / merge / reorder → next burst carries `sequence` |
| T3 | `…test_keyframedLog_derivesIdenticalToFullCapture` (parity, the M0-harness shape) | same edit script with keyframing on/off → byte-identical `derive` output AND identical `derive(ops:upTo:)` at **every** cursor |
| T4 | `…test_concurrentReorder_survivesTextOnlyBurstMerge` | cross-device: B reorders, A (later opId) types text-only → merged derive keeps B's order (pins 4.5) |
| T5 | `…test_freshLog_neverTriggersEmptySequenceRecovery` | keyframed fresh log loads without entering the legacy `.md`-recovery branch |
| T6 | `…test_keyframeFloor_emitsEveryNth` | 50+ sequence-less bursts → floor keyframe emitted |
| T7 | `…test_appendFailure_preservesOrderingDirty` | injected append failure (existing seam `OpLogStore.appendFailureForTesting`) → next successful flush still carries `sequence` |

Files touched: `Maugham/OpLog/Document.swift` (+`Document+Load.swift` comment),
`MaughamTests/`. MaughamCore: none. Phone: none (phone never writes bursts).

## 5. Phase 2 / M2 — Sealed compressed segments

### 5.1 Naming and container

A sealed segment of doc `<docId>` owned by device `<slug>` is:

```
.maugham/ops/<docId>.<slug>.seg<NNNN>.mzseg        NNNN = 0001, 0002, … per (docId, slug)
```

Container layout (binary, little-endian):

| Field | Size | Value |
|---|---|---|
| magic | 4 | `"MZS1"` |
| algorithm | 1 | `1` = LZFSE (Apple Compression framework; `2` = LZMA reserved) |
| reserved | 3 | zeros |
| uncompressedByteCount | 8 (u64) | length of the original JSONL bytes |
| sha256 | 32 | digest of the **uncompressed** JSONL bytes |
| payload | … | compressed JSONL bytes (byte-exact tail content at seal time) |

New MaughamCore type `OpLogSegment` owns encode/decode/verify (CryptoKit +
Compression — both Apple system frameworks, satisfying the MaughamCore
no-third-party rule; both available on iOS for the phone's read path).

The distinct `.mzseg` extension is deliberate: existing `.jsonl` recognizers
(`docId(fromOpLogFilename:)`, the conflict-twin regex
`IntegrityChecks.conflictTwins`, the pending-buffer exclusion) are untouched by
construction. Segment recognition is added **only** to the single-source
helpers (5.3).

### 5.2 Seal procedure (device-local; correctness from dedupe, not ordering)

Only the **owning device** seals **its own tail** — sealing is a rewrite of a
single-writer file, the exact case ADR 0012 makes conflict-twin-free.
Triggers: `Document.close()` (after the final burst flush) and project-open
maintenance, **never mid-typing**. Mac-only in v1 (`MaughamPhone` never seals;
its annotation files stay small). The legacy unsuffixed `<docId>.jsonl` is
**never sealed** — it has had no writer since ADR 0012 (frozen, bounded) and
has no unambiguous owner; sealing it from two Macs would race.

When the live tail `<docId>.<slug>.jsonl` exceeds `segmentSealThreshold`
(constant, default **512 KB**):

1. Coordinated read of the tail. If `loadDiagnosed` reports any skipped line →
   **abort the seal** (leave the tail for the existing quarantine path; never
   bake a torn line into a checksummed segment).
2. Build the container over the tail's exact bytes; write to a temp file in
   `.maugham/ops/`; atomic-rename to `…seg<NNNN>.mzseg` where NNNN =
   max existing + 1 for this (docId, slug). Never overwrite an existing
   segment file.
3. Coordinated **delete** of the tail file (next append recreates it via the
   existing `JSONLAppendStore.append` create branch).

**Crash safety is by construction, not by care:** if the process dies between
steps 2 and 3, the same ops exist in both the segment and the tail — and
`OpLogStore.mergeSortedDedup` collapses them by opId. A half-written temp file
is ignored (wrong extension after no rename). Re-running the seal later
re-converges (next seal sees the still-oversized tail; duplicate ops keep
deduping in the interim). T10 pins the crash-window parity.

### 5.3 Read path

All in MaughamCore, at the existing single-source choke points
(`cross-surface-contracts.md` registry entries updated in the same commit):

- `OpLogStore.opLogFileURLs(forDocId:in:)` — also matches
  `<docId>.<slug>.seg<NNNN>.mzseg`.
- `OpLogStore.docId(fromOpLogFilename:)` — recognizes `.mzseg` names (docId =
  component before the first `.`, unchanged rule).
- `loadDiagnosed` / `loadSyncMerged` — for `.mzseg` URLs: verify magic +
  checksum, decompress, then parse with the **same** JSONL parser. The merged
  result flows through `mergeSortedDedup` exactly as today; every consumer
  still sees one `[Op]`.
- **Checksum mismatch / decompress failure** → best-effort salvage (if
  decompression yields bytes, parse what decodes) + record via
  `IntegrityQuarantine` + surface in `ParseDiagnostics.skipped` so
  `ProjectIntegrity.check` marks the doc unhealthy and **backups pause**
  (existing v0.8.0 behavior — corruption must not propagate).

The phone gets segment reading for free through these shared helpers (its
annotation/task readers already call `loadSyncMerged`/`opLogFileURLs`).

### 5.4 Integrity / backup / presenter interplay

- `ProjectIntegrity.check` builds `opsByDoc` through the same loader → opIds
  inside segments stay visible to the dangling-checkpoint-pointer check (no
  false positives — the check that compaction would have broken).
- `MerkleManifest` / `BackupSignature` hash files as files: a seal is a
  one-time file-set change → exactly one extra backup generation per seal.
  Accepted and documented; sealed segments are immutable thereafter, so
  skip-unchanged gets *more* stable, not less.
- Presenter: on the sealing device, the op-log mirror guard is opId-set-based
  → tail delete + segment appear is a no-op re-derive. On other devices,
  `handleExternalLogChange` re-derives the identical op set → no-op (T11).

### 5.5 Tests (M2)

| # | Test | Asserts |
|---|---|---|
| T8 | `OpLogSegmentTests.test_roundTrip` | container encode → decode → byte-identical JSONL; checksum verifies |
| T9 | `OpLogStoreSegmentTests.test_parityAcrossSeal` (extends `OpLogStorePartitioningParityTests`'s invariant) | derive over (segments + tail) == derive over the same ops in one file |
| T10 | `…test_crashBetweenSealAndTruncate_dedupes` | segment + un-truncated tail with overlapping ops → identical derive; subsequent seal converges |
| T11 | `…test_sealIsDeriveNoOp_acrossPresenter` | external-change delivery after a remote seal → no text/sequence change |
| T12 | `…test_tamperedSegment_quarantinedNotSilent` (ADR 0016 enforcement) | flipped byte → `IntegrityQuarantine` record + unhealthy report + backup paused; salvageable ops still derived |
| T13 | `…test_tornTail_abortsSeal` | tail with a skipped line → no segment written, tail untouched |
| T14 | `…test_legacyFile_neverSealed` + `…test_phoneNeverSeals` (phone target) | scope rules hold |
| T15 | `IntegrityChecksTests` extension | dangling-pointer check resolves opIds inside segments; `.mzseg` never flagged as conflict twin |

Files touched: MaughamCore (`OpLogSegment` new, `OpLogStore`,
`JSONLAppendStore` untouched), Mac seal trigger in `Document.close()` +
project-open maintenance, `TripwirePhoneGrepTest`/`TripwireGrepTests` additions
(no hand-rolled `.mzseg` name templates outside `OpLogStore`), AREA.md +
contracts-registry updates.

## 6. Phase 3 / M3 — Derived-state cache (conditional on Phase 0 budgets)

Ships **only if** the post-M2 load-time budget (§3) is violated.

- Location: `.maugham/cache/derived/<docId>.json` — a new
  `MaughamSidecarPath` class routed as **ignore** (presenter no-op), classified
  *Derived* in the backup table (never in essential backups; restore never
  reads it).
- Content: `{ key, schemaRev, paragraphs, sequence }`. **Key** = SHA-256 over
  the sorted `(filename, byteSize)` pairs of every op-log file for the doc
  (segments are immutable; the tail is append-only, so size moves on every
  append; a seal changes the file set) + a cache-format revision.
- Read at exactly one site: `Document.load`'s initial derive. Key match → use
  snapshot; miss/parse-fail/anything → full derive, then rewrite the cache
  (write-behind, `try?` — a failed cache write is a non-event by design).
  Refreshed after `handleExternalLogChange` re-derives and at `close()`.
- **Never truth:** rewind, integrity, merge, materialize, and the phone never
  read it. Enforcement: a grep tripwire (no `cache/derived` reference outside
  `Document+Load` + the store helper) and T17.

| # | Test | Asserts |
|---|---|---|
| T16 | `DeriveCacheTests.test_deleteCache_rederivesIdentical` (ADR 0016 enforcement) | rm cache → next load byte-identical state |
| T17 | `…test_staleCache_neverWins` | hand-corrupt cache content with a stale key → ignored, full derive runs |
| T18 | `…test_integrityAndRewind_neverReadCache` | poisoned cache + healthy log → integrity report + rewind output unaffected |

## 7. Docs / tripwire deltas (land with each milestone)

- `Maugham/OpLog/AREA.md`: append-only invariant gains one sentence — *sealing
  is a storage-layout change to a single-writer file; the logical log is
  untouched*; new "segments" subsection; keyframing rule beside the
  merge/derive contract (`sequence: nil` = unchanged-by-construction, not
  legacy-only, from M1 on).
- `cross-surface-contracts.md`: `.mzseg` recognition added to the
  `opLogFileURL`/`docId(fromOpLogFilename:)` shared-impl rows.
- CLAUDE.md tripwire 17 footnote: sealing is safe *because* of per-device
  partitioning; **never seal the legacy unsuffixed file or another device's
  file** (enforced by T14).
- Roadmap: mark the ADR 0016 growth-plan item with per-phase status as
  milestones land.

## 8. Sequencing & exit criteria

| Milestone | Gate to start | Exit criteria |
|---|---|---|
| M0 fixture + baseline | — | metrics table recorded in the milestone note; budgets confirmed/adjusted |
| M1 keyframing | M0 baseline exists | T1–T7 green both schemes; fixture re-run shows sequence share < 5% of new-write bytes |
| M2 segments | M1 shipped | T8–T15 green both schemes; fixture drafting-month < ~1 MB/doc; one-generation backup blip observed and documented |
| M3 cache | only if post-M2 load > budget | T16–T18 green; load within budget; cache deleted ad lib in the smoke with no behavior change |

Manual smoke (per CLAUDE.md format) after M2: draft in a screenplay project
past the seal threshold, ⌘Q, relaunch, verify text + full History Rewind back
through sealed history + a Restore from inside a sealed segment's range.

## 9. Open questions (resolve during M0/M1, none block Phase 0)

1. Keyframe floor value (50) and seal threshold (512 KB) — confirm against the
   Phase 0 baseline rather than bikeshedding now.
2. Should project-open maintenance seal *all* eligible docs or only on close?
   (Default: both, idempotent; revisit if open-time cost shows up in M0.)
3. LZFSE vs LZMA default — measure ratio/speed on the fixture corpus in M0;
   container already carries the algorithm byte either way.
