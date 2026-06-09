# 0016 — Op-log growth without compaction: keyframed sequence + sealed compressed segments + derive cache

**Status:** Accepted (design; not yet implemented)
**Date:** 2026-06-09

## Context

The roadmap carried an "Op-log compaction (Automerge/CRDT-style)" item: snapshot
derived state, truncate ancient ops into a compacted base, keep recent ops for
rewind. The 2026-06-09 quality audit assessed it as the one roadmap item that
*fights* the architecture: it directly contradicts the append-only invariant
("No mutation, no deletion" — `Maugham/OpLog/AREA.md`), and its blast radius is
large — pre-horizon `RewindCursor` scrubbing breaks, `Checkpoint.docPointers`
into truncated history dangle (the v0.8.0 dangling-pointer integrity check
would false-positive on healthy compacted logs), Merkle/content signatures
churn on every compaction (spurious full re-backups), and a compacted base is
a new shared writer unless it is itself partitioned — re-opening the
conflict-twin class ADR 0012 closed.

Examining what actually grows reframed the problem. "Unbounded op-log growth"
is three separable costs:

1. **Disk bytes.** Every typing-burst op (one per 30s-idle/90s-max while
   typing) carries full `prior`+`next` text of touched paragraphs — that part
   is the history we want and is bounded by human typing speed — **plus the
   entire `sequence` array, unconditionally** (`Document.flushBurstNow`,
   `Document.swift:584-591`). For per-chapter novel docs the sequence is ~1-2KB;
   for the single-file screenplay (nearly every line a paragraph) it is tens of
   KB of *identical ordering data* duplicated onto every burst. Redundancy, not
   history, dominates.
2. **iCloud sync churn.** Each append makes iCloud re-upload the entire
   ever-growing per-device JSONL. Cost per keystroke-burst grows with total
   history size.
3. **Derive/load time.** `Deriver.derive` replays all ops at every load and
   external-change delivery. This is the only cost compaction's "base state"
   genuinely addressed.

None of the three requires deleting history.

## Decision

**Reject compaction/truncation outright. Keep the op log append-only and
complete, and attack the three costs separately:**

1. **Sequence keyframing (write less at the source).** Emit `sequence` on a
   burst op only when the ordering actually changed since the last flushed
   burst, plus a periodic keyframe (every Nth op) for robustness. `Op.sequence`
   is already `Optional`; the deriver already carries forward the last-seen
   sequence across ops that omit it; `setFullText` already computes
   `sequenceChanged` (`Document.swift:398`) — it just isn't consulted at flush
   time. Rewind stays exact: state-at-cursor uses the last sequence at or
   before the cursor, which is correct precisely because it didn't change.
2. **Sealed compressed segments (storage layout, not truth).** When a device's
   per-doc partition file crosses a size threshold, rotate it: the closed
   segment becomes immutable, is compressed with Apple's Compression framework
   (LZFSE or LZMA — MaughamCore stays Apple-frameworks-only), and carries a
   checksum. The live tail stays small, plain JSONL. Sealing is a device-local
   rewrite of the device's *own* partition file — the exact single-writer case
   ADR 0012 makes conflict-twin-free by construction. Readers
   (`OpLogStore.opLogFileURLs` glob + load) decompress-and-concatenate segments
   with the live tail; every consumer still sees one `[Op]` array.
3. **Derived-state cache (cache, not base).** A snapshot of the derive result
   under `.maugham/cache/`, keyed by a hash of the log tip, invalidated freely,
   rebuilt on any miss. Pure cache: deletable at any time, never consulted as
   truth, so rewind, integrity checks, and checkpoint pointers are untouched.
   (This is deliberately what `Checkpoint` is *not* — checkpoints are pointers
   into history, not materialized state.)

Sequence keyframing is the highest-leverage piece and lands first; segments
second; the cache only if the 100k-word perf fixture shows load-time pain.
All three are gated on **measuring first**: the perf-pass fixture (100k words /
5000 paragraphs) quantifies which terms dominate before any implementation.

## Consequences

### Positive

- **The append-only invariant survives untouched.** Full history, full-fidelity
  rewind to op #1, no compaction horizon, no new coupling between rewind depth
  and backup generations.
- **Zero impact on the integrity/backup layer's semantics** — and segments
  actively help it: immutable inputs make the skip-unchanged content signature
  and Merkle manifests stable instead of churning.
- **Sync traffic drops from O(total history) to O(live tail) per burst.**
  Sealed segments upload to iCloud once, forever. This is arguably the bigger
  win than disk bytes.
- **Per-segment checksums close most of the torn-append exposure** (2026-06-07
  audit finding 0.6) for everything except the live tail — a second open
  finding partially retired by the same mechanism.
- **Keyframing is backward- and forward-compatible.** Old readers already
  handle `sequence: nil` (legacy pre-capture-fix logs exercised this path);
  old logs need no migration (tripwire 11: none would be written anyway).
- JSONL of prose with repeated keys and near-duplicate paragraph snapshots
  compresses on the order of 10–20×; combined with keyframing, a full novel's
  lifetime history should stay in single-digit MB.

### Negative / limitations

- **Three small mechanisms instead of one big one.** Each is individually
  simple, but the read path gains a decompress step and the write path gains a
  rotation policy — more moving parts than "never touch the log," fewer than
  compaction.
- **Sealing rewrites a file the integrity layer knows.** The Merkle manifest
  and backup signature must treat `tail → sealed segment` as the planned,
  recognized transition (one-time signature change per seal), not corruption.
- **Keyframe cadence is a tunable** — too sparse and a reader that lost a
  middle segment reconstructs ordering from further back; per-segment
  checksums plus the keyframe-every-Nth-op floor bound this.
- **Derive time is only fixed by the cache**, which is the one piece that adds
  a staleness-invalidation surface. Keeping it a pure deletable cache (never
  truth) is the guard; it must never be consulted by integrity checks, rewind,
  or merge.
- Does **not** address skew-aware LWW / conflict surfacing — explicitly the
  collaboration milestone's scope, unchanged by this ADR.

### What this supersedes

The roadmap's "Op-log compaction (Automerge/CRDT-style)" item (Group 4,
surfaced in the 2026-06-07 backup brainstorm) is **withdrawn**. Its stated
goals — bound op-log growth, shrink backups, cut derive time — are met by the
three mechanisms above without truncating history. If a future need genuinely
requires truncation (e.g. regulatory deletion), that is a new ADR with the
checkpoint/rewind/integrity interactions specced up front.

## Enforcement / verification

- `OpLogStorePartitioningParityTests`' invariant extends to segments:
  derivation over (sealed segments + tail) must equal derivation over the same
  ops in a single file.
- A keyframing test: a log whose bursts omit unchanged `sequence` derives
  byte-identical text and identical rewind states at every cursor as the same
  log with `sequence` on every op.
- A seal-then-tamper test: a sealed segment with a flipped byte fails its
  checksum and is quarantined via the existing `IntegrityQuarantine` path —
  never silently skipped.
- The derive cache ships with a "delete the cache, derive again, byte-identical"
  test, and integrity checks assert they never read it.

## Related

- ADR 0012 (per-device JSONL partitioning) — sealing is safe *because of* the
  single-writer-per-file guarantee; this ADR builds on it.
- ADR 0014 (backup & integrity) — segments interact with the content signature
  and Merkle manifest; the seal transition must be recognized, not flagged.
- `docs/superpowers/notes/2026-06-09-quality-maintainability-audit.md` §4 — the
  blast-radius assessment that prompted this decision.
- 2026-06-07 audit finding 0.6 (non-atomic append) — partially retired by
  per-segment checksums; the live-tail framing remains a separate item.
