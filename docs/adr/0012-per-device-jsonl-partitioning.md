# 0012 — Per-device JSONL file partitioning for multi-writer sidecars

**Status:** Accepted
**Date:** 2026-05-24

## Context

The op log (`.maugham/ops/d_<docId>.jsonl`) and the new inbox manifest (`.maugham/inbox/inbox.jsonl`, added for the iPhone companion) are append-only JSONL streams that act as the source of truth for derived state. Both were originally designed under a single-writer assumption: one Mac process per project window appends; cross-Mac sync was theoretically supported but rarely exercised by the same user simultaneously.

The iPhone companion introduces a second routine writer to the same files: the phone appends `claudeAccept` / `claudeReject` / `claudeArchive` to the op log and `InboxEntry` rows to the inbox manifest. These writes routinely overlap with Mac-side work (voice capture on phone while paragraph-deletion sweep runs on Mac; reject on phone while accept on Mac).

`NSFileCoordinator` serializes writes within a single device. It does **not** coordinate across devices through iCloud Drive: iCloud's reconciler (`bird`/`cloudd`) runs at daemon level and is oblivious to NSFileCoordinator semantics on the other device. When two devices both append to the same file within an iCloud sync window:

1. iCloud detects divergence (both devices have a "newer than the last common version" file).
2. The reconciler resolves by *whole-file replace*, not line-merge.
3. The loser's copy lands as a conflict-named twin alongside the canonical file: `d_<docId> 2.jsonl`, `d_<docId> (iPhone).jsonl`, or similar (iCloud's exact naming convention varies by macOS/iOS version).
4. `OpLogStore.load(docId:)` opens exactly one path. Twin files are invisible. The loser's ops are silently lost.

Maugham already acknowledges iCloud conflict creation for `.md` files (`Document.swift:1030-1037`, `writeConflictBackup`); the JSONL story was never specced because there was only one writer per file. Adding a second writer requires a structural fix, not a per-conflict handler — a `.md` conflict surfaces to the user via a diff sheet, but a silently-lost op gives the user no signal at all.

A latent form of this bug exists today for Mac↔Mac sync but is rarely triggered. The phone makes it routine.

## Decision

**Each device writes to its own file; readers glob and merge.**

| Today | After |
|---|---|
| `.maugham/ops/d_<docId>.jsonl` (one file, all writers) | `.maugham/ops/d_<docId>.<deviceSlug>.jsonl` (one file per writer) + legacy `d_<docId>.jsonl` continues to load |
| `.maugham/inbox/inbox.jsonl` (one file, all writers) | `.maugham/inbox/inbox.<deviceSlug>.jsonl` (one file per writer) + legacy `inbox.jsonl` continues to load |

Two devices can never target the same file path, so iCloud never has to reconcile divergent versions of the same file. Conflict-twins are impossible by construction. Files are only touched by their owning device; other devices see them as read-only siblings to fold into their merge.

**`deviceSlug` is derived from `Document.device`** (the existing per-install identifier, `Document.swift:106`), sanitized to a filename-safe form (likely lowercased UUID-no-dashes). Stable per install across launches so a device's own files stay addressable to itself.

**Source of truth is unchanged.** The logical op log remains "the merged, opId-sorted, opId-deduped set of all ops." It's just assembled from multiple files at load time instead of being identified with one file. Per the existing `OpLogStore.swift:5-7` comment: *"Dedupes by `op_id` and sorts by `op_id` (timestamp-prefixed ULID gives deterministic cross-device order)."* Cross-device order is already the contract — partitioning extends it from "across writes by the same Mac across sessions" to "across writes by all devices across sessions."

**ULID is load-bearing.** ULID = `[48 bits ms-since-epoch UTC][80 bits cryptographic randomness]`. Lexically sortable, globally unique. Sort any set of ops by `opId` → same total order regardless of source file. `Deriver.derive(ops:)` already folds in opId order and doesn't care where ops came from. Swapping ULID for any non-timestamp-prefixed identifier (UUID v4, sequential int) would break this convergence; ADR 0012 commits us to ULID as cornerstone infrastructure.

**Backward compatibility.** The legacy unsuffixed file (`d_<docId>.jsonl` / `inbox.jsonl`) is one of the files included in the glob. Existing op logs and inbox manifests continue to load with zero migration. New writes go to per-device files. Per CLAUDE.md tripwire 11, no migration logic — the legacy file is left alone and continues as one of the merge sources indefinitely (or until empty and stable, at which point it could be deleted manually).

## Consequences

### Positive

- **No silent data loss** under multi-writer concurrency. The only failure mode this addresses is the most severe one in the iPhone companion's threat model.
- **No schema change.** Op records are byte-identical; only the file naming changes.
- **Storage-layout-only change.** `OpLogStore.load`/`append` and the analogous InboxStore methods are the only seams that know about partitioning. Every consumer (`Deriver`, `Document.load`, `Document.handleExternalLogChange`, `RewindWindow`, `AnnotationDeriver`) still sees a single `[Op]` array and is unchanged.
- **Free for the iCloud sync layer.** iCloud now only has to sync files with single writers — its native semantics.
- **Path forward for future multi-writer sidecars.** Anyone adding a new shared JSONL surface follows the same pattern by default (now codified in CLAUDE.md tripwire #17).

### Negative

- **File count grows linearly with device count.** One file per (device, doc) pair. For a writer with N devices over a project's lifetime (counting retired/replaced devices), N files per doc. Bounded by realistic device count, not by op rate — no directory blowup risk, but the ops directory becomes less tidy than before. Acceptable for v1; cleanup heuristics ("legacy files empty for >30 days can be archived") deferred.
- **ULID becomes cornerstone infrastructure.** Today it's documented as the basis for "cross-Mac log merge"; partitioning makes it the basis for "merge per-device files" as well. Anyone tempted to swap it for a different ID scheme has to reason about both. Documented in the decision section above and in CLAUDE.md tripwire #17.
- **`ProjectFolderPresenter` scope requirement.** New per-device files appear at runtime (a phone's first write creates a file the Mac has never seen). The presenter must subscribe at directory level for `presenterDidChangeSubitem` to fire. CLAUDE.md tripwire #7 implies this is already the case; verified during Phase B0 implementation.
- **Late-arriving ops fold into the past.** Phone offline for a week → ops come back stamped from a week ago, fold into the past at their original ULID position. Rewind history can "grow backwards." This is a property of opId-ordered convergence, not specific to partitioning; partitioning just makes it more frequent because per-device files now arrive at iCloud-propagation cadence rather than being absent entirely. State at cursor X is deterministic *given the ops the load knew about* — can become more-informed than yesterday but never inconsistent.

### What this does NOT solve

- **Annotation race semantics** (spec §5.3 Races 1 and 2) — about deriver-level interpretation of overlapping lifecycle ops, not file-level conflicts. Partitioning makes both ops survive the file system; the deriver still has to decide which lifecycle state wins.
- **Authorization for phone-side writes.** Anyone with the unlocked phone can append ops. Per-device partitioning doesn't change that. Biometric-gate-on-action is a separate concern, possibly Phase H.
- **Multi-user concurrent editing.** Maugham is single-user; ADR 0012 doesn't address shared projects between writers. iCloud Drive folder sharing is a separate scope question.

## Compile-time / runtime enforcement

- `OpLogStorePartitioningWriteTests` (spec §7.1) asserts that `OpLogStore.append` targets the writer's per-device file, not a shared file. Regression net for "someone refactored OpLogStore and accidentally restored single-file writes."
- `OpLogStorePartitioningLoadTests` asserts merge behavior across multiple per-device files + legacy file.
- `OpLogStorePartitioningParityTests` asserts that derivation over the merged-from-N-files result equals derivation over the same ops in a single file. Storage representation must not change derivation output.
- `OpLogStoreBackwardCompatTests` asserts that projects with only the legacy unsuffixed file load byte-identically to today.
- `InboxStorePartitioningTests` — parallel suite for inbox manifests.

## Related

- Spec §3.12 of `docs/superpowers/specs/2026-05-24-iphone-companion-v1-design.md` is the detailed implementation reference; this ADR is the durable decision record.
- CLAUDE.md tripwire #17 (added with the implementation) restates the rule for at-a-glance reference: *"Don't share a single JSONL file across writers via iCloud Drive."*
- ADR 0010 (typed cross-area seams) — `MaughamSidecarPath` already classifies sidecar files; the partitioning pattern fits cleanly because adding a new per-device variant doesn't add a new sidecar owner, just adds new files under existing owners.
