# 0019 — Manuscript files on disk are clean Markdown/Fountain (anchors live only in the op log)

- **Status:** Accepted
- **Date:** 2026-06-29
- **Design detail:** `docs/superpowers/specs/2026-06-29-clean-md-on-disk-design.md`
- **Builds on:** ADR 0018 (manuscript reads always derive from the op log)

## Context

Maugham's manuscript files carried Maugham's internal join-keys inline — own-line
`<!-- ¶id -->` paragraph anchors and mid-line `<!--t-XXXXXX-->` task anchors —
because, historically, things read the file *back* and needed those anchors to
re-join its paragraphs/tasks to the op log. That made `chapter.md` a non-standard
file (noisy to read, ugly in `git diff`, awkward in pandoc / other editors) — a
wart on the app's "plain text on disk, full stop" promise.

ADR 0018 stopped every consumer from treating the file as *truth*: manuscript
content, paragraph `sequence`, and anchors now derive solely from the op log.
(One reader of the file remains — the phone's Read tab renders the on-disk `.md`
for display — but it consumes the file as a *derived render*, not as truth; it's
a contracted divergence, registered in the 2026-07-01 addendum below and in
`docs/superpowers/notes/cross-surface-contracts.md`.) With nothing reading the
anchors back as join keys, they no longer need to live in the file.

## Decision

**Write manuscript files clean** — the editor's display form,
`MarkdownDisplayFilter.stripAnchors(materialize())`, which strips BOTH the
`¶id` paragraph anchors and the `t-` task anchors in one pass. The anchored truth
(the join keys) lives only in the op log and the in-memory editor representation.

Scope: **clean OUTPUT only**. Editing stays Maugham-only; an external edit to a
manuscript file is still discarded on re-materialize (the existing invariant).
Round-tripping external edits back into the op log is explicitly NOT in scope.

The load/recovery path takes a **clean cutover**: the `.md` is no longer read for
content, sequence, or anchors for an existing doc. To make the op-log domain
self-sufficient for crash recovery (the file's last remaining job was recovering
the order of un-flushed reorders), `PendingBuffer` now also durably records the
current `sequence`, so the crash-recovery op captures order from the pending
buffer, not the file. The bootstrap signal moves from "the `.md` has no anchors"
to "the op log is empty," so an existing doc never re-bootstraps from its now
anchor-less file while a new/imported file still bootstraps.

Migration is **lazy**: a file is rewritten clean on its next autosave; untouched
files keep their anchors harmlessly (load reads the op log either way).

## Consequences

- **Manuscript files are standard Markdown/Fountain** — readable, `git diff`-clean,
  pandoc-able. The "plain text on disk" promise is fully kept.
- **The op log + pending buffer are the complete truth.** Neither content,
  sequence, nor anchors are read from the `.md` for an existing doc — extends
  ADR 0018 to `Document.load` itself.
- **The remaining `.md` reads in `Document.load` are the import-bootstrap (a
  new/imported file when the op log is empty) and the echo-guard comparison** —
  both the file-as-initial-input / comparison-reference category, not truth.
  These stay consistent with the ADR 0018 tripwire.
- **The CLAUDE.md "inline `¶id` anchors are the join key" invariant is refined:**
  the anchors are the join key in the **op log and in-memory**, not on disk. The
  on-disk file is a clean derived render.
- **Task anchors come free** — the same `stripAnchors` pass removes them; ADR 0018
  Task 6 already routes task derivation through the op log, so inline tasks still
  derive/toggle/reorder with the file carrying no `t-` anchors.
- **Annotations are unaffected** — they were never inline in the `.md` (op-log
  annotation layer).
- **Visible in git/files:** each edited file's next commit drops its anchor lines
  (a one-time-per-file diff). Lazy migration spreads this out rather than a mass
  rewrite.
- **No manuscript data changes** — content is identical; only internal markers
  leave the file.

## Addendum (2026-06-29) — external `.md` edits are silently discarded; the conflict-sheet machinery is removed

Implementing clean files made the old `.md` conflict sheet both wrong and
universal: with no anchors on disk, `Reconciler.classify` returned `.needsSheet`
for *every* external edit, popping a cross-device conflict sheet that — per the
hard invariant — should never honor an external `.md` edit anyway.

Root-causing this confirmed the sheet was **vestigial**: cross-device conflict
resolution flows entirely through the op-log merge (`handleExternalLogChange`,
which explicitly shows no UI), not through the `.md`. A change to the manuscript
file is only ever a writer editing it in another app (or iCloud delivering
another device's stale derived render) — which the invariant discards.

So `handleExternalDiskChange` now: echo-guards, no-ops if the disk already
matches our clean render, else **snapshots the external bytes forensically under
`.maugham/conflicts/` and re-materializes the op-log truth over them** — the edit
is discarded, the op log is untouched, no UI appears. The now-dead machinery was
removed: `Document.pendingConflict`, `ConflictState`, `ConflictBanner`,
`ConflictDiffSheet`, `LineDiff`, and `resolveConflictKeepMine` /
`resolveConflictUseExternal` / `handleExternalDiskChangeForceIngest`. The
backup-on-discard is retained as a safety net so an *accidental* external edit is
recoverable. `Reconciler.classify` is left in place but uncalled (future
dead-code sweep). The `.silentIngest` path (which had *honored* anchor-intact
external edits — itself a latent contradiction of "external edits not honored")
is gone; all external `.md` edits are now uniformly discarded regardless of
migration state.

## Addendum #2 (2026-07-01) — op-log-spine hardening: recovery gaps, backup completion, distributed inertness

An adversarial review of the ADR 0018 + 0019 landing found silent gaps the test
suite didn't cover (spec `docs/superpowers/specs/2026-07-01-oplog-spine-hardening.md`).
The clean-cutover to op-log-domain load/recovery was correct but had holes at the
edges. Fixed:

- **Ordering-only edits now reach the op log (F1).** Deleting or reordering a
  paragraph without any text change recorded nothing in the pending buffer, and
  `flushBurstNow` gated all op emission on a non-empty buffer — so a
  delete-then-quit emitted no op and the paragraph *resurrected* on next load
  (pre-0019 the anchored `.md` had silently covered this). Now `flushBurstNow`
  emits a **sequence-only `typing_burst` op** — empty `changes`, explicit
  `sequence` — when the buffer is empty but ordering changed, and `Document.load`'s
  recovery fold *also* fires when the pending file carries no changes but a
  `sequence` that **differs** from the op-log-derived sequence. The difference
  check is load-bearing, not incidental: `performAutosave` stamps the current
  sequence on every 750ms flush and `close()` re-creates the pending file after
  the burst flush, so a `{sequence, changes: []}` pending file is the **normal
  post-quit state** — folding unconditionally would append a junk op every launch.
  The Deriver's junk-skip stays `.bootstrap`-kind-only; an empty-changes
  `typing_burst` is honored for its sequence.

- **The F1 gate is a since-load flag, not `_orderingDirty` (Issue 1, hardening).**
  The first cut gated the sequence-only burst arm on `_orderingDirty`, which
  **inits `true`** to anchor the first burst's keyframe — so an UNTOUCHED
  open/close saw it set and appended a junk `{changes: [], sequence}` op on every
  cycle. Because transient `Document` loads are everywhere (MCP `list_annotations`
  / `get_annotation`, task reads, wiki-rename, search-replace, binder navigation),
  this turned read-only paths into op-log writers, and that junk op's newest-ULID
  explicit sequence could revert a peer device's not-yet-synced delete/reorder. The
  arm is now gated on a separate `_orderingChangedSinceLoad` (inits `false`, set
  only at the genuine delete/reorder/insert sites, cleared alongside
  `_orderingDirty` after a successful sequence-bearing append); `_orderingDirty`'s
  init-true keyframe semantics for the text-change arm are untouched.

- **Clean close leaves no pending file; the recovery fold is basis-aware
  (Issue 2, hardening).** A clean `close()` used to leave a `{sequence, changes: []}`
  mirror on disk (the trailing autosave re-created it after the burst flush cleared
  it). If a peer's ops (e.g. a delete) then synced in while the doc was closed, the
  next load saw `derived(merged) != S_local` and the empty-changes fold appended a
  newest-ULID op reasserting `S_local` — reverting the peer's deletion. Two-part
  fix: **(a)** a successful `close()` clears the pending file once more, so a clean
  quit leaves NO pending file (the `{seq, []}` mirror has zero recovery value once
  the burst flushed); a FAILED burst flush keeps it (it is the recovery source).
  **(b)** `PendingBuffer`'s on-disk state gains an optional `basis` — the opId of
  the newest op the writer had folded when the sequence was stamped. At load, if
  `basis` is present and no longer equals the merged log's newest opId, the pending
  sequence is stale relative to ops it never saw: the empty-changes fold is
  **skipped**, and a non-empty-changes recovery fold still recovers the text but
  attaches `sequence: nil` (the deriver carries the last explicit sequence forward).
  Legacy pending files (no `basis`) keep prior behavior for non-empty changes and
  are treated as stale for empty changes (skip — the safer default; they predate
  the sequence field anyway).

- **Anchored file + empty op log no longer opens EMPTY (F2).** Lazy migration
  leaves anchored files around indefinitely; if the op log was then lost (crash
  between Bootstrap's `.md` write and its op append, a deleted `.maugham/`, a
  backup restore missing the hidden dir), `Bootstrap.run`'s `allHaveIds` branch
  returned without emitting an op — the doc derived from zero ops and opened
  empty, and the first autosave (or an MCP `add_note`) clobbered the manuscript
  with the empty render. Now that branch, when the op log is empty, **seeds a
  bootstrap op + initial checkpoint from the anchored file's EXISTING ids**
  (identity preserved; the `.md` is NOT rewritten). With F2 fixed at the source,
  the old `reconcile` `.md`-anchor rescue branches were provably dead and were
  deleted — `reconcile` is now `reconcile(derived:)` and does only orphan-drop
  (a paragraph in the map but not in `sequence`).

- **Backup-on-discard is now complete — the while-closed hole is closed (F4).**
  The addendum-#1 discard net covered only *live* presenter events; a file edited
  while Maugham was **closed** was silently overwritten by the first autosave with
  no snapshot. `Document.load` now takes a **load-time divergence snapshot**: when
  a log exists (not the bootstrap path) and
  `stripAnchors(storedBytes) != stripAnchors(materialize(derived))`, the external
  bytes are written to `.maugham/conflicts/` (kind `diverged`) *before* anything
  can overwrite them. The comparison is on display forms so an unmigrated
  still-anchored file doesn't false-positive; the write dedups against the newest
  existing backup for the doc (byte-equality) so repeated open/close of an
  unchanged divergent file doesn't accumulate copies. Conflict backups now root
  via `resolveProjectURL` (walk up to the manifest), so a **Collection piece's**
  backups land under the project root, not `pieces/.maugham/conflicts/` where
  nothing looks (F8). `performAutosave` also stopped swallowing pending-flush
  failures via `try?` — the pending file is the sole crash-recovery source.

- **Ping-pong damping + conflicts retention + new filename (F7).** When op-log
  sync lags the `.md` (iCloud's normal failure mode) or a version-skewed device
  writes anchored files, the discard handler could bounce rewrites indefinitely.
  Now the handler counts **distinct-byte** discards per session; after
  `discardDampThreshold` (3) it stops auto-rewriting (still snapshots, op log
  stays authoritative in memory) and logs once — a local edit resets the counter.
  `.maugham/conflicts/` is capped at the newest **20 per docId**, pruned on every
  write. Backup filenames are now `<stem>-<docId>-<kind>-<stamp>.<ext>`; the
  `docId` prevents two same-stem Collection pieces from cross-pruning each other.
  (Old-format backups from before this change linger unpruned — accepted under the
  no-migration rule.)

- **Partial-sync re-mint is now inert (F3, first-bootstrap-wins).** Post-migration
  files are clean, so "op log is empty" is the sole bootstrap signal; iCloud
  delivering the `.md` before `.maugham/ops/` made device B re-mint every `¶id`,
  and the real log merging in then read all original ids as removed and
  mass-archived every paragraph-anchored annotation. The **Deriver now honors only
  the first `.bootstrap` op** (ULID order); for any later one it **skips the
  sequence** (it must not win ordering) but **keeps the changes** (Minor 4, in both
  `derive` and `deriveWithSequenceFallback`, logged), so a re-mint is inert once
  the real log syncs in. Keeping the text (rather than dropping it, as the first
  cut did) matters for the worst case: a re-mint followed by an edit that carries
  an explicit sequence of the re-minted ids would otherwise point the ordering at
  ids with no text and render the doc near-empty; keeping the changes degrades that
  to content-preserved-under-new-ids (an annotation archive) instead of data loss.
  **Residual risk (known limitation):** with no post-re-mint edit the kept re-mint
  texts are orphan paragraphs (ids not in the surviving sequence) that
  `Document.reconcile` drops; with a post-re-mint edit annotations on the original
  ids are orphaned — both rarer and smaller than the annotation mass-archive this
  prevents. **Clock-skew winner inversion (accepted):** first-vs-later is by opId
  (ULID), whose high bits are wall-clock, so a behind-clock device's re-mint can
  sort BEFORE the original and win; single-editor by ethos makes concurrent
  bootstraps near-zero-risk, so this is accepted rather than gated. A true fix
  needs a bootstrap tombstone that syncs ahead of `ops/`, and no such channel
  exists.

None of these change the ADR 0019 decision — clean output, op-log-domain
recovery, external edits discarded. They harden the recovery and discard paths
the clean cutover created.
